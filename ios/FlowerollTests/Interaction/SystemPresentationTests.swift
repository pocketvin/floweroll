import Foundation
import XCTest
@testable import Floweroll

extension RuntimeInteractionPolicyTests {
    func testExecutionOwnerSplitUsesBGCPTInAppAndLongRunningForSystemEntry() throws {
        let appRoot = try ProductSourceFiles.iosRoot().appendingPathComponent("Floweroll/App")
        let home = try String(
            contentsOf: appRoot.appendingPathComponent("Home/HomeView.swift"),
            encoding: .utf8
        )
        let intents = try String(
            contentsOf: appRoot.appendingPathComponent("FlowerollIntents.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: appRoot.appendingPathComponent("RuntimeClient/DeviceBackgroundExecutionController.swift"),
            encoding: .utf8
        )
        let info = try String(
            contentsOf: appRoot.appendingPathComponent("Info.plist"),
            encoding: .utf8
        )

        XCTAssertTrue(home.contains("Button(intent: homeInAppIntent)"))
        XCTAssertTrue(intents.contains("struct HomeHouTaskIntent: AppIntent"))
        XCTAssertTrue(intents.contains("struct CaptureHouTaskIntent: LongRunningIntent, CancellableIntent"))
        XCTAssertEqual(intents.components(separatedBy: "performBackgroundTask").count - 1, 1)
        XCTAssertTrue(controller.contains("BGContinuedProcessingTaskRequest"))
        XCTAssertTrue(controller.contains("registerGlobalHandler"))
        XCTAssertTrue(controller.contains("runInAppContinuedPass()"))
        XCTAssertTrue(controller.contains("continuedTaskIDsKey"))
        XCTAssertTrue(info.contains("com.maxenceyu.floweroll.runtime.continued.*"))
        XCTAssertTrue(info.contains("com.maxenceyu.floweroll.runtime.recovery"))
    }

    func testLongRunningProgressUsesPublicSemanticStatusWithFiniteProgress() {
        let planner = continuedProcessingView(
            status: "active",
            activeTitle: "小卷正在思考"
        )
        let plannerUpdate = SystemEntryRuntimeCoordinator.progressUpdate(from: planner)
        XCTAssertEqual(plannerUpdate.title, "小卷正在处理")
        XCTAssertEqual(plannerUpdate.subtitle, "小卷正在思考")
        XCTAssertEqual(
            plannerUpdate.completedUnitCount,
            SystemEntryProgressPresentationPolicy.activeFloorUnitCount
        )
        XCTAssertEqual(
            plannerUpdate.totalUnitCount,
            SystemEntryProgressPresentationPolicy.totalUnitCount
        )

        let tool = continuedProcessingView(
            status: "active",
            activeTitle: "正在查看日程"
        )
        XCTAssertEqual(
            SystemEntryRuntimeCoordinator.progressUpdate(from: tool).subtitle,
            "正在查看日程"
        )
    }

    func testLongRunningProgressPreservesVerifiedWorkFraction() {
        let workSummary = HostWorkSummary(
            items: [
                HostWorkSummary.Item(
                    id: "calendar", title: "查看日程", state: "completed", label: "已完成",
                    reason: nil, resultSummary: "已读取", dependsOn: [], fileIDs: [], missingInformation: []
                ),
                HostWorkSummary.Item(
                    id: "report", title: "整理报告", state: "active", label: "处理中",
                    reason: nil, resultSummary: nil, dependsOn: ["calendar"], fileIDs: [], missingInformation: []
                ),
            ],
            total: 2,
            completed: 1,
            state: "active",
            revision: "r1"
        )
        let view = continuedProcessingView(
            status: "active",
            activeTitle: "正在整理报告",
            workSummary: workSummary
        )
        let update = SystemEntryRuntimeCoordinator.progressUpdate(from: view)
        XCTAssertEqual(
            update.completedUnitCount,
            SystemEntryProgressPresentationPolicy.activeFloorUnitCount
                + (SystemEntryProgressPresentationPolicy.activeCeilingUnitCount
                    - SystemEntryProgressPresentationPolicy.activeFloorUnitCount) / 2
        )
        XCTAssertEqual(update.totalUnitCount, SystemEntryProgressPresentationPolicy.totalUnitCount)
        XCTAssertEqual(update.subtitle, "正在整理报告")
    }

    func testWaitingWithoutHumanInputRemainsRealBackgroundWork() {
        let waiting = continuedProcessingView(
            status: "waiting",
            activeTitle: "等待重试"
        )
        let update = SystemEntryRuntimeCoordinator.progressUpdate(from: waiting)
        XCTAssertEqual(update.title, "小卷正在处理")
        XCTAssertEqual(update.subtitle, "等待重试")
        XCTAssertEqual(
            update.completedUnitCount,
            SystemEntryProgressPresentationPolicy.activeFloorUnitCount
        )
        XCTAssertLessThan(update.completedUnitCount, update.totalUnitCount)
    }

    func testNeedsUserDoesNotClaimBusinessCompletion() {
        let needsUser = continuedProcessingView(
            status: "waiting",
            pendingInteraction: .object([
                "kind": .string("clarification"),
                "clarification_id": .string("clar-1"),
                "question": .string("要把下周一也加入报告吗？"),
                "suggested_options": .array([]),
                "accepts_text": .bool(true),
            ])
        )
        let update = SystemEntryRuntimeCoordinator.progressUpdate(from: needsUser)
        XCTAssertEqual(update.title, "小卷需要你确认")
        XCTAssertEqual(update.subtitle, "要把下周一也加入报告吗？")
        XCTAssertEqual(
            update.completedUnitCount,
            SystemEntryProgressPresentationPolicy.activeCeilingUnitCount
        )
        XCTAssertLessThan(update.completedUnitCount, update.totalUnitCount)
    }

    func testActiveTaskCanNeedInputWhileAuthorizedWorkKeepsRunning() {
        let activeWithClarification = continuedProcessingView(
            status: "active",
            activeTitle: "正在创建提醒",
            pendingInteraction: .object([
                "kind": .string("clarification"),
                "clarification_id": .string("clar-active"),
                "question": .string("酒店预算是多少？"),
                "suggested_options": .array([]),
                "accepts_text": .bool(true),
            ])
        )
        XCTAssertEqual(activeWithClarification.runtimeStateDimensions.lifecycle, .active)
        XCTAssertEqual(activeWithClarification.runtimeStateDimensions.interaction, .clarification)
        XCTAssertEqual(activeWithClarification.presentationTruth.state, .needsUser)

        let update = SystemEntryRuntimeCoordinator.progressUpdate(from: activeWithClarification)
        XCTAssertEqual(update.title, "小卷正在处理")
        XCTAssertEqual(update.subtitle, "正在创建提醒")
        XCTAssertLessThan(update.completedUnitCount, update.totalUnitCount)
    }

    func testTerminalHostTruthWinsOverStalePendingInteraction() {
        let staleInteraction: JSONValue = .object([
            "kind": .string("clarification"),
            "clarification_id": .string("stale"),
            "question": .string("过期的提问"),
            "suggested_options": .array([]),
            "accepts_text": .bool(true),
        ])
        for status in ["completed", "failed", "cancelled", "blocked"] {
            let view = continuedProcessingView(
                status: status,
                pendingInteraction: staleInteraction,
                result: status == "completed"
                    ? .object(["summary": .string("已经完成")])
                    : nil
            )
            let update = SystemEntryRuntimeCoordinator.progressUpdate(from: view)
            XCTAssertEqual(update.completedUnitCount, update.totalUnitCount)
            XCTAssertNotEqual(update.title, "小卷需要你确认")
        }
    }

    func testOrdinaryTaskTerminalNotificationIsSuppressedOnlyWhileAppActive() {
        XCTAssertFalse(FlowerollTaskTerminalNotificationPolicy.shouldSchedule(appIsActive: true))
        XCTAssertTrue(FlowerollTaskTerminalNotificationPolicy.shouldSchedule(appIsActive: false))
    }

    func testRecoveryControllerKeepsBGCPTAndBGProcessingAsSeparateLanes() throws {
        let sourceURL = try ProductSourceFiles.iosRoot()
            .appendingPathComponent("Floweroll/App/RuntimeClient/DeviceBackgroundExecutionController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(source.contains("migrateContinuedProcessingToFallbackIfNeeded"))
        XCTAssertFalse(source.contains("ensureCustomActivityFallback"))
        XCTAssertTrue(source.contains("BGContinuedProcessingTaskRequest"))
        XCTAssertTrue(source.contains("BGProcessingTaskRequest(identifier: Self.recoveryIdentifier)"))
        XCTAssertTrue(source.contains("continuedTaskIDsKey"))
        XCTAssertTrue(source.contains("trackedTaskIDsKey"))
    }

    func testQueuedBackgroundRecoveryIsNotReplacedByRepeatedRefreshes() {
        let identifier = "floweroll.recovery"
        XCTAssertTrue(BackgroundRecoveryRequestPolicy.shouldSubmit(identifier: identifier, pendingIdentifiers: []))
        XCTAssertTrue(BackgroundRecoveryRequestPolicy.shouldSubmit(identifier: identifier, pendingIdentifiers: ["other.app.task"]))
        for _ in 0..<100 {
            XCTAssertFalse(BackgroundRecoveryRequestPolicy.shouldSubmit(identifier: identifier, pendingIdentifiers: [identifier]))
        }
        XCTAssertTrue(
            BackgroundRecoveryRequestPolicy.shouldSubmit(identifier: identifier, pendingIdentifiers: []),
            "After the queued task is launched or removed, recovery may be scheduled again"
        )
    }
}
