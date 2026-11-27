import AppKit
import XCTest

final class SelectionFormatterTests: XCTestCase {
    @MainActor
    func testReadsOnlyNewTextFromObservedClipboardRevision() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString("old", forType: .string))
        let snapshot = try XCTUnwrap(ClipboardSnapshot(board))
        XCTAssertNil(snapshot.copiedText(from: board, changeCount: board.changeCount))

        board.clearContents()
        XCTAssertTrue(board.setString(#"{"a":1}"#, forType: .string))
        let observed = board.changeCount
        XCTAssertEqual(snapshot.copiedText(from: board, changeCount: observed), #"{"a":1}"#)

        board.clearContents()
        XCTAssertTrue(board.setString("newer copy", forType: .string))
        XCTAssertNil(snapshot.copiedText(from: board, changeCount: observed))
    }

    func testExpectedWritePreservesTextOutsideVerifiedUTF16Selection() {
        let range = NSRange(location: 2, length: 7)
        XCTAssertEqual(
            range.replacingSelection(#"{"a":1}"#, with: #"{"a": 1}"#, in: #"😀{"a":1}尾"#),
            #"😀{"a": 1}尾"#
        )
        XCTAssertNil(range.replacingSelection(#"{"b":1}"#, with: "new", in: #"😀{"a":1}尾"#))
        XCTAssertNil(range.replacingSelection(#"{"a":1}"#, with: "new", in: "short"))
    }

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

    func testWebAreaAllowsEditingAcrossAnyAppWithoutWhitelist() {
        let webArea = ElementAccessibilitySnapshot(
            role: "AXWebArea", subrole: nil, editable: false,
            isSelectedTextSettable: false, isValueSettable: false
        )
        XCTAssertTrue(EditabilityEvaluator.canEdit(hasWindow: true, chain: [webArea], afterCopy: false))
        XCTAssertTrue(EditabilityEvaluator.canEdit(hasWindow: true, chain: [webArea], afterCopy: true))
    }

    func testStaticTextRequiresEditableAncestorToAllowEditing() {
        let staticText = ElementAccessibilitySnapshot(
            role: kAXStaticTextRole, subrole: nil, editable: nil,
            isSelectedTextSettable: false, isValueSettable: false
        )
        let readOnlyGroup = ElementAccessibilitySnapshot(
            role: kAXGroupRole, subrole: nil, editable: false,
            isSelectedTextSettable: false, isValueSettable: false
        )
        let editableContainer = ElementAccessibilitySnapshot(
            role: kAXGroupRole, subrole: nil, editable: true,
            isSelectedTextSettable: false, isValueSettable: false
        )

        XCTAssertFalse(EditabilityEvaluator.canEdit(hasWindow: true, chain: [staticText, readOnlyGroup], afterCopy: false))
        XCTAssertFalse(EditabilityEvaluator.canEdit(hasWindow: true, chain: [staticText, readOnlyGroup], afterCopy: true))
        XCTAssertTrue(EditabilityEvaluator.canEdit(hasWindow: true, chain: [staticText, editableContainer], afterCopy: false))
        XCTAssertTrue(EditabilityEvaluator.canEdit(hasWindow: true, chain: [staticText, editableContainer], afterCopy: true))
    }

    func testReadOnlyTextAreaAndSecureTextFieldRemainBlocked() {
        let readOnlyTextArea = ElementAccessibilitySnapshot(
            role: kAXTextAreaRole, subrole: nil, editable: false,
            isSelectedTextSettable: false, isValueSettable: false
        )
        let secureField = ElementAccessibilitySnapshot(
            role: kAXTextFieldRole, subrole: kAXSecureTextFieldSubrole, editable: true,
            isSelectedTextSettable: true, isValueSettable: true
        )

        XCTAssertFalse(EditabilityEvaluator.canEdit(hasWindow: true, chain: [readOnlyTextArea], afterCopy: false))
        XCTAssertFalse(EditabilityEvaluator.canEdit(hasWindow: true, chain: [readOnlyTextArea], afterCopy: true))
        XCTAssertFalse(EditabilityEvaluator.canEdit(hasWindow: true, chain: [secureField], afterCopy: false))
        XCTAssertFalse(EditabilityEvaluator.canEdit(hasWindow: true, chain: [secureField], afterCopy: true))
    }

    @MainActor
    func testCopiedSelectionAllowsUnmappedWebViewRangeWhenValueIsEmpty() {
        XCTAssertTrue(
            SelectionFormatter.selectionStillMatches(
                currentSelection: nil,
                range: NSRange(location: 0, length: 7),
                currentValue: "",
                source: #"{"a":1}"#,
                fromCopy: true,
                initialRangeMatches: false
            )
        )
        XCTAssertFalse(
            SelectionFormatter.selectionStillMatches(
                currentSelection: nil,
                range: NSRange(location: 0, length: 7),
                currentValue: "",
                source: #"{"a":1}"#,
                fromCopy: true,
                initialRangeMatches: true
            )
        )
        XCTAssertFalse(
            SelectionFormatter.selectionStillMatches(
                currentSelection: #"{"b":2}"#,
                range: nil,
                currentValue: nil,
                source: #"{"a":1}"#,
                fromCopy: true,
                initialRangeMatches: false
            )
        )
    }
}
