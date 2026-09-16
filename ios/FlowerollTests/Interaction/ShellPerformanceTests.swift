import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Floweroll

extension RuntimeInteractionPolicyTests {

    @MainActor
    func testProfileRootTabSwitchWithHistory() async throws {
        #if targetEnvironment(simulator)
        let defaults = UserDefaults.standard
        let keys = [RuntimeTaskStore.endpointDefaultsKey, RuntimeTaskStore.homeThreadDefaultsKey,
                    RuntimeTaskStore.continuationTaskDefaultsKey, RuntimeTaskStore.homeThreadAwaitingNewDefaultsKey]
        let savedDefaults = keys.map { defaults.object(forKey: $0) }
        let appDomain = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let savedDomain = defaults.persistentDomain(forName: appDomain)
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("Floweroll/RuntimeClient", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cacheURL = directory.appendingPathComponent("task-history-index-cache.json")
        let savedCache = try? Data(contentsOf: cacheURL)
        defer {
            for (key, value) in zip(keys, savedDefaults) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            if let savedDomain { defaults.setPersistentDomain(savedDomain, forName: appDomain) }
            else { defaults.removePersistentDomain(forName: appDomain) }
            if let savedCache { try? savedCache.write(to: cacheURL, options: .atomic) }
            else { try? FileManager.default.removeItem(at: cacheURL) }
        }
        defaults.set("http://127.0.0.1:1", forKey: RuntimeTaskStore.endpointDefaultsKey)
        defaults.removeObject(forKey: RuntimeTaskStore.homeThreadDefaultsKey)
        defaults.removeObject(forKey: RuntimeTaskStore.continuationTaskDefaultsKey)
        defaults.set(true, forKey: RuntimeTaskStore.homeThreadAwaitingNewDefaultsKey)
        let tasks = (0..<56).map { index in
            terminalReviewTask(id: "profile-task-\(index)", threadID: "profile-thread-\(index)",
                updatedAt: String(format: "2026-09-13T12:%02d:00.484723+00:00", index))
        }
        try JSONEncoder.floweroll.encode(HostTaskIndexPage(items: tasks, nextCursor: nil))
            .write(to: cacheURL, options: .atomic)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ContentView().environment(FlowerollThemeStore()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        try await Task.sleep(for: .seconds(1))
        host.view.layoutIfNeeded()
        func findTab(_ controller: UIViewController) -> UITabBarController? {
            if let tab = controller as? UITabBarController { return tab }
            for child in controller.children { if let tab = findTab(child) { return tab } }
            return nil
        }
        let tab = try XCTUnwrap(findTab(host))
        XCTAssertEqual(tab.tabs.count, 3)
        print("TAB_PROFILE_BEGIN pid=\(ProcessInfo.processInfo.processIdentifier) history=56")
        var warmDurations: [Int: [Double]] = [:]
        for iteration in 0..<30 {
            let index = [1, 2, 0][iteration % 3]
            let destination = tab.tabs[index]
            let previousTab = tab.selectedTab
            let start = CACurrentMediaTime()
            let allowed = tab.delegate?.tabBarController?(tab, shouldSelectTab: destination) ?? true
            XCTAssertTrue(allowed)
            tab.selectedTab = destination
            tab.delegate?.tabBarController?(tab, didSelectTab: destination, previousTab: previousTab)
            XCTAssertEqual(tab.selectedTab?.identifier, destination.identifier)
            host.view.layoutIfNeeded()
            let milliseconds = (CACurrentMediaTime() - start) * 1000
            if iteration >= 3 { warmDurations[index, default: []].append(milliseconds) }
            print(String(format: "TAB_PROFILE_SWITCH iteration=%d tab=%d synchronous_ms=%.3f", iteration, index, milliseconds))
            try await Task.sleep(for: .milliseconds(150))
        }
        for index in 0..<3 {
            let samples = try XCTUnwrap(warmDurations[index]).sorted()
            XCTAssertEqual(samples.count, 9)
            let median = samples[samples.count / 2]
            print(String(format: "TAB_PROFILE_MEDIAN tab=%d synchronous_ms=%.3f", index, median))
            XCTAssertLessThan(median, 100, "Warmed tab switch must not reintroduce the 200ms history-sort stall")
        }
        print("TAB_PROFILE_END")
        #else
        throw XCTSkip("Isolated simulator UI profile; never writes fixtures to the physical device.")
        #endif
    }
}
