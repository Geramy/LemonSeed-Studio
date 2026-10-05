import Foundation
import Testing
import GitKit
@testable import StudioGitUI

/// The words and numbers the clone progress header shows for each stage.
@Suite struct CloneProgressSummaryTests {
    @Test func receivingShowsObjectsBytesAndPercent() {
        var p = TransferProgress(phase: .receiving)
        p.totalObjects = 3_310
        p.receivedObjects = 1_204
        p.receivedBytes = 44_150_000
        let s = CloneProgressSummary(p)
        #expect(s.stage == "Receiving objects")
        #expect(s.percent == 36)
        #expect(s.detail?.hasPrefix("1,204 of 3,310 objects · ") == true)
        #expect(s.detail?.contains("MB") == true)
    }

    @Test func aStepNamesThePartOfTheClone() {
        var resolving = TransferProgress(phase: .resolving)
        resolving.step = "Submodule kernel"
        resolving.totalDeltas = 200
        resolving.indexedDeltas = 50
        let s = CloneProgressSummary(resolving)
        #expect(s.stage == "Submodule kernel · Resolving deltas")
        #expect(s.percent == 25)
        #expect(s.detail == "50 of 200 deltas")

        var checkingOut = TransferProgress(phase: .connecting)
        checkingOut.step = "Checking out"
        #expect(CloneProgressSummary(checkingOut).stage == "Checking out")
        #expect(CloneProgressSummary(checkingOut).percent == nil)

        var lfs = TransferProgress(phase: .lfs)
        lfs.step = "Downloading LFS files"
        lfs.total = 8
        lfs.current = 2
        #expect(CloneProgressSummary(lfs).stage == "Downloading LFS files")
        #expect(CloneProgressSummary(lfs).detail == "2 of 8 files")
    }

    @Test func connectingHasNoMeasureAndFinishedIsComplete() {
        let connecting = CloneProgressSummary(TransferProgress(phase: .connecting))
        #expect(connecting.stage == "Connecting")
        #expect(connecting.fraction == nil)
        #expect(connecting.percent == nil)
        let finished = CloneProgressSummary(TransferProgress(phase: .checkingOut), finished: true)
        #expect(finished.stage == "Cloned")
        #expect(finished.percent == 100)
    }
}
