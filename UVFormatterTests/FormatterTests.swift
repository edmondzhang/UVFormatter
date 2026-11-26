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
        for input in ["", "  \n", "{x:1}", "[1,]", "1 2", "01", "1e+", "[NaN]", "[1\u{A0}]", #"["\u12Z4"]"#, "[\"line\nbreak\"]"] {
            XCTAssertThrowsError(try Formatter.format(input), input)
        }
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
