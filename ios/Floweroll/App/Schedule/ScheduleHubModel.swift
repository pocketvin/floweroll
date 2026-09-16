import CryptoKit
import Foundation
import Observation
import SwiftUI



@MainActor
@Observable
final class ScheduleHubModel {
    private(set) var items: [ScheduleItem] = []
    private(set) var sections: [ScheduleSection] = []
    private(set) var summary: ScheduleHubSummary = .empty
    private(set) var sourceErrors: [ScheduleSourceKind: String] = [:]
    private(set) var isRefreshing = false
    private(set) var lastRefreshedAt: Date?

    @ObservationIgnored private let sources: [any ScheduleHubSource]
    @ObservationIgnored private var sourceCache: [ScheduleSourceKind: [ScheduleItem]] = [:]
    @ObservationIgnored private let removalHistoryStore: ScheduleHubRemovalHistoryStore
    @ObservationIgnored private var removalHistory: [String: ScheduleHubRemovedItemRecord]

    init(sources: [any ScheduleHubSource] = [
        ScheduleHubAlarmSource(),
        ScheduleHubCalendarSource(),
        ScheduleHubReminderSource(),
    ], removalHistoryStore: ScheduleHubRemovalHistoryStore = ScheduleHubRemovalHistoryStore()) {
        self.sources = sources
        self.removalHistoryStore = removalHistoryStore
        self.removalHistory = removalHistoryStore.load()
        rebuild(now: Date(), calendar: .autoupdatingCurrent)
    }

    var hasAnySourceFailure: Bool { !sourceErrors.isEmpty }

    func refresh(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let window = ScheduleHubWindow(now: now, calendar: calendar)
        let activeSources = sources

        await withTaskGroup(of: ScheduleHubSourceLoadOutcome.self) { group in
            for source in activeSources {
                group.addTask {
                    do {
                        return ScheduleHubSourceLoadOutcome(
                            kind: source.kind,
                            items: try await source.load(window: window, now: now, calendar: calendar),
                            errorMessage: nil
                        )
                    } catch {
                        return ScheduleHubSourceLoadOutcome(
                            kind: source.kind,
                            items: nil,
                            errorMessage: error.localizedDescription
                        )
                    }
                }
            }

            for await outcome in group {
                if let fresh = outcome.items {
                    var removalHistoryChanged = false
                    for item in fresh where removalHistory.removeValue(forKey: item.stableIdentity) != nil {
                        removalHistoryChanged = true
                    }
                    sourceCache[outcome.kind] = fresh
                    if removalHistoryChanged {
                        try? removalHistoryStore.save(removalHistory)
                    }
                    sourceErrors[outcome.kind] = nil
                } else if let message = outcome.errorMessage {
                    // Keep the previous safe in-memory projection for only the
                    // failed source; other successful sources still refresh.
                    sourceErrors[outcome.kind] = message
                }
                rebuild(now: now, calendar: calendar)
            }
        }
        rebuild(now: now, calendar: calendar)
        lastRefreshedAt = now
    }

    func recordVerifiedRemoval(
        _ item: ScheduleItem,
        at removedAt: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) {
        guard item.sourceKind == .calendar || item.sourceKind == .reminder else { return }
        sourceCache[item.sourceKind]?.removeAll { $0.stableIdentity == item.stableIdentity }
        let record = ScheduleHubRemovedItemRecord(item: item, removedAt: removedAt)
        removalHistory[record.stableIdentity] = record
        try? removalHistoryStore.save(removalHistory)
        rebuild(now: removedAt, calendar: calendar)
    }

    private func rebuild(now: Date, calendar: Calendar) {
        let removed = removalHistory.values.compactMap { $0.scheduleItem() }
        let snapshots = sourceCache.values.flatMap { $0 } + removed
        items = ScheduleHubAggregation.canonicalItems(snapshots)
        sections = ScheduleHubPresentation.sections(from: items, now: now, calendar: calendar)
        summary = ScheduleHubPresentation.summary(from: items, now: now, calendar: calendar)
    }
}
