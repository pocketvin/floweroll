import Observation
import SwiftUI



private struct RuntimeTerminalReviewSurfaceActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var runtimeTerminalReviewSurfaceActive: Bool {
        get { self[RuntimeTerminalReviewSurfaceActiveKey.self] }
        set { self[RuntimeTerminalReviewSurfaceActiveKey.self] = newValue }
    }
}


private struct RuntimeTerminalReviewVisibilityModifier: ViewModifier {
    let taskID: String
    let state: RuntimeTaskPresentationState
    let surface: RuntimeTerminalReviewSurface
    let store: RuntimeTaskStore
    let enabled: Bool
    let threshold: Double

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.runtimeTerminalReviewSurfaceActive) private var surfaceIsActive
    @State private var isActuallyVisible = false

    private var canAccrueMeaningfulVisibility: Bool {
        enabled && RuntimeTerminalReviewPolicy.canAccrueMeaningfulVisibility(
            state: state,
            surface: surface,
            appIsActive: scenePhase == .active,
            surfaceIsActive: surfaceIsActive,
            isActuallyVisible: isActuallyVisible
        )
    }

    private var reviewTaskKey: String {
        "\(taskID):\(state.rawValue):\(surface.rawValue):\(enabled):\(scenePhase == .active):\(surfaceIsActive):\(isActuallyVisible)"
    }

    func body(content: Content) -> some View {
        content
            .onScrollVisibilityChange(threshold: threshold) { isVisible in
                isActuallyVisible = isVisible
            }
            .task(id: reviewTaskKey) {
                guard canAccrueMeaningfulVisibility,
                      !store.terminalReviewState.isReviewed(taskID: taskID)
                else { return }
                do {
                    try await Task.sleep(
                        for: .milliseconds(RuntimeTerminalReviewPolicy.meaningfulVisibleDelayMilliseconds)
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      canAccrueMeaningfulVisibility
                else { return }
                store.terminalReviewState.markReviewed(taskIDs: [taskID])
            }
    }
}

extension View {
    func runtimeTerminalReviewVisibility(
        taskID: String,
        state: RuntimeTaskPresentationState,
        surface: RuntimeTerminalReviewSurface,
        store: RuntimeTaskStore,
        enabled: Bool,
        threshold: Double = 0.5
    ) -> some View {
        modifier(RuntimeTerminalReviewVisibilityModifier(
            taskID: taskID,
            state: state,
            surface: surface,
            store: store,
            enabled: enabled,
            threshold: threshold
        ))
    }
}
