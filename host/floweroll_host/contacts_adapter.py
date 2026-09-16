from __future__ import annotations

from typing import Any, Dict, Optional
import re

from .execution_contracts import ExecutionProfile, ExecutionVerification


_QUERY_PROFILE = ExecutionProfile(
    timeout_seconds=15,
    idempotency_mode="NATURAL_READ_ONLY",
    retry_mode="SAFE_WITH_SAME_KEY",
    verification_mode="DEVICE_READ_BACK",
    reconciliation_mode="SAFE_REREAD",
    max_attempts=2,
    retry_backoff_seconds=1,
)

_MODEL_CORRECTABLE_ERRORS = {
    "CONTACTS_PERMISSION_NOT_DETERMINED",
    "CONTACTS_PERMISSION_DENIED",
    "CONTACTS_QUERY_INVALID",
}

_TRANSIENT_ERRORS = {
    "CONTACTS_STORE_CHANGED_RETRY_SAFE",
}

_NAME_FIELDS = {
    "contact_id",
    "contact_type",
    "display_name",
    "organization_name",
    "phone_hints",
    "email_hints",
    "representation",
    "container_resolution",
}

_EXACT_FIELDS = {
    "requested_contact_id",
    "contact_id",
    "canonicalized",
    "requested_id_linked_into_result",
    "contact_type",
    "display_name",
    "given_name",
    "family_name",
    "organization_name",
    "phone_numbers",
    "email_addresses",
    "phone_values_truncated",
    "email_values_truncated",
    "revision",
    "update_eligible",
    "update_ineligible_reason",
    "representation",
    "container_resolution",
}

_TOP_LEVEL_FIELDS = {
    "query_mode",
    "authorization_scope",
    "found",
    "requested_contact_id",
    "name_query",
    "contacts",
    "truncated",
    "empty_reason",
    "verified",
}


def normalize_contacts_query_arguments(arguments: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    if not isinstance(arguments, dict):
        return None
    allowed = {"contact_id", "name_query", "max_results"}
    if set(arguments) - allowed:
        return None

    contact_id = arguments.get("contact_id")
    name_query = arguments.get("name_query")
    has_contact = isinstance(contact_id, str) and bool(contact_id.strip())
    has_name = isinstance(name_query, str) and bool(name_query.strip())
    if has_contact == has_name:
        return None

    if has_contact:
        contact_id = contact_id.strip()
        if len(contact_id) > 512 or "max_results" in arguments or "name_query" in arguments:
            return None
        return {
            "mode": "exact_id",
            "contact_id": contact_id,
            "name_query": None,
            "max_results": 1,
        }

    assert isinstance(name_query, str)
    name_query = name_query.strip()
    if not 2 <= len(name_query) <= 80 or "contact_id" in arguments:
        return None
    max_results = arguments.get("max_results", 5)
    if isinstance(max_results, bool) or not isinstance(max_results, int) or not 1 <= max_results <= 10:
        return None
    return {
        "mode": "name",
        "contact_id": None,
        "name_query": name_query,
        "max_results": max_results,
    }


def _failure(error: Optional[str], output: Dict[str, Any]) -> ExecutionVerification:
    code = output.get("error_code")
    if code in _MODEL_CORRECTABLE_ERRORS:
        outcome = "MODEL_CORRECTABLE_FAILURE"
    elif code in _TRANSIENT_ERRORS:
        outcome = "TRANSIENT_FAILURE"
    else:
        outcome = "TERMINAL_FAILURE"
    return ExecutionVerification(
        outcome=outcome,
        error=error or (str(code) if code else "iPhone Contacts query failed"),
    )


def _valid_text(value: Any, *, allow_empty: bool = False, max_len: int = 512) -> bool:
    if not isinstance(value, str) or len(value) > max_len:
        return False
    return allow_empty or bool(value.strip())


def _valid_label_values(value: Any, *, max_count: int) -> bool:
    if not isinstance(value, list) or len(value) > max_count:
        return False
    for item in value:
        if not isinstance(item, dict) or set(item) != {"label", "value"}:
            return False
        if not _valid_text(item.get("label"), allow_empty=True, max_len=80):
            return False
        if not _valid_text(item.get("value"), max_len=512):
            return False
    return True


def _valid_name_contact(item: Any) -> bool:
    if not isinstance(item, dict) or set(item) != _NAME_FIELDS:
        return False
    if not _valid_text(item.get("contact_id")):
        return False
    if item.get("contact_type") not in {"person", "organization"}:
        return False
    if not _valid_text(item.get("display_name"), max_len=240):
        return False
    organization = item.get("organization_name")
    if organization is not None and not _valid_text(organization, allow_empty=True, max_len=240):
        return False
    for key in ("phone_hints", "email_hints"):
        hints = item.get(key)
        if not isinstance(hints, list) or len(hints) > 2:
            return False
        if any(not _valid_text(hint, max_len=160) for hint in hints):
            return False
    return item.get("representation") == "unified_contact" and item.get("container_resolution") == "deferred_v1"


def _valid_exact_contact(item: Any, requested_contact_id: str) -> bool:
    if not isinstance(item, dict) or set(item) != _EXACT_FIELDS:
        return False
    if item.get("requested_contact_id") != requested_contact_id:
        return False
    contact_id = item.get("contact_id")
    if not _valid_text(contact_id):
        return False
    if item.get("contact_type") not in {"person", "organization"}:
        return False
    if not _valid_text(item.get("display_name"), max_len=240):
        return False
    for key, max_len in (("given_name", 80), ("family_name", 80)):
        if not _valid_text(item.get(key), allow_empty=True, max_len=max_len):
            return False
    organization = item.get("organization_name")
    if organization is not None and not _valid_text(organization, allow_empty=True, max_len=160):
        return False
    if not isinstance(item.get("canonicalized"), bool):
        return False
    if not isinstance(item.get("requested_id_linked_into_result"), bool):
        return False
    if item["canonicalized"] != (contact_id != requested_contact_id):
        return False
    if item["canonicalized"] and item["requested_id_linked_into_result"] is not True:
        return False
    if not _valid_label_values(item.get("phone_numbers"), max_count=3):
        return False
    if not _valid_label_values(item.get("email_addresses"), max_count=3):
        return False
    if not isinstance(item.get("phone_values_truncated"), bool):
        return False
    if not isinstance(item.get("email_values_truncated"), bool):
        return False
    update_eligible = item.get("update_eligible")
    revision = item.get("revision")
    reason = item.get("update_ineligible_reason")
    if not isinstance(update_eligible, bool):
        return False
    if update_eligible:
        if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{64}", revision) is None or reason is not None:
            return False
        if item.get("container_resolution") != "single_backing_record":
            return False
    else:
        if revision is not None or not isinstance(reason, str) or not reason:
            return False
        if item.get("container_resolution") not in {"linked_or_ambiguous", "unresolved"}:
            return False
    return item.get("representation") == "unified_contact"


def _summary(observation: Dict[str, Any]) -> str:
    contacts = observation["contacts"]
    if not contacts:
        if observation["authorization_scope"] == "limited":
            return "在目前允许小卷访问的联系人中没有找到匹配项。"
        return "没有找到匹配的联系人。"
    if observation["query_mode"] == "exact_id":
        item = contacts[0]
        phones = item.get("phone_numbers") or []
        emails = item.get("email_addresses") or []
        methods = []
        if phones:
            methods.append(f"{len(phones)} 个电话号码")
        if emails:
            methods.append(f"{len(emails)} 个邮箱")
        suffix = "，" + "、".join(methods) if methods else ""
        return f"已核对联系人「{item['display_name']}」{suffix}。"
    names = "、".join(f"「{item['display_name']}」" for item in contacts[:6])
    suffix = "，还有更多结果" if observation.get("truncated") else ""
    return f"找到 {len(contacts)} 个匹配联系人：{names}{suffix}。"


class ContactsQueryAdapter:
    capability_id = "contacts.query"
    source_kind = "ios"
    execution_profile = _QUERY_PROFILE

    def build_dispatch_snapshot(self, action: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "capability": self.capability_id,
            "arguments": dict(action["payload"]),
            "idempotency_key": action["idempotency_key"],
        }

    def verify_result(
        self,
        action: Dict[str, Any],
        *,
        success: bool,
        output: Dict[str, Any],
        error: Optional[str],
    ) -> ExecutionVerification:
        if not success:
            return _failure(error, output)

        expected = normalize_contacts_query_arguments(action.get("payload", {}))
        if expected is None:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts query Action arguments are invalid")
        if set(output) != _TOP_LEVEL_FIELDS:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts query top-level result shape is invalid")
        if output.get("verified") is not True:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts query was not device verified")
        if output.get("query_mode") != expected["mode"]:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts query mode did not match the Action")
        if output.get("authorization_scope") not in {"authorized", "limited"}:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts authorization scope is invalid")
        if output.get("requested_contact_id") != expected["contact_id"]:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts exact target correlation was lost")
        if output.get("name_query") != expected["name_query"]:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts name query correlation was lost")
        if not isinstance(output.get("found"), bool) or not isinstance(output.get("truncated"), bool):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts result flags are malformed")
        contacts = output.get("contacts")
        if not isinstance(contacts, list) or len(contacts) > expected["max_results"]:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts query exceeded its result bound")
        if output["found"] != bool(contacts):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts found flag disagrees with result count")
        if expected["mode"] == "exact_id" and (len(contacts) > 1 or output["truncated"] is not False):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Exact Contacts query returned an invalid result count")

        ids = []
        for item in contacts:
            valid = (
                _valid_exact_contact(item, expected["contact_id"])
                if expected["mode"] == "exact_id"
                else _valid_name_contact(item)
            )
            if not valid:
                return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts query returned a malformed or overbroad contact")
            ids.append(item["contact_id"])
        if len(ids) != len(set(ids)):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts query returned duplicate canonical identifiers")

        empty_reason = output.get("empty_reason")
        if contacts:
            if empty_reason is not None:
                return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts non-empty result carried an empty reason")
        else:
            expected_empty = "not_accessible_or_not_found" if output["authorization_scope"] == "limited" else "no_match"
            if empty_reason != expected_empty:
                return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts empty-result semantics are invalid")

        observation = {
            "query_mode": output["query_mode"],
            "authorization_scope": output["authorization_scope"],
            "found": output["found"],
            "requested_contact_id": output["requested_contact_id"],
            "name_query": output["name_query"],
            "contacts": contacts,
            "truncated": output["truncated"],
            "empty_reason": output["empty_reason"],
        }
        return ExecutionVerification(
            outcome="SUCCESS",
            observation=observation,
            direct_completion_summary=_summary(observation),
        )


_MUTATION_PROFILE = ExecutionProfile(
    timeout_seconds=20,
    idempotency_mode="DEVICE_JOURNAL_AND_DESIRED_STATE",
    retry_mode="NO_BLIND_RETRY",
    verification_mode="DEVICE_READ_BACK",
    reconciliation_mode="DEVICE_EXACT_STATE_READ_BACK",
    max_attempts=1,
)

_MUTATION_MODEL_CORRECTABLE_ERRORS = {
    "CONTACTS_MUTATION_INVALID",
    "CONTACTS_PERMISSION_NOT_DETERMINED",
    "CONTACTS_PERMISSION_DENIED",
    "CONTACTS_TARGET_NOT_ACCESSIBLE",
    "CONTACTS_TARGET_STALE",
    "CONTACTS_UPDATE_UNSUPPORTED",
}

_CREATE_RESULT_FIELDS = {
    "operation", "authorization_scope", "created_contact_id", "contact_id", "canonicalized",
    "created_id_linked_into_result", "contact_type", "display_name", "given_name", "family_name",
    "organization_name", "phone_numbers", "email_addresses", "revision", "update_eligible",
    "update_ineligible_reason", "applied", "verified",
}
_UPDATE_RESULT_FIELDS = {
    "operation", "authorization_scope", "requested_contact_id", "contact_id", "contact_type",
    "display_name", "given_name", "family_name", "organization_name", "phone_numbers",
    "email_addresses", "revision", "update_eligible", "update_ineligible_reason", "applied", "verified",
}


def _normalize_method_values(value: Any, *, kind: str) -> Optional[list[dict[str, str]]]:
    if not isinstance(value, list) or len(value) > 3:
        return None
    allowed_labels = {"home", "work", "other"} | ({"mobile"} if kind == "phone" else set())
    max_len = 64 if kind == "phone" else 254
    result: list[dict[str, str]] = []
    seen = set()
    for row in value:
        if not isinstance(row, dict) or set(row) != {"label", "value"}:
            return None
        label = row.get("label")
        raw = row.get("value")
        if label not in allowed_labels or not isinstance(raw, str):
            return None
        cleaned = raw.strip()
        if not cleaned or len(cleaned) > max_len:
            return None
        if kind == "email" and ("@" not in cleaned or cleaned.startswith("@") or cleaned.endswith("@")):
            return None
        identity = (label, cleaned.casefold() if kind == "email" else cleaned)
        if identity in seen:
            return None
        seen.add(identity)
        result.append({"label": label, "value": cleaned})
    return result


def _normalize_desired_contact(arguments: Dict[str, Any], *, update: bool) -> Optional[Dict[str, Any]]:
    if not isinstance(arguments, dict):
        return None
    desired_keys = {"given_name", "family_name", "organization_name", "phone_numbers", "email_addresses"}
    allowed = set(desired_keys)
    if update:
        allowed |= {"contact_id", "expected_revision"}
    if set(arguments) != allowed:
        return None

    given = arguments.get("given_name")
    family = arguments.get("family_name")
    organization = arguments.get("organization_name")
    if not all(isinstance(value, str) for value in (given, family, organization)):
        return None
    given = given.strip()
    family = family.strip()
    organization = organization.strip()
    if len(given) > 80 or len(family) > 80 or len(organization) > 160:
        return None
    phones = _normalize_method_values(arguments.get("phone_numbers"), kind="phone")
    emails = _normalize_method_values(arguments.get("email_addresses"), kind="email")
    if phones is None or emails is None:
        return None
    if not any((given, family, organization, phones, emails)):
        return None

    normalized: Dict[str, Any] = {
        "given_name": given,
        "family_name": family,
        "organization_name": organization,
        "phone_numbers": phones,
        "email_addresses": emails,
    }
    if update:
        contact_id = arguments.get("contact_id")
        revision = arguments.get("expected_revision")
        if not isinstance(contact_id, str) or not contact_id.strip() or len(contact_id.strip()) > 512:
            return None
        if not isinstance(revision, str) or re.fullmatch(r"[0-9a-fA-F]{64}", revision) is None:
            return None
        normalized["contact_id"] = contact_id.strip()
        normalized["expected_revision"] = revision.lower()
    return normalized


def normalize_contacts_create_arguments(arguments: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    return _normalize_desired_contact(arguments, update=False)


def normalize_contacts_update_arguments(arguments: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    return _normalize_desired_contact(arguments, update=True)


def _mutation_failure(error: Optional[str], output: Dict[str, Any], fallback: str) -> ExecutionVerification:
    code = output.get("error_code")
    outcome = "MODEL_CORRECTABLE_FAILURE" if code in _MUTATION_MODEL_CORRECTABLE_ERRORS else "TERMINAL_FAILURE"
    return ExecutionVerification(outcome=outcome, error=error or (str(code) if code else fallback))


def _desired_matches_output(expected: Dict[str, Any], output: Dict[str, Any]) -> bool:
    return (
        output.get("given_name") == expected["given_name"]
        and output.get("family_name") == expected["family_name"]
        and output.get("organization_name") == expected["organization_name"]
        and output.get("phone_numbers") == expected["phone_numbers"]
        and output.get("email_addresses") == expected["email_addresses"]
    )


def _valid_managed_common(output: Dict[str, Any]) -> bool:
    if output.get("verified") is not True or output.get("authorization_scope") not in {"authorized", "limited"}:
        return False
    if output.get("contact_type") != "person" or not _valid_text(output.get("contact_id")):
        return False
    if not _valid_text(output.get("display_name"), max_len=240):
        return False
    if not _valid_text(output.get("given_name"), allow_empty=True, max_len=80):
        return False
    if not _valid_text(output.get("family_name"), allow_empty=True, max_len=80):
        return False
    if not _valid_text(output.get("organization_name"), allow_empty=True, max_len=160):
        return False
    if not _valid_label_values(output.get("phone_numbers"), max_count=3):
        return False
    if not _valid_label_values(output.get("email_addresses"), max_count=3):
        return False
    if not isinstance(output.get("update_eligible"), bool):
        return False
    revision = output.get("revision")
    reason = output.get("update_ineligible_reason")
    if output["update_eligible"]:
        return isinstance(revision, str) and re.fullmatch(r"[0-9a-f]{64}", revision) is not None and reason is None
    return revision is None and isinstance(reason, str) and bool(reason)


def _contact_summary_name(output: Dict[str, Any]) -> str:
    display = str(output.get("display_name") or "").strip()
    if display:
        return display
    desired = " ".join(filter(None, (str(output.get("given_name") or "").strip(), str(output.get("family_name") or "").strip())))
    return desired or str(output.get("organization_name") or "未命名联系人")


class ContactsCreateAdapter:
    capability_id = "contacts.create"
    source_kind = "ios"
    execution_profile = _MUTATION_PROFILE

    def build_dispatch_snapshot(self, action: Dict[str, Any]) -> Dict[str, Any]:
        return {"capability": self.capability_id, "arguments": dict(action["payload"]), "idempotency_key": action["idempotency_key"]}

    def predispatch_confirmation(self, action: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        args = normalize_contacts_create_arguments(action.get("payload", {}))
        if args is None:
            return None
        name = " ".join(filter(None, (args["given_name"], args["family_name"]))) or args["organization_name"] or "未命名联系人"
        prompt = f"创建联系人：{name}"
        if args["organization_name"]:
            prompt += f"\n组织：{args['organization_name']}"
        if args["phone_numbers"]:
            prompt += "\n电话：" + "；".join(item["value"] for item in args["phone_numbers"])
        if args["email_addresses"]:
            prompt += "\n邮箱：" + "；".join(item["value"] for item in args["email_addresses"])
        return {
            "prompt": prompt,
            "suggested_options": [{"id": "approve", "label": "确认创建"}, {"id": "cancel", "label": "取消"}],
            "accepts_text": False,
            "reason": "side_effect_approval",
            "execution_fields": dict(action["payload"]),
        }

    def verify_result(self, action: Dict[str, Any], *, success: bool, output: Dict[str, Any], error: Optional[str]) -> ExecutionVerification:
        if not success:
            return _mutation_failure(error, output, "iPhone Contacts create failed")
        expected = normalize_contacts_create_arguments(action.get("payload", {}))
        if expected is None or set(output) != _CREATE_RESULT_FIELDS:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts create result shape is invalid")
        if output.get("operation") != "create" or output.get("applied") is not True or not _valid_managed_common(output):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts create readback is not verified")
        created_id = output.get("created_contact_id")
        if not _valid_text(created_id) or not isinstance(output.get("canonicalized"), bool) or not isinstance(output.get("created_id_linked_into_result"), bool):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts create identity correlation is invalid")
        if output["canonicalized"] != (output["contact_id"] != created_id):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts create canonical identity flag is inconsistent")
        if output["canonicalized"] and output["created_id_linked_into_result"] is not True:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts create canonical alias lacks native linkage proof")
        if not _desired_matches_output(expected, output):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts create readback does not match the approved contact")
        observation = {key: output[key] for key in (
            "contact_id", "contact_type", "display_name", "given_name", "family_name", "organization_name",
            "phone_numbers", "email_addresses", "revision", "update_eligible", "update_ineligible_reason",
        )}
        return ExecutionVerification(
            outcome="SUCCESS", observation=observation,
            direct_completion_summary=f"已创建联系人「{_contact_summary_name(output)}」并重新核对。",
        )


class ContactsUpdateAdapter:
    capability_id = "contacts.update"
    source_kind = "ios"
    execution_profile = _MUTATION_PROFILE

    def build_dispatch_snapshot(self, action: Dict[str, Any]) -> Dict[str, Any]:
        return {"capability": self.capability_id, "arguments": dict(action["payload"]), "idempotency_key": action["idempotency_key"]}

    def predispatch_confirmation(self, action: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        args = normalize_contacts_update_arguments(action.get("payload", {}))
        if args is None:
            return None
        name = " ".join(filter(None, (args["given_name"], args["family_name"]))) or args["organization_name"] or "未命名联系人"
        prompt = f"修改联系人：{name}"
        if args["organization_name"]:
            prompt += f"\n组织：{args['organization_name']}"
        if args["phone_numbers"]:
            prompt += "\n电话：" + "；".join(item["value"] for item in args["phone_numbers"])
        if args["email_addresses"]:
            prompt += "\n邮箱：" + "；".join(item["value"] for item in args["email_addresses"])
        return {
            "prompt": prompt,
            "suggested_options": [{"id": "approve", "label": "确认修改"}, {"id": "cancel", "label": "取消"}],
            "accepts_text": False,
            "reason": "side_effect_approval",
            "execution_fields": dict(action["payload"]),
        }

    def verify_result(self, action: Dict[str, Any], *, success: bool, output: Dict[str, Any], error: Optional[str]) -> ExecutionVerification:
        if not success:
            return _mutation_failure(error, output, "iPhone Contacts update failed")
        expected = normalize_contacts_update_arguments(action.get("payload", {}))
        if expected is None or set(output) != _UPDATE_RESULT_FIELDS:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts update result shape is invalid")
        if output.get("operation") != "update" or output.get("requested_contact_id") != expected["contact_id"]:
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts update lost target correlation")
        if output.get("contact_id") != expected["contact_id"] or output.get("update_eligible") is not True or not _valid_managed_common(output):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts update readback target is not the approved writable contact")
        if not isinstance(output.get("applied"), bool) or not _desired_matches_output(expected, output):
            return ExecutionVerification(outcome="TERMINAL_FAILURE", error="Contacts update readback does not match the approved state")
        observation = {key: output[key] for key in (
            "contact_id", "contact_type", "display_name", "given_name", "family_name", "organization_name",
            "phone_numbers", "email_addresses", "revision", "update_eligible", "update_ineligible_reason", "applied",
        )}
        return ExecutionVerification(
            outcome="SUCCESS", observation=observation,
            direct_completion_summary=f"已修改联系人「{_contact_summary_name(output)}」并重新核对。",
        )
