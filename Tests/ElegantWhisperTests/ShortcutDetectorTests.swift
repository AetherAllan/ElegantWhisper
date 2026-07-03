import ApplicationServices
@testable import ElegantWhisper
import XCTest

final class ShortcutDetectorTests: XCTestCase {
    func testSingleLeftCommandDoesNotToggle() {
        let detector = ShortcutDetector()

        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: [.maskCommand]))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: []))
    }

    func testSingleRightOptionTogglesOnRelease() {
        let detector = ShortcutDetector()

        XCTAssertNil(detector.handleFlagsChanged(keyCode: 61, flags: [.maskAlternate]))
        XCTAssertEqual(detector.handleFlagsChanged(keyCode: 61, flags: []), .toggle)
    }

    func testCommandChordDoesNotToggle() {
        let detector = ShortcutDetector()

        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: [.maskCommand]))
        XCTAssertNil(detector.handleKeyDown(keyCode: 8))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: []))
    }

    func testLeftRightCommandChordResetsAfterAllKeysRelease() {
        let detector = ShortcutDetector()

        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: [.maskCommand]))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 54, flags: [.maskCommand]))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: [.maskCommand]))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 54, flags: []))

        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: [.maskCommand]))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: []))
    }

    func testCommandOptionCrossChordDoesNotToggle() {
        let detector = ShortcutDetector()

        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: [.maskCommand]))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 58, flags: [.maskCommand, .maskAlternate]))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: [.maskAlternate]))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 58, flags: []))
    }

    func testEscapeCancelsAndResetsDetector() {
        let detector = ShortcutDetector()

        XCTAssertNil(detector.handleFlagsChanged(keyCode: 61, flags: [.maskAlternate]))
        XCTAssertEqual(detector.handleKeyDown(keyCode: 53), .cancel)
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 61, flags: []))
    }

    func testStrayModifierReleaseDoesNotArmDetector() {
        let detector = ShortcutDetector()

        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: []))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: []))
    }

    func testCommandVDoesNotToggle() {
        let detector = ShortcutDetector()

        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: [.maskCommand]))
        XCTAssertNil(detector.handleKeyDown(keyCode: 9))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: []))
    }

    func testCommandCDoesNotToggle() {
        let detector = ShortcutDetector()

        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: [.maskCommand]))
        XCTAssertNil(detector.handleKeyDown(keyCode: 8))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: []))
    }

    func testSingleLeftOptionDoesNotToggle() {
        let detector = ShortcutDetector()

        XCTAssertNil(detector.handleFlagsChanged(keyCode: 58, flags: [.maskAlternate]))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 58, flags: []))
    }

    func testHIDStateKeepsAlreadyPressedCommandWhenRightOptionChanges() {
        var hid = HIDKeyboardState()
        let detector = ShortcutDetector()

        XCTAssertNil(detector.handleFlagsChanged(keyCode: 55, flags: hid.update(usage: 0xE3, isPressed: true)))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 61, flags: hid.update(usage: 0xE6, isPressed: true)))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 61, flags: hid.update(usage: 0xE6, isPressed: false)))
    }

    func testHIDStateKeepsAlreadyPressedShiftWhenRightOptionChanges() {
        var hid = HIDKeyboardState()
        let detector = ShortcutDetector()

        _ = hid.update(usage: 0xE1, isPressed: true)
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 61, flags: hid.update(usage: 0xE6, isPressed: true)))
        XCTAssertNil(detector.handleFlagsChanged(keyCode: 61, flags: hid.update(usage: 0xE6, isPressed: false)))
    }

    func testHIDStateStillAllowsSingleRightOptionTap() {
        var hid = HIDKeyboardState()
        let detector = ShortcutDetector()

        XCTAssertNil(detector.handleFlagsChanged(keyCode: 61, flags: hid.update(usage: 0xE6, isPressed: true)))
        XCTAssertEqual(detector.handleFlagsChanged(keyCode: 61, flags: hid.update(usage: 0xE6, isPressed: false)), .toggle)
    }
}
