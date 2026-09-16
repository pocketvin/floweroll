import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Floweroll

extension RuntimeInteractionPolicyTests {

    func testInstalledExecutableIdentityProbeExportsExactBytesAndCleansExactNonce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("b24-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("Floweroll")
        let sourceBytes = Data([0xCF, 0xFA, 0xED, 0xFE, 0x00, 0x01, 0x7F, 0xAA])
        try sourceBytes.write(to: executable)
        let appSupport = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let nonce = "0123456789abcdef0123456789abcdef"
        let request = InstalledExecutableIdentityProbe.Request(
            mode: .export, runNonce: nonce, targetDeviceUDID: "fixture-device",
            expectedBundleID: "com.maxenceyu.floweroll",
            expectedMarketingVersion: "0.1.1", expectedBuildNumber: "2"
        )
        let identity = InstalledExecutableIdentityProbe.BundleIdentity(
            bundleID: request.expectedBundleID,
            marketingVersion: request.expectedMarketingVersion,
            buildNumber: request.expectedBuildNumber
        )
        let metadata = try InstalledExecutableIdentityProbe.export(
            request: request, executableURL: executable, applicationSupportURL: appSupport,
            actualIdentity: identity, now: Date(timeIntervalSince1970: 1_789_257_600)
        )
        let runDirectory = appSupport
            .appendingPathComponent("FlowerollInstalledExecutableReadback", isDirectory: true)
            .appendingPathComponent(nonce, isDirectory: true)
        let copied = runDirectory.appendingPathComponent(InstalledExecutableIdentityProbe.executableFileName)
        XCTAssertEqual(try Data(contentsOf: copied), sourceBytes)
        XCTAssertEqual(metadata.executableSizeBytes, sourceBytes.count)
        XCTAssertEqual(metadata.exportedSizeBytes, sourceBytes.count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: runDirectory.appendingPathComponent("metadata.json").path))
        let cleanup = InstalledExecutableIdentityProbe.Request(
            mode: .cleanup, runNonce: nonce, targetDeviceUDID: request.targetDeviceUDID,
            expectedBundleID: request.expectedBundleID,
            expectedMarketingVersion: request.expectedMarketingVersion,
            expectedBuildNumber: request.expectedBuildNumber
        )
        try InstalledExecutableIdentityProbe.cleanup(request: cleanup, applicationSupportURL: appSupport)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runDirectory.path))
    }

    func testInstalledExecutableIdentityProbeRejectsStaleSameNonceDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("b24-probe-stale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("Floweroll")
        try Data("candidate-bytes".utf8).write(to: executable)
        let appSupport = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let request = InstalledExecutableIdentityProbe.Request(
            mode: .export, runNonce: "abcdef0123456789abcdef0123456789", targetDeviceUDID: "fixture-device",
            expectedBundleID: "com.maxenceyu.floweroll",
            expectedMarketingVersion: "0.1.1", expectedBuildNumber: "2"
        )
        let identity = InstalledExecutableIdentityProbe.BundleIdentity(
            bundleID: request.expectedBundleID,
            marketingVersion: request.expectedMarketingVersion,
            buildNumber: request.expectedBuildNumber
        )
        _ = try InstalledExecutableIdentityProbe.export(
            request: request, executableURL: executable, applicationSupportURL: appSupport, actualIdentity: identity
        )
        XCTAssertThrowsError(try InstalledExecutableIdentityProbe.export(
            request: request, executableURL: executable, applicationSupportURL: appSupport, actualIdentity: identity
        )) { error in
            XCTAssertEqual(error as? InstalledExecutableIdentityProbeError, .staleRunDirectory)
        }
    }
}
