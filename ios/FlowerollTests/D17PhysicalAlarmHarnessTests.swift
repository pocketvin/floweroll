import Foundation
import XCTest
@testable import Floweroll

/// Signed physical-capable wrapper around the D16 phase engine.
///
/// Normal unit runs always skip this test. A future exact-candidate physical run
/// must explicitly set BOTH gates plus one bounded D16 phase. The test bundle is
/// hosted by the normal Floweroll app, so it reuses the already-provisioned
/// Floweroll development signing path instead of creating a new App ID/profile.
final class D17PhysicalAlarmHarnessTests: XCTestCase {
    @MainActor
    func testD17PhysicalAlarmHarnessPhase() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("D17 Alarm physical harness is real-device-only")
        #else
        let env = ProcessInfo.processInfo.environment
        guard env["FLOWEROLL_D17_PHYSICAL"] == "1" else {
            throw XCTSkip("Set FLOWEROLL_D17_PHYSICAL=1 only during the frozen-candidate physical acceptance window")
        }
        guard env["FLOWEROLL_D17_CONFIRM_FROZEN"] == "1" else {
            XCTFail("D17 physical harness requires FLOWEROLL_D17_CONFIRM_FROZEN=1")
            return
        }
        guard let phase = env["FLOWEROLL_D17_PHASE"], Self.allowedPhases.contains(phase) else {
            XCTFail("D17 physical harness requires one bounded FLOWEROLL_D17_PHASE")
            return
        }

        let result = try await D16Runner.execute(command: phase)
        let payload: [String: JSONValue] = [
            "schema": .number(1),
            "assignment_id": .string("D-20260913-build2-alarm-acceptance-harness-rework-17"),
            "phase": .string(phase),
            "ok": .bool(true),
            "result": .object(result),
            "identity": .object([
                "host_bundle_id": .string(Bundle.main.bundleIdentifier ?? "unknown"),
                "test_bundle_id": .string(Bundle(for: D17PhysicalAlarmHarnessTests.self).bundleIdentifier ?? "unknown"),
                "marketing_version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"),
                "build_number": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"),
                "system_version": .string(ProcessInfo.processInfo.operatingSystemVersionString),
            ]),
            "physical_final_acceptance": .string("NOT_RUN_OR_INCOMPLETE"),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        let line = String(decoding: data, as: UTF8.self)
        print("D17_RESULT \(line)")
        #endif
    }

    private static let allowedPhases: Set<String> = [
        "status",
        "request-auth",
        "core",
        "planner-update-prepare",
        "planner-update-recover",
        "ambiguous-title-prepare",
        "ambiguous-title-recover",
        "settings-update-prepare",
        "settings-update-recover",
        "countdown-pause-resume",
        "settings-cancel-prepare",
        "settings-cancel-recover",
        "ring-prepare",
        "ring-readback",
        "cancel-main",
        "cleanup",
        "purge-local",
    ]
}
