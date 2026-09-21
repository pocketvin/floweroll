"""Durable, bounded DAG execution for explicitly safe Host capabilities.

A batch is one ordinary Runtime Action. Its units have independent immutable
inputs and receipts, so retrying that Action never repeats verified units. This
does not bypass the existing single-action approval lane for external writes.
"""
from __future__ import annotations

import hashlib
import json
import math
import re
from copy import deepcopy
import sqlite3
import time
import uuid
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait

from . import planner_capture
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path

from .capability_registry import CapabilitySourceTarget, RegisteredCapability
from .function_execution_worker import FunctionToolError, TaskScopedFunction
from .function_tool_adapter import FunctionToolAdapter
from .mcp_driver import MCPFinalResult, MCPHTTPError, MCPProtocolError
from .mcp_execution_worker import normalize_mcp_final_result
from .planner_contracts import CapabilitySpec
from .task_capability_policy import EffectiveTaskCapabilityPolicy

BATCH_ID = "work.execute"
# Deliberately closed: registering a new provider does not authorize batching it.
SAFE_FUNCTION_CAPABILITIES = frozenset({"materials.inspect", "document.scan_pdf",
    "document.pdf_merge", "document.pdf_select", "deliverables.publish", "web.fetch",
    "coords.convert", "capability.search", "document.docx.inspect",
    "document.docx.generate", "travel.hotel.search"})
SAFE_MCP_CAPABILITIES = frozenset({
    "geocode.resolve", "geocode.reverse", "weather.query",
    "places.search", "places.search_nearby", "places.detail",
    "routes.distance", "routes.drive", "routes.transit", "routes.walk",
    "web.search",
})
SAFE_CAPABILITIES = SAFE_FUNCTION_CAPABILITIES | SAFE_MCP_CAPABILITIES
MAX_UNITS = 8
MAX_BINDINGS = 12
MAX_ATTEMPTS = 3
LEASE_SECONDS = 300


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def validate_arguments(value, schema):
    kind = schema.get("type")
    types = {"object": dict, "array": list, "string": str, "boolean": bool, "integer": int,
             "number": (int, float)}
    if (kind not in types or not isinstance(value, types[kind])
            or (kind in {"integer", "number"} and isinstance(value, bool))):
        raise ValueError("工作项参数类型不符合能力定义。")
    if kind == "number" and not math.isfinite(float(value)):
        raise ValueError("工作项数值参数必须是有限值。")
    if kind in {"integer", "number"}:
        if "minimum" in schema and value < schema["minimum"]:
            raise ValueError("工作项数值参数低于允许范围。")
        if "maximum" in schema and value > schema["maximum"]:
            raise ValueError("工作项数值参数超过允许范围。")
    if "enum" in schema and value not in schema["enum"]:
        raise ValueError("工作项参数不在允许值中。")
    if kind == "object":
        props = schema.get("properties", {})
        if not set(schema.get("required", [])).issubset(value):
            raise ValueError("工作项缺少必填参数。")
        if schema.get("additionalProperties") is False and set(value) - set(props):
            raise ValueError("工作项含有未定义参数。")
        for key, child in value.items():
            if key in props:
                validate_arguments(child, props[key])
    elif kind == "array":
        for child in value:
            validate_arguments(child, schema["items"])


def validate_argument_template(value, schema, bound_arguments):
    """Validate literals while selected top-level args come from verified deps."""
    if schema.get("type") != "object" or not isinstance(value, dict):
        raise ValueError("工作项参数必须是对象。")
    props = schema.get("properties", {})
    if schema.get("additionalProperties") is False and set(value) - set(props):
        raise ValueError("工作项含有未定义参数。")
    if set(bound_arguments) - set(props):
        raise ValueError("工作项绑定目标不是能力定义中的参数。")
    if set(value) & set(bound_arguments):
        raise ValueError("同一个参数不能同时提供固定值和依赖绑定。")
    required = set(schema.get("required", []))
    if not required.issubset(set(value) | set(bound_arguments)):
        raise ValueError("工作项缺少必填参数。")
    for key, child in value.items():
        if key in props:
            validate_arguments(child, props[key])


def resolve_json_pointer(value, pointer):
    """Resolve a bounded RFC6901-style pointer from one verified unit receipt."""
    if not isinstance(pointer, str) or not pointer.startswith("/") or len(pointer) > 400:
        raise ValueError("工作项结果绑定路径无效。")
    parts = pointer.split("/")[1:]
    if not parts or len(parts) > 12:
        raise ValueError("工作项结果绑定路径无效。")
    current = value
    for raw in parts:
        token = raw.replace("~1", "/").replace("~0", "~")
        if isinstance(current, dict):
            if token not in current:
                raise ValueError("依赖回执缺少绑定所需字段。")
            current = current[token]
        elif isinstance(current, list):
            if not re.fullmatch(r"0|[1-9][0-9]*", token):
                raise ValueError("工作项结果绑定数组下标无效。")
            index = int(token)
            if index >= len(current):
                raise ValueError("工作项结果绑定数组下标越界。")
            current = current[index]
        else:
            raise ValueError("工作项结果绑定路径不能继续解析。")
    return deepcopy(current)


class WorkUnitStore:
    def __init__(self, path: Path, *, clock=time.time):
        self.path, self.clock = str(path), clock
        with self.connect() as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("""CREATE TABLE IF NOT EXISTS work_units (
                task_id TEXT NOT NULL, unit_id TEXT NOT NULL, definition_json TEXT NOT NULL,
                digest TEXT NOT NULL, receipt_id TEXT NOT NULL UNIQUE, state TEXT NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0, owner TEXT, lease_until REAL,
                parent_action_id TEXT, output_json TEXT, error TEXT, updated_at REAL NOT NULL,
                PRIMARY KEY(task_id, unit_id))""")

    def connect(self):
        # Context manager explicitly closes; sqlite's own context only commits.
        from contextlib import contextmanager
        @contextmanager
        def connection():
            db = sqlite3.connect(self.path, timeout=15)
            db.row_factory = sqlite3.Row
            try:
                with db:
                    yield db
            finally:
                db.close()
        return connection()

    def prepare(self, task_id, definitions, *, retry_failed=False):
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            existing = {r["unit_id"]: r for r in db.execute("SELECT * FROM work_units WHERE task_id=?", (task_id,))}
            if len(set(existing) | {u["id"] for u in definitions}) > 48:
                raise ValueError("本任务工作项已达到上限，请检查重复计划。")
            for definition in definitions:
                body = encoded(definition)
                digest = hashlib.sha256(body.encode()).hexdigest()
                old = existing.get(definition["id"])
                if old and old["digest"] != digest:
                    raise ValueError("已有工作项的输入不可更改；修改内容请使用新的工作项 ID。")
                if not old:
                    db.execute("""INSERT INTO work_units
                        (task_id,unit_id,definition_json,digest,receipt_id,state,updated_at)
                        VALUES (?,?,?,?,?,'pending',?)""", (task_id, definition["id"], body, digest,
                        "unit_" + uuid.uuid4().hex, self.clock()))
                elif retry_failed and old["state"] in {"failed", "blocked"} and old["attempts"] < MAX_ATTEMPTS:
                    db.execute("UPDATE work_units SET state='pending',error=NULL,updated_at=? WHERE task_id=? AND unit_id=?",
                               (self.clock(), task_id, definition["id"]))

    def rows(self, task_id):
        with self.connect() as db:
            rows = db.execute("SELECT * FROM work_units WHERE task_id=? ORDER BY rowid", (task_id,)).fetchall()
        return [{**dict(r), "definition": json.loads(r["definition_json"]),
                 "output": json.loads(r["output_json"]) if r["output_json"] else None} for r in rows]

    def claim(self, task_id, unit_id, parent_action_id):
        owner = uuid.uuid4().hex
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("""UPDATE work_units SET state='failed',error='执行恢复次数已达上限',updated_at=?
                WHERE task_id=? AND unit_id=? AND attempts>=? AND state='running' AND lease_until<=?""",
                (self.clock(), task_id, unit_id, MAX_ATTEMPTS, self.clock()))
            changed = db.execute("""UPDATE work_units SET state='running',owner=?,lease_until=?,
                parent_action_id=?,attempts=attempts+1,error=NULL,updated_at=?
                WHERE task_id=? AND unit_id=? AND attempts<? AND
                (state='pending' OR (state='running' AND lease_until<=?))""",
                (owner, self.clock()+LEASE_SECONDS, parent_action_id, self.clock(),
                 task_id, unit_id, MAX_ATTEMPTS, self.clock())).rowcount
        return owner if changed else None

    def finish(self, task_id, unit_id, owner, *, output=None, error=None):
        body = encoded(output) if output is not None else None
        if body is not None and len(body.encode()) > 1_000_000:
            raise ValueError("工作项结果超过存储上限。")
        with self.connect() as db:
            return bool(db.execute("""UPDATE work_units SET state=?,output_json=?,error=?,owner=NULL,
                lease_until=NULL,updated_at=? WHERE task_id=? AND unit_id=? AND state='running'
                AND owner=? AND lease_until>?""", ("completed" if error is None else "failed", body,
                str(error)[:400] if error else None, self.clock(), task_id, unit_id, owner, self.clock())).rowcount)

    def stop_pending(self, task_id, unit_ids, state, reason):
        with self.connect() as db:
            for uid in unit_ids:
                db.execute("UPDATE work_units SET state=?,error=?,updated_at=? WHERE task_id=? AND unit_id=? AND state='pending'",
                           (state, reason, self.clock(), task_id, uid))

    def invalidate_file_receipt(self, task_id, unit_id):
        with self.connect() as db:
            db.execute("""UPDATE work_units SET state='failed',output_json=NULL,
                error='原成果文件缺失或校验失败，请重新生成',updated_at=?
                WHERE task_id=? AND unit_id=? AND state='completed'""", (self.clock(), task_id, unit_id))

    def evidence(self, task_id):
        return [{"observation_id": r["receipt_id"], "action_id": r["receipt_id"],
                 "parent_action_id": r["parent_action_id"], "work_unit_id": r["unit_id"],
                 "capability": r["definition"]["capability"], "verified": True,
                 "data": r["output"], "created_at": r["updated_at"]}
                for r in self.rows(task_id) if r["state"] == "completed"]

    def model_evidence(self, task_id):
        """Keep full receipts on disk; only a bounded working set reaches Kimi."""
        from .planner_compaction import project_evidence
        selected, remaining = [], 16000
        for row in reversed(project_evidence(self.evidence(task_id)[-12:])):
            body = encoded(row['data'])
            if len(body) > 12000:
                row = project_evidence([row], recovery=True)[0]
            size = len(encoded(row))
            if size > remaining:
                continue
            selected.append(row)
            remaining -= size
        return list(reversed(selected))

    def summary(self, task_id):
        return [{"id": r["unit_id"], "title": r["definition"]["title"], "state": r["state"],
                 "depends_on": r["definition"]["depends_on"], "attempts": r["attempts"],
                 "capability": r["definition"]["capability"], "error": r["error"],
                 "receipt_id": r["receipt_id"] if r["state"] == "completed" else None}
                for r in self.rows(task_id)]

    def item_actions(self, task_id):
        return {r["definition"]["arguments"]["item_id"]:
                {"status": "executing" if r["state"] == "running" else r["state"],
                 "waiting_input": False, "failure_detail": r["error"],
                 "updated_at": datetime.fromtimestamp(r['updated_at'], timezone.utc).isoformat()}
                for r in self.rows(task_id) if r["definition"]["arguments"].get("item_id")}


class WorkUnitRunner:
    def __init__(self, assets, registry, executors, mcp_drivers=None, *, max_workers=3):
        self.assets, self.registry, self.executors = assets, registry, dict(executors)
        self.store = assets.work_units
        self.storage = assets.task_storage
        self.mcp_drivers = dict(mcp_drivers or {})
        self.max_workers = max_workers

    def active(self, dispatch):
        task = self.storage.get_task(dispatch["task_id"])
        action = self.storage.get_action(dispatch["action_id"])
        attempt = self.storage.current_action_attempt(dispatch["action_id"])
        cancel_pending = any(e['event_type'] == 'CANCEL_REQUEST' and e['status'].upper() == 'ACCEPTED'
                             for e in self.storage.inbox_events(dispatch['task_id']))
        return bool(task and task["status"] not in {"completed", "failed", "cancelled"}
                    and not cancel_pending and not task.get("cancel_requested_at") and action and not action.get("interrupt_requested_at")
                    and action["status"] in {"dispatched", "executing"}
                    and attempt and attempt["attempt_id"] == dispatch.get("attempt_id"))

    def present(self, task_id):
        from .presentation import upsert_timeline_item
        from .storage import utc_now
        states = {'pending':'pending', 'running':'active', 'completed':'completed',
                  'failed':'failed', 'blocked':'pending', 'cancelled':'cancelled'}
        with self.storage._lock:
            rows = self.store.summary(task_id)
            db = self.storage._connect()
            try:
                with db:
                    for row in rows:
                        upsert_timeline_item(db, task_id=task_id, source_key='work_unit:'+row['id'],
                            kind='TOOL_ACTIVITY', presentation_state=states[row['state']], title=row['title'],
                            summary={'pending':'等待开始', 'running':'正在处理', 'completed':'执行结果已核验',
                                     'failed':'这项处理遇到问题，其他成果已保留', 'blocked':'等待相关事项恢复',
                                     'cancelled':'已停止后续处理'}[row['state']],
                            payload={}, source_type='WORK_UNIT', source_id=row['id'],
                            attention_level='TOOL_ACTIVITY', now=utc_now())
            finally:
                self.storage._close(db)

    def definitions(self, dispatch, args):
        units = args.get("units")
        if not isinstance(units, list) or not 2 <= len(units) <= MAX_UNITS:
            raise ValueError("并行工作批次需要 2–8 项；单项请直接调用能力。")
        task = self.storage.get_task(dispatch["task_id"])
        allowed = task["policy_snapshot"].get("allowed_capabilities")
        effective_policy = EffectiveTaskCapabilityPolicy.from_task(
            task, self.storage.inbox_events(dispatch["task_id"])
        )
        definitions = []
        for unit in units:
            required_keys = {"id", "title", "capability", "arguments_json", "depends_on"}
            allowed_keys = required_keys | {"bindings"}
            if not isinstance(unit, dict) or required_keys - set(unit) or set(unit) - allowed_keys:
                raise ValueError("工作项格式无效。")
            if not isinstance(unit["id"], str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", unit["id"]):
                raise ValueError("工作项 ID 无效。")
            if not isinstance(unit["title"], str) or not 1 <= len(unit["title"]) <= 100:
                raise ValueError("工作项标题无效。")
            cap = unit["capability"]
            if cap not in SAFE_CAPABILITIES or (allowed is not None and cap not in allowed):
                raise ValueError(f"子能力 {cap} 未授权或不支持安全并行；需要确认的操作请走普通 Action。")
            entry = self.registry.get(cap)
            if entry.loading == 'deferred':
                raise ValueError(f"子能力 {cap} 当前未就绪。")
            policy_decision = effective_policy.decide(entry.spec, self.registry)
            if not policy_decision.allowed:
                raise ValueError("此子能力已被当前任务的最新用户约束禁止。")
            if cap in SAFE_FUNCTION_CAPABILITIES:
                if cap not in self.executors or entry.source.kind not in {"task_material", "http_api", "host_internal", "managed_cli"}:
                    raise ValueError("此 Host 能力当前不可用于工作批次。")
            elif cap in SAFE_MCP_CAPABILITIES:
                profile = entry.adapter.execution_profile
                if (entry.source.kind != "mcp" or not entry.source.server_id or not entry.source.tool_name
                        or entry.source.server_id not in self.mcp_drivers
                        or profile.idempotency_mode != "NATURAL_READ_ONLY"
                        or profile.retry_mode != "SAFE_WITH_SAME_KEY"):
                    raise ValueError("此 MCP 能力不是当前可安全并行的只读能力。")
            raw = unit["arguments_json"]
            if not isinstance(raw, str) or len(raw) > 65000:
                raise ValueError("工作项参数过大或格式无效。")
            arguments = json.loads(raw)
            deps = unit["depends_on"]
            if not isinstance(deps, list) or any(not isinstance(x, str) for x in deps) or len(set(deps)) != len(deps):
                raise ValueError("工作项依赖无效。")
            raw_bindings = unit.get("bindings", [])
            if not isinstance(raw_bindings, list) or len(raw_bindings) > MAX_BINDINGS:
                raise ValueError("工作项结果绑定数量无效。")
            bindings, bound_arguments = [], set()
            for binding in raw_bindings:
                if not isinstance(binding, dict) or set(binding) != {"argument", "from_unit", "source_pointer"}:
                    raise ValueError("工作项结果绑定格式无效。")
                argument = binding["argument"]
                from_unit = binding["from_unit"]
                source_pointer = binding["source_pointer"]
                if (not isinstance(argument, str) or not 1 <= len(argument) <= 80
                        or not isinstance(from_unit, str) or from_unit not in deps
                        or not isinstance(source_pointer, str)):
                    raise ValueError("工作项结果绑定必须来自显式依赖。")
                if argument in bound_arguments:
                    raise ValueError("同一工作项参数不能重复绑定。")
                if not source_pointer.startswith("/") or len(source_pointer) > 400:
                    raise ValueError("工作项结果绑定路径无效。")
                bound_arguments.add(argument)
                bindings.append({"argument": argument, "from_unit": from_unit,
                                 "source_pointer": source_pointer})
            validate_argument_template(arguments, entry.spec.arguments_schema, bound_arguments)
            definitions.append({"id": unit["id"], "title": unit["title"], "capability": cap,
                "arguments": arguments, "depends_on": deps, "bindings": bindings,
                "binding": {"spec": asdict(entry.spec), "source": entry.source.as_dict(),
                            "profile": entry.adapter.execution_profile.as_dict()}})
        ids = {u["id"] for u in definitions}
        if len(ids) != len(definitions) or any(set(u["depends_on"]) - ids for u in definitions):
            raise ValueError("工作项 ID 重复或依赖不属于当前批次。")
        visited = set()
        while len(visited) < len(ids):
            ready = {u["id"] for u in definitions if u["id"] not in visited and set(u["depends_on"]) <= visited}
            if not ready:
                raise ValueError("工作项依赖存在环。")
            visited.update(ready)
        return definitions

    def resolved_arguments(self, row):
        definition = row["definition"]
        arguments = deepcopy(definition["arguments"])
        if definition.get("bindings"):
            dependency_rows = {r["unit_id"]: r for r in self.store.rows(row["task_id"])}
            for binding in definition["bindings"]:
                source = dependency_rows.get(binding["from_unit"])
                if source is None or source["state"] != "completed" or source["output"] is None:
                    raise ValueError("依赖工作项尚未产生可绑定的已验证回执。")
                arguments[binding["argument"]] = resolve_json_pointer(
                    source["output"], binding["source_pointer"]
                )
        validate_arguments(arguments, self.registry.get(definition["capability"]).spec.arguments_schema)
        return arguments

    def invoke_source(self, cap, scoped, arguments):
        entry = self.registry.get(cap)
        if entry.source.kind != "mcp":
            executor = self.executors[cap]
            output = executor.invoke(scoped, arguments) if isinstance(executor, TaskScopedFunction) else executor(arguments)
            if not isinstance(output, dict):
                raise ValueError("能力未返回结构化结果。")
            return True, output, None

        driver = self.mcp_drivers[entry.source.server_id]
        try:
            result = driver.call_tool(entry.source.tool_name, arguments)
        except MCPHTTPError as exc:
            raise ValueError(f"只读 MCP 请求失败（HTTP {exc.status}）。") from exc
        except MCPProtocolError as exc:
            raise ValueError("只读 MCP 返回了无效协议结果。") from exc
        if not isinstance(result, MCPFinalResult):
            raise ValueError("此只读 MCP 需要继续等待或用户输入，不能在并行工作批次内执行。")
        output, error = normalize_mcp_final_result(
            result,
            server_id=entry.source.server_id,
            tool_name=entry.source.tool_name,
        )
        return not result.is_error, output, error

    @planner_capture.work_unit_operation
    def execute_unit(self, dispatch, row, owner):
        definition = row["definition"]
        cap = definition["capability"]
        try:
            if not self.active(dispatch):
                raise ValueError("任务已暂停或取消，未继续执行。")
            arguments = self.resolved_arguments(row)
            scoped = {**dispatch, "action_id": row["receipt_id"], "parent_action_id": dispatch["action_id"],
                      "work_unit_id": row["unit_id"], "payload": arguments, "idempotency_key": row["receipt_id"]}
            planner_capture.operation_result(outcome='executing', input=arguments)
            success, output, error = self.invoke_source(cap, scoped, arguments)
            verdict = self.registry.get(cap).adapter.verify_result(
                scoped, success=success, output=output, error=error)
            if verdict.outcome != "SUCCESS" or verdict.observation is None:
                raise ValueError(verdict.error or "工作项未通过能力核验。")
            if cap == "materials.inspect" and output.get("complete") is not True:
                raise ValueError("部分附件读取失败，请检查附件后重试。")
            if cap == "web.fetch" and (not isinstance(output.get("status"), int) or not 200 <= output["status"] < 300):
                raise ValueError("网页读取未获得成功响应。")
            if (cap.startswith("document.") and cap != "document.docx.inspect") or cap == "deliverables.publish":
                files = [output["file"]] if "file" in output else output.get("files", [])
                if output.get("verified") is not True or not files:
                    raise ValueError("文件没有核验结果。")
                for file in files:
                    self.assets.verify_unit_file(dispatch["task_id"], row["receipt_id"], file["id"])
            # A superseded attempt cannot publish authoritative evidence.
            if not self.active(dispatch):
                raise ValueError("执行期间任务已变更；结果未作为完成回执发布。")
            accepted = self.store.finish(dispatch["task_id"], row["unit_id"], owner, output=verdict.observation)
            planner_capture.operation_result(outcome='verified' if accepted else 'superseded',
                                             output=verdict.observation, accepted=accepted)
        except Exception as exc:
            accepted = self.store.finish(dispatch["task_id"], row["unit_id"], owner, error=str(exc))
            planner_capture.operation_result(outcome='failed' if accepted else 'superseded',
                                             accepted=accepted, error_type=type(exc).__name__)
        self.present(dispatch['task_id'])

    def run(self, dispatch, args):
        try:
            definitions = self.definitions(dispatch, args)
            retry_failed = args.get("retry_failed", False)
            if not isinstance(retry_failed, bool):
                raise ValueError("retry_failed 必须为布尔值。")
            if not self.active(dispatch):
                raise ValueError("执行批次已失效。")
            self.store.prepare(dispatch["task_id"], definitions, retry_failed=retry_failed)
        except (ValueError, KeyError, TypeError) as exc:
            raise FunctionToolError(str(exc), error_kind="model_correctable") from exc
        task_id = dispatch["task_id"]
        ids = {u["id"] for u in definitions}
        for row in self.store.rows(task_id):
            if row['unit_id'] not in ids or row['state'] != 'completed':
                continue
            output = row['output'] or {}
            files = [output['file']] if 'file' in output else output.get('files', [])
            try:
                for file in files:
                    self.assets.verify_unit_file(task_id, row['receipt_id'], file['id'])
            except (ValueError, KeyError, OSError):
                self.store.invalidate_file_receipt(task_id, row['unit_id'])
        self.present(task_id)
        with ThreadPoolExecutor(max_workers=self.max_workers, thread_name_prefix="floweroll-unit") as pool:
            futures = {}
            while True:
                rows = {r["unit_id"]: r for r in self.store.rows(task_id) if r["unit_id"] in ids}
                if not self.active(dispatch):
                    self.store.stop_pending(task_id, ids, "cancelled", "任务已暂停或取消")
                    break
                blocked_changed = False
                for uid, row in rows.items():
                    if uid in futures.values() or row["state"] not in {"pending", "running"}:
                        continue
                    deps = [rows[x]["state"] for x in row["definition"]["depends_on"]]
                    if any(s in {"failed", "blocked", "cancelled"} for s in deps):
                        self.store.stop_pending(task_id, [uid], "blocked", "等待相关事项恢复")
                        blocked_changed = row["state"] == "pending" or blocked_changed
                    elif all(s == "completed" for s in deps) and len(futures) < self.max_workers:
                        owner = self.store.claim(task_id, uid, dispatch["action_id"])
                        if owner:
                            futures[pool.submit(self.execute_unit, dispatch, row, owner)] = uid
                self.present(task_id)
                if not futures:
                    fresh_states = {r['unit_id']: r['state'] for r in self.store.rows(task_id) if r['unit_id'] in ids}
                    if blocked_changed or fresh_states != {uid: r['state'] for uid, r in rows.items()}:
                        continue
                    if any(state == 'running' for state in fresh_states.values()):
                        # A reopened Host may encounter the previous process's
                        # lease. Wait for its receipt/expiry without burning
                        # Action retries or issuing another model call.
                        time.sleep(1)
                        continue
                    break
                done, _ = wait(futures, return_when=FIRST_COMPLETED)
                for future in done:
                    future.result()
                    del futures[future]
        summary = [r for r in self.store.summary(task_id) if r["id"] in ids]
        self.present(task_id)
        if any(r["state"] == "running" for r in summary):
            raise FunctionToolError("工作项仍由在途执行持有，稍后恢复。", error_kind="transient")
        return {"units": summary, "completed": sum(r["state"] == "completed" for r in summary),
                "total": len(summary), "all_completed": all(r["state"] == "completed" for r in summary),
                "notice": "这里只说明工作项执行情况；任务是否办完仍按交付项的核验依据判断。"}


def batch_capability_spec(spec, capabilities):
    """The model may batch only currently visible, authorized safe tools.

    Their argument schemas are already present alongside this envelope. The
    executor repeats the policy/source checks at dispatch, so this is not an
    authorization shortcut. No hidden child-tool schemas or fake permissions.
    """
    from dataclasses import replace
    schema = deepcopy(spec.arguments_schema)
    if 'units' not in schema.get('properties', {}):
        return spec  # Minimal registry fixtures may model routing only.
    names = sorted(cap.name for cap in capabilities if cap.name in SAFE_CAPABILITIES)
    schema['properties']['units']['minItems'] = 2
    schema['properties']['units']['maxItems'] = MAX_UNITS
    schema['properties']['units']['items']['properties']['capability'] = {'type': 'string', 'enum': names}
    return replace(spec, arguments_schema=schema)


def register_work_units(registry, assets, executors, mcp_drivers=None):
    runner = WorkUnitRunner(assets, registry, executors, mcp_drivers=mcp_drivers)
    text = {"type": "string"}
    spec = CapabilitySpec(name=BATCH_ID,
        description="并行/按依赖执行同一任务内 2–8 项安全工作，保存独立已验证回执并可恢复。支持 capability.search 并行发现、DOCX读取/生成、酒店只读查询、Host文件处理和地图/网页只读 MCP；可嵌套名称以 capability 枚举为准，参数遵循相邻工具 schema；设备动作、写操作、支付、预订和需要交互/长时 provider task 的 MCP 不允许嵌套。arguments_json 是固定参数 JSON；bindings 可把显式 depends_on 工作项的已验证回执字段绑定到当前顶层参数，中间不需要重新调用 Planner。bindings 每项包含 argument、from_unit、source_pointer（如 /location 或 /structured_content/city）。重试使用原 ID/原参数/原绑定且 retry_failed=true，已完成项复用。单项直接调用工具。",
        arguments_schema={"type": "object", "properties": {
            "units": {"type": "array", "items": {"type": "object", "properties": {
                "id": text, "title": text, "capability": {"type":"string", "enum": sorted(SAFE_CAPABILITIES)}, "arguments_json": text,
                "depends_on": {"type": "array", "items": text},
                "bindings": {"type": "array", "items": {"type": "object", "properties": {
                    "argument": text, "from_unit": text, "source_pointer": text},
                    "required": ["argument", "from_unit", "source_pointer"], "additionalProperties": False}}},
                "required": ["id", "title", "capability", "arguments_json", "depends_on"], "additionalProperties": False}},
            "retry_failed": {"type": "boolean"}}, "required": ["units"], "additionalProperties": False},
        post_verify_mode="REPLAN_REQUIRED")
    registry.register(RegisteredCapability(spec=spec,
        adapter=FunctionToolAdapter(
            capability_id=BATCH_ID,
            source_kind="host_internal",
            read_only=False,
            replay_safe=True,
            timeout_seconds=1800,
            max_attempts=3,
        ),
        source=CapabilitySourceTarget(kind="host_internal", tool_name=BATCH_ID,
            metadata={"effect": "bounded_safe_work", "foreground_policy": "background_only"}),
        tags=("task", "parallel", "document", "并行", "工作项"), loading="always_visible"))
    return {BATCH_ID: TaskScopedFunction(runner.run)}
