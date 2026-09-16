import ActivityKit
import Foundation


enum FlowerollLiveActivityOwner: String, Codable, Sendable, Equatable {
    case systemLongRunningIntent
    case customActivityFallback
}


enum FlowerollCustomActivityStartDecision: Sendable, Equatable {
    case requestNew
    case reuseMatchingTask(endDuplicateCount: Int)
}


enum FlowerollCustomActivityOwnershipPolicy {
    static func startDecision(matchingTaskActivityCount: Int) -> FlowerollCustomActivityStartDecision {
        guard matchingTaskActivityCount > 0 else { return .requestNew }
        return .reuseMatchingTask(endDuplicateCount: max(0, matchingTaskActivityCount - 1))
    }
}


struct FlowerollPresentationLease: Codable, Sendable, Equatable {
    let taskID: String
    let owner: FlowerollLiveActivityOwner
    let generation: Int
    let startedAt: Date
    let processInstanceID: String
    var activityID: String?
}


actor FlowerollPresentationLeaseStore {
    static let shared = FlowerollPresentationLeaseStore()
    static let defaultsKey = "floweroll.presentation.leases.v1"

    private struct Snapshot: Codable {
        var generations: [String: Int] = [:]
        var active: [String: FlowerollPresentationLease] = [:]
    }

    private let defaults: UserDefaults
    private let defaultsKey: String
    nonisolated let processInstanceID: String

    init(
        suiteName: String? = nil,
        defaultsKey: String = FlowerollPresentationLeaseStore.defaultsKey,
        processInstanceID: String = UUID().uuidString
    ) {
        self.defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.defaultsKey = defaultsKey
        self.processInstanceID = processInstanceID
    }

    func current(taskID: String) -> FlowerollPresentationLease? {
        snapshot().active[taskID]
    }

    func owns(_ lease: FlowerollPresentationLease) -> Bool {
        snapshot().active[lease.taskID] == lease
    }

    func isCurrentProcess(_ lease: FlowerollPresentationLease) -> Bool {
        lease.processInstanceID == processInstanceID
    }

    /// Acquire only when no different owner/generation is active. A caller that
    /// wants to migrate must first relinquish the exact old lease/resource.
    func acquire(
        taskID: String,
        owner: FlowerollLiveActivityOwner,
        activityID: String? = nil,
        startedAt: Date = Date()
    ) -> FlowerollPresentationLease? {
        var state = snapshot()
        if let existing = state.active[taskID] {
            guard existing.owner == owner,
                  existing.processInstanceID == processInstanceID
            else { return nil }
            if let activityID, existing.activityID != activityID {
                var rebound = existing
                rebound.activityID = activityID
                state.active[taskID] = rebound
                persist(state)
                return rebound
            }
            return existing
        }

        let generation = (state.generations[taskID] ?? 0) + 1
        let lease = FlowerollPresentationLease(
            taskID: taskID,
            owner: owner,
            generation: generation,
            startedAt: startedAt,
            processInstanceID: processInstanceID,
            activityID: activityID
        )
        state.generations[taskID] = generation
        state.active[taskID] = lease
        persist(state)
        return lease
    }

    /// Renew the same system-owner kind into a fresh generation. A superseded
    /// handler's callbacks then fail the exact-lease release check instead of
    /// stealing presentation ownership from the newer handler.
    func renew(
        taskID: String,
        owner: FlowerollLiveActivityOwner,
        startedAt: Date = Date()
    ) -> FlowerollPresentationLease? {
        var state = snapshot()
        if let existing = state.active[taskID], existing.owner != owner {
            return nil
        }
        let generation = (state.generations[taskID] ?? 0) + 1
        let lease = FlowerollPresentationLease(
            taskID: taskID,
            owner: owner,
            generation: generation,
            startedAt: startedAt,
            processInstanceID: processInstanceID,
            activityID: nil
        )
        state.generations[taskID] = generation
        state.active[taskID] = lease
        persist(state)
        return lease
    }

    func bindActivityID(
        _ activityID: String,
        to lease: FlowerollPresentationLease
    ) -> FlowerollPresentationLease? {
        var state = snapshot()
        guard state.active[lease.taskID] == lease else { return nil }
        var updated = lease
        updated.activityID = activityID
        state.active[lease.taskID] = updated
        persist(state)
        return updated
    }

    @discardableResult
    func release(_ lease: FlowerollPresentationLease) -> Bool {
        var state = snapshot()
        guard state.active[lease.taskID] == lease else { return false }
        state.active.removeValue(forKey: lease.taskID)
        persist(state)
        return true
    }

    /// Durable Host terminal truth may be observed after the process that owned
    /// a system presentation window has already died. In that case there is no
    /// live process-local handler left that can release the persisted lease.
    /// Only reclaim *stale system* owners here: a current-process system owner
    /// still owns the real system UI and must finish/release itself, while a
    /// custom ActivityKit owner has its own explicit end path below.
    func reclaimStaleSystemForTerminal(taskID: String) -> FlowerollPresentationLease? {
        var state = snapshot()
        guard let lease = state.active[taskID],
              lease.processInstanceID != processInstanceID,
              lease.owner == .systemLongRunningIntent
        else { return nil }
        state.active.removeValue(forKey: taskID)
        persist(state)
        return lease
    }

    /// Process-local system execution cannot survive process death. Custom
    /// ActivityKit presentation can survive and is adopted into a new custom
    /// generation by the new process.
    func reclaimStale(
        taskID: String,
        owners: Set<FlowerollLiveActivityOwner>
    ) -> FlowerollPresentationLease? {
        var state = snapshot()
        guard let lease = state.active[taskID],
              lease.processInstanceID != processInstanceID,
              owners.contains(lease.owner)
        else { return nil }
        state.active.removeValue(forKey: taskID)
        persist(state)
        return lease
    }

    func activeLeases() -> [FlowerollPresentationLease] {
        Array(snapshot().active.values)
    }

    private func snapshot() -> Snapshot {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return Snapshot() }
        return decoded
    }

    private func persist(_ state: Snapshot) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}


private enum FlowerollPresentationDiagnostics {
    private static let lock = NSLock()
    private static let filename = "presentation-ownership.jsonl"

    static func record(
        event: String,
        taskID: String,
        lease: FlowerollPresentationLease? = nil,
        detail: String? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }

        var payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "event": event,
            "task_id": taskID,
        ]
        if let lease {
            payload["owner"] = lease.owner.rawValue
            payload["generation"] = lease.generation
            payload["started_at"] = ISO8601DateFormatter().string(from: lease.startedAt)
            payload["process_instance_id"] = lease.processInstanceID
            if let activityID = lease.activityID { payload["activity_id"] = activityID }
        }
        if let detail, !detail.isEmpty { payload["detail"] = detail }
        guard JSONSerialization.isValidJSONObject(payload),
              var data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { return }
        data.append(0x0A)

        do {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("Floweroll", isDirectory: true)
            .appendingPathComponent("RuntimeClient", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            // Ownership diagnostics must never affect presentation behavior.
        }
    }
}

/// Cosmetic processing motion for Floweroll's custom Live Activity.
///
/// Live Activity views don't own a reliable continuous rendering clock. While
/// this app process has execution time, advance only `presentationPulse`; Task
/// progress/result truth remains untouched. There is intentionally no fixed
/// iteration cap: a processing Activity keeps pulsing until its phase changes,
/// its presentation lease disappears, or iOS suspends the process. A later real
/// Task update calls `ensureRunning` again, so foreground/resume recovers motion.
private actor FlowerollProcessingPulseDriver {
    static let shared = FlowerollProcessingPulseDriver()

    private var jobs: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]

    func ensureRunning(taskID: String) {
        guard jobs[taskID] == nil else { return }
        let generation = UUID()
        generations[taskID] = generation
        jobs[taskID] = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(220))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                guard await FlowerollActivitySession.advanceProcessingPresentationPulse(taskID: taskID) else {
                    break
                }
            }
            finish(taskID: taskID, generation: generation)
        }
    }

    func stop(taskID: String) {
        jobs[taskID]?.cancel()
        jobs.removeValue(forKey: taskID)
        generations.removeValue(forKey: taskID)
    }

    private func finish(taskID: String, generation: UUID) {
        guard generations[taskID] == generation else { return }
        jobs.removeValue(forKey: taskID)
        generations.removeValue(forKey: taskID)
    }
}


enum FlowerollActivitySession {
    private static var leaseStore: FlowerollPresentationLeaseStore {
        FlowerollPresentationLeaseStore.shared
    }

    fileprivate static func advanceProcessingPresentationPulse(taskID: String) async -> Bool {
        guard let lease = await leaseStore.current(taskID: taskID),
              lease.owner == .customActivityFallback,
              await leaseStore.isCurrentProcess(lease),
              let activity = customActivity(taskID: taskID, preferredID: lease.activityID)
        else { return false }
        var state = activity.content.state
        guard state.phase == .processing else { return false }
        state.presentationVersion = FlowerollActivityPresentation.currentVersion
        state.advancePresentationPulse()
        await activity.update(ActivityContent(state: state, staleDate: nil))
        return true
    }

    /// Ordered custom -> LongRunningIntent migration. A fresh system execution
    /// may take over a durable Task only after an older custom fallback has ended.
    static func prepareForSystemLongRunningIntent(taskID: String) async -> Bool {
        if let stale = await leaseStore.reclaimStale(
            taskID: taskID,
            owners: [.customActivityFallback, .systemLongRunningIntent]
        ) {
            if stale.owner == .customActivityFallback {
                await endCustomActivities(taskID: taskID, dismissalPolicy: .immediate)
            }
            FlowerollPresentationDiagnostics.record(
                event: "stale_owner_reclaimed_before_long_running",
                taskID: taskID,
                lease: stale
            )
        }

        guard let current = await leaseStore.current(taskID: taskID) else { return true }
        switch current.owner {
        case .customActivityFallback:
            await endCustomActivities(taskID: taskID, dismissalPolicy: .immediate)
            guard await leaseStore.release(current) else { return false }
            FlowerollPresentationDiagnostics.record(
                event: "custom_owner_relinquished_before_long_running",
                taskID: taskID,
                lease: current
            )
            return true
        case .systemLongRunningIntent:
            return await leaseStore.isCurrentProcess(current)
        }
    }

    @discardableResult
    static func beginSystemPresentation(
        owner: FlowerollLiveActivityOwner,
        taskID: String
    ) async -> FlowerollPresentationLease? {
        precondition(owner != .customActivityFallback)
        if owner == .systemLongRunningIntent,
           let stale = await leaseStore.reclaimStale(
               taskID: taskID,
               owners: [.systemLongRunningIntent]
           ) {
            FlowerollPresentationDiagnostics.record(
                event: "stale_system_owner_reclaimed",
                taskID: taskID,
                lease: stale
            )
        }
        let lease = await leaseStore.acquire(taskID: taskID, owner: owner)
        if let lease {
            FlowerollPresentationDiagnostics.record(
                event: "system_owner_acquired",
                taskID: taskID,
                lease: lease
            )
        } else {
            let current = await leaseStore.current(taskID: taskID)
            FlowerollPresentationDiagnostics.record(
                event: "system_owner_conflict",
                taskID: taskID,
                lease: current,
                detail: "requested=\(owner.rawValue)"
            )
        }
        return lease
    }

    @discardableResult
    static func releaseSystemPresentation(_ lease: FlowerollPresentationLease) async -> Bool {
        guard lease.owner != .customActivityFallback else { return false }
        let released = await leaseStore.release(lease)
        if released {
            FlowerollPresentationDiagnostics.record(
                event: "system_owner_released",
                taskID: lease.taskID,
                lease: lease
            )
        }
        return released
    }

    /// The old system owner must already be gone when this is called. Exact
    /// generation release prevents a stale cancellation callback from stealing a
    /// newer system/custom presentation owner.
    @discardableResult
    static func migrateSystemPresentationToCustomFallback(
        from lease: FlowerollPresentationLease,
        phase: FlowerollActivityPhase = .processing,
        message: String
    ) async -> Bool {
        guard lease.owner != .customActivityFallback else { return false }
        guard await leaseStore.release(lease) else { return false }
        FlowerollPresentationDiagnostics.record(
            event: "system_owner_relinquished_for_custom_fallback",
            taskID: lease.taskID,
            lease: lease
        )
        do {
            _ = try await startCustomFallback(
                phase: phase,
                message: message,
                taskID: lease.taskID
            )
            return true
        } catch {
            FlowerollPresentationDiagnostics.record(
                event: "custom_fallback_start_failed",
                taskID: lease.taskID,
                detail: String(reflecting: type(of: error))
            )
            return false
        }
    }

    @discardableResult
    static func start(
        phase: FlowerollActivityPhase,
        message: String,
        taskID: String? = nil
    ) async throws -> Activity<FlowerollActivityAttributes> {
        if let taskID {
            return try await startCustomFallback(phase: phase, message: message, taskID: taskID)
        }
        return try await startLegacyActivity(phase: phase, message: message)
    }

    static func update(phase: FlowerollActivityPhase, message: String, taskID: String? = nil) async {
        guard let taskID else {
            guard let activity = legacyActivities().first else { return }
            await update(activity, phase: phase, message: message)
            return
        }

        await reclaimPresentationIfNeeded(taskID: taskID, phase: phase, message: message)
        guard let lease = await leaseStore.current(taskID: taskID),
              lease.owner == .customActivityFallback,
              await leaseStore.isCurrentProcess(lease),
              let activity = customActivity(taskID: taskID, preferredID: lease.activityID)
        else { return }
        await update(activity, phase: phase, message: message)
        if phase == .processing {
            await FlowerollProcessingPulseDriver.shared.ensureRunning(taskID: taskID)
        } else {
            await FlowerollProcessingPulseDriver.shared.stop(taskID: taskID)
        }
    }

    static func sync(from view: HostTaskView) async {
        let status = view.task.status.lowercased()
        let phase: FlowerollActivityPhase = status == "completed" ? .completed
            : status == "cancelled" ? .cancelled
            : status == "failed" ? .failed
            : ["waiting", "blocked"].contains(status) ? .needsUser : .processing
        let active = view.timeline.last { $0.isUserVisible && $0.presentationState.uppercased() == "ACTIVE" }
        let message = view.pendingInteraction?.objectValue?["prompt"]?.stringValue
            ?? view.pendingInteraction?.objectValue?["question"]?.stringValue
            ?? active?.title ?? view.timeline.last(where: { $0.isUserVisible })?.summary
            ?? view.timeline.last(where: { $0.isUserVisible })?.title ?? "正在处理"

        let taskID = view.task.taskID
        let isTerminal = phase == .completed || phase == .failed || phase == .cancelled
        await reclaimPresentationIfNeeded(
            taskID: taskID,
            phase: phase,
            message: String(message.prefix(120))
        )

        if !isTerminal,
           customActivities(taskID: taskID).isEmpty,
           await leaseStore.current(taskID: taskID) == nil {
            _ = try? await startCustomFallback(
                phase: phase,
                message: String(message.prefix(120)),
                taskID: taskID
            )
        }

        guard let lease = await leaseStore.current(taskID: taskID),
              lease.owner == .customActivityFallback,
              await leaseStore.isCurrentProcess(lease),
              let activity = customActivity(taskID: taskID, preferredID: lease.activityID)
        else { return }

        let previous = activity.content.state
        if let updatedAt = previous.updatedAt, updatedAt > view.task.updatedAt { return }
        let counts = view.progressUnitCounts
        let state = FlowerollActivityAttributes.ContentState(
            phase: phase,
            message: String(message.prefix(120)),
            taskID: taskID,
            taskTitle: String(view.task.goal.prefix(28)),
            completedCount: counts.total > 0 ? Int(counts.completed) : nil,
            totalCount: counts.total > 0 ? Int(counts.total) : nil,
            updatedAt: view.task.updatedAt,
            presentationPulse: previous.presentationPulse
        )
        let presentationChanged = state != previous
        let content = ActivityContent(state: state, staleDate: nil)
        if isTerminal {
            await FlowerollProcessingPulseDriver.shared.stop(taskID: taskID)
            await activity.end(content, dismissalPolicy: dismissalPolicy(after: 4))
            _ = await leaseStore.release(lease)
            FlowerollPresentationDiagnostics.record(
                event: "custom_owner_terminal_ended",
                taskID: taskID,
                lease: lease,
                detail: "phase=\(phase.rawValue)"
            )
            return
        }
        if presentationChanged {
            await activity.update(content)
        }
        if phase == .processing {
            await FlowerollProcessingPulseDriver.shared.ensureRunning(taskID: taskID)
        } else {
            await FlowerollProcessingPulseDriver.shared.stop(taskID: taskID)
        }
    }

    static func completeAndEnd(message: String = "已完成") async {
        await finishAndEnd(phase: .completed, message: message, dismissAfter: 0)
    }

    static func finishAndEnd(
        phase: FlowerollActivityPhase,
        message: String,
        dismissAfter seconds: TimeInterval,
        taskID: String? = nil
    ) async {
        guard let taskID else {
            guard let activity = legacyActivities().first else { return }
            var state = activity.content.state
            state.phase = phase
            state.message = message
            state.presentationVersion = FlowerollActivityPresentation.currentVersion
            let content = ActivityContent(state: state, staleDate: nil)
            await activity.end(content, dismissalPolicy: dismissalPolicy(after: seconds))
            return
        }

        await FlowerollProcessingPulseDriver.shared.stop(taskID: taskID)
        if let staleSystemLease = await leaseStore.reclaimStaleSystemForTerminal(taskID: taskID) {
            FlowerollPresentationDiagnostics.record(
                event: "stale_system_owner_released_at_terminal",
                taskID: taskID,
                lease: staleSystemLease
            )
        }

        let matching = customActivities(taskID: taskID)
        guard !matching.isEmpty else {
            if let lease = await leaseStore.current(taskID: taskID),
               lease.owner == .customActivityFallback {
                _ = await leaseStore.release(lease)
            }
            return
        }
        for activity in matching {
            var state = activity.content.state
            state.phase = phase
            state.message = message
            state.presentationVersion = FlowerollActivityPresentation.currentVersion
            let content = ActivityContent(state: state, staleDate: nil)
            await activity.end(content, dismissalPolicy: dismissalPolicy(after: seconds))
        }
        if let lease = await leaseStore.current(taskID: taskID),
           lease.owner == .customActivityFallback {
            _ = await leaseStore.release(lease)
            FlowerollPresentationDiagnostics.record(
                event: "custom_owner_terminal_released",
                taskID: taskID,
                lease: lease
            )
        }
    }

    static func endImmediately() async {
        for activity in legacyActivities() {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// One-way migration cleanup for the system-only presentation policy. End
    /// every app-owned custom ActivityKit instance left by older builds and
    /// clear only Floweroll's persisted presentation leases. New Task execution
    /// must not call `start` after this migration.
    /// Migrate only the exact in-app Task IDs that the global BGCPT owner is
    /// taking over. LongRunningIntent-owned system-entry Tasks are intentionally
    /// absent from this set and must not be swept.
    static func retireCustomActivitiesForSystemContinuedProcessing(taskIDs: Set<String>) async {
        for taskID in taskIDs where !taskID.isEmpty {
            await FlowerollProcessingPulseDriver.shared.stop(taskID: taskID)
            await endCustomActivities(taskID: taskID, dismissalPolicy: .immediate)
            if let lease = await leaseStore.current(taskID: taskID),
               lease.owner == .customActivityFallback {
                _ = await leaseStore.release(lease)
                FlowerollPresentationDiagnostics.record(
                    event: "custom_owner_released_for_global_continued_processing",
                    taskID: taskID,
                    lease: lease
                )
            }
        }
    }

    static func retireAllCustomActivitiesForSystemOnlyMigration() async {
        for activity in Activity<FlowerollActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        for lease in await leaseStore.activeLeases() {
            _ = await leaseStore.release(lease)
        }
    }

    private static func startCustomFallback(
        phase: FlowerollActivityPhase,
        message: String,
        taskID: String
    ) async throws -> Activity<FlowerollActivityAttributes> {
        if let stale = await leaseStore.reclaimStale(
            taskID: taskID,
            owners: [.customActivityFallback, .systemLongRunningIntent]
        ) {
            FlowerollPresentationDiagnostics.record(
                event: "stale_owner_reclaimed_for_custom",
                taskID: taskID,
                lease: stale
            )
        }

        guard let lease = await leaseStore.acquire(
            taskID: taskID,
            owner: .customActivityFallback
        ) else {
            throw CocoaError(.userCancelled)
        }

        let matching = customActivities(taskID: taskID)
        if case .reuseMatchingTask = FlowerollCustomActivityOwnershipPolicy.startDecision(
            matchingTaskActivityCount: matching.count
        ), let existing = matching.first {
            for duplicate in matching.dropFirst() {
                await duplicate.end(nil, dismissalPolicy: .immediate)
            }
            _ = await leaseStore.bindActivityID(existing.id, to: lease)
            let previous = existing.content.state
            var state = existing.content.state
            // The activity is already bound to this exact task. Never mutate a
            // custom Activity from one durable Task into another Task identity.
            state.phase = phase
            state.message = message
            state.presentationVersion = FlowerollActivityPresentation.currentVersion
            if state != previous {
                await existing.update(ActivityContent(state: state, staleDate: nil))
            }
            FlowerollPresentationDiagnostics.record(
                event: "custom_owner_reused_same_task",
                taskID: taskID,
                lease: await leaseStore.current(taskID: taskID),
                detail: "duplicates_ended=\(max(0, matching.count - 1))"
            )
            if phase == .processing {
                await FlowerollProcessingPulseDriver.shared.ensureRunning(taskID: taskID)
            } else {
                await FlowerollProcessingPulseDriver.shared.stop(taskID: taskID)
            }
            return existing
        }

        let attributes = FlowerollActivityAttributes(sessionID: UUID().uuidString)
        let state = FlowerollActivityAttributes.ContentState(
            phase: phase,
            message: message,
            taskID: taskID,
            presentationPulse: 0
        )
        let content = ActivityContent(state: state, staleDate: nil)
        let activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
        let bound = await leaseStore.bindActivityID(activity.id, to: lease)
        FlowerollPresentationDiagnostics.record(
            event: "custom_owner_started",
            taskID: taskID,
            lease: bound ?? lease
        )
        if phase == .processing {
            await FlowerollProcessingPulseDriver.shared.ensureRunning(taskID: taskID)
        } else {
            await FlowerollProcessingPulseDriver.shared.stop(taskID: taskID)
        }
        return activity
    }

    private static func startLegacyActivity(
        phase: FlowerollActivityPhase,
        message: String
    ) async throws -> Activity<FlowerollActivityAttributes> {
        let matching = legacyActivities()
        if let existing = matching.first {
            for duplicate in matching.dropFirst() {
                await duplicate.end(nil, dismissalPolicy: .immediate)
            }
            await update(existing, phase: phase, message: message)
            return existing
        }
        let attributes = FlowerollActivityAttributes(sessionID: UUID().uuidString)
        let state = FlowerollActivityAttributes.ContentState(
            phase: phase,
            message: message,
            taskID: nil,
            presentationPulse: 0
        )
        return try Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil
        )
    }

    private static func reclaimPresentationIfNeeded(
        taskID: String,
        phase: FlowerollActivityPhase,
        message: String
    ) async {
        if let lease = await leaseStore.current(taskID: taskID) {
            if await leaseStore.isCurrentProcess(lease) { return }
            // New builds use custom ActivityKit as the only product owner. A
            // system lease from another process can only be legacy persisted
            // state, so reclaim all three historical owner kinds on relaunch.
            switch lease.owner {
            case .systemLongRunningIntent, .customActivityFallback:
                _ = await leaseStore.reclaimStale(taskID: taskID, owners: [lease.owner])
                do {
                    _ = try await startCustomFallback(phase: phase, message: message, taskID: taskID)
                    FlowerollPresentationDiagnostics.record(
                        event: "presentation_reclaimed_after_process_relaunch",
                        taskID: taskID,
                        detail: "from=\(lease.owner.rawValue) old_generation=\(lease.generation)"
                    )
                } catch {
                    FlowerollPresentationDiagnostics.record(
                        event: "presentation_reclaim_failed",
                        taskID: taskID,
                        detail: String(reflecting: type(of: error))
                    )
                }
            }
            return
        }

        // Backward compatibility for a task-bound custom Activity created by an
        // older build before presentation leases existed. Adopt only a matching
        // Task activity; never steal a different task's island.
        guard !customActivities(taskID: taskID).isEmpty else { return }
        do {
            _ = try await startCustomFallback(phase: phase, message: message, taskID: taskID)
            FlowerollPresentationDiagnostics.record(
                event: "legacy_custom_activity_adopted",
                taskID: taskID
            )
        } catch {
            // Best-effort migration; Host Task truth remains authoritative.
        }
    }

    private static func customActivities(taskID: String) -> [Activity<FlowerollActivityAttributes>] {
        Activity<FlowerollActivityAttributes>.activities.filter { $0.content.state.taskID == taskID }
    }

    private static func legacyActivities() -> [Activity<FlowerollActivityAttributes>] {
        Activity<FlowerollActivityAttributes>.activities.filter { $0.content.state.taskID == nil }
    }

    private static func customActivity(
        taskID: String,
        preferredID: String?
    ) -> Activity<FlowerollActivityAttributes>? {
        let matching = customActivities(taskID: taskID)
        if let preferredID, let preferred = matching.first(where: { $0.id == preferredID }) {
            return preferred
        }
        return matching.first
    }

    private static func endCustomActivities(
        taskID: String,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) async {
        await FlowerollProcessingPulseDriver.shared.stop(taskID: taskID)
        for activity in customActivities(taskID: taskID) {
            await activity.end(nil, dismissalPolicy: dismissalPolicy)
        }
    }

    private static func dismissalPolicy(after seconds: TimeInterval) -> ActivityUIDismissalPolicy {
        seconds <= 0 ? .immediate : .after(Date().addingTimeInterval(seconds))
    }

    private static func update(
        _ activity: Activity<FlowerollActivityAttributes>,
        phase: FlowerollActivityPhase,
        message: String
    ) async {
        let previous = activity.content.state
        var state = activity.content.state
        state.phase = phase
        state.message = message
        state.presentationVersion = FlowerollActivityPresentation.currentVersion
        guard state != previous else { return }
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }
}
