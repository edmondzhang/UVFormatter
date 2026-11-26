import Foundation

enum Formatter {
    /// Validates a complete JSON value or XML document and returns its indented form.
    /// Throws a user-facing error for empty, invalid, unsupported or oversized selections.
    /// This operation is deterministic and has no external side effects or mutable shared state.
    static func format(_ text: String) throws -> String {
        guard text.utf8.count <= 4 * 1024 * 1024 else { throw FormatError.selectionTooLarge }
        var input = Array(text.utf8)
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let hasBOM = input.starts(with: bom)
        if hasBOM { input.removeFirst(bom.count) }
        guard let first = input.first(where: { !$0.isMarkupWhitespace }) else {
            throw FormatError.empty
        }

        let formatted: String
        if first == ASCII.tagStart {
            var formatter = XMLFormatter(input: input)
            formatted = try formatter.format()
        } else {
            var formatter = JSONFormatter(input: input)
            formatted = try formatter.format()
        }
        return hasBOM ? "\u{FEFF}" + formatted : formatted
    }
}

private enum FormatError: LocalizedError {
    case empty, invalidJSON, invalidXML, xmlDocumentType, selectionTooLarge, nestingTooDeep, resultTooLarge

    var errorDescription: String? {
        switch self {
        case .empty: return "请先选中一段 JSON 或 XML。"
        case .invalidJSON: return "选区不是完整的有效 JSON。"
        case .invalidXML: return "选区不是完整的有效 XML。"
        case .xmlDocumentType: return "选区包含 XML 文档类型声明，无法安全格式化。"
        case .selectionTooLarge: return "选区超过 4 MB，无法格式化。"
        case .nestingTooDeep: return "选区的嵌套层数过多，无法格式化。"
        case .resultTooLarge: return "格式化结果超过 16 MB，无法写回。"
        }
    }
}

private enum ASCII {
    static let quote: UInt8 = 0x22
    static let apostrophe: UInt8 = 0x27
    static let backslash: UInt8 = 0x5C
    static let objectStart: UInt8 = 0x7B
    static let objectEnd: UInt8 = 0x7D
    static let arrayStart: UInt8 = 0x5B
    static let arrayEnd: UInt8 = 0x5D
    static let colon: UInt8 = 0x3A
    static let comma: UInt8 = 0x2C
    static let minus: UInt8 = 0x2D
    static let plus: UInt8 = 0x2B
    static let point: UInt8 = 0x2E
    static let tagStart: UInt8 = 0x3C
    static let tagEnd: UInt8 = 0x3E
    static let slash: UInt8 = 0x2F
}

private extension UInt8 {
    var isMarkupWhitespace: Bool { self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D }
    var isDigit: Bool { (0x30...0x39).contains(self) }
    var isHexDigit: Bool { isDigit || (0x41...0x46).contains(self) || (0x61...0x66).contains(self) }
}

private struct IndentedOutput {
    private(set) var bytes: [UInt8] = []
    private static let maxBytes = 16 * 1024 * 1024
    static let maxDepth = 256

    mutating func append(_ byte: UInt8) throws {
        guard bytes.count < Self.maxBytes else { throw FormatError.resultTooLarge }
        bytes.append(byte)
    }

    mutating func append(_ source: ArraySlice<UInt8>) throws {
        guard source.count <= Self.maxBytes - bytes.count else { throw FormatError.resultTooLarge }
        bytes.append(contentsOf: source)
    }

    mutating func newline(depth: Int) throws {
        let spaces = 2 * depth
        guard 1 + spaces <= Self.maxBytes - bytes.count else { throw FormatError.resultTooLarge }
        bytes.append(0x0A)
        bytes.append(contentsOf: repeatElement(0x20, count: spaces))
    }
}

private struct JSONFormatter {
    let input: [UInt8]
    private var index = 0
    private var output = IndentedOutput()

    init(input: [UInt8]) { self.input = input }

    /// Copies each validated literal directly from the selection to retain precision and spelling.
    mutating func format() throws -> String {
        try value(depth: 0)
        skipWhitespace()
        guard index == input.count else { throw FormatError.invalidJSON }
        return String(decoding: output.bytes, as: UTF8.self)
    }

    private var current: UInt8? { index < input.count ? input[index] : nil }

    private mutating func skipWhitespace() {
        while current?.isMarkupWhitespace == true { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard current == byte else { return false }
        index += 1
        return true
    }

    private mutating func value(depth: Int) throws {
        skipWhitespace()
        let start = index
        switch current {
        case ASCII.objectStart:
            try container(depth: depth, object: true)
            return
        case ASCII.arrayStart:
            try container(depth: depth, object: false)
            return
        case ASCII.quote: try string()
        case 0x74: try literal("true")
        case 0x66: try literal("false")
        case 0x6E: try literal("null")
        default: try number()
        }
        try output.append(input[start..<index])
    }

    private mutating func container(depth: Int, object: Bool) throws {
        guard depth < IndentedOutput.maxDepth else { throw FormatError.nestingTooDeep }
        try output.append(object ? ASCII.objectStart : ASCII.arrayStart)
        let end = object ? ASCII.objectEnd : ASCII.arrayEnd
        index += 1
        skipWhitespace()
        if consume(end) {
            try output.append(end)
            return
        }

        repeat {
            try output.newline(depth: depth + 1)
            skipWhitespace()
            if object {
                let keyStart = index
                try string()
                try output.append(input[keyStart..<index])
                skipWhitespace()
                guard consume(ASCII.colon) else { throw FormatError.invalidJSON }
                try output.append(ASCII.colon)
                try output.append(0x20)
            }
            try value(depth: depth + 1)
            skipWhitespace()
            guard consume(ASCII.comma) else { break }
            try output.append(ASCII.comma)
        } while true

        guard consume(end) else { throw FormatError.invalidJSON }
        try output.newline(depth: depth)
        try output.append(end)
    }

    private mutating func string() throws {
        guard consume(ASCII.quote) else { throw FormatError.invalidJSON }
        while let byte = current {
            index += 1
            switch byte {
            case ASCII.quote: return
            case ASCII.backslash:
                if consume(0x75) {
                    for _ in 0..<4 {
                        guard current?.isHexDigit == true else { throw FormatError.invalidJSON }
                        index += 1
                    }
                } else {
                    guard let escaped = current, [ASCII.quote, ASCII.backslash, ASCII.slash, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escaped) else {
                        throw FormatError.invalidJSON
                    }
                    index += 1
                }
            case 0..<0x20: throw FormatError.invalidJSON
            default: break
            }
        }
        throw FormatError.invalidJSON
    }

    private mutating func literal(_ expected: String) throws {
        guard input[index...].starts(with: expected.utf8) else { throw FormatError.invalidJSON }
        index += expected.utf8.count
    }

    private mutating func number() throws {
        _ = consume(ASCII.minus)
        if !consume(0x30) { try digits() }
        if consume(ASCII.point) { try digits() }
        if consume(0x65) || consume(0x45) {
            if !consume(ASCII.plus) { _ = consume(ASCII.minus) }
            try digits()
        }
    }

    private mutating func digits() throws {
        guard current?.isDigit == true else { throw FormatError.invalidJSON }
        repeat { index += 1 } while current?.isDigit == true
    }
}

private struct XMLFormatter {
    private enum Kind { case opening, closing, empty, trivia, text, whitespace }

    private struct Token {
        let kind: Kind
        let range: Range<Int>
        var closingIndex = 0
        var hasChildElement = false
        var hasText = false
    }

    let input: [UInt8]
    private var tokens: [Token] = []
    private var output = IndentedOutput()
    private var index = 0

    init(input: [UInt8]) { self.input = input }

    /// The tokenizer rejects DTDs before Foundation can parse declarations or expand entities.
    /// The document validates XML syntax and decodes xml:space while the renderer copies raw markup.
    mutating func format() throws -> String {
        // XML forbids literal NULs. Reject them before the parser can auto-detect UTF-16 or UTF-32.
        guard !input.contains(0) else { throw FormatError.invalidXML }
        try tokenize()
        let document: XMLDocument
        do {
            document = try XMLDocument(data: Data(input), options: [.nodeLoadExternalEntitiesNever])
        } catch {
            throw FormatError.invalidXML
        }
        guard let root = document.rootElement(), document.dtd == nil else { throw FormatError.invalidXML }
        if let encoding = document.characterEncoding {
            let encodingID = CFStringConvertIANACharSetNameToEncoding(encoding as CFString)
            guard encodingID == CFStringBuiltInEncodings.UTF8.rawValue || encoding.caseInsensitiveCompare("UTF8") == .orderedSame else {
                throw FormatError.invalidXML
            }
        }

        var cursor = 0
        while cursor < tokens.count {
            let token = tokens[cursor]
            if token.kind == .whitespace {
                cursor += 1
                continue
            }
            if !output.bytes.isEmpty { try output.newline(depth: 0) }
            if token.kind == .opening {
                cursor = try renderElement(at: cursor, element: root, depth: 0)
            } else {
                try output.append(input[token.range])
                cursor += 1
            }
        }
        return String(decoding: output.bytes, as: UTF8.self)
    }

    private mutating func tokenize() throws {
        var openElements: [Int] = []
        while index < input.count {
            let start = index
            let kind = try readToken()
            let parent = openElements.last
            if let parent {
                switch kind {
                case .opening, .empty: tokens[parent].hasChildElement = true
                case .text: tokens[parent].hasText = true
                default: break
                }
            }
            let position = tokens.count
            tokens.append(Token(kind: kind, range: start..<index))
            switch kind {
            case .opening:
                guard openElements.count < IndentedOutput.maxDepth else { throw FormatError.nestingTooDeep }
                openElements.append(position)
            case .closing:
                guard let opening = openElements.popLast() else { throw FormatError.invalidXML }
                tokens[opening].closingIndex = position
            default: break
            }
        }
        guard openElements.isEmpty else { throw FormatError.invalidXML }
    }

    private mutating func readToken() throws -> Kind {
        let remainder = input[index...]
        guard remainder.first == ASCII.tagStart else {
            let start = index
            while index < input.count && input[index] != ASCII.tagStart { index += 1 }
            return input[start..<index].allSatisfy(\.isMarkupWhitespace) ? .whitespace : .text
        }
        if remainder.starts(with: "<!--".utf8) {
            try scanMarkup(prefixLength: 4, terminator: "-->")
            return .trivia
        }
        if remainder.starts(with: "<?".utf8) {
            try scanMarkup(prefixLength: 2, terminator: "?>")
            return .trivia
        }
        if remainder.starts(with: "<![CDATA[".utf8) {
            try scanMarkup(prefixLength: 9, terminator: "]]>")
            return .text
        }
        if remainder.starts(with: "<!DOCTYPE".utf8) { throw FormatError.xmlDocumentType }
        if remainder.starts(with: "<!".utf8) { throw FormatError.invalidXML }

        let closing = remainder.dropFirst().first == ASCII.slash
        index += 1
        var quote: UInt8?
        while index < input.count {
            let byte = input[index]
            index += 1
            if let delimiter = quote {
                if byte == delimiter { quote = nil }
            } else if byte == ASCII.quote || byte == ASCII.apostrophe {
                quote = byte
            } else if byte == ASCII.tagEnd {
                if closing { return .closing }
                return input[index - 2] == ASCII.slash ? .empty : .opening
            }
        }
        throw FormatError.invalidXML
    }

    private mutating func scanMarkup(prefixLength: Int, terminator: String) throws {
        index += prefixLength
        while index < input.count {
            if input[index...].starts(with: terminator.utf8) {
                index += terminator.utf8.count
                return
            }
            index += 1
        }
        throw FormatError.invalidXML
    }

    /// Preserves mixed content and xml:space regions byte-for-byte. In element-only
    /// containers, the whitespace between markup tokens is treated as indentation.
    private mutating func renderElement(at openingIndex: Int, element: XMLElement, depth: Int) throws -> Int {
        let opening = tokens[openingIndex]
        let closing = tokens[opening.closingIndex]
        let space = element.attribute(forName: "xml:space")?.stringValue
        if opening.hasText || !opening.hasChildElement || (space != nil && space != "default") {
            try output.append(input[opening.range.lowerBound..<closing.range.upperBound])
            return opening.closingIndex + 1
        }

        try output.append(input[opening.range])
        var cursor = openingIndex + 1
        let children = (element.children ?? []).compactMap { $0 as? XMLElement }
        var child = children.startIndex
        while cursor < opening.closingIndex {
            let token = tokens[cursor]
            if token.kind == .whitespace {
                cursor += 1
                continue
            }
            try output.newline(depth: depth + 1)
            switch token.kind {
            case .opening:
                guard child < children.endIndex else { throw FormatError.invalidXML }
                cursor = try renderElement(at: cursor, element: children[child], depth: depth + 1)
                child += 1
            case .empty:
                try output.append(input[token.range])
                cursor += 1
                child += 1
            default:
                try output.append(input[token.range])
                cursor += 1
            }
        }
        try output.newline(depth: depth)
        try output.append(input[closing.range])
        return opening.closingIndex + 1
    }
}
