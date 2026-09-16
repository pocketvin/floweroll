import Foundation
import Observation



enum RuntimeTerminalReviewSurface: String, Equatable, Sendable {
    case homeResult
    case taskDetail
}


enum RuntimeTerminalReviewPolicy {
    /// Result/detail review deliberately requires a longer, independent
    /// foreground visibility window than the lightweight completion-attention
    /// card. The two channels must never share a "seen" bit.
    static let meaningfulVisibleDelayMilliseconds = 800

    static func canAccrueMeaningfulVisibility(
        state: RuntimeTaskPresentationState,
        surface: RuntimeTerminalReviewSurface,
        appIsActive: Bool,
        surfaceIsActive: Bool,
        isActuallyVisible: Bool
    ) -> Bool {
        _ = surface
        return state.isTerminal
            && appIsActive
            && surfaceIsActive
            && isActuallyVisible
    }

    /// Resolve the newest terminal episode per Thread first, then apply the
    /// one reversible local review truth. This prevents an older episode from
    /// resurrecting a Thread after its newest terminal result was reviewed.
    static func pendingReviewTasks(
        terminalTasks: [HostTaskIndexItem],
        reviewedTaskIDs: Set<String>,
        excludingThreadID: String? = nil
    ) -> [HostTaskIndexItem] {
        var latestByThread: [String: HostTaskIndexItem] = [:]
        for task in terminalTasks where task.presentationTruth.isTerminal {
            if let excludingThreadID, task.threadID == excludingThreadID {
                continue
            }
            if let existing = latestByThread[task.threadID],
               existing.updatedAt >= task.updatedAt {
                continue
            }
            latestByThread[task.threadID] = task
        }

        return latestByThread.values
            .filter { !reviewedTaskIDs.contains($0.taskID) }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt { return lhs.taskID > rhs.taskID }
                return lhs.updatedAt > rhs.updatedAt
            }
    }
}


@MainActor
@Observable
final class RuntimeTerminalReviewState {
    nonisolated static let reviewedDefaultsKey = "floweroll.terminalReviewedTaskIDs.v1"

    private let defaults: UserDefaults
    private(set) var reviewedTaskIDs: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.reviewedDefaultsKey) != nil {
            self.reviewedTaskIDs = Self.loadTaskIDs(
                defaults: defaults,
                key: Self.reviewedDefaultsKey
            )
        } else {
            // Compatibility migration only. After this one-time seed,
            // terminal review and B17 completion-attention acknowledgement
            // evolve independently.
            let migrated = Self.loadTaskIDs(
                defaults: defaults,
                key: RuntimeCompletionAttentionOwner.acknowledgedDefaultsKey
            )
            self.reviewedTaskIDs = migrated
            Self.persistTaskIDs(
                migrated,
                defaults: defaults,
                key: Self.reviewedDefaultsKey
            )
        }
    }

    func isReviewed(taskID: String) -> Bool {
        reviewedTaskIDs.contains(taskID)
    }

    func markReviewed(taskIDs: [String]) {
        let normalized = Self.normalizedTaskIDs(taskIDs)
        guard !normalized.isEmpty else { return }
        let before = reviewedTaskIDs
        reviewedTaskIDs.formUnion(normalized)
        guard reviewedTaskIDs != before else { return }
        persist()
    }

    func markPending(taskIDs: [String]) {
        let normalized = Self.normalizedTaskIDs(taskIDs)
        guard !normalized.isEmpty else { return }
        let before = reviewedTaskIDs
        reviewedTaskIDs.subtract(normalized)
        guard reviewedTaskIDs != before else { return }
        persist()
    }

    private func persist() {
        Self.persistTaskIDs(
            reviewedTaskIDs,
            defaults: defaults,
            key: Self.reviewedDefaultsKey
        )
    }

    nonisolated private static func normalizedTaskIDs(_ rawValues: [String]) -> Set<String> {
        Set(rawValues.compactMap { rawValue -> String? in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        })
    }

    nonisolated private static func loadTaskIDs(
        defaults: UserDefaults,
        key: String
    ) -> Set<String> {
        guard let raw = defaults.string(forKey: key),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Set<String>.self, from: data)
        else { return [] }
        return decoded
    }

    nonisolated private static func persistTaskIDs(
        _ taskIDs: Set<String>,
        defaults: UserDefaults,
        key: String
    ) {
        guard let data = try? JSONEncoder().encode(taskIDs),
              let raw = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(raw, forKey: key)
    }
}


@MainActor
@Observable
final class RuntimeTaskHistoryPresentationState {
    nonisolated static let hiddenTaskIDsDefaultsKey = "floweroll.hiddenHistoryTaskIDs.v1"

    private let defaults: UserDefaults
    private(set) var hiddenTaskIDs: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hiddenTaskIDs = Self.loadTaskIDs(defaults: defaults)
    }

    func isHidden(taskID: String) -> Bool {
        hiddenTaskIDs.contains(taskID)
    }

    func hide(taskIDs: [String]) {
        let normalized = Self.normalizedTaskIDs(taskIDs)
        guard !normalized.isEmpty else { return }
        let before = hiddenTaskIDs
        hiddenTaskIDs.formUnion(normalized)
        guard hiddenTaskIDs != before else { return }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(hiddenTaskIDs),
              let raw = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(raw, forKey: Self.hiddenTaskIDsDefaultsKey)
    }

    nonisolated private static func loadTaskIDs(defaults: UserDefaults) -> Set<String> {
        guard let raw = defaults.string(forKey: hiddenTaskIDsDefaultsKey),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Set<String>.self, from: data)
        else { return [] }
        return decoded
    }

    nonisolated private static func normalizedTaskIDs(_ rawValues: [String]) -> Set<String> {
        Set(rawValues.compactMap { rawValue -> String? in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        })
    }
}
