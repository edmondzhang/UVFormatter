import AppKit
import Carbon
import XCTest

final class HotKeyTests: XCTestCase {
    func testRequiresCommandControlOrOption() {
        XCTAssertNil(HotKey.capture(keyCode: 3, modifiers: [.shift]))
        XCTAssertEqual(HotKey.capture(keyCode: 3, modifiers: [.command, .shift]),
                       HotKey(keyCode: 3, modifiers: UInt32(cmdKey | shiftKey)))
    }

    func testRejectsCommandCopyPasteAndUndo() {
        for code in [kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_Z] {
            XCTAssertNil(HotKey.capture(keyCode: UInt32(code), modifiers: [.command]))
        }
    }

    func testRejectsKeypadAndFunctionModifier() {
        XCTAssertNil(HotKey.capture(keyCode: 3, modifiers: [.command, .function]))
        XCTAssertNil(HotKey.capture(keyCode: 82, modifiers: [.command, .numericPad]))
    }
}
