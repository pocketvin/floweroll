"""Pydantic contracts for the Host HTTP boundary.

Request models accept unknown fields for forward-compatible clients but only
expose declared fields to the existing services. Response models retain unknown
fields because Runtime read models may add fields before older iOS clients use
them. Detailed domain validation remains in the owning service.
"""
from __future__ import annotations

import math
from typing import Annotated, Any, ClassVar, Literal

from pydantic import (
    AfterValidator,
    BaseModel,
    BeforeValidator,
    ConfigDict,
    Field,
    JsonValue,
    RootModel,
    model_validator,
)

ValidationProblem = tuple[str, str, str]
JSONObject = dict[str, JsonValue]


class RequestContract:
    validation_error: ClassVar[ValidationProblem] = (
        "INVALID_REQUEST",
        "Invalid request",
        "Invalid request body.",
    )

    @classmethod
    def validation_problem(cls, errors: list[dict[str, Any]]) -> ValidationProblem:
        return cls.validation_error


class RequestModel(RequestContract, BaseModel):
    model_config = ConfigDict(extra="ignore", strict=True)


class ResponseModel(BaseModel):
    model_config = ConfigDict(extra="allow", strict=True, ser_json_inf_nan="constants")


def nonblank(value: str) -> str:
    if not value.strip():
        raise ValueError("must not be blank")
    return value


Nonblank = Annotated[str, AfterValidator(nonblank)]
Nonempty = Annotated[str, Field(min_length=1)]
LegacyString = Annotated[str, BeforeValidator(str)]
LegacyObject = Annotated[JSONObject, BeforeValidator(lambda value: value if isinstance(value, dict) else {})]
LegacyBool = Annotated[bool, BeforeValidator(bool)]
QueryBool = Annotated[bool, BeforeValidator(lambda value: value == "true" if isinstance(value, str) else bool(value))]
LegacyInt = Annotated[int, BeforeValidator(int)]
LegacyFloat = Annotated[float, BeforeValidator(float)]


class TextInput(RequestModel):
    kind: Literal["text"]
    text: Nonblank
    attachment_ids: list[str] = Field(default_factory=list)


class TaskSubmission(RequestModel):
    submission_id: Nonblank
    input: TextInput
    parent_task_id: Nonblank | None = None
    invocation_source: LegacyString = "unknown"


class ProbeSubmission(RequestModel):
    goal: LegacyString = ""
    invocation_source: LegacyString = "unknown"
    policy_snapshot: LegacyObject = Field(default_factory=dict)


class TaskCreate(RequestContract, RootModel[TaskSubmission | ProbeSubmission]):
    @model_validator(mode="before")
    @classmethod
    def select_contract(cls, value: Any) -> Any:
        if isinstance(value, dict):
            contract = TaskSubmission if "input" in value or "submission_id" in value else ProbeSubmission
            return contract.model_validate(value)
        return value

    @classmethod
    def validation_problem(cls, errors: list[dict[str, Any]]) -> ValidationProblem:
        fields = {str(item) for error in errors for item in error.get("loc", ())}
        if "submission_id" in fields:
            return (
                "INVALID_SUBMISSION_ID",
                "Invalid submission ID",
                "submission_id is required for the idempotent TaskSubmission contract.",
            )
        if "parent_task_id" in fields:
            return (
                "INVALID_PARENT_TASK_ID",
                "Invalid parent Task ID",
                "parent_task_id must be a non-empty string when present.",
            )
        if "kind" in fields:
            return (
                "UNSUPPORTED_TASK_INPUT",
                "Unsupported task input",
                "Slice 2 currently accepts normalized text TaskSubmission input only.",
            )
        if "text" in fields:
            return ("INVALID_TASK_INPUT", "Invalid task input", "input.text must be a non-empty string.")
        return ("INVALID_TASK_INPUT", "Invalid task input", "input must be an object.")


class ActionResultRequest(RequestModel):
    attempt_id: LegacyString | None = None
    success: LegacyBool = False
    output: LegacyObject = Field(default_factory=dict)
    error: LegacyString | None = None


class DeviceDefinitelyNotStartedRequest(RequestModel):
    attempt_id: Nonblank


class ReplyContext(RequestModel):
    clarification_id: str | None = None


class UserTurn(RequestModel):
    event_id: Nonblank
    content: TextInput
    reply_context: Annotated[ReplyContext, BeforeValidator(lambda value: value if isinstance(value, dict) else {})] = Field(default_factory=ReplyContext)

    @classmethod
    def validation_problem(cls, errors: list[dict[str, Any]]) -> ValidationProblem:
        fields = {str(item) for error in errors for item in error.get("loc", ())}
        if "event_id" in fields:
            return ("INVALID_EVENT_ID", "Invalid event ID", "event_id is required.")
        if "reply_context" in fields or "clarification_id" in fields:
            return (
                "INVALID_REPLY_CONTEXT",
                "Invalid reply context",
                "clarification_id must be a string when present.",
            )
        return (
            "INVALID_USER_TURN",
            "Invalid user turn",
            "content must be a non-empty normalized text object.",
        )


class ClarificationResponse(RequestModel):
    validation_error = (
        "INVALID_CLARIFICATION_RESPONSE",
        "Invalid clarification response",
        "event_id and response object are required.",
    )
    event_id: Nonblank
    response: JSONObject


class ActionInputResponse(ClarificationResponse):
    validation_error = (
        "INVALID_ACTION_INPUT_RESPONSE",
        "Invalid action input response",
        "event_id, binding_digest and response object are required.",
    )
    binding_digest: Nonempty


class CancelRequest(RequestModel):
    event_id: Nonblank
    reason: str | None = None

    @classmethod
    def validation_problem(cls, errors: list[dict[str, Any]]) -> ValidationProblem:
        fields = {str(item) for error in errors for item in error.get("loc", ())}
        if "event_id" in fields:
            return ("INVALID_EVENT_ID", "Invalid event ID", "event_id is required.")
        return (
            "INVALID_CANCEL_REASON",
            "Invalid cancellation reason",
            "reason must be a string when present.",
        )


class ArtifactEdit(RequestModel):
    validation_error = (
        "INVALID_ARTIFACT_EDIT",
        "Invalid Artifact edit",
        "event_id, expected_revision_id and content object are required.",
    )
    event_id: Nonblank
    expected_revision_id: Nonempty
    content: JSONObject


class TaskIndexQuery(RequestModel):
    validation_error = (
        "INVALID_TASK_INDEX_QUERY",
        "Invalid task index query",
        "bucket, cursor, thread_id or limit is invalid.",
    )
    bucket: Literal["all", "running", "needs_user", "history"] = "all"
    cursor: str | None = None
    thread_id: str | None = None
    limit: Annotated[LegacyInt, Field(ge=1, le=100)] = 20


class PresentationCursor(RequestModel):
    validation_error = (
        "INVALID_PRESENTATION_CURSOR",
        "Invalid presentation cursor",
        "after_seq / Last-Event-ID must be a non-negative integer.",
    )
    after_seq: Annotated[LegacyInt, Field(ge=0)] | None = None


def bounded_wait(value: float) -> float:
    if not math.isfinite(value) or value < 0 or value > 20:
        raise ValueError("wait_seconds must be a finite number between 0 and 20")
    return value


class DeviceWait(RequestModel):
    validation_error = (
        "INVALID_DEVICE_ACTION_WAIT",
        "Invalid device action wait",
        "wait_seconds must be between 0 and 20.",
    )
    wait_seconds: Annotated[LegacyFloat, AfterValidator(bounded_wait)] = 0.0
    supports_reconciliation: QueryBool = False


class UploadHeaders(RequestModel):
    validation_error = ("INVALID_UPLOAD", "Invalid upload", "Invalid upload headers.")
    file_id: str = Field(default="", alias="x-file-id")
    name: str = Field(default="附件", alias="x-file-name")
    media_type: str = Field(default="", alias="x-file-media-type")
    expected_size: LegacyInt = Field(default=0, alias="upload-length")
    sha256: str = Field(default="", alias="x-content-sha256")


class UploadChunkHeaders(RequestModel):
    validation_error = (
        "INVALID_UPLOAD_CHUNK",
        "Invalid upload chunk",
        "Invalid resumable upload headers.",
    )
    media_type: str = Field(default="", alias="content-type")
    offset: LegacyInt = Field(alias="upload-offset")
    length: LegacyInt = Field(default=0, alias="content-length")
    complete: str = Field(default="?0", alias="upload-complete")


class BinaryUploadHeaders(RequestModel):
    validation_error = (
        "INVALID_ATTACHMENT",
        "Invalid attachment",
        "Invalid attachment headers.",
    )
    length: LegacyInt = Field(default=0, alias="content-length")
    file_id: str = Field(default="", alias="x-file-id")
    name: str = Field(default="附件", alias="x-file-name")
    media_type: str = Field(default="", alias="content-type")
    sha256: str = Field(default="", alias="x-content-sha256")


class ObservationRequest(RequestModel):
    validation_error = (
        "INVALID_OBSERVATION",
        "Invalid observation",
        "观察数据格式不正确。",
    )


class ObservationCreate(ObservationRequest):
    id: str
    sources: list[str]
    preset: str
    created_at: str
    consent_version: Literal[1]


class ObservationBatch(ObservationRequest):
    events: Annotated[list[JSONObject], Field(max_length=32)]


class ObservationEventStatus(ObservationRequest):
    ids: Annotated[list[str], Field(min_length=1, max_length=32)]


class ObservationFinish(ObservationRequest):
    event_count: Annotated[int, Field(ge=0)]


class ObservationQuestion(ObservationRequest):
    id: str
    question: str


class Health(ResponseModel):
    ok: bool
    service: str


class LegacyError(ResponseModel):
    error: str


class Problem(ResponseModel):
    type: str
    title: str
    status: int
    detail: str
    instance: str | None = None
    code: str


class Task(ResponseModel):
    task_id: str
    submission_id: str | None = None
    thread_id: str
    parent_task_id: str | None = None
    goal: str
    status: str
    current_step: int
    created_at: str
    updated_at: str
    idempotent_replay: bool | None = None


class TaskRetry(ResponseModel):
    task: Task
    resumed: bool


class TaskIndexItem(ResponseModel):
    task_id: str
    thread_id: str
    title: str
    goal: str
    status: str
    bucket: str
    needs_user: bool
    created_at: str
    updated_at: str


class TaskIndexPage(ResponseModel):
    items: list[TaskIndexItem]
    next_cursor: str | None


class TimelineItem(ResponseModel):
    timeline_item_id: str
    display_order: int
    kind: str
    presentation_state: str
    title: str
    summary: str | None
    payload: JSONObject
    revision: int
    created_at: str
    updated_at: str


class ArtifactSummary(ResponseModel):
    artifact_id: str
    kind: str
    title: str
    current_revision_id: str | None


class Artifact(ArtifactSummary):
    task_id: str


class TaskView(ResponseModel):
    task: Task
    timeline: list[TimelineItem]
    artifacts: list[ArtifactSummary]
    pending_interaction: JSONObject | None
    result: JsonValue
    presentation_cursor: int
    work_summary: JSONObject | None = None


class ActionDispatch(ResponseModel):
    task_id: str
    action_id: str
    action_type: str
    payload: JSONObject
    status: Literal["dispatched"]
    runtime_action_status: str
    idempotency_key: str
    attempt_id: str
    attempt_number: int
    attempt_status: str
    dispatch_digest: str


class ActionResult(ResponseModel):
    task: Task
    action: JSONObject


class Trace(ResponseModel):
    task_id: str
    events: list[JSONObject]


class CapabilityStatusItem(ResponseModel):
    capability_id: str
    description: str
    post_verify_mode: str
    loading: str
    tags: list[str]
    source: JSONObject
    ready: bool


class CapabilityStatus(ResponseModel):
    capabilities: list[CapabilityStatusItem]
    mcp_servers: dict[str, JSONObject]


class PresentationEvent(ResponseModel):
    seq: int
    presentation_event_id: str
    task_id: str
    payload: JSONObject


class Accepted(ResponseModel):
    accepted: JSONObject


class AcceptedActionInput(Accepted):
    request: JSONObject


class Cancelled(Accepted):
    task: Task


class FileMetadata(ResponseModel):
    id: str
    name: str
    media_type: str
    size_bytes: int
    sha256: str
    category: str
    created_at: str
    metadata: JSONObject


class UploadState(ResponseModel):
    file_id: str
    offset: int
    complete: bool
    file: FileMetadata | None
    expected_size: int | None = None


class Materials(ResponseModel):
    inputs: list[FileMetadata]
    outputs: list[FileMetadata]
    progressive_outputs: list[FileMetadata]
    initial_input_ids: list[str]
    input_provenance: list[JSONObject]
    plan: JSONObject | None
    work_units: list[JSONObject]
    work_summary: JSONObject


class ObservationHealth(ResponseModel):
    schema_version: int = Field(alias="schema")
    ready: bool
    summary_interval_seconds: int


class ObservationView(ResponseModel):
    id: str
    status: str
    event_count: int
    last_seq: int
    summary_through_seq: int
    analysis_running: bool
    model_ready: bool
    last_error: str | None
    notes: list[JSONObject]
    questions: list[JSONObject]
    screen_insights: list[JSONObject]
    vision_running: bool


class ObservationAcknowledged(ResponseModel):
    acknowledged_ids: list[str]


class ObservationIngested(ObservationAcknowledged):
    session: ObservationView


class ObservationEvidence(ResponseModel):
    events: list[JSONObject]


class ObservationDeleted(ResponseModel):
    deleted: bool
    id: str
