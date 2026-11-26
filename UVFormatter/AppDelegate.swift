import AppKit
import Sparkle

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    private let registration = HotKeyRegistration()
    private let formatter = SelectionFormatter()
    private var updater: SPUStandardUpdaterController?
    private var settings: SettingsWindow?
    private var item: NSStatusItem?
    private var feedback: NSPanel?
    private var result: String?
    private var formatting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let updateKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        if let updateKey, Data(base64Encoded: updateKey)?.count == 32 {
            updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }

        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "{ }"
        status.button?.toolTip = "UVFormatter"
        status.button?.setAccessibilityLabel("UVFormatter")
        let menu = NSMenu()
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "检查更新…", action: #selector(checkUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 UVFormatter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu
        item = status

        registration.onPress = { [weak self] in self?.format() }
        let saved = UserDefaults.standard.data(forKey: "formatShortcut")
            .flatMap { try? PropertyListDecoder().decode(HotKey.self, from: $0) } ?? .standard
        if registration.register(saved) != noErr {
            showFeedback("无法注册 \(saved.display)，请在设置中更换快捷键。", result: nil)
        }
        if !UserDefaults.standard.bool(forKey: "didOpenSettings") {
            UserDefaults.standard.set(true, forKey: "didOpenSettings")
            showSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { registration.stop() }

    @objc private func showSettings() {
        if settings == nil {
            let page = SettingsWindow(registration: registration, updaterAvailable: updater != nil,
                                      automaticallyChecks: updater?.updater.automaticallyChecksForUpdates ?? false)
            page.onCheckUpdates = { [weak self] in self?.checkUpdates() }
            page.onToggleUpdates = { [weak self] enabled in
                self?.updater?.updater.automaticallyChecksForUpdates = enabled
            }
            settings = page
        }
        NSApp.activate()
        settings?.showWindow(nil)
    }

    @objc private func checkUpdates() {
        guard let updater else {
            showFeedback("这个构建没有配置签名更新。", result: nil)
            return
        }
        NSApp.activate()
        updater.checkForUpdates(nil)
    }

    /// Runs one replacement at a time. A previous manual-copy result expires on a new invocation.
    private func format() {
        guard !formatting else { return }
        feedback?.close()
        feedback = nil
        result = nil
        if let local = settings?.formatSample() {
            display(local)
            return
        }
        formatting = true
        Task {
            let outcome = await formatter.formatSelection()
            formatting = false
            display(outcome)
        }
    }

    private func display(_ outcome: SelectionOutcome) {
        switch outcome {
        case .replaced:
            // Keep editing focus and let the visible document confirm success.
            break
        case .unchanged:
            showFeedback("选区已符合格式。", result: nil)
        case let .failure(reason):
            showFeedback(reason, result: nil)
        case let .copyAvailable(value, reason), let .writeUnconfirmed(value, reason):
            showFeedback(reason, result: value)
        }
    }

    /// Presents a short message without moving focus away from the editor.
    private func showFeedback(_ message: String, result: String?) {
        feedback?.close()
        self.result = result
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 356, height: result == nil ? 72 : 106),
                            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .windowBackgroundColor
        panel.collectionBehavior = [.transient, .canJoinAllSpaces, .fullScreenAuxiliary]

        let text = NSTextField(wrappingLabelWithString: message)
        text.setAccessibilityLabel(message)
        let row = NSStackView()
        if result != nil {
            let copy = NSButton(title: "复制结果", target: self, action: #selector(copyResult))
            copy.setAccessibilityIdentifier("copy-formatting-result")
            row.addArrangedSubview(copy)
            let dismiss = NSButton(title: "关闭", target: self, action: #selector(dismissResult))
            dismiss.setAccessibilityIdentifier("dismiss-formatting-result")
            row.addArrangedSubview(dismiss)
        }
        let stack = NSStackView(views: result == nil ? [text] : [text, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let content = panel.contentView {
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 13),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                text.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
        }
        if let frame = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 18, y: frame.maxY - 16))
        }
        panel.orderFrontRegardless()
        feedback = panel
        if result == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak panel] in
                guard let panel, self?.feedback === panel else { return }
                self?.dismissResult()
            }
        }
    }

    /// Writes the result to the general clipboard only when the user clicks Copy.
    @objc private func copyResult() {
        guard let result else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(result, forType: .string) {
            showFeedback("已复制格式化结果。", result: nil)
        } else {
            showFeedback("无法写入剪贴板，请重试。", result: result)
        }
    }

    @objc private func dismissResult() {
        feedback?.close()
        feedback = nil
        result = nil
    }
}
