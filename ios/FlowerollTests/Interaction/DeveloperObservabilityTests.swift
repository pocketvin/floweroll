import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Floweroll

extension RuntimeInteractionPolicyTests {


    func testDeveloperObservabilityClientUsesReadOnlyAuthenticatedHostRouteAndDeveloperHeader() async throws {
        HomePresentationURLProtocol.install { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/developer/observability/tasks")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Floweroll-Developer-Mode"), "1")
            let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "limit" })?.value, "7")
            let body = #"{"tasks":[{"task_id":"11111111-1111-4111-8111-111111111111","goal":"开发者调试测试","status":"completed","created_at":"2026-09-14T10:00:00Z","updated_at":"2026-09-14T10:00:01Z","phase":"planning","planner_calls":2,"action_count":1}],"limit":7,"status":{"enabled":true,"capture_mode":"local_full","full_capture_available":true,"configuration_note":null,"read_only":true,"limitations":["read only"]}}"#
            return (200, Data(body.utf8))
        }

        let client = FlowerollHostClient(
            baseURL: try XCTUnwrap(URL(string: "http://localhost")),
            session: homePresentationSession()
        )
        let response = try await client.fetchDeveloperTaskIndex(limit: 7)
        XCTAssertTrue(response.status.readOnly)
        XCTAssertTrue(response.status.fullCaptureAvailable)
        XCTAssertEqual(response.tasks.map(\.goal), ["开发者调试测试"])
        XCTAssertEqual(response.tasks.first?.plannerCalls, 2)
        XCTAssertEqual(response.tasks.first?.actionCount, 1)
    }
}
