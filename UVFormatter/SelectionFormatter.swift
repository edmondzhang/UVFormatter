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
        guard let target = Target.capture(), target.isTextControl else {
            return .failure("请在可编辑区域中选中 JSON 或 XML。")
        }
        busy = true
        defer { busy = false }

        if let source = target.selectedText {
            guard !source.isEmpty else { return .failure("请先选中 JSON 或 XML。") }
            return await format(source, in: target, range: target.selectedRange)
        }
        if target.selectedRange?.length == 0 {
            return .failure("请先选中 JSON 或 XML。")
        }
        return await formatByCopying(in: target)
    }

    /// 只在控件支持当前选区属性时直接写入，否则通过控件自己的粘贴流程编辑。
    /// AX 调用超时时写入状态不明，避免重复写入。
    private func format(_ source: String, in target: Target, range: NSRange?) async -> SelectionOutcome {
        let formatted: String
        do { formatted = try Formatter.format(source) }
        catch { return .failure(error.localizedDescription) }
        guard !source.utf8.elementsEqual(formatted.utf8) else { return .unchanged }

        let canSetSelection = target.isSelectedTextSettable
        guard target.selectedText?.utf8.elementsEqual(source.utf8) == true,
              target.selectedRange == range, target.editability != false, target.isCurrent else {
            return .copyAvailable(formatted, reason: "选区、窗口或编辑权限有变化。")
        }
        if canSetSelection {
            let result = AXUIElementSetAttributeValue(
                target.element, kAXSelectedTextAttribute as CFString, formatted as CFString
            )
            if result == .success { return .replaced }
            if result == .cannotComplete {
                return .writeUnconfirmed(formatted, reason: "编辑器未及时确认替换。")
            }
        }
        return await paste(formatted, replacing: source, in: target)
    }

    /// 在选区文字未通过 AX 暴露时，以一次定向复制读取文本。触发粘贴前复核焦点与可用选区信息。
    /// 临时剪贴板内容只在仍持有写入序号时恢复。
    private func formatByCopying(in target: Target) async -> SelectionOutcome {
        let range = target.selectedRange
        let before = target.value
        let board = NSPasteboard.general
        guard CGPreflightPostEventAccess(), let snapshot = ClipboardSnapshot(board), target.isCurrent,
              let copy = KeyStroke(virtualKey: 8) else {
            return .failure("无法读取当前选区。")
        }
        let originalCount = snapshot.changeCount
        guard board.changeCount == originalCount else {
            return .failure("剪贴板在读取选区时已变化。")
        }
        copy.post(to: target.pid)
        guard let copiedCount = await waitForCopy(on: board, after: originalCount, in: target) else {
            return .failure("未取得选区文本。请确认已选中文字。")
        }
        guard let source = board.string(forType: .string), board.changeCount == copiedCount, !source.isEmpty else {
            return .failure("未取得选区文本。")
        }
        // 剪贴板没有写入者身份。只有在 AX 可独立佐证时才接管本次剪贴板内容。
        let confirmsRange = range.flatMap { range in before.map { range.matches(source, in: $0) } } ?? false
        defer {
            if confirmsRange { _ = snapshot.restoreIfOwned(board, changeCount: copiedCount) }
        }
        let formatted: String
        do { formatted = try Formatter.format(source) }
        catch { return .failure(error.localizedDescription) }
        guard !source.utf8.elementsEqual(formatted.utf8) else { return .unchanged }

        guard confirmsRange,
              target.isCurrent, target.editability != false,
              target.selectedRange == range, target.value == before else {
            return .copyAvailable(formatted, reason: "无法确认原选区仍可替换。")
        }
        return await writePaste(formatted, replacing: source, in: target, snapshot: snapshot, count: copiedCount)
    }

    private func waitForCopy(on board: NSPasteboard, after count: Int, in target: Target) async -> Int? {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(450))
        while ContinuousClock.now < deadline, !Task.isCancelled, target.isCurrent {
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
        in target: Target, snapshot: ClipboardSnapshot, count: Int
    ) async -> SelectionOutcome {
        let board = NSPasteboard.general
        let reason = "无法安全写回当前选区。"
        let range = target.selectedRange
        let before = target.value
        let confirmsRange = range.flatMap { range in before.map { range.matches(source, in: $0) } } ?? false
        guard target.editability != false, target.isCurrent, board.changeCount == count,
              target.selectedText?.utf8.elementsEqual(source.utf8) == true || confirmsRange,
              let paste = KeyStroke(virtualKey: 9), !Task.isCancelled else {
            return .copyAvailable(formatted, reason: reason)
        }

        let expected: String?
        if confirmsRange, let before, let range {
            expected = (before as NSString).replacingCharacters(in: range, with: formatted)
        } else {
            expected = nil
        }

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
              target.selectedText.map({ $0.utf8.elementsEqual(source.utf8) }) ?? confirmsRange,
              target.isCurrent, board.changeCount == ownedCount else {
            return .copyAvailable(formatted, reason: reason)
        }

        paste.post(to: target.pid)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while ContinuousClock.now < deadline, !Task.isCancelled, board.changeCount == ownedCount {
            if let expected, target.isCurrent, target.value?.utf8.elementsEqual(expected.utf8) == true { return .replaced }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if let expected, target.isCurrent, target.value?.utf8.elementsEqual(expected.utf8) == true { return .replaced }
        return .writeUnconfirmed(formatted, reason: "已尝试粘贴。请检查选中的文本是否已替换。")
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
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: false) else { return nil }
        down.flags = .maskCommand
        up.flags = .maskCommand
        self.down = down
        self.up = up
    }

    // 将按键发给已核对的进程，避免全局投递时切窗影响其他 App。
    func post(to pid: pid_t) {
        down.postToPid(pid)
        up.postToPid(pid)
    }
}

@MainActor
private struct Target {
    let pid: pid_t
    let bundleID: String?
    let window: AXUIElement
    let element: AXUIElement

    static func capture() -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.2)
        guard let window = child(appElement, kAXFocusedWindowAttribute),
              let element = child(appElement, kAXFocusedUIElementAttribute) else { return nil }
        return Target(pid: app.processIdentifier, bundleID: app.bundleIdentifier, window: window, element: element)
    }

    var isCurrent: Bool {
        guard let current = Self.capture() else { return false }
        return current.pid == pid && CFEqual(current.window, window) && CFEqual(current.element, element)
    }

    var isTextControl: Bool {
        let role = Self.attribute(element, kAXRoleAttribute) as? String
        let subrole = Self.attribute(element, kAXSubroleAttribute) as? String
        guard subrole != kAXSecureTextFieldSubrole else { return false }
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role ?? "")
            || editability == true || (isKnownEditor && role == "AXWebArea")
    }

    var isKnownEditor: Bool {
        ["com.alibaba.DingTalkMac", "com.tencent.xinWeChat", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
            .contains(bundleID ?? "")
    }

    var editability: Bool? { Self.attribute(element, "AXEditable") as? Bool }
    var selectedText: String? {
        if let selection = Self.attribute(element, kAXSelectedTextAttribute) as? String {
            return selection
        }
        // 部分编辑器通过按范围取文本接口暴露选区。
        guard let range = selectedRange, range.length > 0 else { return nil }
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
        var writable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &writable) == .success
            && writable.boolValue
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private static func child(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        guard let raw = attribute(element, key), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }
}

private extension NSRange {
    // AX 文本范围使用 UTF-16，用 NSString 按相同单位检查边界和原选区。
    func matches(_ selection: String, in text: String) -> Bool {
        let text = text as NSString
        guard location >= 0, length > 0, location <= text.length, length <= text.length - location else {
            return false
        }
        return text.substring(with: self).utf8.elementsEqual(selection.utf8)
    }
}
