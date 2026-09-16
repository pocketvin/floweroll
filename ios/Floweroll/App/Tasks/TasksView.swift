import AVFAudio
import AVFoundation
import ContactsUI
import SwiftUI
import UserNotifications


struct TasksView: View {
    let runtimeStore: RuntimeTaskStore
    let onBringThreadHome: () -> Void
    @Environment(\.flowerollThemePalette) private var themePalette
    @State private var focus: TaskSectionFocus = .active
    @State private var taskListTopY: CGFloat = 0
    @State private var historyHeaderMinY: CGFloat?
    @State private var taskListNativeScroller = TaskListNativeScroller()
    @State private var programmaticSectionScrollTarget: TaskSectionFocus?
    @State private var historyRoute: TaskHistoryRoute?
    @State private var observationHistoryRoute: ObservationHistoryRoute?
    @State private var observationSession = ObservationController.shared
    @State private var activeDeletionTaskIDs: Set<String> = []
    @State private var activeDeletionError: String?
    @State private var observationDeletionError: String?

    private var activeThreadRepresentatives: [HostTaskIndexItem] {
        threadRepresentatives(
            runtimeStore.activeTasks.filter { task in
                !runtimeStore.historyPresentationState.isHidden(taskID: task.taskID)
                    && !activeDeletionTaskIDs.contains(task.taskID)
            }
        )
    }

    private var activeThreadIDs: Set<String> {
        Set(activeThreadRepresentatives.map(\.threadID))
    }

    private var historyThreadRepresentatives: [HostTaskIndexItem] {
        let activeIDs = activeThreadIDs
        return threadRepresentatives(
            runtimeStore.historyTasks.filter { !activeIDs.contains($0.threadID) }
        )
        .filter {
            !runtimeStore.historyPresentationState.isHidden(taskID: $0.taskID)
        }
    }

    private var observationHistoryRecords: [ObservationSessionRecord] {
        observationSession.history.filter { record in
            record.hasEnded || record.phase == .completed || record.phase == .finalizing || record.phase == .failed
        }
    }

    private var unifiedHistoryItems: [TaskListHistoryItem] {
        let taskItems = historyThreadRepresentatives.map(TaskListHistoryItem.runtime)
        let observationItems = observationHistoryRecords.map(TaskListHistoryItem.observation)
        return TaskListHistoryItem.newestFirst(taskItems + observationItems)
    }

    var body: some View {
        let historyRows = unifiedHistoryItems
        let episodeCounts = Dictionary(grouping: runtimeStore.allKnownTasks, by: \.threadID)
            .mapValues(\.count)
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                    HStack(alignment: .center) {
                        Text("任务")
                            .font(.system(size: 34, weight: .bold, design: .default))
                            .tracking(-0.7)
                        Spacer()
                        RuntimeConnectionBadge(state: runtimeStore.connectionState)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 12)

                    Picker(
                        "任务范围",
                        selection: Binding(
                            get: { focus },
                            set: { newValue in
                                focus = newValue
                                programmaticSectionScrollTarget = newValue
                                let target: TaskListNativeScroller.Target = newValue == .active ? .active : .history
                                Task { @MainActor in
                                    await Task.yield()
                                    if !taskListNativeScroller.scroll(
                                        to: target,
                                        activeRowCount: activeThreadRepresentatives.count
                                    ) {
                                        try? await Task.sleep(for: .milliseconds(80))
                                        _ = taskListNativeScroller.scroll(
                                            to: target,
                                            activeRowCount: activeThreadRepresentatives.count
                                        )
                                    }
                                    try? await Task.sleep(for: .milliseconds(560))
                                    guard programmaticSectionScrollTarget == newValue else { return }
                                    programmaticSectionScrollTarget = nil
                                    if let historyHeaderMinY {
                                        synchronizeTaskSectionFocus(
                                            historyHeaderMinY: historyHeaderMinY,
                                            listTopY: taskListTopY
                                        )
                                    }
                                }
                            }
                        )
                    ) {
                        ForEach(TaskSectionFocus.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)

                    GeometryReader { scrollProxy in
                        List {
                            if !runtimeStore.hasConfiguredEndpoint {
                                RuntimeEmptyState(
                                    title: "还没有连接后台",
                                    message: "配置 Host 后，任务列表完全从后台 Runtime 恢复，不依赖手机上一次打开时的状态。",
                                    symbol: "server.rack"
                                )
                                .taskListRowChrome(verticalInset: 4)
                            } else {
                                taskSectionHeader("进行中", count: activeThreadRepresentatives.count)
                                    .id(TaskSectionFocus.active.anchorID)
                                    .background(
                                        TaskListNativeScrollAnchor(
                                            key: TaskSectionFocus.active.anchorID,
                                            scroller: taskListNativeScroller
                                        )
                                    )
                                    .taskListRowChrome(verticalInset: 4)

                                if activeThreadRepresentatives.isEmpty {
                                    HStack(spacing: 8) {
                                        Image(systemName: "checkmark.circle")
                                            .foregroundStyle(.secondary)
                                        Text("当前没有进行中的任务")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 5)
                                    .taskListRowChrome(verticalInset: 3)
                                } else {
                                    ForEach(activeThreadRepresentatives, id: \.threadID) { task in
                                        Button {
                                            historyRoute = TaskHistoryRoute(
                                                taskID: task.taskID,
                                                threadID: task.threadID
                                            )
                                        } label: {
                                            MinimalRuntimeTaskCard(
                                                task: task,
                                                episodeCount: max(1, episodeCounts[task.threadID] ?? 0)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .taskListRowChrome()
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            Button {
                                                let taskID = task.taskID
                                                guard !activeDeletionTaskIDs.contains(taskID) else { return }
                                                activeDeletionError = nil
                                                withAnimation(.easeOut(duration: 0.16)) {
                                                    _ = activeDeletionTaskIDs.insert(taskID)
                                                }
                                                Task { @MainActor in
                                                    defer {
                                                        withAnimation(.easeInOut(duration: 0.16)) {
                                                            _ = activeDeletionTaskIDs.remove(taskID)
                                                        }
                                                    }
                                                    do {
                                                        _ = try await runtimeStore.cancelAndHideActiveTaskFromList(
                                                            taskID: taskID,
                                                            reason: "用户从任务列表左滑删除进行中任务"
                                                        )
                                                    } catch {
                                                        activeDeletionError = RuntimeTaskStore.userMessage(for: error)
                                                    }
                                                }
                                            } label: {
                                                Label("删除", systemImage: "trash")
                                            }
                                            .tint(Color(uiColor: .systemGray3))
                                            .disabled(activeDeletionTaskIDs.contains(task.taskID))
                                            .accessibilityLabel("停止并删除任务")
                                            .accessibilityIdentifier("tasks.active.delete.\(task.taskID)")
                                        }
                                    }
                                }

                                Divider()
                                    .padding(.vertical, 4)
                                    .taskListRowChrome(verticalInset: 1)

                                taskSectionHeader("历史", count: historyRows.count)
                                    .id(TaskSectionFocus.history.anchorID)
                                    .background(
                                        TaskListNativeScrollAnchor(
                                            key: TaskSectionFocus.history.anchorID,
                                            scroller: taskListNativeScroller
                                        )
                                    )
                                    .taskListRowChrome(verticalInset: 4)
                                    .onGeometryChange(for: CGFloat.self) { proxy in
                                        proxy.frame(in: .global).minY
                                    } action: { historyY in
                                        historyHeaderMinY = historyY
                                        synchronizeTaskSectionFocus(
                                            historyHeaderMinY: historyY,
                                            listTopY: taskListTopY
                                        )
                                    }

                                if historyRows.isEmpty {
                                    HStack(spacing: 8) {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .foregroundStyle(.secondary)
                                        Text("还没有历史任务或观察记录")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 5)
                                    .taskListRowChrome(verticalInset: 3)
                                } else {
                                    ForEach(historyRows) { item in
                                        switch item {
                                        case let .runtime(task):
                                            Button {
                                                historyRoute = TaskHistoryRoute(
                                                    taskID: task.taskID,
                                                    threadID: task.threadID
                                                )
                                            } label: {
                                                MinimalRuntimeTaskCard(
                                                    task: task,
                                                    episodeCount: max(1, episodeCounts[task.threadID] ?? 0),
                                                    showsPendingReviewBadge: !runtimeStore.terminalReviewState.isReviewed(taskID: task.taskID),
                                                    showsTimestamp: true
                                                )
                                            }
                                            .buttonStyle(.plain)
                                            .taskListRowChrome()
                                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                                Button {
                                                    runtimeStore.terminalReviewState.markReviewed(taskIDs: [task.taskID])
                                                    runtimeStore.historyPresentationState.hide(taskIDs: [task.taskID])
                                                } label: {
                                                    Label("删除", systemImage: "trash")
                                                }
                                                .tint(Color(uiColor: .systemGray3))
                                                .accessibilityIdentifier("tasks.history.delete.\(task.taskID)")

                                                Button {
                                                    runtimeStore.terminalReviewState.markPending(taskIDs: [task.taskID])
                                                } label: {
                                                    Label("待看", systemImage: "bookmark")
                                                }
                                                .tint(themePalette.accent.opacity(0.72))
                                                .accessibilityIdentifier("tasks.history.mark-pending.\(task.taskID)")
                                            }

                                        case let .observation(record):
                                            Button {
                                                observationHistoryRoute = ObservationHistoryRoute(recordID: record.id)
                                            } label: {
                                                ObservationTaskHistoryCard(record: record)
                                            }
                                            .buttonStyle(.plain)
                                            .taskListRowChrome()
                                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                                Button {
                                                    observationDeletionError = nil
                                                    Task { @MainActor in
                                                        let deleted = await observationSession.deleteHistory(record)
                                                        if !deleted {
                                                            observationDeletionError = observationSession.errorMessage ?? "这段观察记录暂时无法删除。"
                                                        }
                                                    }
                                                } label: {
                                                    Label("删除", systemImage: "trash")
                                                }
                                                .tint(Color(uiColor: .systemGray3))
                                                .accessibilityIdentifier("tasks.observation.delete.\(record.id)")
                                            }
                                        }
                                    }
                                }

                                if runtimeStore.canLoadMoreHistory || runtimeStore.isLoadingMoreHistory {
                                    HStack {
                                        Spacer()
                                        Button {
                                            Task { @MainActor in
                                                await runtimeStore.loadMoreHistory()
                                            }
                                        } label: {
                                            if runtimeStore.isLoadingMoreHistory {
                                                ProgressView("正在加载更早任务…")
                                            } else {
                                                Label("加载更早任务", systemImage: "arrow.down.circle")
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(runtimeStore.isLoadingMoreHistory)
                                        Spacer()
                                    }
                                    .padding(.vertical, 6)
                                    .taskListRowChrome(verticalInset: 3)
                                }
                            }

                            if let error = runtimeStore.lastError {
                                StatusNote(text: error, icon: "exclamationmark.triangle", tone: .warning)
                                    .taskListRowChrome(verticalInset: 3)
                            }

                            if let activeDeletionError {
                                StatusNote(text: activeDeletionError, icon: "exclamationmark.triangle", tone: .warning)
                                    .taskListRowChrome(verticalInset: 3)
                            }

                            if let observationDeletionError {
                                StatusNote(text: observationDeletionError, icon: "exclamationmark.triangle", tone: .warning)
                                    .taskListRowChrome(verticalInset: 3)
                            }

                            // Keep enough native-list tail space for the segmented
                            // control to align History near the top even with only
                            // one or two historical tasks.
                            Color.clear
                                .frame(height: max(48, scrollProxy.size.height - 72))
                                .accessibilityHidden(true)
                                .taskListRowChrome(verticalInset: 0)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .environment(\.defaultMinListRowHeight, 1)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.frame(in: .global).minY
                        } action: { listTopY in
                            taskListTopY = listTopY
                            if let historyHeaderMinY {
                                synchronizeTaskSectionFocus(
                                    historyHeaderMinY: historyHeaderMinY,
                                    listTopY: listTopY
                                )
                            }
                        }
                        .onScrollPhaseChange { _, phase in
                            switch phase {
                            case .tracking, .interacting:
                                // A real finger gesture takes ownership back from
                                // any in-flight segmented-control scroll.
                                programmaticSectionScrollTarget = nil
                            case .idle, .decelerating, .animating:
                                break
                            }
                        }
                        .refreshable {
                            await runtimeStore.refresh()
                        }
                    }
                }
        }
        .accessibilityIdentifier("tasks.root")
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $historyRoute) { route in
            RuntimeCanonicalTaskDetailView(
                taskID: route.taskID,
                knownThreadID: route.threadID,
                store: runtimeStore,
                onBringToHome: onBringThreadHome
            )
        }
        .navigationDestination(item: $observationHistoryRoute) { route in
            ObservationHistoryDetailView(
                controller: observationSession,
                recordID: route.recordID
            )
        }
        .task {
            // Tasks is a presentation surface, not an execution trigger. Paint
            // cached state immediately, then refresh only the lightweight
            // Task Index after the first frame instead of running device/runtime
            // reconciliation on tab entry.
            await Task.yield()
            await runtimeStore.refreshPresentationIndex()
        }
    }

    private func synchronizeTaskSectionFocus(
        historyHeaderMinY: CGFloat,
        listTopY: CGFloat
    ) {
        guard programmaticSectionScrollTarget == nil else { return }
        let next = TaskSectionFocus.resolve(
            historyHeaderMinY: historyHeaderMinY,
            listTopY: listTopY
        )
        if focus != next {
            focus = next
        }
    }

    private func threadRepresentatives(_ tasks: [HostTaskIndexItem]) -> [HostTaskIndexItem] {
        var latestByThread: [String: HostTaskIndexItem] = [:]
        for task in tasks {
            if let existing = latestByThread[task.threadID],
               existing.updatedAt >= task.updatedAt {
                continue
            }
            latestByThread[task.threadID] = task
        }
        return latestByThread.values.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt { return lhs.threadID > rhs.threadID }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func taskSectionHeader(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.bold())
            Text("\(count)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 4)
    }
}

private struct TaskHistoryRoute: Hashable {
    let taskID: String
    let threadID: String
}

private struct ObservationHistoryRoute: Hashable {
    let recordID: String
}

enum TaskListHistoryItem: Identifiable {
    case runtime(HostTaskIndexItem)
    case observation(ObservationSessionRecord)

    var id: String {
        switch self {
        case let .runtime(task): return "task:" + task.taskID
        case let .observation(record): return "observation:" + record.id
        }
    }

    var sortDate: Date {
        switch self {
        case let .runtime(task):
            return RuntimeTaskStore.hostDate(task.updatedAt)
                ?? RuntimeTaskStore.hostDate(task.createdAt)
                ?? .distantPast
        case let .observation(record):
            return RuntimeTaskStore.hostDate(record.configuration.createdAt) ?? .distantPast
        }
    }

    static func newestFirst(
        _ items: [Self],
        timestamp: (Self) -> Date = { $0.sortDate }
    ) -> [Self] {
        // Parse each row once. Stable input order is retained for equal instants.
        items.enumerated()
            .map { (position: $0.offset, item: $0.element, date: timestamp($0.element)) }
            .sorted { lhs, rhs in
                if lhs.date == rhs.date { return lhs.position < rhs.position }
                return lhs.date > rhs.date
            }
            .map(\.item)
    }
}


enum TaskSectionFocus: String, CaseIterable, Identifiable {
    case active
    case history

    private static let automaticSwitchBand: CGFloat = 96

    var id: Self { self }
    var title: String { self == .active ? "进行中" : "历史" }
    var anchorID: String { "task-section-\(rawValue)" }

    static func resolve(historyHeaderMinY: CGFloat, listTopY: CGFloat) -> TaskSectionFocus {
        historyHeaderMinY <= listTopY + automaticSwitchBand ? .history : .active
    }
}
