import AppKit
import ApplicationServices

enum SelectionOutcome {
    case replaced
    case unchanged
    case failure(String)
    case copyAvailable(String, reason: String)
    case writeUnconfirmed(String, reason: String)
}

@MainActor
final class SelectionFormatter {
    private var busy = false

    /// 格式化快捷键触发时的前台选区。每次只处理一个选区，失败通过结果返回。
    /// 必须在主线程调用。该操作可能修改前台应用和临时使用系统剪贴板，不可并行或自动重试。
    func formatSelection() async -> SelectionOutcome {
        guard !busy else { return .failure("正在处理选区。") }
        guard AXIsProcessTrusted() else { return .failure("请先在 UVFormatter 设置中开启辅助功能权限。") }
        guard let target = Target.capture(), target.isCurrent else {
            return .failure("未找到当前应用中的选区。")
        }
        guard !target.isSecureTextField else { return .failure("安全输入框中的内容无法格式化。") }
        busy = true
        defer { busy = false }

        if let source = target.selectedText, !source.isEmpty {
            return await format(source, in: target, range: target.selectedRange)
        }
        // 外层控件的空选区可能与内嵌编辑器或消息正文的实际选区不同。
        // 让宿主应用自己的复制命令尝试读取当前选区。
        return await formatByCopying(in: target)
    }

    /// 只在控件支持当前选区属性时直接写入，否则通过控件自己的粘贴流程编辑。
    /// AX 调用超时时写入状态不明，避免重复写入。
    private func format(_ source: String, in target: Target, range: NSRange?) async -> SelectionOutcome {
        let formatted: String
        do { formatted = try parse(source, for: target).text }
        catch { return .failure(error.localizedDescription) }
        guard !source.utf8.elementsEqual(formatted.utf8) else { return .unchanged }

        guard target.canReplaceSelection else {
            return .copyAvailable(formatted, reason: "当前选区可读取，无法确认可编辑。")
        }
        let before = target.value
        let expected = range?.replacingSelection(source, with: formatted, in: before)
        guard target.selectedText?.utf8.elementsEqual(source.utf8) == true,
              target.selectedRange == range, target.isCurrent else {
            return .copyAvailable(formatted, reason: "选区、窗口或编辑权限有变化。")
        }
        if let element = target.element, target.isSelectedTextSettable {
            let result = AXUIElementSetAttributeValue(
                element, kAXSelectedTextAttribute as CFString, formatted as CFString
            )
            if result == .success {
                if let outcome = await confirmAXReplacement(
                    expected: expected, before: before, source: source, formatted: formatted, in: target
                ) {
                    return outcome
                }
            } else if result == .cannotComplete {
                guard target.isUnchanged(value: before, selectedText: source) else {
                    return .writeUnconfirmed(formatted, reason: "编辑器未及时确认替换。")
                }
            }
        }
        return await paste(formatted, replacing: source, in: target)
    }

    /// 核实直接写入 AX 属性是否生效；若编辑器接受了请求但全文与选区均未变化，返回 nil 以回退到粘贴。
    private func confirmAXReplacement(
        expected: String?, before: String?, source: String, formatted: String, in target: Target
    ) async -> SelectionOutcome? {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
        while true {
            if let expected, target.isCurrent, target.value?.utf8.elementsEqual(expected.utf8) == true {
                return .replaced
            }
            if !target.isUnchanged(value: before, selectedText: source) {
                return .writeUnconfirmed(formatted, reason: "编辑器接受了替换请求，但无法核实结果。请检查原选区。")
            }
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return nil }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 在选区文字未通过 AX 暴露时，以一次定向复制读取文本。触发粘贴前复核焦点与可用选区信息。
    /// 临时剪贴板内容只在仍持有写入序号时恢复。
    private func formatByCopying(in target: Target) async -> SelectionOutcome {
        let range = target.selectedRange
        let before = target.value
        let board = NSPasteboard.general
        guard CGPreflightPostEventAccess(), let copy = KeyStroke(virtualKey: 8) else {
            return .failure("无法读取当前选区。")
        }
        await waitForNonCommandModifiersRelease(in: target)
        guard let snapshot = ClipboardSnapshot(board), target.isCurrent,
              target.selectedRange == range, target.value == before else {
            return .failure("无法读取当前选区。")
        }
        let originalCount = snapshot.changeCount
        guard board.changeCount == originalCount else {
            return .failure("剪贴板在读取选区时已变化。")
        }
        copy.post()
        guard let copiedCount = await waitForCopy(on: board, after: originalCount, in: target) else {
            return .failure("未取得选区文本。请确认已选中文字。")
        }
        guard target.isCurrent, !target.isSecureTextField,
              let source = snapshot.copiedText(from: board, changeCount: copiedCount) else {
            return .failure("未取得选区文本。")
        }
        // 剪贴板序号无法证明写入者身份。只有 AX 独立佐证时才记录原文或直接恢复复制前内容。
        let confirmsRange = range.flatMap { range in before.map { range.matches(source, in: $0) } } ?? false
        let confirmsSelection = confirmsRange || target.selectedText?.utf8.elementsEqual(source.utf8) == true
        defer {
            if confirmsSelection { _ = snapshot.restoreIfOwned(board, changeCount: copiedCount) }
        }
        let formatted: String
        do {
            formatted = try confirmsSelection ? parse(source, for: target).text : Formatter.format(source)
        } catch {
            return .failure(error.localizedDescription)
        }
        guard !source.utf8.elementsEqual(formatted.utf8) else { return .unchanged }

        guard target.isCurrent, target.selectedRange == range, target.value == before else {
            return .copyAvailable(formatted, reason: "复制后焦点或选区发生变化。")
        }
        return await writePaste(formatted, replacing: source, in: target, snapshot: snapshot,
                                count: copiedCount, fromCopy: true, initialRangeMatches: confirmsRange)
    }

    /// Records parser failures and accepted JSONC/JSON5 selections to help improve dialect handling.
    /// The store is local-only, defaults to enabled, and never persists strict JSON or XML success cases.
    private func parse(_ source: String, for target: Target) throws -> FormattedSelection {
        do {
            let formatted = try Formatter.formatDetailed(source)
            DiagnosticsStore.shared.record(source: source, targetBundleID: target.bundleID, formatted: formatted)
            return formatted
        } catch {
            DiagnosticsStore.shared.record(source: source, targetBundleID: target.bundleID, error: error)
            throw error
        }
    }

    /// 避免默认快捷键 ⌘⌥⇧F 的 ⌥/⇧ 尚未松开时，合成的 ⌘C / ⌘V 被目标应用识别成带额外修饰键的快捷键。
    private func waitForNonCommandModifiersRelease(in target: Target) async {
        let extra: CGEventFlags = [.maskAlternate, .maskShift, .maskControl]
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        while ContinuousClock.now < deadline, !Task.isCancelled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid {
            if CGEventSource.flagsState(.hidSystemState).intersection(extra).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    private func waitForCopy(on board: NSPasteboard, after count: Int, in target: Target) async -> Int? {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(450))
        while ContinuousClock.now < deadline, !Task.isCancelled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid {
            let changed = board.changeCount
            if changed != count { return changed }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func paste(_ formatted: String, replacing source: String, in target: Target) async -> SelectionOutcome {
        let board = NSPasteboard.general
        guard CGPreflightPostEventAccess(), let snapshot = ClipboardSnapshot(board),
              target.selectedText?.utf8.elementsEqual(source.utf8) == true else {
            return .copyAvailable(formatted, reason: "此编辑器无法直接替换选区。")
        }
        return await writePaste(formatted, replacing: source, in: target, snapshot: snapshot, count: snapshot.changeCount)
    }

    /// 发送一次粘贴按键。能够从控件回读时用完整文本核对结果，否则报告写入待确认。
    /// 保留新的外部剪贴板内容。恢复前留出目标应用读取剪贴板的时间。
    private func writePaste(
        _ formatted: String, replacing source: String,
        in target: Target, snapshot: ClipboardSnapshot, count: Int,
        fromCopy: Bool = false, initialRangeMatches: Bool = false
    ) async -> SelectionOutcome {
        let board = NSPasteboard.general
        let reason = "无法安全写回当前选区。"
        let range = target.selectedRange
        let before = target.value
        func selectionStillMatches() -> Bool {
            Self.selectionStillMatches(
                currentSelection: target.selectedText,
                range: range,
                currentValue: before,
                source: source,
                fromCopy: fromCopy,
                initialRangeMatches: initialRangeMatches
            )
        }
        guard (fromCopy ? target.canPasteAfterCopy : target.canReplaceSelection),
              target.isCurrent, selectionStillMatches(),
              !fromCopy || snapshot.copiedText(from: board, changeCount: count)?.utf8.elementsEqual(source.utf8) == true,
              board.changeCount == count,
              let paste = KeyStroke(virtualKey: 9), !Task.isCancelled else {
            return .copyAvailable(formatted, reason: reason)
        }

        await waitForNonCommandModifiersRelease(in: target)
        guard target.isCurrent, target.selectedRange == range, target.value == before,
              selectionStillMatches(), board.changeCount == count, !Task.isCancelled else {
            return .copyAvailable(formatted, reason: reason)
        }

        let expected = range?.replacingSelection(source, with: formatted, in: before)

        let temporary = NSPasteboardItem()
        guard temporary.setString(formatted, forType: .string) else {
            return .copyAvailable(formatted, reason: reason)
        }
        // 剪贴板管理器支持该约定时可略过临时粘贴内容。
        _ = temporary.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        guard board.changeCount == count else { return .copyAvailable(formatted, reason: reason) }
        let clearedCount = board.clearContents()
        guard board.writeObjects([temporary]) else {
            _ = snapshot.restoreIfOwned(board, changeCount: clearedCount)
            return .copyAvailable(formatted, reason: reason)
        }
        let ownedCount = board.changeCount
        defer { _ = snapshot.restoreIfOwned(board, changeCount: ownedCount) }
        guard target.selectedRange == range, target.value == before,
              selectionStillMatches(), (fromCopy ? target.canPasteAfterCopy : target.canReplaceSelection),
              target.isCurrent, board.changeCount == ownedCount, !Task.isCancelled else {
            return .copyAvailable(formatted, reason: reason)
        }

        paste.post()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while ContinuousClock.now < deadline, !Task.isCancelled, board.changeCount == ownedCount {
            if let expected, target.isCurrent, target.value?.utf8.elementsEqual(expected.utf8) == true { return .replaced }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if let expected, target.isCurrent, target.value?.utf8.elementsEqual(expected.utf8) == true { return .replaced }
        return .writeUnconfirmed(formatted, reason: "已尝试粘贴。请检查选中的文本是否已替换。")
    }

    static func selectionStillMatches(
        currentSelection: String?,
        range: NSRange?,
        currentValue: String?,
        source: String,
        fromCopy: Bool,
        initialRangeMatches: Bool
    ) -> Bool {
        if let currentSelection { return currentSelection.utf8.elementsEqual(source.utf8) }
        if fromCopy && !initialRangeMatches { return true }
        if let range, range.length > 0, let currentValue { return range.matches(source, in: currentValue) }
        return fromCopy
    }
}

@MainActor
struct ClipboardSnapshot {
    private let items: [NSPasteboardItem]
    let changeCount: Int

    /// 备份剪贴板对象的所有当前可读类型。读取失败或有并发写入时放弃。
    /// 在主线程调用。结果只保存在内存，不保证恢复原来的延迟数据提供者。
    init?(_ board: NSPasteboard) {
        let before = board.changeCount
        var items: [NSPasteboardItem] = []
        for item in board.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type), copy.setData(data, forType: type) else { return nil }
            }
            items.append(copy)
        }
        guard before == board.changeCount else { return nil }
        self.items = items
        self.changeCount = before
    }

    /// 在主线程读取本次复制后观测到的非空文本。序号只用于判断内容变化，不能标识写入者。
    func copiedText(from board: NSPasteboard, changeCount observedCount: Int) -> String? {
        guard observedCount != changeCount, board.changeCount == observedCount,
              let text = board.string(forType: .string), !text.isEmpty,
              board.changeCount == observedCount else { return nil }
        return text
    }

    /// 若系统剪贴板仍对应当前操作最后一次观察到的序号，恢复全部表示。
    /// 在主线程调用。失败返回 false。系统剪贴板的比较和写入无法原子执行。
    @discardableResult
    func restoreIfOwned(_ board: NSPasteboard, changeCount: Int) -> Bool {
        guard board.changeCount == changeCount else { return false }
        board.clearContents()
        return items.isEmpty || board.writeObjects(items)
    }
}

private struct KeyStroke {
    let down: CGEvent
    let up: CGEvent

    init?(virtualKey: CGKeyCode) {
        // 使用独立事件源，避免复用会话中尚未松开的 ⌥/⇧ 修饰键状态。
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else { return nil }
        down.flags = .maskCommand
        up.flags = .maskCommand
        self.down = down
        self.up = up
    }

    // 通过会话事件流投递给已复核的前台焦点，兼容 Electron / Chromium WebView 等多进程容器。
    func post() {
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}

struct ElementAccessibilitySnapshot: Equatable {
    let role: String?
    let subrole: String?
    let editable: Bool?
    let isSelectedTextSettable: Bool
    let isValueSettable: Bool

    var isSecureTextField: Bool { subrole == kAXSecureTextFieldSubrole }
    var isTextInputRole: Bool { [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role ?? "") }
    var isWebArea: Bool { role == "AXWebArea" }
    var isReadOnlyLeafRole: Bool { role == kAXStaticTextRole || role == "AXLink" }
}

enum EditabilityEvaluator {
    /// 判断焦点控件（含富文本/WebView 内嵌节点及直接外层容器）是否可接受自动写回或粘贴。
    static func canEdit(hasWindow: Bool, chain: [ElementAccessibilitySnapshot], afterCopy: Bool) -> Bool {
        guard hasWindow else { return false }
        guard let focused = chain.first else { return afterCopy }
        guard !focused.isSecureTextField else { return false }

        if focused.isSelectedTextSettable || focused.isValueSettable || focused.editable == true { return true }
        if focused.isTextInputRole { return focused.editable != false }
        // Chromium / Electron / WebKit 对话框经常只暴露外层 AXWebArea 且标记 AXEditable = false 或缺失，
        // 无法从 AX 区分只读网页与富文本输入区时交给宿主决定是否接受粘贴。
        if focused.isWebArea { return true }

        let hasEditableAncestor = chain.dropFirst().contains { ancestor in
            !ancestor.isSecureTextField && (
                ancestor.isSelectedTextSettable || ancestor.isValueSettable
                    || ancestor.editable == true
                    || (ancestor.isTextInputRole && ancestor.editable != false)
            )
        }
        if hasEditableAncestor { return true }

        if focused.editable == false || focused.isReadOnlyLeafRole { return false }
        return afterCopy
    }
}

@MainActor
private struct Target {
    let pid: pid_t
    let bundleID: String?
    let window: AXUIElement?
    let element: AXUIElement?

    static func capture() -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        let window = child(appElement, kAXFocusedWindowAttribute)
        let element = child(appElement, kAXFocusedUIElementAttribute)
        return Target(pid: app.processIdentifier, bundleID: app.bundleIdentifier, window: window, element: element)
    }

    var isCurrent: Bool {
        guard let current = Self.capture() else { return false }
        return current.pid == pid && Self.sameElement(current.window, window)
            && Self.sameElement(current.element, element)
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private static func sameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return CFEqual(lhs, rhs)
    }

    var isSecureTextField: Bool {
        Self.attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole
    }

    func isUnchanged(value before: String?, selectedText source: String) -> Bool {
        guard isCurrent else { return false }
        let valueUnchanged: Bool
        switch (before, value) {
        case (nil, nil): valueUnchanged = true
        case let (lhs?, rhs?): valueUnchanged = lhs.utf8.elementsEqual(rhs.utf8)
        default: valueUnchanged = false
        }
        return valueUnchanged && selectedText?.utf8.elementsEqual(source.utf8) == true
    }

    // 缺少内部控件信息的窗口依靠宿主执行粘贴，明确只读的控件只提供复制结果。
    var canPasteAfterCopy: Bool {
        EditabilityEvaluator.canEdit(hasWindow: window != nil, chain: accessibilityChain, afterCopy: true)
    }

    // 控件角色和兼容规则只用于判断自动写回，不依赖具体宿主应用白名单。
    var canReplaceSelection: Bool {
        EditabilityEvaluator.canEdit(hasWindow: window != nil, chain: accessibilityChain, afterCopy: false)
    }

    private var accessibilityChain: [ElementAccessibilitySnapshot] {
        var chain: [ElementAccessibilitySnapshot] = []
        var current = element
        for _ in 0..<5 {
            guard let node = current else { break }
            let snapshot = ElementAccessibilitySnapshot(
                role: Self.attribute(node, kAXRoleAttribute) as? String,
                subrole: Self.attribute(node, kAXSubroleAttribute) as? String,
                editable: Self.attribute(node, "AXEditable") as? Bool,
                isSelectedTextSettable: Self.isSettable(kAXSelectedTextAttribute, on: node),
                isValueSettable: Self.isSettable(kAXValueAttribute, on: node)
            )
            if !chain.isEmpty && (snapshot.role == kAXWindowRole || snapshot.role == kAXApplicationRole) {
                break
            }
            chain.append(snapshot)
            if snapshot.role == "AXWebArea" { break }
            current = Self.child(node, kAXParentAttribute)
        }
        return chain
    }

    var selectedText: String? {
        if let selection = Self.attribute(element, kAXSelectedTextAttribute) as? String, !selection.isEmpty {
            return selection
        }
        // 部分编辑器通过按范围取文本接口暴露选区。
        guard let element, let range = selectedRange, range.length > 0 else { return nil }
        var coordinates = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &coordinates) else { return nil }
        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value
        )
        return status == .success ? value as? String : nil
    }
    var value: String? { Self.attribute(element, kAXValueAttribute) as? String }
    var selectedRange: NSRange? {
        guard let raw = Self.attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }
    var isSelectedTextSettable: Bool {
        guard let element else { return false }
        return Self.isSettable(kAXSelectedTextAttribute, on: element)
    }

    private static func isSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var writable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &writable) == .success
            && writable.boolValue
    }

    private static func attribute(_ element: AXUIElement?, _ key: String) -> CFTypeRef? {
        guard let element else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private static func child(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        guard let raw = attribute(element, key), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }
}

extension NSRange {
    // 仅当原选区与提供的 UTF-16 范围一致时生成预期全文，供写入后回读比较。
    func replacingSelection(_ source: String, with replacement: String, in original: String?) -> String? {
        guard let original, matches(source, in: original) else { return nil }
        return (original as NSString).replacingCharacters(in: self, with: replacement)
    }

    // AX 文本范围使用 UTF-16，用 NSString 按相同单位检查边界和原选区。
    func matches(_ selection: String, in text: String) -> Bool {
        let text = text as NSString
        guard location >= 0, length > 0, location <= text.length, length <= text.length - location else {
            return false
        }
        return text.substring(with: self).utf8.elementsEqual(selection.utf8)
    }
}
