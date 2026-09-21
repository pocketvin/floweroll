import AVFAudio
import AVFoundation
import ContactsUI
import SwiftUI
import UserNotifications



struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: RootTab = .home
    @State private var runtimeStore = RuntimeTaskStore()
    @State private var linkedTaskID: String?
    @State private var taskTabNavigation = AppShellTaskNavigationState()
    @State private var explicitHomeDeepLinkOwnsPresentation = false

    private var tabSelection: Binding<RootTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                guard selectedTab != newValue else { return }
                selectedTab = newValue
            }
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            Tab("小卷", systemImage: "sparkles", value: RootTab.home) {
                HomeRootTab(runtimeStore: runtimeStore)
            }

            Tab("任务", systemImage: "checklist", value: RootTab.tasks) {
                TasksRootTab(
                    runtimeStore: runtimeStore,
                    navigationGeneration: taskTabNavigation.generation,
                    onBringThreadHome: {
                        taskTabNavigation.explicitBringToHome()
                        selectedTab = .home
                    }
                )
            }

            Tab("设置", systemImage: "gearshape", value: RootTab.settings) {
                SettingsRootTab(runtimeStore: runtimeStore)
            }
        }
        .overlay(alignment: .top) {
            if linkedTaskID == nil,
               let presentation = runtimeStore.completionAttentionOwner.presentation(on: completionAttentionSurface) {
                AppShellCompletionAttentionCard(
                    presentation: presentation,
                    owner: runtimeStore.completionAttentionOwner,
                    appIsActive: scenePhase == .active,
                    onViewTask: { taskID in linkedTaskID = taskID }
                )
                .padding(.horizontal, 18)
                .padding(.top, 58)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(100)
            }
        }
        .task {
            runtimeStore.beginCompletionAttentionAppSession()
            await runtimeStore.bootstrap()
            runtimeStore.reconcileCompletionAttention()
            openPendingNotifyUserRoute()
        }
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await runtimeStore.refreshPresentationIndex()
                await runtimeStore.recoverForegroundWork()
                runtimeStore.reconcileCompletionAttention()
                do {
                    try await Task.sleep(for: .seconds(AppShellCompletionAttentionPolicy.presentationIndexPollSeconds))
                } catch {
                    return
                }
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase != .active {
                explicitHomeDeepLinkOwnsPresentation = false
                return
            }
            guard oldPhase == .background, newPhase == .active else { return }
            // Preserve the process-level completion-attention session start so
            // Tasks that finished while backgrounded remain eligible.
            Task { @MainActor in
                await runtimeStore.refreshPresentationIndex()
                runtimeStore.reconcileCompletionAttention()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .flowerollNotifyUserRouteAvailable)) { _ in
            explicitHomeDeepLinkOwnsPresentation = false
            openPendingNotifyUserRoute()
        }
        .onChange(of: selectedTab) { oldTab, newTab in
            guard RuntimeTaskDetailRoutePolicy.shouldRedrivePendingNotification(
                previousLinkedTaskID: linkedTaskID,
                currentLinkedTaskID: linkedTaskID,
                previousTasksTabIsActive: oldTab == .tasks,
                currentTasksTabIsActive: newTab == .tasks
            ) else { return }
            openPendingNotifyUserRoute()
        }
        .onChange(of: linkedTaskID) { previousTaskID, currentTaskID in
            let tasksTabIsActive = selectedTab == .tasks
            guard RuntimeTaskDetailRoutePolicy.shouldRedrivePendingNotification(
                previousLinkedTaskID: previousTaskID,
                currentLinkedTaskID: currentTaskID,
                previousTasksTabIsActive: tasksTabIsActive,
                currentTasksTabIsActive: tasksTabIsActive
            ) else { return }
            openPendingNotifyUserRoute()
        }
        .onOpenURL { url in
            guard url.scheme == "floweroll" else { return }
            if url.host == "home" {
                explicitHomeDeepLinkOwnsPresentation = true
                linkedTaskID = nil
                selectedTab = .home
                return
            }
            guard url.host == "task",
                  url.pathComponents.count == 2,
                  let id = url.pathComponents.last, UUID(uuidString: id) != nil else { return }
            explicitHomeDeepLinkOwnsPresentation = false
            linkedTaskID = id
        }
        .sheet(isPresented: Binding(get: { linkedTaskID != nil }, set: { if !$0 { linkedTaskID = nil } })) {
            if let linkedTaskID {
                NavigationStack {
                    RuntimeCanonicalTaskDetailView(
                        taskID: linkedTaskID,
                        knownThreadID: nil,
                        store: runtimeStore,
                        onBringToHome: {
                            taskTabNavigation.explicitBringToHome()
                            selectedTab = .home
                            self.linkedTaskID = nil
                        }
                    )
                    .environment(\.runtimeTerminalReviewSurfaceActive, true)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("关闭") { self.linkedTaskID = nil }
                            }
                        }
                }
                .overlay(alignment: .top) {
                    if let presentation = runtimeStore.completionAttentionOwner.presentation(
                        on: .taskDetail(taskID: linkedTaskID)
                    ) {
                        AppShellCompletionAttentionCard(
                            presentation: presentation,
                            owner: runtimeStore.completionAttentionOwner,
                            appIsActive: scenePhase == .active,
                            onViewTask: { taskID in self.linkedTaskID = taskID }
                        )
                        .padding(.horizontal, 18)
                        .padding(.top, 58)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(100)
                    }
                }
            }
        }
    }

    private var completionAttentionSurface: RuntimeCompletionAttentionSurface {
        switch selectedTab {
        case .home: return .home
        case .tasks: return .tasks
        case .settings: return .settings
        }
    }

    private func openPendingNotifyUserRoute() {
        guard !explicitHomeDeepLinkOwnsPresentation else { return }
        guard let route = AppShellNotifyUserRouteRouting.consumePendingRoute(
            currentLinkedTaskID: linkedTaskID,
            tasksTabIsActive: selectedTab == .tasks
        ) else { return }
        // Notification routing is exact-target only. If this Task is stale or
        // unavailable, the canonical detail shows that exact failure; never
        // substitute the current/latest/unrelated Task.
        linkedTaskID = route.taskID
    }
}
