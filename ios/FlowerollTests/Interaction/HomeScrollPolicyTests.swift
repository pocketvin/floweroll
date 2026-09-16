import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Floweroll

extension RuntimeInteractionPolicyTests {

    func testIdleHomeFixedCanvasRequiresNoVisibleScrollableSurface() {
        XCTAssertTrue(HomeIdleCanvasPolicy.isFixedCanvas(
            hasHomeThreadContent: false,
            hasHomePresentationSelection: false,
            hasVisibleResultSurface: false,
            isRecording: false
        ))

        // Collapsed Inbox results are represented by the top badge only; they
        // do not turn the otherwise empty Home body into a scrollable surface.
        XCTAssertTrue(HomeIdleCanvasPolicy.isFixedCanvas(
            hasHomeThreadContent: false,
            hasHomePresentationSelection: false,
            hasVisibleResultSurface: false,
            isRecording: false
        ))

        XCTAssertFalse(HomeIdleCanvasPolicy.isFixedCanvas(
            hasHomeThreadContent: true,
            hasHomePresentationSelection: false,
            hasVisibleResultSurface: false,
            isRecording: false
        ))
        XCTAssertFalse(HomeIdleCanvasPolicy.isFixedCanvas(
            hasHomeThreadContent: false,
            hasHomePresentationSelection: true,
            hasVisibleResultSurface: false,
            isRecording: false
        ))
        XCTAssertFalse(HomeIdleCanvasPolicy.isFixedCanvas(
            hasHomeThreadContent: false,
            hasHomePresentationSelection: false,
            hasVisibleResultSurface: true,
            isRecording: false
        ))
        XCTAssertFalse(HomeIdleCanvasPolicy.isFixedCanvas(
            hasHomeThreadContent: false,
            hasHomePresentationSelection: false,
            hasVisibleResultSurface: false,
            isRecording: true
        ))
    }

    func testIdleGazeMappingIsContinuousRadialAndBounded() {
        let neutral = HomeIdleGazePolicy.resolve(
            fingerX: 200, fingerY: 300,
            mascotCenterX: 200, mascotCenterY: 300
        )
        XCTAssertEqual(neutral, .neutral)

        let halfwayRight = HomeIdleGazePolicy.resolve(
            fingerX: 275, fingerY: 300,
            mascotCenterX: 200, mascotCenterY: 300,
            responseRadius: 150
        )
        XCTAssertEqual(halfwayRight.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(halfwayRight.y, 0, accuracy: 0.001)

        let up = HomeIdleGazePolicy.resolve(
            fingerX: 200, fingerY: 0,
            mascotCenterX: 200, mascotCenterY: 300
        )
        XCTAssertEqual(up.x, 0, accuracy: 0.001)
        XCTAssertEqual(up.y, -1, accuracy: 0.001)

        let diagonal = HomeIdleGazePolicy.resolve(
            fingerX: 500, fingerY: 600,
            mascotCenterX: 200, mascotCenterY: 300
        )
        XCTAssertEqual(diagonal.x, 1 / sqrt(2), accuracy: 0.001)
        XCTAssertEqual(diagonal.y, 1 / sqrt(2), accuracy: 0.001)
        XCTAssertLessThanOrEqual(abs(diagonal.x), 1)
        XCTAssertLessThanOrEqual(abs(diagonal.y), 1)

        XCTAssertLessThan(
            HomeIdleGazePolicy.verticalSourcePixelAmplitude,
            HomeIdleGazePolicy.horizontalSourcePixelAmplitude
        )
        XCTAssertEqual(HomeIdleGazePolicy.horizontalSourcePixelAmplitude, 30)
        XCTAssertEqual(HomeIdleGazePolicy.verticalSourcePixelAmplitude, 12)
    }

    func testShortThreadNeverShowsReturnToLatest() {
        var state = HomeScrollOwnershipState()
        state.beginGeneration("thread-a")
        state.updateViewport(.resolve(contentHeight: 620, viewportHeight: 700, distanceFromLatest: 0))
        state.userBeganBrowsingHistory()
        state.updateViewport(.resolve(contentHeight: 620, viewportHeight: 700, distanceFromLatest: 0))
        XCTAssertFalse(state.hasScrollableOverflow)
        XCTAssertFalse(state.showsReturnToLatest)
        XCTAssertTrue(state.shouldAutoFollowLiveUpdates)
    }

    func testLongThreadAtBottomDoesNotShowReturnToLatest() {
        var state = HomeScrollOwnershipState()
        state.beginGeneration("thread-a")
        state.updateViewport(.resolve(contentHeight: 1_600, viewportHeight: 700, distanceFromLatest: 0))
        XCTAssertEqual(state.mode, .followingLiveTask)
        XCTAssertTrue(state.shouldAutoFollowLiveUpdates)
        XCTAssertFalse(state.showsReturnToLatest)
    }

    func testUserScrollAwayShowsReturnToLatestAndStopsAutoFollow() {
        var state = HomeScrollOwnershipState()
        state.beginGeneration("thread-a")
        state.updateViewport(.resolve(contentHeight: 1_600, viewportHeight: 700, distanceFromLatest: 0))
        state.userBeganBrowsingHistory()
        state.updateViewport(.resolve(contentHeight: 1_600, viewportHeight: 700, distanceFromLatest: 360))
        XCTAssertEqual(state.mode, .browsingHistory)
        XCTAssertTrue(state.showsReturnToLatest)
        XCTAssertFalse(state.shouldAutoFollowLiveUpdates)
    }

    func testReturnToLatestCanBeRepeatedAfterAnotherUserScroll() {
        var state = HomeScrollOwnershipState()
        state.beginGeneration("thread-a")
        state.updateViewport(.resolve(contentHeight: 1_600, viewportHeight: 700, distanceFromLatest: 0))
        state.userBeganBrowsingHistory()
        state.updateViewport(.resolve(contentHeight: 1_600, viewportHeight: 700, distanceFromLatest: 420))
        XCTAssertTrue(state.showsReturnToLatest)
        state.returnToLatest()
        XCTAssertFalse(state.showsReturnToLatest)
        XCTAssertTrue(state.shouldAutoFollowLiveUpdates)
        state.updateViewport(.resolve(contentHeight: 1_600, viewportHeight: 700, distanceFromLatest: 0))
        state.userBeganBrowsingHistory()
        state.updateViewport(.resolve(contentHeight: 1_600, viewportHeight: 700, distanceFromLatest: 300))
        XCTAssertTrue(state.showsReturnToLatest)
        XCTAssertFalse(state.shouldAutoFollowLiveUpdates)
    }

    func testLiveGrowthFollowsAtBottomButNotWhileBrowsingHistory() {
        var state = HomeScrollOwnershipState()
        state.beginGeneration("thread-a")
        state.updateViewport(.resolve(contentHeight: 1_500, viewportHeight: 700, distanceFromLatest: 0))
        XCTAssertTrue(state.shouldAutoFollowLiveUpdates)
        state.userBeganBrowsingHistory()
        state.updateViewport(.resolve(contentHeight: 1_500, viewportHeight: 700, distanceFromLatest: 300))
        XCTAssertFalse(state.shouldAutoFollowLiveUpdates)
        state.updateViewport(.resolve(contentHeight: 1_720, viewportHeight: 700, distanceFromLatest: 520))
        XCTAssertEqual(state.mode, .browsingHistory)
        XCTAssertTrue(state.showsReturnToLatest)
        XCTAssertFalse(state.shouldAutoFollowLiveUpdates)
    }

    func testKeyboardOrLayoutGeometryDoesNotInventBrowsingIntent() {
        var state = HomeScrollOwnershipState()
        state.beginGeneration("thread-a")
        state.updateViewport(.resolve(contentHeight: 1_500, viewportHeight: 700, distanceFromLatest: 0))
        state.updateViewport(.resolve(contentHeight: 1_500, viewportHeight: 480, distanceFromLatest: 260))
        XCTAssertEqual(state.mode, .followingLiveTask)
        XCTAssertFalse(state.showsReturnToLatest)
        XCTAssertTrue(state.shouldAutoFollowLiveUpdates)
    }

    func testUserDragAtBottomPausesFollowThenRestoresIfBottomNeverLeft() {
        var state = HomeScrollOwnershipState()
        state.beginGeneration("thread-a")
        state.updateViewport(.resolve(contentHeight: 1_500, viewportHeight: 700, distanceFromLatest: 0))
        state.userBeganBrowsingHistory()
        XCTAssertFalse(state.shouldAutoFollowLiveUpdates)
        XCTAssertFalse(state.showsReturnToLatest)
        state.userEndedBrowsingGesture()
        XCTAssertTrue(state.shouldAutoFollowLiveUpdates)
        XCTAssertFalse(state.showsReturnToLatest)
    }

    func testThreadGenerationResetsEveryScrollOwnershipBit() {
        var state = HomeScrollOwnershipState()
        state.beginGeneration("thread-a")
        state.updateViewport(.resolve(contentHeight: 1_500, viewportHeight: 700, distanceFromLatest: 0))
        state.userBeganBrowsingHistory()
        state.updateViewport(.resolve(contentHeight: 1_500, viewportHeight: 700, distanceFromLatest: 360))
        XCTAssertTrue(state.showsReturnToLatest)
        state.beginGeneration("thread-b")
        XCTAssertEqual(state.generationID, "thread-b")
        XCTAssertEqual(state.mode, .followingLiveTask)
        XCTAssertTrue(state.isNearLiveBottom)
        XCTAssertFalse(state.hasScrollableOverflow)
        XCTAssertFalse(state.showsReturnToLatest)
        XCTAssertTrue(state.shouldAutoFollowLiveUpdates)
    }

    func testInboxBrowseIsExplicitAndReturnsToFollowAtBottom() {
        var state = HomeScrollOwnershipState()
        state.beginGeneration("thread-a")
        state.updateViewport(.resolve(contentHeight: 1_500, viewportHeight: 700, distanceFromLatest: 0))
        state.openInbox()
        XCTAssertFalse(state.shouldAutoFollowLiveUpdates)
        XCTAssertFalse(state.showsReturnToLatest)
        state.updateViewport(.resolve(contentHeight: 1_500, viewportHeight: 700, distanceFromLatest: 500))
        XCTAssertEqual(state.mode, .browsingInbox)
        XCTAssertTrue(state.showsReturnToLatest)
        XCTAssertFalse(state.shouldAutoFollowLiveUpdates)
        state.updateViewport(.resolve(contentHeight: 1_500, viewportHeight: 700, distanceFromLatest: 0))
        XCTAssertEqual(state.mode, .followingLiveTask)
        XCTAssertFalse(state.showsReturnToLatest)
    }
}
