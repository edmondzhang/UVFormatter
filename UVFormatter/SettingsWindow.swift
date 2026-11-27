import AppKit
import ApplicationServices
import ServiceManagement

@MainActor
final class SettingsWindow: NSWindowController {
    private let registration: HotKeyRegistration
    private let hotKeyButton = NSButton(title: "录入新快捷键", target: nil, action: nil)
    private let shortcutStatus = NSTextField(wrappingLabelWithString: "")
    private let permissionStatus = NSTextField(wrappingLabelWithString: "")
    private let startupStatus = NSTextField(wrappingLabelWithString: "")
    private let login = NSButton(checkboxWithTitle: "登录时启动", target: nil, action: nil)
    private let autoUpdate = NSButton(checkboxWithTitle: "自动检查更新", target: nil, action: nil)
    private let diagnosticsEnabled = NSButton(checkboxWithTitle: "保存本地解析诊断（默认开启）", target: nil, action: nil)
    private let diagnosticsStatus = NSTextField(wrappingLabelWithString: "")
    private let sample = NSTextView(frame: .zero)
    private var capture: Any?

    init(registration: HotKeyRegistration, updaterAvailable: Bool, automaticallyChecks: Bool) {
        self.registration = registration
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 680),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "UVFormatter 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()

        hotKeyButton.target = self
        hotKeyButton.action = #selector(record)
        hotKeyButton.setAccessibilityIdentifier("record-hotkey")
        login.target = self
        login.action = #selector(toggleLogin)
        login.setAccessibilityIdentifier("launch-at-login")
        autoUpdate.target = self
        autoUpdate.action = #selector(toggleUpdates)
        autoUpdate.setAccessibilityIdentifier("automatic-updates")
        autoUpdate.state = automaticallyChecks ? .on : .off
        autoUpdate.isEnabled = updaterAvailable
        diagnosticsEnabled.target = self
        diagnosticsEnabled.action = #selector(toggleDiagnostics)
        diagnosticsEnabled.setAccessibilityIdentifier("diagnostics-enabled")

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = sample
        sample.isRichText = false
        sample.isAutomaticQuoteSubstitutionEnabled = false
        sample.isAutomaticDashSubstitutionEnabled = false
        sample.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        sample.textContainerInset = NSSize(width: 6, height: 6)
        sample.isVerticallyResizable = true
        sample.autoresizingMask = [.width]
        sample.textContainer?.widthTracksTextView = true
        sample.string = #"{"sample":{"items":[1,2],"status":"ready"}}"#
        sample.setAccessibilityIdentifier("formatting-sample")
        scroll.heightAnchor.constraint(equalToConstant: 90).isActive = true

        let stack = NSStackView(views: [
            heading("全局快捷键"), shortcutStatus,
            row([hotKeyButton, button("恢复默认", #selector(resetShortcut), "reset-hotkey")]),
            heading("辅助功能权限"), permissionStatus,
            row([button("打开系统设置", #selector(openSystemSettings), "open-accessibility"),
                 button("重新检查", #selector(refreshPermissions), "refresh-accessibility")]),
            NSTextField(labelWithString: "选中示例文本后按快捷键，测试读取与替换。"),
            scroll, login, startupStatus, autoUpdate,
            button("检查更新…", #selector(checkUpdates), "check-updates"),
            heading("解析诊断日志"),
            diagnosticsEnabled,
            diagnosticsStatus,
            row([button("打开日志目录", #selector(openDiagnostics), "open-diagnostics"),
                 button("清除日志", #selector(clearDiagnostics), "clear-diagnostics")]),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let content = window.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            shortcutStatus.widthAnchor.constraint(equalTo: stack.widthAnchor),
            permissionStatus.widthAnchor.constraint(equalTo: stack.widthAnchor),
            startupStatus.widthAnchor.constraint(equalTo: stack.widthAnchor),
            diagnosticsStatus.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window.delegate = self
        refreshShortcut()
        refreshPermissions()
        refreshDiagnostics()
    }

    required init?(coder: NSCoder) { nil }

    var onCheckUpdates: (() -> Void)?
    var onToggleUpdates: ((Bool) -> Void)?

    override func showWindow(_ sender: Any?) {
        refreshShortcut()
        refreshPermissions()
        refreshDiagnostics()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    @objc func refreshPermissions() {
        let access = AXIsProcessTrusted()
        permissionStatus.stringValue = access ? "辅助功能已授权。" : "尚未授权。启用辅助功能后，可在其他 App 中读取和替换选区。"
        updateLoginStatus()
    }

    private func updateLoginStatus() {
        let status = SMAppService.mainApp.status
        login.state = status == .enabled || status == .requiresApproval ? .on : .off
        startupStatus.stringValue = status == .requiresApproval ? "请在系统设置的「登录项与扩展」中允许。" : ""
    }

    @objc private func toggleLogin() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            updateLoginStatus()
        } catch {
            updateLoginStatus()
            startupStatus.stringValue = "无法更改登录项。请确认 UVFormatter 已移到「应用程序」。"
        }
    }

    @objc private func toggleUpdates() { onToggleUpdates?(autoUpdate.state == .on) }
    @objc private func checkUpdates() { onCheckUpdates?() }

    /// Persists the user's choice for subsequent local parser events.
    @objc private func toggleDiagnostics() {
        DiagnosticsStore.shared.setEnabled(diagnosticsEnabled.state == .on)
        refreshDiagnostics()
    }

    /// Opens the local folder containing raw parser selections and diagnostic records.
    @objc private func openDiagnostics() {
        do {
            try DiagnosticsStore.shared.openDirectory()
            diagnosticsStatus.stringValue = "本机日志目录已打开。日志最多占用 100 MiB。"
        } catch {
            diagnosticsStatus.stringValue = "无法打开日志目录：\(error.localizedDescription)"
        }
    }

    /// Deletes the local diagnostics file only after the user selects Clear.
    @objc private func clearDiagnostics() {
        do {
            try DiagnosticsStore.shared.clear()
            diagnosticsStatus.stringValue = "本机解析诊断日志已清除。"
        } catch {
            diagnosticsStatus.stringValue = "无法清除日志：\(error.localizedDescription)"
        }
    }

    private func refreshDiagnostics() {
        let enabled = DiagnosticsStore.shared.isEnabled
        diagnosticsEnabled.state = enabled ? .on : .off
        let status = enabled
            ? "仅记录 JSONC / JSON5 输入和解析异常，保存在本机，最多 100 MiB。内容可能含敏感信息。"
            : "本地解析诊断已关闭。之前保存的日志仍可清理。"
        diagnosticsStatus.stringValue = DiagnosticsStore.shared.storageError.map { "\(status)\n保存失败：\($0)" } ?? status
    }

    @objc private func openSystemSettings() {
        if !AXIsProcessTrusted() {
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func heading(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 14)
        return label
    }

    private func button(_ title: String, _ action: Selector, _ id: String) -> NSButton {
        let item = NSButton(title: title, target: self, action: action)
        item.setAccessibilityIdentifier(id)
        return item
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        return row
    }

    private func refreshShortcut() {
        shortcutStatus.stringValue = registration.active.map { "当前快捷键  \($0.display)" } ?? "当前没有可用的快捷键，请重新录入。"
    }

    @objc private func resetShortcut() {
        endCapture()
        apply(.standard)
    }

    /// Captures the next key in this window and leaves the current shortcut registered during recording.
    @objc private func record() {
        guard capture == nil else { endCapture(); refreshShortcut(); return }
        shortcutStatus.stringValue = "按下要使用的组合键，或按 Esc 取消。"
        hotKeyButton.title = "取消录入"
        capture = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.keyCode == 53 {
                self.endCapture()
                self.refreshShortcut()
            } else if let key = HotKey.capture(keyCode: UInt32(event.keyCode), modifiers: event.modifierFlags) {
                self.endCapture()
                self.apply(key)
            } else {
                self.shortcutStatus.stringValue = "请选择包含 ⌘、⌃ 或 ⌥ 的可用组合键。按 Esc 取消。"
            }
            return nil
        }
    }

    private func endCapture() {
        if let capture { NSEvent.removeMonitor(capture) }
        capture = nil
        hotKeyButton.title = "录入新快捷键"
    }

    private func apply(_ key: HotKey) {
        let status = registration.register(key)
        refreshShortcut()
        guard status == noErr else {
            shortcutStatus.stringValue += "\n无法注册 \(key.display)，可能已被系统或其他 App 占用。"
            return
        }
        if let value = try? PropertyListEncoder().encode(key) {
            UserDefaults.standard.set(value, forKey: "formatShortcut")
        }
    }

    /// Uses the local text view's native editing operation so the permission exercise can be undone.
    func formatSample() -> SelectionOutcome? {
        guard window?.isKeyWindow == true else { return nil }
        if capture != nil { return .failure("请先完成或取消快捷键录入。") }
        guard window?.firstResponder === sample else { return .failure("请先在示例文本中选中文字。") }
        let range = sample.selectedRange()
        guard range.length > 0,
              let selected = Range(range, in: sample.string) else { return .failure("请先在示例文本中选中文字。") }
        do {
            let original = String(sample.string[selected])
            let result = try Formatter.format(original)
            guard result != original else { return .unchanged }
            guard AXIsProcessTrusted() else { return .failure("请先授予辅助功能权限。") }
            sample.insertText(result, replacementRange: range)
            return .replaced
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

extension SettingsWindow: NSWindowDelegate {
    func windowDidBecomeKey(_ notification: Notification) { refreshPermissions() }
    func windowWillClose(_ notification: Notification) { endCapture() }
}
