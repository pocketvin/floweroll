# 小卷 V1 Host Protocol

Status: Runtime Slices 1–8 implementation baseline. The protocol is model-independent, durable across foreground/process loss, and now has an explicit secure cross-device boundary.

## Invariants

1. Every Task has a stable `task_id`.
2. Product Task creation uses a client-generated stable `submission_id`; replaying the same submission must not create another Task.
3. Every Action has a stable `action_id`, monotonic `step_index` and `idempotency_key`.
4. Retrying the same Action result must not advance a Task twice.
5. SQLite/Runtime state is correctness truth; the model, iPhone foreground state and SSE connection are not.
6. Public Timeline is a durable user-safe read model; low-level Trace remains separate.
7. A Task only advances after the relevant verifier/Runtime transition accepts the real result.

## 1. Delegate a Task — product contract

`POST /v1/tasks`

```json
{
  "submission_id": "sub_...",
  "input": {
    "kind": "text",
    "text": "明天下午帮我安排面试行程"
  },
  "invocation_source": "ios_new_task"
}
```

Slice 2 accepts normalized text input. Voice/ASR is expected to normalize into this same TaskSubmission boundary rather than create a second Runtime protocol.

First durable acceptance returns `201 Created`:

```json
{
  "task_id": "...",
  "submission_id": "sub_...",
  "goal": "明天下午帮我安排面试行程",
  "status": "active",
  "current_step": 1,
  "idempotent_replay": false
}
```

If the HTTP response is lost, retry the **same** `submission_id` with the same semantic payload. The Host returns the existing Task with `200 OK` and `idempotent_replay=true`. Reusing the same ID with conflicting input fails closed with `409 Conflict` Problem Details.

`Task accepted` means the Host has durably committed the Task and initial public presentation state. It does not mean Planner/execution has finished.

### Legacy probe compatibility

The current deterministic probe tests may still submit:

```json
{
  "goal": "验证最小数据链",
  "invocation_source": "integration_test",
  "policy_snapshot": {"mode": "probe-only"}
}
```

This compatibility shape is not the intended iPhone product contract and does not provide Task-submission idempotency.

## 2. Rediscover Tasks after foreground state loss

`GET /v1/tasks?bucket=running|needs_user|history&cursor=...&limit=20`

The Task Index is Host-owned. A recreated iPhone UI must be able to rediscover Tasks without a local list of Task IDs.

Response:

```json
{
  "items": [
    {
      "task_id": "...",
      "submission_id": "sub_...",
      "title": "明天下午帮我安排面试行程",
      "status": "active",
      "phase": "planning",
      "bucket": "running",
      "needs_user": false,
      "latest_timeline": {
        "title": "准备验证设备执行链路",
        "summary": null,
        "updated_at": "..."
      }
    }
  ],
  "next_cursor": null
}
```

`bucket` is a presentation/read-model grouping, not another Task lifecycle state. Pagination cursors are server-issued opaque values.

## 3. Rebuild one Task Detail

`GET /v1/tasks/{task_id}/view`

This is the foreground recovery snapshot. It is read from one consistent SQLite snapshot and returns:

```text
Task current state
TaskRuntime read projection
Public Timeline items
Artifact summaries
pending user interaction, if any
terminal result, if any
presentation_cursor
```

Example shape:

```json
{
  "task": {"task_id": "...", "status": "active"},
  "runtime": {"phase": "planning", "runtime_revision": 0},
  "timeline": [
    {
      "timeline_item_id": "tl_...",
      "kind": "PUBLIC_WORKLOG",
      "presentation_state": "COMPLETE",
      "title": "任务已交给小卷",
      "revision": 1
    }
  ],
  "artifacts": [],
  "pending_interaction": null,
  "result": null,
  "presentation_cursor": 2
}
```

The cursor is the durable PresentationEvent boundary corresponding to that snapshot. Slice 7 will expose cursor replay over SSE; Slice 2 already persists and tests the replay source so a future stream cannot depend on in-memory history.

## 4. Public Timeline vs Trace

Public Timeline is the normal user-facing history and may update one stable card over time:

```text
○ 正在验证设备执行链路
        ↓
✓ 验证设备执行链路已完成
```

Every material card revision creates a monotonic durable PresentationEvent sequence. Replaying the same storage transition does not duplicate a Timeline card or PresentationEvent.

Trace remains the technical execution chronology used for debugging/evaluation. Ordinary iPhone UI must not consume arbitrary raw Trace rows as its product history.

## 5. Current device-probe execution compatibility

`GET /v1/tasks/{task_id}/next-action`

For the current harmless proof, the Host returns/replays the same unfinished `device.probe` Action until a result is acknowledged.

```json
{
  "action_id": "...",
  "task_id": "...",
  "step_index": 1,
  "action_type": "device.probe",
  "payload": {"message": "小卷收到：..."},
  "status": "dispatched",
  "runtime_action_status": "executing",
  "attempt_id": "...",
  "attempt_number": 1,
  "attempt_status": "IN_FLIGHT",
  "dispatch_digest": "...",
  "idempotency_key": "{task_id}:1:device.probe",
  "on_verified": "COMPLETE"
}
```

`POST /v1/tasks/{task_id}/actions/{action_id}/result`

```json
{
  "attempt_id": "...",
  "success": true,
  "output": {"echo": "小卷收到：..."}
}
```

The Host persists `ActionAttempt=IN_FLIGHT` plus the exact dispatch snapshot/digest **before** returning a dispatch. Losing the HTTP response therefore replays the same Attempt rather than creating another invocation. Result callers should send `attempt_id`; omission is accepted only for the one-Attempt legacy compatibility case. Duplicate terminal results remain idempotent. `UNKNOWN` attempts enter reconciliation and cannot create a later Attempt until Runtime has established that retry is safe.

## 6. Durable user/control inputs

The public client never posts arbitrary internal Inbox event types. It uses typed semantic endpoints; the Host validates/correlates them and admits durable Runtime events internally.

### Free steering / Conversation turn

`POST /v1/tasks/{task_id}/turns` -> `202 Accepted`

```json
{
  "event_id": "turn_...",
  "content": {"kind": "text", "text": "改成十点"},
  "reply_context": null
}
```

A new UserTurn arriving before a real Attempt begins supersedes the stale undispatched Action and returns the Task to semantic planning. Once an Attempt is already in flight/ambiguous, the Runtime does not pretend the effect never started.

When a real Attempt may already have external effects, the same durable UserTurn may also be inspected asynchronously by an optional **narrow control-interrupt classifier**. This does not delay the `202 Accepted` response and it cannot call Tools or replace Planner semantics. Only a high-confidence classification can produce:

- `CANCEL_TASK` — request safe cancellation of the whole Task;
- `INTERRUPT_CURRENT_ACTION` — request cooperative cancellation/reconciliation of only the current Action while preserving the Task/UserTurn for subsequent replanning.

Low-confidence/classifier failure is a no-op. Every control decision is fenced to the exact `runtime_revision`, Inbox sequence and `attempt_id`; a newer UserTurn makes an older classifier result stale. An interrupted Action is never redispatched, pending ActionInput for that Action is invalidated, and a real provider result that wins the race remains authoritative evidence.

### Planner Clarification response

`POST /v1/tasks/{task_id}/clarifications/{clarification_id}/responses` -> `202 Accepted`

The response is validated against the exact pending Clarification and becomes a correlated durable UserTurn; Planner semantics resolve/keep/cancel that Clarification on the next decision.

### Action-owned input / approval

`POST /v1/tasks/{task_id}/action-inputs/{input_request_id}/responses` -> `202 Accepted`

Request carries stable `event_id`, exact `binding_digest`, and a structured response. Pre-dispatch approvals require `approved=true|false`. The approved binding includes the exact Adapter `dispatch_digest`; the subsequent Attempt stores `approved_input_request_id`. Mid-tool input resumes the same Attempt/source continuation and must not replay the original Tool invocation.

### Cancellation

`POST /v1/tasks/{task_id}/cancel` -> `202 Accepted`

If no real Attempt started, cancellation can be terminal immediately. If an Attempt is in flight or UNKNOWN, the Task records `cancel_requested_at`, blocks new dispatch and settles/reconciles that external effect before becoming terminal `CANCELLED`. A real side effect that completed before cancellation settled remains a succeeded Action/Observation; cancellation stops future work rather than falsifying history.

### Artifact read/edit

`GET /v1/tasks/{task_id}/artifacts/{artifact_id}`

`POST /v1/tasks/{task_id}/artifacts/{artifact_id}/revisions`

Artifact edits require `event_id`, `expected_revision_id`, and new content. Every edit creates an immutable new revision. Exact replay of the same edit event is idempotent; a stale base returns `409 STALE_ARTIFACT_REVISION`. Editing approval-bound content before dispatch invalidates the old approval/action path; editing after dispatch cannot rewrite the historical Attempt snapshot.

## 7. Public Timeline live stream

After loading `/view`, subscribe with:

`GET /v1/tasks/{task_id}/stream?after_seq={presentation_cursor}`

The Host first replays durable `PresentationEvent.seq > cursor`, then tails new events. SSE frames use:

```text
id: <seq>
event: presentation
data: <user-safe PresentationEvent JSON>
```

`Last-Event-ID` is honored when `after_seq` is omitted. The stream is backed by SQLite replay rather than an in-memory event bus, so Host/foreground disconnects do not lose history. A terminal Task closes after replay. Normal SSE contains only the public presentation projection, not raw Trace/dispatch evidence.

## 8. Legacy technical reads

`GET /v1/tasks/{task_id}` — current Task row projection.

`GET /v1/tasks/{task_id}/trace` — low-level technical Trace.

These are not replacements for the product `/view` endpoint.

## 9. Current error contract

New semantic endpoints use RFC-9457-style `application/problem+json` with a stable machine `code` for conflicts/validation. Example:

```json
{
  "type": "urn:floweroll:problem:submission-id-conflict",
  "title": "Submission ID conflict",
  "status": 409,
  "detail": "submission_id is already bound to different task input",
  "instance": "/v1/tasks",
  "code": "SUBMISSION_ID_CONFLICT"
}
```

Legacy probe routes retain their older `{ "error": "..." }` shape during coexistence.

## 10. Next protocol slice

Host Runtime Slices 1–7 are implemented behind this `/v1` facade. The next cross-device step is the iPhone durability/client layer: preserve a stable pending `submission_id` until Host acceptance and journal native ActionAttempt execution/result delivery so phone process/network loss cannot duplicate native side effects.


## Security / transport boundary

- The built-in Mac HTTP Host binds only to loopback.
- Real-device access must use HTTPS termination (for V1, an HTTPS tunnel/reverse proxy to loopback is acceptable).
- When `FLOWEROLL_HOST_TOKEN` is configured, all `/v1` routes require exact Bearer authentication; `/health` exposes only minimal reachability state.
- The iPhone stores the paired bearer credential in Keychain, not UserDefaults, PendingSubmission, DeviceActionJournal, Task payloads or Timeline.
- The iPhone client refuses non-loopback plaintext HTTP and refuses remote HTTPS when no paired credential is available.
- This is authentication/transport protection only; Host-authoritative Policy still decides whether an authenticated request is allowed to execute a side effect.
# 2026-09-11 additive contract: verified work progress

`GET /v1/tasks/{task_id}/view` adds optional `work_summary` when task material support is enabled. It uses the same projection as `/materials`: `items`, `total`, `completed`, `state`, `revision`, dependencies, file/evidence IDs and missing information. Item states additionally include `waiting_approval` and `cancelled`. Counts measure verified deliverables, never elapsed time or successful tool calls.

The Host joins the Runtime view and asset projection through a bounded revision fence. During sustained concurrent changes it may return `work_summary: null`; older Hosts may omit the field. Clients must decode both cases, use indeterminate progress for nonterminal unplanned work, and avoid inventing a denominator. A simple verified terminal task may use 1/1 without requiring a deliverable plan. Cancellation or a successful OS background-window handoff is not task completion.

Clients refresh `/view` at tool lifecycle changes as well as important/user-required presentation events so file verification can update progress during a long task. File bytes remain behind the existing authenticated per-task download endpoint.

The iOS Live Activity links to `floweroll://task/<UUID>` and carries the owning task ID. Opening the link reads that task workspace through the configured Host; it grants no execution permission and cannot override connection configuration.
# Native result recovery after cancellation / UNKNOWN (2026-09-11)

`GET /v1/tasks/{task_id}/next-device-action?supports_reconciliation=true` opts into an additional envelope field, `reconciliation_only: true`. `wait_seconds` remains supported. Legacy clients and the generic `next-action` endpoint never receive these recovery envelopes.

The recovery envelope reuses the current iOS ActionAttempt ID and dispatch digest after an in-flight task/action cancellation or an UNKNOWN result. It does not admit a new Attempt or approve a new side effect. The device may read authoritative native state or replay its durable result. It must never invoke fresh execution, including when its journal is missing/received or a reconciler says definitely-not-started. Without sufficient evidence it retains the unresolved state. A task cancellation is not an instruction to undo an already-created calendar event.

Positive native evidence passes through the same verifier and current-attempt fence as ordinary results. A cancelled task can retain the verified receipt while stopping subsequent work. Terminal tasks receive no new recovery envelope. iOS opts in only with the accompanying coordinator guards; older deployed clients remain safe during a staggered rollout.
