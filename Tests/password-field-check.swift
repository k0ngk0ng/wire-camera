import AppKit

final class PasswordFieldCheck: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let password = WiFiPasswordField(frame: NSRect(x: 24, y: 95, width: 432, height: 26))
    private let other = NSTextField(frame: NSRect(x: 24, y: 54, width: 432, height: 26))
    private let state = NSTextField(labelWithString: "准备验证密码输入框")
    private var checks: [[String: Any]] = []
    private var heartbeat = 0
    private var cycles = 0
    private let output: URL
    private let automated: Bool
    private let sample = "WireCamera-'--test-123"

    init(output: URL, automated: Bool) {
        self.output = output
        self.automated = automated
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "WireCamera Password Check"
        window.delegate = self
        window.center()
        panel.title = "Wi-Fi 密码输入验证"
        panel.delegate = self
        password.placeholderString = "Wi-Fi 密码"
        password.setAccessibilityLabel("测试 Wi-Fi 密码")
        password.delegate = self
        other.stringValue = "WireCameraLab"
        other.setAccessibilityLabel("测试 Wi-Fi 名称")
        let verify = NSButton(title: "验证并关闭面板", target: self, action: #selector(verifyAndClose))
        verify.frame = NSRect(x: 300, y: 12, width: 156, height: 30)
        let open = NSButton(title: "打开密码面板", target: self, action: #selector(openPanel))
        open.frame = NSRect(x: 24, y: 175, width: 160, height: 32)
        let finish = NSButton(title: "保存报告并退出", target: self, action: #selector(finishCheck))
        finish.frame = NSRect(x: 24, y: 125, width: 160, height: 32)
        state.frame = NSRect(x: 24, y: 230, width: 512, height: 28)
        for view in [password, other, verify] { panel.contentView?.addSubview(view) }
        for view in [state, open, finish] { window.contentView?.addSubview(view) }
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        NSApp.mainMenu = menu
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in self.heartbeat += 1 }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        openPanel()
        if automated { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.automatedCycle() } }
    }

    @objc private func openPanel() {
        password.stringValue = ""
        window.beginSheet(panel)
        panel.makeFirstResponder(other)
        state.stringValue = "密码面板已打开"
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === password, let editor = password.currentEditor() as? NSTextView else { return }
        checks.append(["name": "editor_purpose_empty_\(cycles)", "passed": editor.contentType?.rawValue == ""])
        checks.append(["name": "editor_completion_disabled_\(cycles)", "passed": !editor.isAutomaticTextCompletionEnabled])
        checks.append(["name": "editor_replacement_disabled_\(cycles)", "passed": !editor.isAutomaticTextReplacementEnabled && !editor.isAutomaticQuoteSubstitutionEnabled && !editor.isAutomaticDashSubstitutionEnabled])
    }

    @objc private func verifyAndClose() {
        panel.makeFirstResponder(other)
        checks.append(["name": "password_roundtrip_\(cycles)", "passed": password.stringValue == sample])
        checks.append(["name": "field_purpose_empty_\(cycles)", "passed": password.contentType?.rawValue == ""])
        checks.append(["name": "field_completion_disabled_\(cycles)", "passed": !password.isAutomaticTextCompletionEnabled])
        checks.append(["name": "secure_field_\(cycles)", "passed": password.isKind(of: NSSecureTextField.self) && (password.cell as? NSSecureTextFieldCell)?.echosBullets == true])
        checks.append(["name": "main_loop_responsive_\(cycles)", "passed": heartbeat > 0])
        window.endSheet(panel)
        panel.orderOut(nil)
        cycles += 1
        state.stringValue = "完成第 \(cycles) 次输入验证"
        checks.append(["name": "sheet_closed_\(cycles)", "passed": window.attachedSheet == nil && !panel.isVisible])
        password.stringValue = ""
    }

    private func automatedCycle() {
        panel.makeFirstResponder(password)
        guard let editor = password.currentEditor() as? NSTextView else { finishCheck(); return }
        editor.insertText(sample, replacementRange: NSRange(location: NSNotFound, length: 0))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.capture("focused-\(self.cycles).png")
            self.verifyAndClose()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if self.cycles < 2 { self.openPanel(); self.automatedCycle() }
                else { self.finishCheck() }
            }
        }
    }

    private func capture(_ name: String) {
        guard let root = panel.contentView, let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name))
    }

    @objc private func finishCheck() {
        let passed = cycles >= 2 && checks.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "cycles": cycles, "heartbeat": heartbeat, "checks": checks, "automated": automated, "timestamp": ISO8601DateFormatter().string(from: Date())]
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("report.json"), options: .atomic)
        } catch { NSLog("Password check report failed: %@", error.localizedDescription) }
        NSApp.terminate(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === panel { window.endSheet(panel); panel.orderOut(nil); return false }
        finishCheck()
        return true
    }
}

@main
struct PasswordFieldCheckMain {
    static func main() {
        let app = NSApplication.shared
        let output = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("manual")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let delegate = PasswordFieldCheck(output: output, automated: CommandLine.arguments.contains("--automated"))
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
