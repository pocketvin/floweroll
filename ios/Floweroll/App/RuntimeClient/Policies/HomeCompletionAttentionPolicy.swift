import Foundation
import Observation


/// Legacy Home-scoped compatibility state. The app-global owner above is the
/// source for C's App-shell integration; this remains only so the current Home
/// surface compiles until that follow-up removes the old local presentation.
struct HomeCompletionAttentionState: Equatable {
    private(set) var currentTaskID: String?
    private(set) var queuedTaskIDs: [String] = []

    @discardableResult
    mutating func enqueue(_ taskIDs: [String]) -> [String] {
        var accepted: [String] = []
        for taskID in taskIDs where !taskID.isEmpty {
            guard taskID != currentTaskID,
                  !queuedTaskIDs.contains(taskID)
            else { continue }
            accepted.append(taskID)
            if currentTaskID == nil {
                currentTaskID = taskID
            } else {
                queuedTaskIDs.append(taskID)
            }
        }
        return accepted
    }

    mutating func dismissCurrent() {
        currentTaskID = queuedTaskIDs.isEmpty ? nil : queuedTaskIDs.removeFirst()
    }

    mutating func clear() {
        currentTaskID = nil
        queuedTaskIDs.removeAll(keepingCapacity: false)
    }
}

enum HomeCompletionAttentionScenePolicy {
    static func shouldClear(isBackground: Bool) -> Bool {
        isBackground
    }

    static func shouldBeginNewSession(wasBackground: Bool, isActive: Bool) -> Bool {
        wasBackground && isActive
    }
}

enum HomeTaskIndexPollingPolicy {
    static let intervalSeconds = 3.0

    static func shouldPoll(isRootTabActive: Bool, appIsActive: Bool) -> Bool {
        isRootTabActive && appIsActive
    }
}

enum HomeCompletionAttentionPolicy {
    static func shouldEnqueue(
        taskID: String,
        taskThreadID: String,
        currentThreadID: String?,
        completedAt: Date?,
        sessionStartedAt: Date,
        seenTaskIDs: Set<String>
    ) -> Bool {
        guard !seenTaskIDs.contains(taskID),
              taskThreadID != currentThreadID,
              let completedAt,
              completedAt >= sessionStartedAt
        else { return false }
        return true
    }
}

enum HomeInboxBadgePolicy {
    static func usesDarkForeground(accentRGB: UInt32) -> Bool {
        contrastRatio(foregroundRGB: 0x000000, backgroundRGB: accentRGB)
            >= contrastRatio(foregroundRGB: 0xFFFFFF, backgroundRGB: accentRGB)
    }

    static func bestContrastRatio(accentRGB: UInt32) -> Double {
        max(
            contrastRatio(foregroundRGB: 0x000000, backgroundRGB: accentRGB),
            contrastRatio(foregroundRGB: 0xFFFFFF, backgroundRGB: accentRGB)
        )
    }

    private static func contrastRatio(foregroundRGB: UInt32, backgroundRGB: UInt32) -> Double {
        let foreground = relativeLuminance(foregroundRGB)
        let background = relativeLuminance(backgroundRGB)
        return (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
    }

    private static func relativeLuminance(_ rgb: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let raw = Double((rgb >> shift) & 0xFF) / 255.0
            return raw <= 0.04045
                ? raw / 12.92
                : pow((raw + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }
}
