import AppKit
import XCTest

final class SelectionFormatterTests: XCTestCase {
    @MainActor
    func testClipboardRestoresEveryOriginalRepresentation() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        let custom = NSPasteboard.PasteboardType("org.uvformatter.test")
        XCTAssertTrue(item.setString("original", forType: .string))
        XCTAssertTrue(item.setData(Data([0, 255]), forType: custom))
        XCTAssertTrue(board.writeObjects([item]))

        let snapshot = try XCTUnwrap(ClipboardSnapshot(board))
        board.clearContents()
        XCTAssertTrue(board.setString("temporary", forType: .string))
        XCTAssertTrue(snapshot.restoreIfOwned(board, changeCount: board.changeCount))
        XCTAssertEqual(board.string(forType: .string), "original")
        XCTAssertEqual(board.data(forType: custom), Data([0, 255]))
    }

    @MainActor
    func testClipboardNeverRestoresOverNewerCopy() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString("original", forType: .string))
        let snapshot = try XCTUnwrap(ClipboardSnapshot(board))
        board.clearContents()
        XCTAssertTrue(board.setString("temporary", forType: .string))
        let owned = board.changeCount
        board.clearContents()
        XCTAssertTrue(board.setString("user copy", forType: .string))

        XCTAssertFalse(snapshot.restoreIfOwned(board, changeCount: owned))
        XCTAssertEqual(board.string(forType: .string), "user copy")
    }
}
