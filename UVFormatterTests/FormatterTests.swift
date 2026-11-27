import XCTest

final class FormatterTests: XCTestCase {
    func testJSONKeepsOriginalOrderNumbersAndEscapes() throws {
        let input = #"{"z":90071992547409931234567890,"a":[1e+9999,-0.00,{"duplicate":"\u4e2d\/","duplicate":"a\"b"}],"empty":{"array":[]}}"#
        let expected = #"""
        {
          "z": 90071992547409931234567890,
          "a": [
            1e+9999,
            -0.00,
            {
              "duplicate": "\u4e2d\/",
              "duplicate": "a\"b"
            }
          ],
          "empty": {
            "array": []
          }
        }
        """#
        XCTAssertEqual(try Formatter.format(input), expected)
        XCTAssertEqual(try Formatter.format(expected), expected)
    }

    func testAcceptsJSONScalarsAndEmptyContainers() throws {
        XCTAssertEqual(try Formatter.format(" \ttrue\r\n"), "true")
        XCTAssertEqual(try Formatter.format(#""value ""#), #""value ""#)
        XCTAssertEqual(try Formatter.format("[ \n ]"), "[]")
    }

    func testRejectsMalformedJSONAndEmptyInput() {
        for input in ["", "  \n", "1 2", "01", "1e+", "[1\u{200B}]", #"["\u12Z4"]"#, "[\"line\nbreak\"]"] {
            XCTAssertThrowsError(try Formatter.format(input), input)
        }
    }

    func testJSONCFormatsCommentsAndTrailingCommasWithoutDroppingThem() throws {
        let input = """
        {
        // endpoint note
        "path": "/v1", /* inline note */
        "items": [
        1,
        2,
        ],
        }
        """
        let expected = """
        {
          // endpoint note
          "path": "/v1",
          /* inline note */
          "items": [
            1,
            2,
          ],
        }
        """
        XCTAssertEqual(try Formatter.format(input), expected)
    }

    func testJSON5KeepsDialectEscapesAndExtendedNumbers() throws {
        let input = #"{unquoted:'slash\/ identity\* hex\x41', number:+0x2A, continued:"two\nlines"}"#
        let expected = #"""
        {
          unquoted: 'slash\/ identity\* hex\x41',
          number: +0x2A,
          continued: "two\nlines"
        }
        """#
        XCTAssertEqual(try Formatter.format(input), expected)
    }

    func testJSON5AcceptsUnicodeWhitespaceAndLineCommentTerminators() throws {
        let input = "{\u{00A0}note:'value',// comment\u{2028}next:1,}"
        let expected = """
        {
          note: 'value',
          // comment
          next: 1,
        }
        """
        XCTAssertEqual(try Formatter.format(input), expected)
    }

    func testMalformedJSONErrorIdentifiesLineAndColumn() {
        let input = "{\n  \"ok\": true,\n  \"broken\": \"bad\\u12Z4\"\n}"
        XCTAssertThrowsError(try Formatter.format(input)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("第 3 行"), message)
            XCTAssertTrue(message.contains("列"), message)
        }
    }

    @MainActor
    func testDiagnosticsDefaultOnKeepJSON5SourceAndCanClear() throws {
        let name = "UVFormatterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = DiagnosticsStore(directoryURL: directory, defaults: defaults)
        let source = #"{note:'slash\*', value:+0x2A}"#

        XCTAssertTrue(store.isEnabled)
        store.record(source: source, targetBundleID: "test.editor", formatted: try Formatter.formatDetailed(source))

        let data = try Data(contentsOf: store.logFileURL)
        let line = try XCTUnwrap(String(data: data, encoding: .utf8)?.split(separator: "\n").first)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(record["kind"] as? String, "parsed")
        XCTAssertEqual(record["dialect"] as? String, "json5")
        XCTAssertEqual(record["targetBundleID"] as? String, "test.editor")
        XCTAssertEqual(record["originalBase64"] as? String, Data(source.utf8).base64EncodedString())
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(record["originalBase64"] as? String)), Data(source.utf8))
        let directoryMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber).intValue
        let fileMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: store.logFileURL.path)[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        XCTAssertEqual(fileMode & 0o777, 0o600)

        let malformed = "{\"broken\":\"bad\\u12Z4\"}"
        XCTAssertThrowsError(try Formatter.formatDetailed(malformed)) { error in
            store.record(source: malformed, targetBundleID: "test.editor", error: error)
        }
        let lines = String(decoding: try Data(contentsOf: store.logFileURL), as: UTF8.self).split(separator: "\n")
        let failure = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(lines.last).utf8)) as? [String: Any])
        XCTAssertEqual(failure["kind"] as? String, "parse-error")
        XCTAssertEqual(failure["line"] as? Int, 1)
        XCTAssertNotNil(failure["reason"] as? String)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(failure["originalBase64"] as? String)), Data(malformed.utf8))

        try store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.logFileURL.path))
    }

    @MainActor
    func testDiagnosticsCanBeDisabledAndStrictJSONSuccessIsNotLogged() throws {
        let name = "UVFormatterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = DiagnosticsStore(directoryURL: directory, defaults: defaults)

        store.record(source: #"{"ok":true}"#, targetBundleID: nil,
                     formatted: try Formatter.formatDetailed(#"{"ok":true}"#))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.logFileURL.path))

        store.setEnabled(false)
        store.record(source: #"{broken:'value'}"#, targetBundleID: nil,
                     formatted: try Formatter.formatDetailed(#"{broken:'value'}"#))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.logFileURL.path))
    }

    @MainActor
    func testDiagnosticsRollingLimitKeepsCompleteNewestRecords() throws {
        let name = "UVFormatterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = DiagnosticsStore(directoryURL: directory, defaults: defaults, maximumBytes: 1_000)
        let formatted = try Formatter.formatDetailed("{note:'ok'}")

        for index in 0..<12 {
            store.record(source: "{note:'value-\(index)'}", targetBundleID: "target-\(index)", formatted: formatted)
        }

        let data = try Data(contentsOf: store.logFileURL)
        XCTAssertLessThanOrEqual(data.count, 1_000)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        XCTAssertFalse(lines.isEmpty)
        let records = try lines.map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        XCTAssertTrue(records.allSatisfy { ($0["kind"] as? String) == "parsed" })
        let targetIDs = try records.map { try XCTUnwrap($0["targetBundleID"] as? String) }
        let indexes = targetIDs.compactMap { Int($0.replacingOccurrences(of: "target-", with: "")) }
        XCTAssertEqual(indexes.count, targetIDs.count)
        XCTAssertEqual(indexes, indexes.sorted())
        XCTAssertGreaterThan(try XCTUnwrap(indexes.first), 0)
    }

    func testXMLFormatsElementOnlyContentAndKeepsRawTokens() throws {
        let input = #"<?xml version="1.0"?><!-- leading --><r xmlns:t="urn:test"><t:a b='&quot; >'/><?demo go?><b><c></c></b></r>"#
        let expected = #"""
        <?xml version="1.0"?>
        <!-- leading -->
        <r xmlns:t="urn:test">
          <t:a b='&quot; >'/>
          <?demo go?>
          <b>
            <c></c>
          </b>
        </r>
        """#
        XCTAssertEqual(try Formatter.format(input), expected)
        XCTAssertEqual(try Formatter.format(expected), expected)
    }

    func testXMLKeepsMixedContentTextAndCDATA() throws {
        let input = "<r><empty> \t </empty><p>Hello <b>world</b> <![CDATA[<raw>&text]]>!</p><x><y/></x></r>"
        let expected = """
        <r>
          <empty> \t </empty>
          <p>Hello <b>world</b> <![CDATA[<raw>&text]]>!</p>
          <x>
            <y/>
          </x>
        </r>
        """
        XCTAssertEqual(try Formatter.format(input), expected)
    }

    func testXMLKeepsSpacePreserveSubtreeAndWhitespaceReferences() throws {
        let input = #"<r><outer xml:space='pres&#101;rve'> <inner><child/></inner> </outer><blank>&#32;<child/></blank></r>"#
        let expected = #"""
        <r>
          <outer xml:space='pres&#101;rve'> <inner><child/></inner> </outer>
          <blank>&#32;<child/></blank>
        </r>
        """#
        XCTAssertEqual(try Formatter.format(input), expected)
    }

    func testXMLKeepsWhitespaceInTextOnlyElementsWithComments() throws {
        let input = "<root><leaf> \t<!-- explanation -->\n </leaf></root>"
        XCTAssertEqual(try Formatter.format(input), "<root>\n  <leaf> \t<!-- explanation -->\n </leaf>\n</root>")
    }

    func testAcceptsUTF8DeclarationAliasAndKeepsBOM() throws {
        let input = "\u{FEFF}" + #"<?xml version="1.0" encoding="utf8"?><r><child/></r>"#
        let expected = "\u{FEFF}" + #"<?xml version="1.0" encoding="utf8"?>"# + "\n<r>\n  <child/>\n</r>"
        XCTAssertEqual(try Formatter.format(input), expected)
    }

    func testXMLRejectsBadMarkupAndDocumentTypes() {
        for input in ["<x><y></x>", "<x/><y/>", "<x>&other;</x>", "<x>\u{0}</x>", "<prefix:r/>", "<!DOCTYPE r><r/>"] {
            XCTAssertThrowsError(try Formatter.format(input), input)
        }
    }

    func testInvalidXMLErrorReportsParserLocationAndReason() {
        XCTAssertThrowsError(try Formatter.format("<root>\n  <item></root>")) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("第 2 行"), message)
            XCTAssertTrue(message.contains("列"), message)
            XCTAssertFalse(message.contains("XML 语法错误\n建议"), message)
        }
    }

    func testRejectsBinaryUTF16PosingAsPlainText() throws {
        let xml = #"<?xml version="1.0"?><r><child/></r>"#
        let utf16 = try XCTUnwrap(xml.data(using: .utf16LittleEndian))
        let encodedSelection = String(decoding: utf16, as: UTF8.self)
        XCTAssertThrowsError(try Formatter.format(encodedSelection))
    }

    func testDeepNestingFailsWithoutStackOverflow() {
        XCTAssertThrowsError(try Formatter.format(String(repeating: "[", count: 600) + String(repeating: "]", count: 600)))
        XCTAssertThrowsError(try Formatter.format(String(repeating: "<n>", count: 600) + String(repeating: "</n>", count: 600)))
    }
}
