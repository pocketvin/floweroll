import AVFAudio
import AVFoundation
import ContactsUI
import SwiftUI
import UserNotifications


enum AppShellCompletionAttentionPolicy {
    static let meaningfulVisibleDelayMilliseconds = 450
    static let timeoutSeconds = 3.4
    static let presentationIndexPollSeconds = 3.0
}


struct AppShellTaskNavigationState: Equatable {
    private(set) var generation = 0

    mutating func ordinaryRootTabSelection() {
        // Root-tab round trips preserve the Tasks NavigationStack exactly.
    }

    mutating func explicitBringToHome() {
        generation &+= 1
    }
}


enum AppShellNotifyUserRouteRouting {
    static func consumePendingRoute(
        store: NotifyUserRouteStore = .shared,
        currentLinkedTaskID: String?,
        tasksTabIsActive: Bool
    ) -> NotifyUserRoute? {
        guard RuntimeTaskDetailRoutePolicy.shouldConsumePendingNotification(
            currentLinkedTaskID: currentLinkedTaskID,
            tasksTabIsActive: tasksTabIsActive
        ) else { return nil }
        return store.consume()
    }
}

enum RootTab: Hashable {
    case home
    case tasks
    case settings
}

private struct RootTabSurfaceActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var rootTabSurfaceActive: Bool {
        get { self[RootTabSurfaceActiveKey.self] }
        set { self[RootTabSurfaceActiveKey.self] = newValue }
    }
}

/// Keep tab-local animation/review activity separate from shell selection.
/// Task.yield() offers a scheduling opportunity; it is not a first-frame fence.
struct HomeRootTab: View {
    let runtimeStore: RuntimeTaskStore
    @State private var isActive = false

    var body: some View {
        NavigationStack {
            HomeView(runtimeStore: runtimeStore)
                .environment(\.rootTabSurfaceActive, isActive)
                .environment(\.runtimeTerminalReviewSurfaceActive, isActive)
        }
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            isActive = true
            await runtimeStore.refreshCurrentHomeThreadFast()
        }
        .onDisappear {
            isActive = false
        }
    }
}

struct TasksRootTab: View {
    let runtimeStore: RuntimeTaskStore
    let navigationGeneration: Int
    let onBringThreadHome: () -> Void
    @State private var isActive = false

    var body: some View {
        NavigationStack {
            TasksView(
                runtimeStore: runtimeStore,
                onBringThreadHome: onBringThreadHome
            )
            .environment(\.runtimeTerminalReviewSurfaceActive, isActive)
        }
        .id(navigationGeneration)
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            isActive = true
        }
        .onDisappear {
            isActive = false
        }
    }
}

struct SettingsRootTab: View {
    let runtimeStore: RuntimeTaskStore

    var body: some View {
        NavigationStack {
            SettingsView(runtimeStore: runtimeStore)
        }
    }
}
