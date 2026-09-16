import Foundation
import Observation



enum HomeScrollMode: Equatable {
    case followingLiveTask
    case browsingInbox
    case browsingHistory
}

struct HomeScrollViewportState: Equatable {
    let hasScrollableOverflow: Bool
    let isNearLiveBottom: Bool

    static func resolve(
        contentHeight: Double,
        viewportHeight: Double,
        distanceFromLatest: Double,
        overflowTolerance: Double = 1,
        nearLatestThreshold: Double = 120
    ) -> Self {
        let hasOverflow = contentHeight - viewportHeight > overflowTolerance
        return Self(
            hasScrollableOverflow: hasOverflow,
            isNearLiveBottom: !hasOverflow || distanceFromLatest <= nearLatestThreshold
        )
    }
}


struct HomeScrollOwnershipState: Equatable {
    private(set) var generationID: String?
    private(set) var mode: HomeScrollMode = .followingLiveTask
    private(set) var isNearLiveBottom = true
    private(set) var hasScrollableOverflow = false
    private var pendingBrowseMode: HomeScrollMode?

    var shouldAutoFollowLiveUpdates: Bool {
        mode == .followingLiveTask && pendingBrowseMode == nil
    }

    var showsReturnToLatest: Bool {
        hasScrollableOverflow
            && !isNearLiveBottom
            && mode != .followingLiveTask
    }

    mutating func beginGeneration(_ id: String?) {
        guard generationID != id else { return }
        generationID = id
        mode = .followingLiveTask
        isNearLiveBottom = true
        hasScrollableOverflow = false
        pendingBrowseMode = nil
    }

    mutating func updateViewport(_ viewport: HomeScrollViewportState) {
        hasScrollableOverflow = viewport.hasScrollableOverflow
        isNearLiveBottom = viewport.isNearLiveBottom

        guard viewport.hasScrollableOverflow else {
            mode = .followingLiveTask
            pendingBrowseMode = nil
            return
        }

        if viewport.isNearLiveBottom {
            // Preserve a just-armed explicit browse intent until geometry
            // actually leaves the live edge. This prevents keyboard/layout
            // changes from becoming fake user browsing.
            if pendingBrowseMode == nil {
                mode = .followingLiveTask
            }
            return
        }

        if let pendingBrowseMode {
            mode = pendingBrowseMode
            self.pendingBrowseMode = nil
        }
    }

    mutating func updateViewportNearBottom(_ isNearBottom: Bool) {
        updateViewport(
            HomeScrollViewportState(
                hasScrollableOverflow: hasScrollableOverflow,
                isNearLiveBottom: isNearBottom
            )
        )
    }

    mutating func openInbox() {
        guard hasScrollableOverflow else { return }
        pendingBrowseMode = .browsingInbox
    }

    mutating func userBeganBrowsingHistory() {
        guard mode == .followingLiveTask, hasScrollableOverflow else { return }
        pendingBrowseMode = .browsingHistory
    }

    mutating func userEndedBrowsingGesture() {
        guard mode == .followingLiveTask,
              pendingBrowseMode == .browsingHistory,
              isNearLiveBottom
        else { return }
        pendingBrowseMode = nil
    }

    mutating func returnToLatest() {
        mode = .followingLiveTask
        isNearLiveBottom = true
        pendingBrowseMode = nil
    }
}

struct HomeIdleGazeVector: Equatable {
    let x: Double
    let y: Double

    static let neutral = HomeIdleGazeVector(x: 0, y: 0)
}

enum HomeIdleCanvasPolicy {
    static func isFixedCanvas(
        hasHomeThreadContent: Bool,
        hasHomePresentationSelection: Bool,
        hasVisibleResultSurface: Bool,
        isRecording: Bool
    ) -> Bool {
        !hasHomeThreadContent
            && !hasHomePresentationSelection
            && !hasVisibleResultSurface
            && !isRecording
    }
}

enum HomeIdleGazePolicy {
    /// Gaze is intentionally subtle at phone scale. Both eyes use the same
    /// normalized vector; the sprite surface applies these source-pixel bounds.
    static let horizontalSourcePixelAmplitude = 30.0
    static let verticalSourcePixelAmplitude = 12.0
    static let responseRadiusPoints = 130.0

    static func resolve(
        fingerX: Double,
        fingerY: Double,
        mascotCenterX: Double,
        mascotCenterY: Double,
        responseRadius: Double = responseRadiusPoints
    ) -> HomeIdleGazeVector {
        guard responseRadius > 0 else { return .neutral }

        let dx = fingerX - mascotCenterX
        let dy = fingerY - mascotCenterY
        let distance = hypot(dx, dy)
        guard distance > 0.001 else { return .neutral }

        let strength = min(1, distance / responseRadius)
        return HomeIdleGazeVector(
            x: max(-1, min(1, dx / distance * strength)),
            y: max(-1, min(1, dy / distance * strength))
        )
    }

}
