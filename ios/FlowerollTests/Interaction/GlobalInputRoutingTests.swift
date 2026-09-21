import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Floweroll

extension RuntimeInteractionPolicyTests {

    func testGlobalHomeInputDefaultsToNewTaskWhenTaskAIsActive() {
        for text in [
            "帮我查一下明天杭州天气",
            "再帮我查杭州天气",
            "继续帮我查杭州天气",
            "接着订个酒店",
            "不要创建日程，查询我明天的安排",
        ] {
            XCTAssertEqual(
                FlowerollGlobalInputRoutingPolicy.route(
                    text: text,
                    currentHomeActiveTaskID: "task-a"
                ),
                .newTask,
                "an active Task alone must not capture an independent global input: \(text)"
            )
        }
    }

    func testExplicitCurrentTaskControlLanguageStillSteersCurrentTask() {
        for text in ["先别发送", "改成十点", "取消", "停止当前任务"] {
            XCTAssertEqual(
                FlowerollGlobalInputRoutingPolicy.route(
                    text: text,
                    currentHomeActiveTaskID: "task-a"
                ),
                .steerCurrentTask(taskID: "task-a"),
                text
            )
        }
    }

    func testContextDependentContinuationLanguageStaysOnCurrentTask() {
        for text in [
            "把下周一也加进去",
            "再加上周一",
            "继续把下周一也查一下",
        ] {
            XCTAssertEqual(
                FlowerollGlobalInputRoutingPolicy.route(
                    text: text,
                    currentHomeActiveTaskID: "task-a"
                ),
                .steerCurrentTask(taskID: "task-a"),
                "expected current-task continuation for: \(text)"
            )
        }
    }

    func testNoCurrentTaskAlwaysUsesNewTaskRoute() {
        for text in ["500以内", "新任务，帮我订酒店", "普通新请求", "改成十点"] {
            XCTAssertEqual(
                FlowerollGlobalInputRoutingPolicy.route(text: text, context: .none),
                .newTask,
                "without an exact current Task there is nothing to steer: \(text)"
            )
        }
    }

    func testPendingClarificationOnlyCapturesShapeCompatibleAnswer() {
        let budget = FlowerollPendingInteractionRoutingContext(
            kind: .clarification,
            id: "clar-budget",
            prompt: "预算上限是多少？",
            options: [],
            acceptsText: true,
            actionAttemptID: nil,
            bindingDigest: nil
        )
        XCTAssertEqual(
            FlowerollGlobalInputRoutingPolicy.route(
                text: "500以内",
                context: routingContext(pending: budget)
            ),
            .answerPendingInteraction(
                taskID: "task-a",
                interaction: budget,
                response: .text("500以内")
            )
        )
        XCTAssertEqual(
            FlowerollGlobalInputRoutingPolicy.route(
                text: "西湖附近",
                context: routingContext(pending: budget)
            ),
            .newTask,
            "an unrelated fragment must not be swallowed by the pending clarification"
        )

        let location = FlowerollPendingInteractionRoutingContext(
            kind: .clarification,
            id: "clar-location",
            prompt: "希望住在哪个区域？",
            options: [],
            acceptsText: true,
            actionAttemptID: nil,
            bindingDigest: nil
        )
        XCTAssertEqual(
            FlowerollGlobalInputRoutingPolicy.route(
                text: "西湖附近",
                context: routingContext(pending: location)
            ),
            .answerPendingInteraction(
                taskID: "task-a",
                interaction: location,
                response: .text("西湖附近")
            )
        )
        XCTAssertEqual(
            FlowerollGlobalInputRoutingPolicy.route(
                text: "500以内",
                context: routingContext(pending: location)
            ),
            .newTask
        )
    }

    func testPendingClarificationCapturesLongSameSubjectWorkflowCorrection() {
        let pending = FlowerollPendingInteractionRoutingContext(
            kind: .clarification,
            id: "clar-reminder-delete",
            prompt: "是否删除这条提醒？",
            options: [
                .init(id: "confirm_delete", label: "确认删除这条提醒"),
                .init(id: "keep", label: "暂时保留，不删除"),
            ],
            acceptsText: true,
            actionAttemptID: nil,
            bindingDigest: nil
        )
        let context = routingContext(pending: pending)
        let correction = "先查询确认这条提醒确实存在，再继续按原计划；真正删除时再向我确认。"

        XCTAssertEqual(
            FlowerollGlobalInputRoutingPolicy.route(text: correction, context: context),
            .answerPendingInteraction(
                taskID: "task-a",
                interaction: pending,
                response: .text(correction)
            )
        )
        XCTAssertEqual(
            FlowerollGlobalInputRoutingPolicy.route(
                text: "新任务，帮我查询提醒事项",
                context: context
            ),
            .newTask,
            "an explicit independent-task marker must still win"
        )
        XCTAssertEqual(
            FlowerollGlobalInputRoutingPolicy.route(
                text: "帮我查明天杭州天气",
                context: context
            ),
            .newTask,
            "same pending clarification must not capture an unrelated goal"
        )
    }

    func testPendingInteractionDoesNotCaptureUnrelatedIndependentGoal() {
        let pending = FlowerollPendingInteractionRoutingContext(
            kind: .clarification,
            id: "clar-budget",
            prompt: "预算上限是多少？",
            options: [],
            acceptsText: true,
            actionAttemptID: nil,
            bindingDigest: nil
        )
        let context = routingContext(pending: pending)

        for text in ["帮我查明天杭州天气", "停止播放音乐", "谢谢"] {
            XCTAssertEqual(
                FlowerollGlobalInputRoutingPolicy.route(text: text, context: context),
                .newTask,
                "unrelated global input must stay independent: \(text)"
            )
        }
    }

    func testPendingOptionsAndApprovalPreserveExactResponseSemantics() {
        let choice = FlowerollPendingInteractionRoutingContext(
            kind: .clarification,
            id: "clar-hotel",
            prompt: "你更偏向哪一个？",
            options: [
                .init(id: "hotel-1", label: "第一个方案"),
                .init(id: "hotel-2", label: "第二个方案"),
            ],
            acceptsText: true,
            actionAttemptID: nil,
            bindingDigest: nil
        )
        XCTAssertEqual(
            FlowerollGlobalInputRoutingPolicy.route(
                text: "选第二个",
                context: routingContext(pending: choice)
            ),
            .answerPendingInteraction(
                taskID: "task-a",
                interaction: choice,
                response: .option(id: "hotel-2")
            )
        )

        let approval = FlowerollPendingInteractionRoutingContext(
            kind: .actionInput,
            id: "input-1",
            prompt: "确认发送吗？",
            options: [],
            acceptsText: false,
            actionAttemptID: nil,
            bindingDigest: "digest-1"
        )
        XCTAssertEqual(
            FlowerollGlobalInputRoutingPolicy.route(
                text: "可以",
                context: routingContext(pending: approval)
            ),
            .answerPendingInteraction(
                taskID: "task-a",
                interaction: approval,
                response: .approval(true)
            )
        )
    }

    func testExplicitIndependentGoalMarkersCreateNewTask() {
        for text in [
            "新开一个任务",
            "新任务，帮我订酒店",
            "另开一个任务查天气",
            "单独查一下这家公司在哪个地铁站",
            "这个和当前任务分开做",
        ] {
            XCTAssertEqual(
                FlowerollGlobalInputRoutingPolicy.route(
                    text: text,
                    context: routingContext()
                ),
                .newTask,
                text
            )
        }
    }

    func testMixedInputPreservesCurrentOperationAndIndependentGoal() {
        XCTAssertEqual(
            FlowerollGlobalInputRoutingPolicy.route(
                text: "预算改成六百，顺便另开一个任务查机票",
                context: routingContext()
            ),
            .mixed(
                currentTaskID: "task-a",
                currentOperation: .userTurn(text: "预算改成六百"),
                newTaskText: "查机票"
            )
        )

        XCTAssertEqual(
            FlowerollGlobalInputRoutingPolicy.route(
                text: "改成十点，另外帮我查明天杭州天气",
                context: routingContext()
            ),
            .mixed(
                currentTaskID: "task-a",
                currentOperation: .userTurn(text: "改成十点"),
                newTaskText: "帮我查明天杭州天气"
            )
        )
    }

    func testNewTaskCarryoverMaterializesOnlyBoundedReferent() throws {
        let source = FlowerollRoutingReferentSourceSnapshot(
            taskID: "task-a",
            taskUpdatedAt: "2026-09-12T04:00:00Z",
            goal: "准备这家公司的面试材料",
            brief: "准备曼福科技面试材料"
        )
        let resolution = FlowerollGlobalInputRoutingPolicy.resolve(
            text: "单独查一下这家公司在哪个地铁站",
            context: routingContext(referentSource: source)
        )
        XCTAssertEqual(resolution.route, .newTask)
        let carryover = try XCTUnwrap(resolution.newTaskCarryover)
        XCTAssertEqual(carryover.binding.value, "曼福科技")
        XCTAssertEqual(carryover.binding.sourceTaskID, "task-a")
        XCTAssertEqual(carryover.materializedText, "单独查一下曼福科技在哪个地铁站")
    }

    func testMixedNewTaskHalfCanUseBoundedReferentCarryover() {
        let source = FlowerollRoutingReferentSourceSnapshot(
            taskID: "task-a",
            taskUpdatedAt: "2026-09-12T04:00:00Z",
            goal: "准备这家公司的面试材料",
            brief: "准备曼福科技面试材料"
        )
        let resolution = FlowerollGlobalInputRoutingPolicy.resolve(
            text: "预算改成六百，顺便另开一个任务查这家公司地址",
            context: routingContext(referentSource: source)
        )
        XCTAssertEqual(
            resolution.route,
            .mixed(
                currentTaskID: "task-a",
                currentOperation: .userTurn(text: "预算改成六百"),
                newTaskText: "查曼福科技地址"
            )
        )
        XCTAssertNil(resolution.newTaskCarryover)
    }

    func testDirectCancelCommandsNeverBecomeIndependentNewTaskIntent() {
        for text in [
            "取消", "停止", "取消任务。", "停止当前任务", "取消当前任务",
            "停止这个任务", "取消这个任务", "取消整个任务", "STOP", "cancel!"
        ] {
            XCTAssertTrue(FlowerollDirectTaskControlPolicy.isCancelCommand(text), text)
            XCTAssertEqual(
                FlowerollGlobalInputRoutingPolicy.route(
                    text: text,
                    context: routingContext()
                ),
                .steerCurrentTask(taskID: "task-a"),
                text
            )
        }
        for text in ["取消明天的会议", "停止创建闹钟", "帮我查天气", ""] {
            XCTAssertFalse(FlowerollDirectTaskControlPolicy.isCancelCommand(text), text)
        }
    }
}
