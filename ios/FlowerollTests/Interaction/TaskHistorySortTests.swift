import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Floweroll

extension RuntimeInteractionPolicyTests {


    func testHostDateParserHandlesOffsetsFractionsAndInvalidValues() throws {
        let instant = try XCTUnwrap(RuntimeTaskStore.hostDate("2030-01-02T07:00:00+08:00"))
        for raw in ["2030-01-01T23:00:00Z", "2030-01-01T23:00:00.000Z",
                    "2030-01-01T18:00:00-05:00", "2030-01-02T04:30:00+05:30"] {
            XCTAssertEqual(try XCTUnwrap(RuntimeTaskStore.hostDate(raw)), instant)
        }
        let fractional = try XCTUnwrap(RuntimeTaskStore.hostDate("2026-09-14T15:14:51.484723+00:00"))
        let seconds = try XCTUnwrap(RuntimeTaskStore.hostDate("2026-09-14T15:14:51Z"))
        XCTAssertEqual(fractional.timeIntervalSince(seconds), 0.484723, accuracy: 0.000001)
        XCTAssertNil(RuntimeTaskStore.hostDate(""))
        XCTAssertNil(RuntimeTaskStore.hostDate("not-a-timestamp"))
        XCTAssertNil(RuntimeTaskStore.hostDate("2026-99-99T99:99:99Z"))
    }

    func testHistorySortComputesExactlyOneKeyPerRow() {
        let items: [TaskListHistoryItem] = (0..<56).map { offset in
            let index = (offset * 17) % 56
            return .runtime(terminalReviewTask(id: "sort-\(index)", threadID: "thread-\(index)",
                updatedAt: String(format: "2026-09-13T12:%02d:00.484723+00:00", index)))
        }
        var keyCount = 0
        let sorted = TaskListHistoryItem.newestFirst(items) { item in
            keyCount += 1
            return item.sortDate
        }
        XCTAssertEqual(keyCount, items.count, "Date parsing must not run in the comparator")
        XCTAssertEqual(sorted.map(\.id), (0..<56).reversed().map { "task:sort-\($0)" })
        XCTAssertTrue(TaskListHistoryItem.newestFirst([]).isEmpty)
    }

    func testHistorySortPreservesEqualInstantsAndPlacesInvalidDatesLast() {
        let items: [TaskListHistoryItem] = [
            .runtime(terminalReviewTask(id: "invalid", threadID: "t-invalid", updatedAt: "invalid")),
            .runtime(terminalReviewTask(id: "local", threadID: "t-local", updatedAt: "2030-01-02T07:00:00+08:00")),
            .runtime(terminalReviewTask(id: "utc", threadID: "t-utc", updatedAt: "2030-01-01T23:00:00.000Z")),
            .runtime(terminalReviewTask(id: "later", threadID: "t-later", updatedAt: "2030-01-02T00:00:00Z"))
        ]
        XCTAssertEqual(TaskListHistoryItem.newestFirst(items).map(\.id),
                       ["task:later", "task:local", "task:utc", "task:invalid"])
    }
}
