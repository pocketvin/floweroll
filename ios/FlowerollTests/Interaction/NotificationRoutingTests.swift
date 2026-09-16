import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Floweroll

extension RuntimeInteractionPolicyTests {

    func testExplicitTaskDetailRouteOutranksPendingNotificationRoute() {
        XCTAssertFalse(RuntimeTaskDetailRoutePolicy.shouldConsumePendingNotification(
            currentLinkedTaskID: "task-explicit"
        ))
        XCTAssertFalse(RuntimeTaskDetailRoutePolicy.shouldConsumePendingNotification(
            currentLinkedTaskID: nil,
            tasksTabIsActive: true
        ))
        XCTAssertTrue(RuntimeTaskDetailRoutePolicy.shouldConsumePendingNotification(
            currentLinkedTaskID: nil,
            tasksTabIsActive: false
        ))
    }

    func testDeferredNotifyRouteOnTasksTabRedrivesOnLeaveAndConsumesExactOnce() throws {
        let fixture = try notifyRouteFixture("tasks-deferred")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        fixture.store.record(fixture.route)

        XCTAssertNil(AppShellNotifyUserRouteRouting.consumePendingRoute(
            store: fixture.store,
            currentLinkedTaskID: nil,
            tasksTabIsActive: true
        ))
        XCTAssertEqual(fixture.store.peek(), fixture.route)
        XCTAssertFalse(RuntimeTaskDetailRoutePolicy.shouldRedrivePendingNotification(
            previousLinkedTaskID: nil,
            currentLinkedTaskID: nil,
            previousTasksTabIsActive: true,
            currentTasksTabIsActive: true
        ))
        XCTAssertTrue(RuntimeTaskDetailRoutePolicy.shouldRedrivePendingNotification(
            previousLinkedTaskID: nil,
            currentLinkedTaskID: nil,
            previousTasksTabIsActive: true,
            currentTasksTabIsActive: false
        ))

        let consumed = AppShellNotifyUserRouteRouting.consumePendingRoute(
            store: fixture.store,
            currentLinkedTaskID: nil,
            tasksTabIsActive: false
        )
        XCTAssertEqual(consumed, fixture.route)
        XCTAssertNil(fixture.store.peek())
        XCTAssertNil(AppShellNotifyUserRouteRouting.consumePendingRoute(
            store: fixture.store,
            currentLinkedTaskID: nil,
            tasksTabIsActive: false
        ), "a consumed deferred notification route must not replay on later tab transitions")
    }

    func testDeferredNotifyRouteBehindLinkedTaskRedrivesOnlyAfterExactOwnerClears() throws {
        let taskA = UUID().uuidString
        let taskB = UUID().uuidString
        let fixture = try notifyRouteFixture("linked-deferred", taskID: taskB)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        fixture.store.record(fixture.route)

        XCTAssertNil(AppShellNotifyUserRouteRouting.consumePendingRoute(
            store: fixture.store,
            currentLinkedTaskID: taskA,
            tasksTabIsActive: false
        ))
        XCTAssertEqual(fixture.store.peek()?.taskID, taskB)
        XCTAssertFalse(RuntimeTaskDetailRoutePolicy.shouldRedrivePendingNotification(
            previousLinkedTaskID: taskA,
            currentLinkedTaskID: taskA,
            previousTasksTabIsActive: false,
            currentTasksTabIsActive: false
        ))
        XCTAssertTrue(RuntimeTaskDetailRoutePolicy.shouldRedrivePendingNotification(
            previousLinkedTaskID: taskA,
            currentLinkedTaskID: nil,
            previousTasksTabIsActive: false,
            currentTasksTabIsActive: false
        ))

        let consumed = try XCTUnwrap(AppShellNotifyUserRouteRouting.consumePendingRoute(
            store: fixture.store,
            currentLinkedTaskID: nil,
            tasksTabIsActive: false
        ))
        XCTAssertEqual(consumed.taskID, taskB)
        XCTAssertNotEqual(consumed.taskID, taskA)
        XCTAssertNil(fixture.store.peek())
    }

    func testDeferredNotifyRouteBlockerStaysZeroConsume() throws {
        let fixture = try notifyRouteFixture("still-blocked")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        fixture.store.record(fixture.route)

        for _ in 0..<3 {
            XCTAssertNil(AppShellNotifyUserRouteRouting.consumePendingRoute(
                store: fixture.store,
                currentLinkedTaskID: nil,
                tasksTabIsActive: true
            ))
        }
        XCTAssertEqual(fixture.store.peek(), fixture.route)
    }

    func testDeferredNotifyRouteSuccessfulConsumeDoesNotReplay() throws {
        let fixture = try notifyRouteFixture("consume-once")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        fixture.store.record(fixture.route)

        XCTAssertEqual(AppShellNotifyUserRouteRouting.consumePendingRoute(
            store: fixture.store,
            currentLinkedTaskID: nil,
            tasksTabIsActive: false
        ), fixture.route)
        XCTAssertNil(AppShellNotifyUserRouteRouting.consumePendingRoute(
            store: fixture.store,
            currentLinkedTaskID: nil,
            tasksTabIsActive: false
        ))
    }

    func testDeferredNotifyRouteStaleExactTargetNeverFallsBackToUnrelatedTask() throws {
        let staleTaskB = UUID().uuidString
        let unrelatedCurrentTask = UUID().uuidString
        let unrelatedLatestTask = UUID().uuidString
        let fixture = try notifyRouteFixture("stale-exact", taskID: staleTaskB)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        fixture.store.record(fixture.route)

        let consumed = try XCTUnwrap(AppShellNotifyUserRouteRouting.consumePendingRoute(
            store: fixture.store,
            currentLinkedTaskID: nil,
            tasksTabIsActive: false
        ))
        XCTAssertEqual(consumed.taskID, staleTaskB)
        XCTAssertNotEqual(consumed.taskID, unrelatedCurrentTask)
        XCTAssertNotEqual(consumed.taskID, unrelatedLatestTask)
        XCTAssertNil(fixture.store.peek())
    }
}
