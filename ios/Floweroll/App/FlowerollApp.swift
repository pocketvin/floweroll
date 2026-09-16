import Foundation
import SwiftUI
import UserNotifications


struct InstalledExecutableIdentityProbeMetadata: Codable, Equatable {
    let schema: Int
    let runNonce: String
    let targetDeviceUDID: String
    let bundleID: String
    let marketingVersion: String
    let buildNumber: String
    let executableFileName: String
    let executableSizeBytes: Int
    let exportedSizeBytes: Int
    let createdAt: String
}


enum InstalledExecutableIdentityProbeError: Error, Equatable {
    case invalidRequest
    case bundleIdentityMismatch
    case missingExecutable
    case staleRunDirectory
    case emptyExecutable
    case sizeMismatch
}


enum InstalledExecutableIdentityProbe {
    static let launchArgument = "--floweroll-installed-executable-readback-v1"
    static let relativeRoot = "Library/Application Support/FlowerollInstalledExecutableReadback"
    static let executableFileName = "installed-executable"
    static let metadataFileName = "metadata.json"

    private static let modeKey = "FLOWEROLL_EXECUTABLE_PROBE_MODE"
    private static let nonceKey = "FLOWEROLL_EXECUTABLE_PROBE_NONCE"
    private static let deviceKey = "FLOWEROLL_EXECUTABLE_PROBE_DEVICE_UDID"
    private static let bundleKey = "FLOWEROLL_EXECUTABLE_PROBE_BUNDLE_ID"
    private static let versionKey = "FLOWEROLL_EXECUTABLE_PROBE_MARKETING_VERSION"
    private static let buildKey = "FLOWEROLL_EXECUTABLE_PROBE_BUILD_NUMBER"

    struct Request: Equatable {
        enum Mode: String {
            case export
            case cleanup
        }

        let mode: Mode
        let runNonce: String
        let targetDeviceUDID: String
        let expectedBundleID: String
        let expectedMarketingVersion: String
        let expectedBuildNumber: String
    }

    struct BundleIdentity: Equatable {
        let bundleID: String
        let marketingVersion: String
        let buildNumber: String
    }

    static func request(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Request? {
        guard arguments.contains(launchArgument) else { return nil }
        guard let rawMode = environment[modeKey],
              let mode = Request.Mode(rawValue: rawMode),
              let runNonce = environment[nonceKey],
              isValidNonce(runNonce),
              let targetDeviceUDID = nonempty(environment[deviceKey]),
              let bundleID = nonempty(environment[bundleKey]),
              let version = nonempty(environment[versionKey]),
              let build = nonempty(environment[buildKey])
        else {
            throw InstalledExecutableIdentityProbeError.invalidRequest
        }
        return Request(
            mode: mode,
            runNonce: runNonce,
            targetDeviceUDID: targetDeviceUDID,
            expectedBundleID: bundleID,
            expectedMarketingVersion: version,
            expectedBuildNumber: build
        )
    }

    static func runIfRequested() {
        do {
            guard let request = try request() else { return }
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw InstalledExecutableIdentityProbeError.invalidRequest
            }
            let bundle = Bundle.main
            let identity = BundleIdentity(
                bundleID: bundle.bundleIdentifier ?? "",
                marketingVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            )
            try validateExpectedBundleIdentity(request: request, actual: identity)
            switch request.mode {
            case .export:
                guard let executableURL = bundle.executableURL else {
                    throw InstalledExecutableIdentityProbeError.missingExecutable
                }
                _ = try export(
                    request: request,
                    executableURL: executableURL,
                    applicationSupportURL: applicationSupport,
                    actualIdentity: identity
                )
            case .cleanup:
                try cleanup(request: request, applicationSupportURL: applicationSupport)
            }
        } catch {
            // The Mac-side candidate gate treats missing/malformed readback as
            // fatal. This message is diagnostic only and is never identity proof.
            fputs("floweroll executable identity probe failed: \(error)\n", stderr)
        }
    }

    @discardableResult
    static func export(
        request: Request,
        executableURL: URL,
        applicationSupportURL: URL,
        actualIdentity: BundleIdentity,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> InstalledExecutableIdentityProbeMetadata {
        try validateExpectedBundleIdentity(request: request, actual: actualIdentity)
        guard fileManager.fileExists(atPath: executableURL.path) else {
            throw InstalledExecutableIdentityProbeError.missingExecutable
        }
        let sourceSize = try fileSize(executableURL, fileManager: fileManager)
        guard sourceSize > 0 else { throw InstalledExecutableIdentityProbeError.emptyExecutable }

        let root = applicationSupportURL
            .appendingPathComponent("FlowerollInstalledExecutableReadback", isDirectory: true)
        let runDirectory = root.appendingPathComponent(request.runNonce, isDirectory: true)
        guard !fileManager.fileExists(atPath: runDirectory.path) else {
            throw InstalledExecutableIdentityProbeError.staleRunDirectory
        }
        try fileManager.createDirectory(at: runDirectory, withIntermediateDirectories: true)

        let partialExecutable = runDirectory.appendingPathComponent("\(executableFileName).part")
        let exportedExecutable = runDirectory.appendingPathComponent(executableFileName)
        try fileManager.copyItem(at: executableURL, to: partialExecutable)
        try fileManager.moveItem(at: partialExecutable, to: exportedExecutable)
        let exportedSize = try fileSize(exportedExecutable, fileManager: fileManager)
        guard exportedSize > 0 else { throw InstalledExecutableIdentityProbeError.emptyExecutable }
        guard exportedSize == sourceSize else { throw InstalledExecutableIdentityProbeError.sizeMismatch }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let metadata = InstalledExecutableIdentityProbeMetadata(
            schema: 1,
            runNonce: request.runNonce,
            targetDeviceUDID: request.targetDeviceUDID,
            bundleID: actualIdentity.bundleID,
            marketingVersion: actualIdentity.marketingVersion,
            buildNumber: actualIdentity.buildNumber,
            executableFileName: executableFileName,
            executableSizeBytes: sourceSize,
            exportedSizeBytes: exportedSize,
            createdAt: formatter.string(from: now)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let metadataData = try encoder.encode(metadata)
        try metadataData.write(
            to: runDirectory.appendingPathComponent(metadataFileName),
            options: .atomic
        )
        return metadata
    }

    static func cleanup(
        request: Request,
        applicationSupportURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let runDirectory = applicationSupportURL
            .appendingPathComponent("FlowerollInstalledExecutableReadback", isDirectory: true)
            .appendingPathComponent(request.runNonce, isDirectory: true)
        if fileManager.fileExists(atPath: runDirectory.path) {
            try fileManager.removeItem(at: runDirectory)
        }
    }

    private static func validateExpectedBundleIdentity(
        request: Request,
        actual: BundleIdentity
    ) throws {
        guard actual.bundleID == request.expectedBundleID,
              actual.marketingVersion == request.expectedMarketingVersion,
              actual.buildNumber == request.expectedBuildNumber
        else {
            throw InstalledExecutableIdentityProbeError.bundleIdentityMismatch
        }
    }

    private static func fileSize(_ url: URL, fileManager: FileManager) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func isValidNonce(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { $0.isHexDigit }
    }
}


@main
struct FlowerollApp: App {
    @UIApplicationDelegateAdaptor(FlowerollAppDelegate.self) private var appDelegate
    @State private var theme = FlowerollThemeStore()

    init() {
        #if DEBUG
        InstalledExecutableIdentityProbe.runIfRequested()
        #endif
        UNUserNotificationCenter.current().delegate = FlowerollNotificationDelegate.shared
        DeviceBackgroundExecutionController.shared.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(theme)
                .environment(\.flowerollThemePalette, theme.palette)
                .tint(theme.palette.accent)
                .task {
                    await FlowerollTaskNotifications.requestAuthorizationIfNeeded()
                }
        }
    }
}
