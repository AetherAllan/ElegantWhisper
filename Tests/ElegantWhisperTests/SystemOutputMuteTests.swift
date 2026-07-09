@testable import ElegantWhisper
import XCTest

final class SystemOutputMuteTests: XCTestCase {
    func testAlreadyMutedDoesNotClaimOwnership() {
        var tracker = OutputMuteTracker()
        tracker.registerMuteResult(deviceID: 42, wasAlreadyMuted: true, applied: false)
        XCTAssertNil(tracker.mutedDeviceID)
        XCTAssertFalse(tracker.didMuteByUs)
    }

    func testSuccessfulMuteStoresDeviceUntilCleared() {
        var tracker = OutputMuteTracker()
        tracker.registerMuteResult(deviceID: 7, wasAlreadyMuted: false, applied: true)
        XCTAssertEqual(tracker.mutedDeviceID, 7)
        XCTAssertTrue(tracker.didMuteByUs)

        tracker.clearOwnership()
        XCTAssertNil(tracker.mutedDeviceID)
        XCTAssertFalse(tracker.didMuteByUs)
    }

    func testFailedMuteDoesNotStoreDevice() {
        var tracker = OutputMuteTracker()
        tracker.registerMuteResult(deviceID: 9, wasAlreadyMuted: false, applied: false)
        XCTAssertNil(tracker.mutedDeviceID)
    }

    func testOwnershipSurvivesFailedUnmuteUntilCleared() {
        var tracker = OutputMuteTracker()
        tracker.registerMuteResult(deviceID: 3, wasAlreadyMuted: false, applied: true)
        // Simulate unmute failure: ownership must remain so a later retry (e.g. terminate) can try again.
        XCTAssertEqual(tracker.mutedDeviceID, 3)
        tracker.clearOwnership()
        XCTAssertNil(tracker.mutedDeviceID)
    }
}
