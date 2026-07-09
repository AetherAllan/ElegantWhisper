@testable import ElegantWhisper
import XCTest

final class AudioInputDevicesTests: XCTestCase {
    func testListReturnsUniqueUIDs() {
        let devices = AudioInputDevices.list()
        let uids = devices.map(\.uid)
        XCTAssertEqual(uids.count, Set(uids).count)
        XCTAssertTrue(devices.allSatisfy { !$0.name.isEmpty && !$0.uid.isEmpty })
    }
}
