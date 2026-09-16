import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Floweroll

final class RuntimeInteractionPolicyTests: XCTestCase {
    override func tearDown() {
        HomePresentationURLProtocol.reset()
        super.tearDown()
    }

    func notifyRouteFixture(
        _ label: String,
        taskID: String = UUID().uuidString
    ) throws -> (suite: String, defaults: UserDefaults, store: NotifyUserRouteStore, route: NotifyUserRoute) {
        let suite = "RuntimeInteractionPolicyTests.notify-route.\(label).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = NotifyUserRouteStore(defaults: defaults)
        let route = NotifyUserRoute(
            taskID: taskID,
            actionID: UUID().uuidString,
            notificationID: NotifyUserConstants.stableNotificationID(idempotencyKey: label)
        )
        return (suite, defaults, store, route)
    }


    func homePresentationSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomePresentationURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func installHomePresentationResponses(exactPages: [HostTaskIndexPage]) {
        let sequence = HomePresentationPageSequence(exactPages)
        HomePresentationURLProtocol.install { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let page = query["thread_id"] == "thread-a"
                ? sequence.next()
                : HostTaskIndexPage(items: [], nextCursor: nil)
            return (200, try JSONEncoder.floweroll.encode(page))
        }
    }

    @MainActor
    func makeHomePresentationStore(
        ownership: HomePresentationOwnership,
        continuationTaskID: String? = nil,
        exactPages: [HostTaskIndexPage]
    ) -> (RuntimeTaskStore, UserDefaults, String) {
        let suiteName = "RuntimeInteractionPolicyTests.home-presentation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("http://localhost", forKey: RuntimeTaskStore.endpointDefaultsKey)
        RuntimeTaskStore.persistHomePresentationSelection(
            defaults: defaults,
            threadID: "thread-a",
            ownership: ownership
        )
        if let continuationTaskID {
            defaults.set(continuationTaskID, forKey: RuntimeTaskStore.continuationTaskDefaultsKey)
        }
        installHomePresentationResponses(exactPages: exactPages)
        return (
            RuntimeTaskStore(defaults: defaults, session: homePresentationSession()),
            defaults,
            suiteName
        )
    }

    func homePage(
        status: String,
        updatedAt: String = "2026-09-12T02:14:42Z"
    ) -> HostTaskIndexPage {
        HostTaskIndexPage(
            items: [
                HostTaskIndexItem(
                    taskID: "task-a",
                    submissionID: "submission-a",
                    threadID: "thread-a",
                    parentTaskID: nil,
                    title: "当前任务",
                    goal: "查询日程并总结",
                    status: status,
                    phase: status,
                    bucket: RuntimeTaskStore.isTerminalStatus(status) ? "history" : "running",
                    needsUser: status == "waiting",
                    latestTimeline: nil,
                    createdAt: "2026-09-12T02:14:41Z",
                    updatedAt: updatedAt
                )
            ],
            nextCursor: nil
        )
    }

    func routingContext(
        pending: FlowerollPendingInteractionRoutingContext? = nil,
        referentSource: FlowerollRoutingReferentSourceSnapshot? = nil
    ) -> FlowerollGlobalInputRoutingContext {
        FlowerollGlobalInputRoutingContext(
            currentTask: .init(
                taskID: "task-a",
                goal: "当前任务",
                pendingInteraction: pending,
                referentSource: referentSource
            )
        )
    }

    func continuedProcessingView(
        status: String,
        activeTitle: String? = nil,
        pendingInteraction: JSONValue? = nil,
        result: JSONValue? = nil,
        workSummary: HostWorkSummary? = nil
    ) -> HostTaskView {
        var timeline: [HostTimelineItem] = []
        if let activeTitle {
            timeline.append(HostTimelineItem(
                timelineItemID: "timeline-1",
                displayOrder: 1,
                kind: "TOOL_ACTIVITY",
                presentationState: "ACTIVE",
                title: activeTitle,
                summary: nil,
                payload: [:],
                revision: 1,
                createdAt: "2026-09-11T00:00:00Z",
                updatedAt: "2026-09-11T00:00:00Z"
            ))
        }
        return HostTaskView(
            task: HostTask(
                taskID: "task-live",
                submissionID: nil,
                threadID: "thread-live",
                parentTaskID: nil,
                goal: "测试后台任务",
                status: status,
                currentStep: 0,
                idempotentReplay: nil,
                createdAt: "2026-09-11T00:00:00Z",
                updatedAt: "2026-09-11T00:00:00Z"
            ),
            timeline: timeline,
            artifacts: [],
            pendingInteraction: pendingInteraction,
            result: result,
            presentationCursor: timeline.count,
            workSummary: workSummary
        )
    }


    func presentationTask(
        id: String,
        status: String,
        needsUser: Bool = false,
        updatedAt: String = "2026-09-12T10:00:00Z"
    ) -> HostTaskIndexItem {
        HostTaskIndexItem(
            taskID: id,
            submissionID: nil,
            threadID: "thread-\\(id)",
            parentTaskID: nil,
            title: id,
            goal: id,
            status: status,
            phase: nil,
            bucket: RuntimeTaskStore.isTerminalStatus(status) ? "history" : (needsUser ? "needs_user" : "running"),
            needsUser: needsUser,
            latestTimeline: nil,
            createdAt: "2026-09-12T09:00:00Z",
            updatedAt: updatedAt
        )
    }

    func threadIndexTask(
        id: String,
        threadID: String,
        status: String,
        title: String,
        latestSummary: String? = nil,
        createdAt: String,
        updatedAt: String
    ) -> HostTaskIndexItem {
        HostTaskIndexItem(
            taskID: id,
            submissionID: nil,
            threadID: threadID,
            parentTaskID: nil,
            title: title,
            goal: title,
            status: status,
            phase: RuntimeTaskStore.isTerminalStatus(status) ? nil : status,
            bucket: RuntimeTaskStore.isTerminalStatus(status) ? "history" : "running",
            needsUser: false,
            latestTimeline: latestSummary.map {
                HostTaskIndexItem.LatestTimeline(
                    title: title,
                    summary: $0,
                    updatedAt: updatedAt
                )
            },
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func threadPresentationView(
        id: String,
        threadID: String,
        status: String,
        goal: String? = nil,
        createdAt: String,
        updatedAt: String
    ) -> HostTaskView {
        HostTaskView(
            task: HostTask(
                taskID: id,
                submissionID: nil,
                threadID: threadID,
                parentTaskID: nil,
                goal: goal ?? id,
                status: status,
                currentStep: 0,
                idempotentReplay: nil,
                createdAt: createdAt,
                updatedAt: updatedAt
            ),
            timeline: [],
            artifacts: [],
            pendingInteraction: nil,
            result: nil,
            presentationCursor: 0,
            workSummary: nil
        )
    }

    func presentationView(
        id: String,
        status: String,
        updatedAt: String,
        cursor: Int = 0,
        pendingInteraction: JSONValue? = nil,
        result: JSONValue? = nil,
        threadID: String? = nil
    ) -> HostTaskView {
        HostTaskView(
            task: HostTask(
                taskID: id,
                submissionID: nil,
                threadID: threadID ?? "thread-\\(id)",
                parentTaskID: nil,
                goal: id,
                status: status,
                currentStep: 0,
                idempotentReplay: nil,
                createdAt: "2026-09-12T09:00:00Z",
                updatedAt: updatedAt
            ),
            timeline: [],
            artifacts: [],
            pendingInteraction: pendingInteraction,
            result: result,
            presentationCursor: cursor,
            workSummary: nil
        )
    }

    func presentationEvent(
        taskID: String,
        seq: Int,
        revision: Int
    ) -> HostPresentationEvent {
        HostPresentationEvent(
            seq: seq,
            presentationEventID: "event-\\(seq)",
            taskID: taskID,
            timelineItemID: "timeline-1",
            operation: "UPSERT",
            payload: HostTimelineDelta(
                timelineItemID: "timeline-1",
                kind: "AGENT_ACTIVITY",
                presentationState: "ACTIVE",
                title: "still processing",
                summary: nil,
                payload: [:],
                revision: revision
            ),
            attentionLevel: "AMBIENT",
            createdAt: "2026-09-12T10:02:00Z"
        )
    }

    func cancellationResponse(
        taskID: String,
        status: String,
        pending: Bool,
        updatedAt: String
    ) -> HostTaskCancellationResponse {
        HostTaskCancellationResponse(
            accepted: .object(["duplicate": .bool(false)]),
            task: .init(
                taskID: taskID,
                submissionID: "submission-\(taskID)",
                threadID: "thread-\(taskID)",
                parentTaskID: nil,
                goal: taskID,
                status: status,
                currentStep: 0,
                cancelRequestedAt: updatedAt,
                cancelReason: "user cancelled",
                cancellationPending: pending,
                createdAt: "2026-09-13T02:00:00Z",
                updatedAt: updatedAt
            )
        )
    }

    func terminalReviewTask(
        id: String,
        threadID: String,
        status: String = "completed",
        updatedAt: String
    ) -> HostTaskIndexItem {
        HostTaskIndexItem(
            taskID: id,
            submissionID: nil,
            threadID: threadID,
            parentTaskID: nil,
            title: id,
            goal: id,
            status: status,
            phase: nil,
            bucket: "history",
            needsUser: false,
            latestTimeline: nil,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }

    func completionAttentionTask(
        id: String,
        status: String = "completed",
        updatedAt: String
    ) -> HostTaskIndexItem {
        HostTaskIndexItem(
            taskID: id,
            submissionID: nil,
            threadID: "thread-\(id)",
            parentTaskID: nil,
            title: id,
            goal: id,
            status: status,
            phase: nil,
            bucket: "history",
            needsUser: false,
            latestTimeline: nil,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }

    func task(id: String, status: String) -> HostTaskIndexItem {
        HostTaskIndexItem(
            taskID: id,
            submissionID: nil,
            threadID: "thread",
            parentTaskID: nil,
            title: id,
            goal: id,
            status: status,
            phase: nil,
            bucket: RuntimeTaskStore.isTerminalStatus(status) ? "history" : "running",
            needsUser: false,
            latestTimeline: nil,
            createdAt: "2026-09-11T00:00:00Z",
            updatedAt: "2026-09-11T00:00:00Z"
        )
    }
}
