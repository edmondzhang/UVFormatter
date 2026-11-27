import Foundation

enum FormatterDialect: String, Codable {
    case json
    case jsonc
    case json5
    case xml
}

struct FormattedSelection {
    let text: String
    let dialect: FormatterDialect
}

struct FormatterIssue: LocalizedError {
    let dialect: FormatterDialect
    let line: Int
    let column: Int
    let reason: String
    let candidates: [String]

    var errorDescription: String? {
        "第 \(line) 行第 \(column) 列：\(reason)\n建议：\(candidates.joined(separator: "；"))"
    }
}

enum Formatter {
    /// Validates a complete JSON, JSONC, JSON5, or XML selection and returns its indented form.
    /// Throws a user-facing error for empty, malformed, unsupported, or oversized selections.
    /// Parsing and formatting are deterministic and keep source tokens instead of reserializing values.
    static func format(_ text: String) throws -> String {
        try formatDetailed(text).text
    }

    static func formatDetailed(_ text: String) throws -> FormattedSelection {
        guard text.utf8.count <= 4 * 1024 * 1024 else { throw FormatError.selectionTooLarge }
        var input = Array(text.utf8)
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let hasBOM = input.starts(with: bom)
        if hasBOM { input.removeFirst(bom.count) }
        guard let first = input.first(where: { !$0.isMarkupWhitespace }) else {
            throw FormatError.empty
        }

        if first == ASCII.tagStart {
            var formatter = XMLFormatter(input: input)
            do {
                let formatted = try formatter.format()
                return FormattedSelection(text: hasBOM ? "\u{FEFF}" + formatted : formatted, dialect: .xml)
            } catch let failure as XMLParseFailure {
                if let line = failure.line, let column = failure.column {
                    throw FormatterIssue(dialect: .xml, line: line, column: column,
                                         reason: failure.reason, candidates: failure.candidates)
                }
                throw issue(for: text, offset: failure.offset ?? 0, dialect: .xml,
                            reason: failure.reason, candidates: failure.candidates)
            } catch let error as FormatError {
                throw issue(for: text, offset: 0, dialect: .xml,
                            reason: error.localizedDescription,
                            candidates: ["检查标签、注释、CDATA 和属性引号是否完整。"])
            } catch {
                throw issue(for: text, offset: 0, dialect: .xml, reason: error.localizedDescription,
                            candidates: ["检查标签、注释、CDATA 和属性引号是否完整。"])
            }
        }

        var failures: [JSONFailure] = []
        for dialect in [FormatterDialect.json, .jsonc, .json5] {
            var formatter = JSONFormatter(input: input, dialect: dialect)
            do {
                let formatted = try formatter.format()
                return FormattedSelection(text: hasBOM ? "\u{FEFF}" + formatted : formatted, dialect: dialect)
            } catch let failure as JSONFailure {
                failures.append(failure)
            }
        }
        let failure = failures.max { $0.offset < $1.offset }
            ?? JSONFailure(offset: 0, dialect: .json5, reason: "JSON 语法错误", candidates: [])
        throw issue(for: text, offset: failure.offset + (hasBOM ? bom.count : 0), dialect: failure.dialect,
                    reason: failure.reason, candidates: failure.candidates)
    }

    private static func issue(
        for text: String,
        offset: Int,
        dialect: FormatterDialect,
        reason: String,
        candidates: [String]
    ) -> FormatterIssue {
        let bytes = Array(text.utf8.prefix(offset))
        let prefix = String(decoding: bytes, as: UTF8.self)
        var line = 1
        var column = 1
        var afterCarriageReturn = false
        for scalar in prefix.unicodeScalars {
            if scalar == "\r" {
                line += 1
                column = 1
                afterCarriageReturn = true
            } else if scalar == "\n" {
                if !afterCarriageReturn { line += 1 }
                column = 1
                afterCarriageReturn = false
            } else if scalar == "\u{2028}" || scalar == "\u{2029}" {
                line += 1
                column = 1
                afterCarriageReturn = false
            } else {
                column += 1
                afterCarriageReturn = false
            }
        }
        return FormatterIssue(dialect: dialect, line: line, column: column, reason: reason, candidates: candidates)
    }
}

private enum FormatError: LocalizedError {
    case empty
    case invalidJSON
    case invalidXML
    case xmlDocumentType
    case selectionTooLarge
    case nestingTooDeep
    case resultTooLarge
    var errorDescription: String? {
        switch self {
        case .empty: return "请先选中一段 JSON 或 XML。"
        case .invalidJSON: return "选区不是完整的有效 JSON。"
        case .invalidXML: return "XML 结构不完整或包含非法标记。"
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
    static let asterisk: UInt8 = 0x2A
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
        while bytes.last == 0x20 { bytes.removeLast() }
        if bytes.last != 0x0A {
            guard 1 <= Self.maxBytes - bytes.count else { throw FormatError.resultTooLarge }
            bytes.append(0x0A)
        }
        guard spaces <= Self.maxBytes - bytes.count else { throw FormatError.resultTooLarge }
        bytes.append(contentsOf: repeatElement(0x20, count: spaces))
    }
}

private struct JSONFailure: Error {
    let offset: Int
    let dialect: FormatterDialect
    let reason: String
    let candidates: [String]
}

private struct XMLParseFailure: Error {
    let offset: Int?
    let line: Int?
    let column: Int?
    let reason: String
    let candidates: [String]

    init(offset: Int, reason: String) {
        self.offset = offset
        self.line = nil
        self.column = nil
        self.reason = reason
        self.candidates = ["检查标签配对、注释、CDATA 和属性引号是否完整。"]
    }

    init(parser: XMLParser, error: Error) {
        self.offset = nil
        self.line = max(1, parser.lineNumber)
        self.column = max(1, parser.columnNumber)
        self.reason = error.localizedDescription
        self.candidates = ["检查此位置附近的 XML 标签、属性和实体引用。"]
    }
}

private final class XMLParseErrorDelegate: NSObject, XMLParserDelegate {
    var error: Error?

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        error = parseError
    }

    func parser(_ parser: XMLParser, validationErrorOccurred validationError: Error) {
        error = validationError
    }
}

private struct JSONFormatter {
    private struct Comment {
        let range: Range<Int>
        let isLine: Bool
    }

    let input: [UInt8]
    let dialect: FormatterDialect
    private var index = 0
    private var output = IndentedOutput()

    init(input: [UInt8], dialect: FormatterDialect) {
        self.input = input
        self.dialect = dialect
    }

    private var current: UInt8? { index < input.count ? input[index] : nil }
    private var json5: Bool { dialect == .json5 }
    private var commentsAllowed: Bool { dialect != .json }

    /// Copies validated source tokens into a formatted buffer while preserving dialect-specific syntax.
    /// The input is never evaluated or rewritten through a value model.
    mutating func format() throws -> String {
        let leading = try trivia()
        try appendComments(leading, depth: 0)
        if !leading.isEmpty { try output.newline(depth: 0) }
        try value(depth: 0)
        let trailing = try trivia()
        try appendComments(trailing, depth: 0)
        guard index == input.count else {
            throw failure("JSON 值后存在多余内容。")
        }
        return String(decoding: output.bytes, as: UTF8.self)
    }

    private func failure(
        _ reason: String,
        offset: Int? = nil,
        candidates: [String] = []
    ) -> JSONFailure {
        JSONFailure(
            offset: offset ?? index,
            dialect: dialect,
            reason: reason,
            candidates: candidates.isEmpty ? ["检查引号、反斜杠转义、分隔符和选区是否完整。"] : candidates
        )
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard current == byte else { return false }
        index += 1
        return true
    }

    private mutating func value(depth: Int) throws {
        guard depth <= IndentedOutput.maxDepth else { throw FormatError.nestingTooDeep }
        let start = index
        switch current {
        case ASCII.objectStart:
            try container(depth: depth, isObject: true)
            return
        case ASCII.arrayStart:
            try container(depth: depth, isObject: false)
            return
        case ASCII.quote:
            try string(quote: ASCII.quote)
        case ASCII.apostrophe where json5:
            try string(quote: ASCII.apostrophe)
        case 0x74:
            try literal("true")
        case 0x66:
            try literal("false")
        case 0x6E:
            try literal("null")
        case 0x49 where json5:
            try literal("Infinity")
        case 0x4E where json5:
            try literal("NaN")
        default:
            if json5, current == ASCII.minus || current == ASCII.plus,
               hasSignedSpecialNumber {
                index += 1
                if input[index...].starts(with: "Infinity".utf8) { try literal("Infinity") }
                else { try literal("NaN") }
            } else {
                try number()
            }
        }
        try output.append(input[start..<index])
    }

    private var hasSignedSpecialNumber: Bool {
        guard index + 1 < input.count else { return false }
        let remainder = input.dropFirst(index + 1)
        return remainder.starts(with: "Infinity".utf8) || remainder.starts(with: "NaN".utf8)
    }

    private mutating func container(depth: Int, isObject: Bool) throws {
        guard depth < IndentedOutput.maxDepth else { throw FormatError.nestingTooDeep }
        let open = isObject ? ASCII.objectStart : ASCII.arrayStart
        let close = isObject ? ASCII.objectEnd : ASCII.arrayEnd
        try output.append(open)
        index += 1

        var comments = try trivia()
        if consume(close) {
            if !comments.isEmpty {
                try output.newline(depth: depth + 1)
                try appendComments(comments, depth: depth + 1)
                try output.newline(depth: depth)
            }
            try output.append(close)
            return
        }

        while true {
            try output.newline(depth: depth + 1)
            try appendComments(comments, depth: depth + 1)
            if !comments.isEmpty { try output.newline(depth: depth + 1) }

            if isObject {
                let keyStart = index
                try key()
                try output.append(input[keyStart..<index])
                let afterKey = try trivia()
                if !afterKey.isEmpty {
                    try output.newline(depth: depth + 2)
                    try appendComments(afterKey, depth: depth + 2)
                    try output.newline(depth: depth + 2)
                }
                guard consume(ASCII.colon) else {
                    throw failure("对象成员名后缺少冒号。")
                }
                try output.append(ASCII.colon)

                let beforeValue = try trivia()
                if !beforeValue.isEmpty {
                    try output.newline(depth: depth + 2)
                    try appendComments(beforeValue, depth: depth + 2)
                    try output.newline(depth: depth + 2)
                } else {
                    try output.append(0x20)
                }
            }

            try value(depth: depth + 1)
            comments = try trivia()
            if consume(ASCII.comma) {
                try output.append(ASCII.comma)
                comments.append(contentsOf: try trivia())
                if current == close {
                    index += 1
                    try output.newline(depth: depth + 1)
                    try appendComments(comments, depth: depth + 1)
                    try output.newline(depth: depth)
                    try output.append(close)
                    return
                }
                continue
            }
            guard consume(close) else {
                if current == nil { throw failure("JSON 容器缺少结束符。") }
                throw failure(isObject ? "对象成员间缺少逗号。" : "数组元素间缺少逗号。")
            }
            try output.newline(depth: depth + 1)
            try appendComments(comments, depth: depth + 1)
            try output.newline(depth: depth)
            try output.append(close)
            return
        }
    }

    private mutating func key() throws {
        if current == ASCII.quote {
            try string(quote: ASCII.quote)
        } else if json5, current == ASCII.apostrophe {
            try string(quote: ASCII.apostrophe)
        } else if json5 {
            try identifier()
        } else {
            throw failure("对象成员名必须使用双引号。", candidates: ["如果输入使用 JSON5 非引号键，请检查该标识符。"])
        }
    }

    private mutating func string(quote: UInt8) throws {
        let start = index
        guard consume(quote) else { throw failure("字符串必须以引号开头。") }

        while let byte = current {
            if byte == quote {
                index += 1
                return
            }
            if byte == ASCII.backslash {
                let escapeOffset = index
                index += 1
                if json5, index + 2 < input.count, input[index] == 0xE2,
                   input[index + 1] == 0x80, (input[index + 2] == 0xA8 || input[index + 2] == 0xA9) {
                    index += 3
                    continue
                }
                guard let escaped = current else {
                    throw failure("字符串以未完成的反斜杠转义结束。", offset: escapeOffset)
                }
                index += 1
                if escaped == 0x75 {
                    try consumeHexDigits(count: 4)
                } else if json5, escaped == 0x78 {
                    try consumeHexDigits(count: 2)
                } else if json5, isLineTerminator(escaped) {
                    consumeLineTerminator(escaped)
                } else if isStandardEscape(escaped, quote: quote)
                            || (json5 && escaped == ASCII.apostrophe)
                            || (json5 && escaped == 0x76)
                            || (json5 && escaped == 0x30 && current?.isDigit != true)
                            || (json5 && !escaped.isDigit) {
                    continue
                } else {
                    throw failure(
                        "字符串中的反斜杠转义无效。",
                        offset: escapeOffset,
                        candidates: ["仅对 JSON5 按身份转义处理此字符。", "检查反斜杠是否应写为 \\\\。"]
                    )
                }
                continue
            }
            if byte < 0x20 {
                throw failure("字符串中包含未转义的控制字符。")
            }
            if json5, isLineCommentTerminator(at: index) {
                throw failure("JSON5 字符串中不能包含未转义的行终止符。")
            }
            index += 1
        }
        throw failure("字符串缺少结束引号。", offset: start)
    }

    private func isStandardEscape(_ byte: UInt8, quote: UInt8) -> Bool {
        byte == quote || byte == ASCII.backslash || byte == ASCII.slash
            || [0x62, 0x66, 0x6E, 0x72, 0x74].contains(byte)
    }

    private func isLineTerminator(_ byte: UInt8) -> Bool {
        byte == 0x0A || byte == 0x0D
    }

    private mutating func consumeLineTerminator(_ first: UInt8) {
        if first == 0x0D, current == 0x0A { index += 1 }
    }

    private mutating func consumeHexDigits(count: Int) throws {
        for _ in 0..<count {
            guard current?.isHexDigit == true else {
                throw failure("反斜杠后的十六进制转义位数不正确。")
            }
            index += 1
        }
    }

    private mutating func identifier() throws {
        var first = true
        while index < input.count {
            if current == ASCII.backslash {
                let escapeOffset = index
                index += 1
                guard consume(0x75) else {
                    throw failure("JSON5 标识符中的反斜杠必须跟随 Unicode 转义。", offset: escapeOffset)
                }
                let scalar = try identifierEscape()
                guard first ? isIdentifierStart(scalar) : isIdentifierContinue(scalar) else {
                    throw failure("Unicode 转义不构成有效的 JSON5 标识符。", offset: escapeOffset)
                }
                first = false
                continue
            }
            guard let scalar = scalar(at: index),
                  first ? isIdentifierStart(scalar) : isIdentifierContinue(scalar) else { break }
            index += scalar.utf8.count
            first = false
        }
        guard !first else { throw failure("此处需要 JSON5 成员键。") }
    }

    private mutating func identifierEscape() throws -> Unicode.Scalar {
        var first = try readCodeUnit()
        if (0xD800...0xDBFF).contains(first), current == ASCII.backslash,
           index + 1 < input.count, input[index + 1] == 0x75 {
            index += 2
            let second = try readCodeUnit()
            guard (0xDC00...0xDFFF).contains(second) else { throw failure("Unicode 代理项转义无效。") }
            first = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
        }
        guard let scalar = Unicode.Scalar(first) else { throw failure("Unicode 转义不构成有效标识符。") }
        return scalar
    }

    private mutating func readCodeUnit() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = current, byte.isHexDigit else { throw failure("Unicode 转义位数不足。") }
            value = value * 16 + byte.hexValue
            index += 1
        }
        return value
    }

    private func scalar(at offset: Int) -> Unicode.Scalar? {
        guard offset < input.count else { return nil }
        return String(decoding: input[offset...], as: UTF8.self).unicodeScalars.first
    }

    private func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "$" || scalar == "_" || CharacterSet.letters.contains(scalar)
    }

    private func isIdentifierContinue(_ scalar: Unicode.Scalar) -> Bool {
        isIdentifierStart(scalar) || CharacterSet.decimalDigits.contains(scalar)
            || CharacterSet.nonBaseCharacters.contains(scalar)
            || scalar == "\u{200C}" || scalar == "\u{200D}"
    }

    private mutating func number() throws {
        let start = index
        if current == ASCII.minus || (json5 && current == ASCII.plus) { index += 1 }
        if json5, current == 0x30, index + 1 < input.count,
           input[index + 1] == 0x78 || input[index + 1] == 0x58 {
            index += 2
            let digitsStart = index
            while current?.isHexDigit == true { index += 1 }
            guard index > digitsStart else { throw failure("十六进制数缺少数字。", offset: start) }
            return
        }
        if json5, input[index...].starts(with: "Infinity".utf8) {
            try literal("Infinity")
            return
        }
        if json5, input[index...].starts(with: "NaN".utf8) {
            try literal("NaN")
            return
        }

        if current == ASCII.point {
            guard json5 else { throw failure("严格 JSON 小数点前缺少数字。", offset: start) }
            index += 1
            try digits()
        } else {
            guard current?.isDigit == true else { throw failure("此处需要 JSON 值。", offset: start) }
            if current == 0x30 {
                index += 1
                if current?.isDigit == true {
                    throw failure("数字不能包含前导零。", offset: start)
                }
            } else {
                try digits()
            }
            if current == ASCII.point {
                index += 1
                if json5 {
                    while current?.isDigit == true { index += 1 }
                } else {
                    try digits()
                }
            }
        }
        if current == 0x65 || current == 0x45 {
            index += 1
            if current == ASCII.plus || current == ASCII.minus { index += 1 }
            try digits()
        }
    }

    private mutating func digits() throws {
        guard current?.isDigit == true else { throw failure("数字位数不足。") }
        repeat { index += 1 } while current?.isDigit == true
    }

    private mutating func literal(_ expected: String) throws {
        guard input[index...].starts(with: expected.utf8) else {
            throw failure("此处需要 JSON 值。")
        }
        index += expected.utf8.count
    }

    private mutating func trivia() throws -> [Comment] {
        var comments: [Comment] = []
        while index < input.count {
            if let whitespaceLength = whitespaceLength(at: index) {
                index += whitespaceLength
                continue
            }
            guard commentsAllowed, current == ASCII.slash, index + 1 < input.count else { break }
            let start = index
            if input[index + 1] == ASCII.slash {
                index += 2
                while index < input.count && !isLineCommentTerminator(at: index) { index += 1 }
                comments.append(Comment(range: start..<index, isLine: true))
                continue
            }
            if input[index + 1] == ASCII.asterisk {
                index += 2
                while index + 1 < input.count && !(input[index] == ASCII.asterisk && input[index + 1] == ASCII.slash) {
                    index += 1
                }
                guard index + 1 < input.count else {
                    throw failure("块注释缺少结束标记 */。", offset: start)
                }
                index += 2
                comments.append(Comment(range: start..<index, isLine: false))
                continue
            }
            break
        }
        return comments
    }

    private func whitespaceLength(at offset: Int) -> Int? {
        guard offset < input.count else { return nil }
        switch input[offset] {
        case 0x09, 0x0A, 0x0D, 0x20: return 1
        case 0x0B, 0x0C: return json5 ? 1 : nil
        case 0xC2 where json5 && offset + 1 < input.count && input[offset + 1] == 0xA0: return 2
        case 0xE1 where json5 && offset + 2 < input.count && input[offset + 1] == 0x9A
                && input[offset + 2] == 0x80: return 3
        case 0xE2 where json5 && offset + 2 < input.count && input[offset + 1] == 0x80
                && ((0x80...0x8A).contains(input[offset + 2]) || input[offset + 2] == 0xA8
                    || input[offset + 2] == 0xA9 || input[offset + 2] == 0xAF): return 3
        case 0xE3 where json5 && offset + 2 < input.count && input[offset + 1] == 0x80
                && input[offset + 2] == 0x80: return 3
        case 0xEF where json5 && offset + 2 < input.count && input[offset + 1] == 0xBB
                && input[offset + 2] == 0xBF: return 3
        case 0xE2 where json5 && offset + 2 < input.count && input[offset + 1] == 0x81
                && input[offset + 2] == 0x9F: return 3
        default: return nil
        }
    }

    private func isLineCommentTerminator(at offset: Int) -> Bool {
        if input[offset] == 0x0A || input[offset] == 0x0D { return true }
        return json5 && offset + 2 < input.count && input[offset] == 0xE2
            && input[offset + 1] == 0x80 && (input[offset + 2] == 0xA8 || input[offset + 2] == 0xA9)
    }

    private mutating func appendComments(_ comments: [Comment], depth: Int) throws {
        for comment in comments {
            if !output.bytes.isEmpty { try output.newline(depth: depth) }
            try output.append(input[comment.range])
            try output.newline(depth: depth)
        }
    }
}

private extension UInt8 {
    var hexValue: UInt32 {
        switch self {
        case 0x30...0x39: return UInt32(self - 0x30)
        case 0x41...0x46: return UInt32(self - 0x41 + 10)
        default: return UInt32(self - 0x61 + 10)
        }
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
        guard !input.contains(0) else { throw XMLParseFailure(offset: 0, reason: "XML 内容包含 NUL 字节。") }
        try tokenize()
        let validator = XMLParser(data: Data(input))
        let errorDelegate = XMLParseErrorDelegate()
        validator.delegate = errorDelegate
        validator.shouldResolveExternalEntities = false
        guard validator.parse() else {
            throw XMLParseFailure(parser: validator, error: errorDelegate.error ?? validator.parserError
                ?? CocoaError(.fileReadCorruptFile))
        }
        let document: XMLDocument
        do {
            document = try XMLDocument(data: Data(input), options: [.nodeLoadExternalEntitiesNever])
        } catch let error as NSError {
            let line = error.userInfo["NSXMLParserErrorLineNumber"] as? Int
            let column = error.userInfo["NSXMLParserErrorColumn"] as? Int
            if let line, let column {
                throw FormatterIssue(dialect: .xml, line: line, column: column,
                                     reason: error.localizedDescription,
                                     candidates: ["检查此位置附近的 XML 标签和属性。"])
            }
            throw XMLParseFailure(offset: 0, reason: error.localizedDescription)
        }
        guard let root = document.rootElement(), document.dtd == nil else {
            throw XMLParseFailure(offset: 0, reason: "选区必须包含一个完整的 XML 根元素。")
        }
        if let encoding = document.characterEncoding {
            let encodingID = CFStringConvertIANACharSetNameToEncoding(encoding as CFString)
            guard encodingID == CFStringBuiltInEncodings.UTF8.rawValue || encoding.caseInsensitiveCompare("UTF8") == .orderedSame else {
                throw XMLParseFailure(offset: 0, reason: "XML 声明必须使用 UTF-8 编码。")
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
                guard let opening = openElements.popLast() else {
                    throw XMLParseFailure(offset: start, reason: "存在没有对应开始标签的结束标签。")
                }
                tokens[opening].closingIndex = position
            default: break
            }
        }
        guard openElements.isEmpty else {
            throw XMLParseFailure(offset: input.count, reason: "XML 开始标签缺少对应的结束标签。")
        }
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
        if remainder.starts(with: "<!DOCTYPE".utf8) {
            throw XMLParseFailure(offset: index, reason: "选区包含 XML 文档类型声明，无法安全格式化。")
        }
        if remainder.starts(with: "<!".utf8) {
            throw XMLParseFailure(offset: index, reason: "XML 声明类型不受支持。")
        }

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
        throw XMLParseFailure(offset: index, reason: "XML 标记缺少结束符。")
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
        throw XMLParseFailure(offset: index, reason: "XML 注释、处理指令或 CDATA 缺少结束符。")
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
                guard child < children.endIndex else {
                    throw XMLParseFailure(offset: token.range.lowerBound, reason: "XML 子元素无法与根文档结构对应。")
                }
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
