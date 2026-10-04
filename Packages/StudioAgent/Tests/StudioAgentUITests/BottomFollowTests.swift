import Testing
@testable import StudioAgentUI

/// The streaming transcript and the live reasoning follow their newest line
/// the same way: new text appends at the bottom and stays in view until the
/// user scrolls up; back at the bottom, following resumes.
@Suite("Following the newest line")
struct BottomFollowTests {
    @Test func theBottomIsTheEndOfTheContentWithinTheTolerance() {
        #expect(BottomFollow.isAtBottom(visibleMaxY: 1000, contentHeight: 1000))
        #expect(BottomFollow.isAtBottom(visibleMaxY: 1000 - BottomFollow.tolerance, contentHeight: 1000))
        #expect(!BottomFollow.isAtBottom(visibleMaxY: 900, contentHeight: 1000))
        // Content shorter than the view is at its bottom.
        #expect(BottomFollow.isAtBottom(visibleMaxY: 400, contentHeight: 120))
    }

    @Test func contentGrowingUnderneathKeepsFollowing() {
        var f = BottomFollow()
        #expect(f.following)
        // New lines push the end below the view before the scroll catches up.
        f.geometryChanged(atBottom: false)
        #expect(f.following)
        f.geometryChanged(atBottom: true)
        #expect(f.following)
    }

    @Test func scrollingUpByHandStopsFollowingUntilTheBottom() {
        var f = BottomFollow()
        f.phaseChanged(userDriven: true)
        f.geometryChanged(atBottom: false)
        #expect(!f.following)
        f.phaseChanged(userDriven: false)
        // Streaming goes on: the content grows, the view stays where the user left it.
        f.geometryChanged(atBottom: false)
        #expect(!f.following)
        // The user scrolls back down to the end.
        f.phaseChanged(userDriven: true)
        f.geometryChanged(atBottom: true)
        f.phaseChanged(userDriven: false)
        #expect(f.following)
    }

    @Test func aFlingThatSettlesAwayFromTheBottomStopsFollowing() {
        var f = BottomFollow()
        f.phaseChanged(userDriven: true)
        f.geometryChanged(atBottom: true)
        #expect(f.following)
        f.geometryChanged(atBottom: false)  // decelerating upward
        f.phaseChanged(userDriven: false)
        #expect(!f.following)
    }

    @Test func sendingAMessageResumesFollowing() {
        var f = BottomFollow()
        f.phaseChanged(userDriven: true)
        f.geometryChanged(atBottom: false)
        f.phaseChanged(userDriven: false)
        #expect(!f.following)
        f.resume()
        #expect(f.following)
    }
}
