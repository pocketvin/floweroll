import Foundation


enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }
}

struct PendingSubmission: Codable, Equatable, Sendable, Identifiable {
    let submissionID: String
    let text: String
    let invocationSource: String
    let parentTaskID: String?
    let createdAt: Date
    var attachments: [PendingAttachment]? = nil
    var attemptCount: Int = 0
    var lastAttemptAt: Date? = nil
    var lastErrorMessage: String? = nil

    var id: String { submissionID }

    enum CodingKeys: String, CodingKey {
        case submissionID, text, invocationSource, parentTaskID, createdAt, attachments
        case attemptCount, lastAttemptAt, lastErrorMessage
    }

    init(
        submissionID: String,
        text: String,
        invocationSource: String,
        parentTaskID: String?,
        createdAt: Date,
        attachments: [PendingAttachment]? = nil,
        attemptCount: Int = 0,
        lastAttemptAt: Date? = nil,
        lastErrorMessage: String? = nil
    ) {
        self.submissionID = submissionID
        self.text = text
        self.invocationSource = invocationSource
        self.parentTaskID = parentTaskID
        self.createdAt = createdAt
        self.attachments = attachments
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
        self.lastErrorMessage = lastErrorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        submissionID = try container.decode(String.self, forKey: .submissionID)
        text = try container.decode(String.self, forKey: .text)
        invocationSource = try container.decode(String.self, forKey: .invocationSource)
        parentTaskID = try container.decodeIfPresent(String.self, forKey: .parentTaskID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        attachments = try container.decodeIfPresent([PendingAttachment].self, forKey: .attachments)
        attemptCount = try container.decodeIfPresent(Int.self, forKey: .attemptCount) ?? 0
        lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        lastErrorMessage = try container.decodeIfPresent(String.self, forKey: .lastErrorMessage)
    }
}

struct HostTask: Codable, Equatable, Sendable {
    let taskID: String
    let submissionID: String?
    let threadID: String
    let parentTaskID: String?
    let goal: String
    let status: String
    let currentStep: Int
    let idempotentReplay: Bool?
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case submissionID = "submission_id"
        case threadID = "thread_id"
        case parentTaskID = "parent_task_id"
        case goal
        case status
        case currentStep = "current_step"
        case idempotentReplay = "idempotent_replay"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct HostTaskRetryResponse: Codable, Equatable, Sendable {
    let task: HostTask
    let resumed: Bool
}


struct HostTaskCancellationResponse: Codable, Equatable, Sendable {
    struct TaskSnapshot: Codable, Equatable, Sendable {
        let taskID: String
        let submissionID: String?
        let threadID: String
        let parentTaskID: String?
        let goal: String
        let status: String
        let currentStep: Int
        let cancelRequestedAt: String?
        let cancelReason: String?
        let cancellationPending: Bool?
        let createdAt: String
        let updatedAt: String

        enum CodingKeys: String, CodingKey {
            case taskID = "task_id"
            case submissionID = "submission_id"
            case threadID = "thread_id"
            case parentTaskID = "parent_task_id"
            case goal
            case status
            case currentStep = "current_step"
            case cancelRequestedAt = "cancel_requested_at"
            case cancelReason = "cancel_reason"
            case cancellationPending = "cancellation_pending"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    let accepted: JSONValue
    let task: TaskSnapshot
}

struct DeviceActionDispatch: Codable, Equatable, Sendable {
    let actionID: String
    let taskID: String
    let actionType: String
    let payload: [String: JSONValue]
    let status: String
    let runtimeActionStatus: String?
    var onVerified: String? = nil
    let idempotencyKey: String
    let attemptID: String
    let attemptNumber: Int
    let attemptStatus: String
    let dispatchDigest: String
    var reconciliationOnly: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case actionID = "action_id"
        case taskID = "task_id"
        case actionType = "action_type"
        case payload
        case status
        case runtimeActionStatus = "runtime_action_status"
        case onVerified = "on_verified"
        case idempotencyKey = "idempotency_key"
        case attemptID = "attempt_id"
        case attemptNumber = "attempt_number"
        case attemptStatus = "attempt_status"
        case dispatchDigest = "dispatch_digest"
        case reconciliationOnly = "reconciliation_only"
    }
}

struct HostTaskIndexItem: Codable, Equatable, Sendable {
    struct LatestTimeline: Codable, Equatable, Sendable {
        let title: String?
        let summary: String?
        let updatedAt: String?

        enum CodingKeys: String, CodingKey {
            case title
            case summary
            case updatedAt = "updated_at"
        }
    }

    let taskID: String
    let submissionID: String?
    let threadID: String
    let parentTaskID: String?
    let title: String
    let goal: String
    let status: String
    let phase: String?
    let bucket: String
    let needsUser: Bool
    let latestTimeline: LatestTimeline?
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case submissionID = "submission_id"
        case threadID = "thread_id"
        case parentTaskID = "parent_task_id"
        case title
        case goal
        case status
        case phase
        case bucket
        case needsUser = "needs_user"
        case latestTimeline = "latest_timeline"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct HostTaskIndexPage: Codable, Equatable, Sendable {
    let items: [HostTaskIndexItem]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }
}

struct HostWorkSummary: Codable, Sendable {
    struct Item: Codable, Sendable, Identifiable {
        let id: String
        let title: String
        let state: String
        let label: String
        let reason: String?
        let resultSummary: String?
        let dependsOn: [String]
        let fileIDs: [String]
        let missingInformation: [String]

        enum CodingKeys: String, CodingKey {
            case id, title, state, label, reason
            case dependsOn = "depends_on", fileIDs = "file_ids"
            case missingInformation = "missing_information"
            case resultSummary = "result_summary"
        }
    }
    let items: [Item]
    let total: Int
    let completed: Int
    let state: String
    let revision: String?

    var hasVerifiedCounts: Bool {
        total > 0 && total == items.count && completed >= 0 && completed <= total
            && completed == items.filter { $0.state == "completed" }.count
    }

    var fraction: Double? {
        hasVerifiedCounts ? Double(completed) / Double(total) : nil
    }
}

struct HostTaskRuntimeView: Codable, Equatable, Sendable {
    let phase: String
    let blockReason: String?

    enum CodingKeys: String, CodingKey {
        case phase
        case blockReason = "block_reason"
    }
}

struct HostTaskView: Codable, Sendable {
    let task: HostTask
    let runtime: HostTaskRuntimeView?
    let timeline: [HostTimelineItem]
    let artifacts: [ArtifactSummary]
    let pendingInteraction: JSONValue?
    let result: JSONValue?
    let presentationCursor: Int
    let workSummary: HostWorkSummary?

    init(
        task: HostTask,
        runtime: HostTaskRuntimeView? = nil,
        timeline: [HostTimelineItem],
        artifacts: [ArtifactSummary],
        pendingInteraction: JSONValue?,
        result: JSONValue?,
        presentationCursor: Int,
        workSummary: HostWorkSummary?
    ) {
        self.task = task
        self.runtime = runtime
        self.timeline = timeline
        self.artifacts = artifacts
        self.pendingInteraction = pendingInteraction
        self.result = result
        self.presentationCursor = presentationCursor
        self.workSummary = workSummary
    }

    // Unknown work has no invented denominator. A simple verified terminal
    // task can still complete without creating an unnecessary deliverable plan.
    var progressUnitCounts: (completed: Int64, total: Int64) {
        if let summary = workSummary, summary.hasVerifiedCounts {
            return (Int64(summary.completed), Int64(summary.total))
        }
        return task.status.lowercased() == "completed" ? (1, 1) : (0, -1)
    }

    enum CodingKeys: String, CodingKey {
        case task
        case runtime
        case timeline
        case artifacts
        case pendingInteraction = "pending_interaction"
        case result
        case presentationCursor = "presentation_cursor"
        case workSummary = "work_summary"
    }
}

struct HostTimelineItem: Codable, Equatable, Sendable {
    let timelineItemID: String
    let displayOrder: Int
    let kind: String
    let presentationState: String
    let title: String
    let summary: String?
    let payload: [String: JSONValue]
    let revision: Int
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case timelineItemID = "timeline_item_id"
        case displayOrder = "display_order"
        case kind
        case presentationState = "presentation_state"
        case title
        case summary
        case payload
        case revision
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var isUserVisible: Bool {
        !(kind.uppercased() == "AGENT_ACTIVITY"
          && presentationState.uppercased() != "ACTIVE")
    }
}

struct ArtifactSummary: Codable, Equatable, Sendable {
    let artifactID: String
    let kind: String
    let title: String
    let currentRevisionID: String?
    let currentRevisionNumber: Int?

    enum CodingKeys: String, CodingKey {
        case artifactID = "artifact_id"
        case kind
        case title
        case currentRevisionID = "current_revision_id"
        case currentRevisionNumber = "current_revision_number"
    }
}

struct HostProblem: Codable, Error, Sendable, CustomStringConvertible {
    let type: String?
    let title: String?
    let status: Int?
    let detail: String?
    let code: String?

    var description: String {
        [code, title, detail].compactMap { $0 }.joined(separator: ": ")
    }
}


struct HostTimelineDelta: Codable, Equatable, Sendable {
    let timelineItemID: String
    let kind: String
    let presentationState: String
    let title: String
    let summary: String?
    let payload: [String: JSONValue]
    let revision: Int

    enum CodingKeys: String, CodingKey {
        case timelineItemID = "timeline_item_id"
        case kind
        case presentationState = "presentation_state"
        case title
        case summary
        case payload
        case revision
    }
}

struct HostPresentationEvent: Codable, Equatable, Sendable {
    let seq: Int
    let presentationEventID: String
    let taskID: String
    let timelineItemID: String?
    let operation: String
    let payload: HostTimelineDelta
    let attentionLevel: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case seq
        case presentationEventID = "presentation_event_id"
        case taskID = "task_id"
        case timelineItemID = "timeline_item_id"
        case operation
        case payload
        case attentionLevel = "attention_level"
        case createdAt = "created_at"
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }
}

struct HostSuggestedOption: Equatable, Sendable, Identifiable {
    let id: String
    let label: String
}

enum HostPendingInteraction: Equatable, Sendable {
    case clarification(
        id: String,
        question: String,
        options: [HostSuggestedOption],
        acceptsText: Bool,
        reason: String?
    )
    case actionInput(
        id: String,
        attemptID: String?,
        prompt: String,
        options: [HostSuggestedOption],
        acceptsText: Bool,
        reason: String?,
        bindingDigest: String
    )

    static func parse(_ value: JSONValue?) -> HostPendingInteraction? {
        guard let object = value?.objectValue,
              let kind = object["kind"]?.stringValue
        else { return nil }

        func options(_ raw: JSONValue?) -> [HostSuggestedOption] {
            raw?.arrayValue?.compactMap { item in
                guard let object = item.objectValue,
                      let id = object["id"]?.stringValue,
                      let label = object["label"]?.stringValue
                else { return nil }
                return HostSuggestedOption(id: id, label: label)
            } ?? []
        }

        switch kind {
        case "clarification":
            guard let id = object["clarification_id"]?.stringValue,
                  let question = object["question"]?.stringValue
            else { return nil }
            return .clarification(
                id: id,
                question: question,
                options: options(object["suggested_options"]),
                acceptsText: object["accepts_text"]?.boolValue ?? false,
                reason: object["reason"]?.stringValue
            )
        case "action_input":
            guard let id = object["input_request_id"]?.stringValue,
                  let prompt = object["prompt"]?.stringValue,
                  let bindingDigest = object["binding_digest"]?.stringValue
            else { return nil }
            return .actionInput(
                id: id,
                attemptID: object["attempt_id"]?.stringValue,
                prompt: prompt,
                options: options(object["suggested_options"]),
                acceptsText: object["accepts_text"]?.boolValue ?? false,
                reason: object["reason"]?.stringValue,
                bindingDigest: bindingDigest
            )
        default:
            return nil
        }
    }
}

extension HostTaskView {
    var typedPendingInteraction: HostPendingInteraction? {
        HostPendingInteraction.parse(pendingInteraction)
    }
}

struct HostArtifactRevision: Codable, Equatable, Sendable, Identifiable {
    let revisionID: String
    let revisionNumber: Int
    let content: [String: JSONValue]?
    let contentDigest: String
    let createdBy: String
    let createdAt: String

    var id: String { revisionID }

    enum CodingKeys: String, CodingKey {
        case revisionID = "revision_id"
        case revisionNumber = "revision_number"
        case content
        case contentDigest = "content_digest"
        case createdBy = "created_by"
        case createdAt = "created_at"
    }
}

struct HostArtifact: Codable, Equatable, Sendable, Identifiable {
    let artifactID: String
    let taskID: String
    let kind: String
    let title: String
    let currentRevisionID: String?
    let finalRevisionID: String?
    let revisions: [HostArtifactRevision]

    var id: String { artifactID }

    enum CodingKeys: String, CodingKey {
        case artifactID = "artifact_id"
        case taskID = "task_id"
        case kind
        case title
        case currentRevisionID = "current_revision_id"
        case finalRevisionID = "final_revision_id"
        case revisions
    }
}

struct HostCapabilityStatusResponse: Codable, Equatable, Sendable {
    let capabilities: [HostCapabilityStatus]
}

struct HostCapabilityStatus: Codable, Equatable, Sendable, Identifiable {
    struct Source: Codable, Equatable, Sendable {
        let kind: String
        let serverID: String?
        let toolName: String?

        enum CodingKeys: String, CodingKey {
            case kind
            case serverID = "server_id"
            case toolName = "tool_name"
        }
    }

    let capabilityID: String
    let description: String
    let loading: String
    let tags: [String]
    let source: Source
    let ready: Bool

    var id: String { capabilityID }

    enum CodingKeys: String, CodingKey {
        case capabilityID = "capability_id"
        case description
        case loading
        case tags
        case source
        case ready
    }
}

// MARK: - Developer observability (read-only)

struct HostDeveloperObservabilityStatus: Codable, Equatable, Sendable {
    let enabled: Bool
    let captureMode: String
    let fullCaptureAvailable: Bool
    let configurationNote: String?
    let readOnly: Bool
    let limitations: [String]

    enum CodingKeys: String, CodingKey {
        case enabled
        case captureMode = "capture_mode"
        case fullCaptureAvailable = "full_capture_available"
        case configurationNote = "configuration_note"
        case readOnly = "read_only"
        case limitations
    }
}

struct HostDeveloperTaskIndexResponse: Codable, Equatable, Sendable {
    let tasks: [HostDeveloperTaskSummary]
    let limit: Int
    let status: HostDeveloperObservabilityStatus
}

struct HostDeveloperTaskSummary: Codable, Equatable, Sendable, Identifiable {
    let taskID: String
    let goal: String
    let status: String
    let createdAt: String
    let updatedAt: String
    let phase: String?
    let plannerCalls: Int?
    let actionCount: Int

    var id: String { taskID }

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case goal
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case phase
        case plannerCalls = "planner_calls"
        case actionCount = "action_count"
    }
}

struct HostDeveloperTaskOverview: Codable, Equatable, Sendable {
    struct Task: Codable, Equatable, Sendable {
        let taskID: String
        let goal: String
        let status: String
        let createdAt: String
        let updatedAt: String
        let threadID: String?
        let parentTaskID: String?
        let phase: String?
        let plannerCalls: Int?
        let runtimeRevision: Int?
        let blockReason: String?
        let waitKind: String?
        let wakeAt: String?

        enum CodingKeys: String, CodingKey {
            case taskID = "task_id"
            case goal, status
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case threadID = "thread_id"
            case parentTaskID = "parent_task_id"
            case phase
            case plannerCalls = "planner_calls"
            case runtimeRevision = "runtime_revision"
            case blockReason = "block_reason"
            case waitKind = "wait_kind"
            case wakeAt = "wake_at"
        }
    }

    struct Summary: Codable, Equatable, Sendable {
        let plannerCalls: Int
        let actions: Int
        let reportedTokensOnly: Int
        let modelMSSum: Double
        let fullCapturedCalls: Int
        let captureMode: String
        let cost: Double?
        let costNote: String

        enum CodingKeys: String, CodingKey {
            case plannerCalls = "planner_calls"
            case actions
            case reportedTokensOnly = "reported_tokens_only"
            case modelMSSum = "model_ms_sum"
            case fullCapturedCalls = "full_captured_calls"
            case captureMode = "capture_mode"
            case cost
            case costNote = "cost_note"
        }
    }

    struct PlannerCall: Codable, Equatable, Sendable, Identifiable {
        let callNumber: Int
        let startedAt: String?
        let endedAt: String?
        let durationMS: Double?
        let outcome: String
        let providerModel: String?
        let modelMS: Double?
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?
        let visibleCapabilities: [String]
        let captureAvailable: Bool
        let promptSHA256: String?
        let errorType: String?

        var id: Int { callNumber }

        enum CodingKeys: String, CodingKey {
            case callNumber = "call_number"
            case startedAt = "started_at"
            case endedAt = "ended_at"
            case durationMS = "duration_ms"
            case outcome
            case providerModel = "provider_model"
            case modelMS = "model_ms"
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
            case visibleCapabilities = "visible_capabilities"
            case captureAvailable = "capture_available"
            case promptSHA256 = "prompt_sha256"
            case errorType = "error_type"
        }
    }

    struct Action: Codable, Equatable, Sendable, Identifiable {
        let actionID: String
        let stepIndex: Int
        let actionType: String
        let status: String
        let failureCode: String?
        let errorText: String?
        let createdAt: String
        let updatedAt: String
        let attemptCount: Int

        var id: String { actionID }

        enum CodingKeys: String, CodingKey {
            case actionID = "action_id"
            case stepIndex = "step_index"
            case actionType = "action_type"
            case status
            case failureCode = "failure_code"
            case errorText = "error_text"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case attemptCount = "attempt_count"
        }
    }

    struct Evidence: Codable, Equatable, Sendable, Identifiable {
        let eventID: Int
        let eventType: String
        let createdAt: String
        let data: JSONValue

        var id: Int { eventID }

        enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case eventType = "event_type"
            case createdAt = "created_at"
            case data
        }
    }

    let task: Task
    let summary: Summary
    let plannerCalls: [PlannerCall]
    let actions: [Action]
    let evidence: [Evidence]
    let observability: HostDeveloperObservabilityStatus

    enum CodingKeys: String, CodingKey {
        case task, summary
        case plannerCalls = "planner_calls"
        case actions, evidence, observability
    }
}

struct HostDeveloperPlannerCallDetail: Codable, Equatable, Sendable {
    struct Metadata: Codable, Equatable, Sendable {
        let state: String?
        let startedAt: String?
        let endedAt: String?
        let requestBytes: Int?
        let requestSHA256: String?
        let providerModel: String?
        let errorType: String?
        let contentOmitted: String?
        let visibleCapabilities: [String]?
        let promptSHA256: String?

        enum CodingKeys: String, CodingKey {
            case state
            case startedAt = "started_at"
            case endedAt = "ended_at"
            case requestBytes = "request_bytes"
            case requestSHA256 = "request_sha256"
            case providerModel = "provider_model"
            case errorType = "error_type"
            case contentOmitted = "content_omitted"
            case visibleCapabilities = "visible_capabilities"
            case promptSHA256 = "prompt_sha256"
        }
    }

    struct Tools: Codable, Equatable, Sendable {
        let visible: [String]
        let definitions: [JSONValue]
        let note: String
    }

    let taskID: String
    let callNumber: Int
    let available: Bool
    let captureMode: String
    let metadata: Metadata
    let metrics: [[String: JSONValue]]
    let note: String
    let systemPrompt: String?
    let decisionContext: JSONValue?
    let tools: Tools?
    let wireRequest: JSONValue?
    let modelResponse: JSONValue?
    let promptMatchesCurrentSource: Bool?

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case callNumber = "call_number"
        case available
        case captureMode = "capture_mode"
        case metadata, metrics, note
        case systemPrompt = "system_prompt"
        case decisionContext = "decision_context"
        case tools
        case wireRequest = "wire_request"
        case modelResponse = "model_response"
        case promptMatchesCurrentSource = "prompt_matches_current_source"
    }
}
