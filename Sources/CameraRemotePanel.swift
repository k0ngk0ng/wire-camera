import AppKit
import CoreImage
import Darwin
import SystemConfiguration

enum CameraSettingsSection: String {
    case recording
    case connection
}

final class CameraRemotePanel: NSObject, NSToolbarDelegate, NSTextFieldDelegate {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let toolbar = NSToolbar(identifier: "WireCamera.Settings")
    private let connectionPage = NSView()
    private let recordingPage = NSView()
    private let status = NSTextField(labelWithString: "")
    private let service = NSSwitch()
    private let address = NSPopUpButton(frame: .zero, pullsDown: false)
    private let port = NSTextField(string: "")
    private let password = NSSecureTextField(string: "")
    private let revealedPassword = NSTextField(string: "")
    private let eye = NSButton()
    private let connectionError = NSTextField(wrappingLabelWithString: "")
    private let saveConnection = NSButton(title: "保存更改", target: nil, action: nil)
    private let qr = NSImageView()
    private let qrCard = NSView()
    private let qrPlaceholder = NSTextField(labelWithString: "开启后显示二维码")
    private let qrCaption = NSTextField(labelWithString: "用 WireCamera 扫码连接")
    private let location = NSTextField(labelWithString: "")
    private let used = NSTextField(labelWithString: "正在计算…")
    private let daily = NSTextField(labelWithString: "正在计算…")
    private let retention = NSPopUpButton(frame: .zero, pullsDown: false)
    private let customDays = NSTextField(string: "7")
    private let customRow = NSStackView()
    private let retentionHelp = NSTextField(wrappingLabelWithString: "")
    private let retentionEstimate = NSTextField(labelWithString: "")
    private let cleanupStatus = NSTextField(wrappingLabelWithString: "")
    private let saveRetention = NSButton(title: "保存更改", target: nil, action: nil)
    private let cleanupNow = NSButton(title: "立即清理", target: nil, action: nil)
    private var cleaning = false
    private var settings = CameraRemoteSettings()
    private var summary: CameraStorageSummary?
    private(set) var section: CameraSettingsSection = .connection
    var onChange: ((CameraRemoteSettings) -> Void)?
    var onRetention: ((Int) -> Void)?
    var onCleanupNow: (() -> Void)?

    override init() {
        super.init()
        window.title = "WireCamera 设置"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        for page in [connectionPage, recordingPage] {
            page.translatesAutoresizingMaskIntoConstraints = false
            window.contentView!.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
                page.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
                page.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
                page.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24)
            ])
        }
        buildConnection()
        buildRecording()
    }

    func show(settings: CameraRemoteSettings, status: String, section: CameraSettingsSection = .connection) {
        update(settings: settings, status: status)
        select(section)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(settings: CameraRemoteSettings, status: String) {
        self.settings = settings
        port.stringValue = String(settings.port)
        password.stringValue = settings.password
        revealedPassword.stringValue = settings.password
        service.state = settings.enabled ? .on : .off
        self.status.stringValue = settings.enabled ? status : "已关闭"
        self.status.textColor = settings.enabled && status.hasPrefix("已开启") ? .systemGreen : .secondaryLabelColor
        let selected = address.titleOfSelectedItem
        address.removeAllItems()
        Self.addresses().forEach { address.addItem(withTitle: $0) }
        if let selected, address.itemTitles.contains(selected) { address.selectItem(withTitle: selected) }
        if address.numberOfItems == 0 { address.addItem(withTitle: "暂无局域网地址") }
        let days = settings.retentionDays
        if retention.itemArray.contains(where: { $0.tag == days }) { retention.selectItem(withTag: days) }
        else { retention.selectItem(withTag: -1); customDays.stringValue = String(days) }
        validateConnection()
        changeRetention()
        renderQR()
    }

    func updateStorage(_ value: CameraStorageSummary, cleaning: Bool, error: String?) {
        summary = value
        self.cleaning = cleaning
        location.stringValue = value.directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        location.toolTip = value.directory.path
        used.stringValue = Self.bytes(Double(value.usedBytes))
        daily.stringValue = value.dailyBytes.map { "约 " + Self.bytes($0) + " / 天" } ?? "录制一分钟后估算"
        cleanupStatus.stringValue = cleaning ? "正在清理到期录像…" : (error ?? "")
        cleanupStatus.isHidden = cleanupStatus.stringValue.isEmpty
        cleanupStatus.textColor = error == nil ? .secondaryLabelColor : .systemOrange
        changeRetention()
    }

    func showError(_ message: String) {
        let label = section == .connection ? connectionError : cleanupStatus
        label.stringValue = message
        label.textColor = .systemOrange
        label.isHidden = false
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init(CameraSettingsSection.recording.rawValue), .init(CameraSettingsSection.connection.rawValue)] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let recording = identifier.rawValue == CameraSettingsSection.recording.rawValue
        item.label = recording ? "录像" : "iPhone 连接"
        item.image = NSImage(systemSymbolName: recording ? "externaldrive" : "iphone", accessibilityDescription: item.label)
        item.target = self; item.action = #selector(selectToolbar)
        return item
    }

    @objc private func selectToolbar(_ sender: NSToolbarItem) { if let section = CameraSettingsSection(rawValue: sender.itemIdentifier.rawValue) { select(section) } }

    private func select(_ value: CameraSettingsSection) {
        section = value
        toolbar.selectedItemIdentifier = .init(value.rawValue)
        connectionPage.isHidden = value != .connection
        recordingPage.isHidden = value != .recording
        window.defaultButtonCell = (value == .connection ? saveConnection : saveRetention).cell as? NSButtonCell
    }

    private func buildConnection() {
        service.target = self; service.action = #selector(toggleService)
        service.setAccessibilityLabel("允许 iPhone 连接"); service.setAccessibilityIdentifier("settings-service")
        let header = horizontal([heading("iPhone 连接"), NSView(), service])
        let stack = vertical([header, status], spacing: 6)
        status.font = .systemFont(ofSize: 12)
        address.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        address.target = self; address.action = #selector(renderQR)
        address.setAccessibilityLabel("Mac 地址"); address.setAccessibilityIdentifier("settings-address")
        port.placeholderString = "48760"; port.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        port.setAccessibilityIdentifier("settings-port"); port.setAccessibilityLabel("端口"); port.delegate = self
        port.widthAnchor.constraint(equalToConstant: 100).isActive = true
        for field in [password, revealedPassword] {
            field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            field.setAccessibilityLabel("连接密码"); field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
        }
        password.setAccessibilityIdentifier("settings-password")
        revealedPassword.isHidden = true
        let passwordContainer = NSView()
        for field in [password, revealedPassword] {
            passwordContainer.addSubview(field)
            NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: passwordContainer.leadingAnchor), field.trailingAnchor.constraint(equalTo: passwordContainer.trailingAnchor), field.topAnchor.constraint(equalTo: passwordContainer.topAnchor), field.bottomAnchor.constraint(equalTo: passwordContainer.bottomAnchor)])
        }
        passwordContainer.heightAnchor.constraint(equalToConstant: 24).isActive = true
        configureIcon(eye, symbol: "eye", label: "显示密码", action: #selector(revealPassword))
        eye.setAccessibilityIdentifier("settings-reveal")
        let details = vertical([
            field("Mac 地址", control: horizontal([address, icon("doc.on.doc", label: "复制地址", action: #selector(copyAddress))])),
            field("端口", control: horizontal([port, NSView()])),
            field("连接密码", control: horizontal([passwordContainer, eye, icon("doc.on.doc", label: "复制密码", action: #selector(copyPassword))])),
            NSButton(title: "重置密码…", target: self, action: #selector(resetPassword))
        ], spacing: 16)
        qrCard.wantsLayer = true; qrCard.layer?.cornerRadius = 12
        qrCard.widthAnchor.constraint(equalToConstant: 208).isActive = true
        qrCard.heightAnchor.constraint(equalToConstant: 244).isActive = true
        qr.imageScaling = .scaleProportionallyUpOrDown
        qr.setAccessibilityLabel("配对二维码"); qr.setAccessibilityIdentifier("settings-qr")
        qr.wantsLayer = true; qr.layer?.magnificationFilter = .nearest
        qrCaption.font = .systemFont(ofSize: 11); qrCaption.textColor = .darkGray
        qrPlaceholder.font = .systemFont(ofSize: 12); qrPlaceholder.textColor = .secondaryLabelColor
        for view in [qr, qrCaption, qrPlaceholder] { view.translatesAutoresizingMaskIntoConstraints = false; qrCard.addSubview(view) }
        NSLayoutConstraint.activate([
            qr.widthAnchor.constraint(equalToConstant: 176), qr.heightAnchor.constraint(equalToConstant: 176),
            qr.topAnchor.constraint(equalTo: qrCard.topAnchor, constant: 16), qr.centerXAnchor.constraint(equalTo: qrCard.centerXAnchor),
            qrCaption.centerXAnchor.constraint(equalTo: qrCard.centerXAnchor), qrCaption.bottomAnchor.constraint(equalTo: qrCard.bottomAnchor, constant: -16),
            qrPlaceholder.centerXAnchor.constraint(equalTo: qrCard.centerXAnchor), qrPlaceholder.centerYAnchor.constraint(equalTo: qrCard.centerYAnchor)
        ])
        let body = horizontal([details, qrCard], spacing: 24)
        body.alignment = .top
        details.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -232).isActive = true
        let hint = NSTextField(wrappingLabelWithString: "iPhone 与 Mac 需连接同一局域网。修改端口或密码后，手机需重新连接。")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        connectionError.font = .systemFont(ofSize: 11); connectionError.textColor = .systemOrange
        saveConnection.target = self; saveConnection.action = #selector(applyConnection)
        saveConnection.bezelStyle = .rounded; saveConnection.keyEquivalent = "\r"
        saveConnection.setAccessibilityIdentifier("settings-save-connection")
        install(vertical([stack, body, hint, connectionError, NSView(), horizontal([NSView(), saveConnection])], spacing: 16), in: connectionPage)
    }

    private func buildRecording() {
        location.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        location.lineBreakMode = .byTruncatingMiddle; location.isSelectable = true
        location.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let folder = horizontal([location, icon("folder", label: "打开录像文件夹", action: #selector(openRecordings))])
        let metrics = horizontal([field("已保存录像", control: used), field("预计每天", control: daily)], spacing: 44)
        for label in [used, daily] { label.font = .systemFont(ofSize: 19, weight: .medium) }
        for (title, value) in [("永久保留", 0), ("1 天", 1), ("3 天", 3), ("7 天", 7), ("14 天", 14), ("30 天", 30), ("60 天", 60), ("90 天", 90), ("自定义…", -1)] { retention.addItem(withTitle: title); retention.lastItem?.tag = value }
        retention.target = self; retention.action = #selector(changeRetention)
        retention.setAccessibilityIdentifier("settings-retention"); retention.setAccessibilityLabel("录像保留时间")
        retention.widthAnchor.constraint(equalToConstant: 150).isActive = true
        customDays.delegate = self; customDays.setAccessibilityLabel("保留天数"); customDays.setAccessibilityIdentifier("settings-retention-days")
        customDays.widthAnchor.constraint(equalToConstant: 80).isActive = true
        customRow.orientation = .horizontal; customRow.spacing = 8
        customRow.addArrangedSubview(customDays); customRow.addArrangedSubview(NSTextField(labelWithString: "天"))
        let policy = horizontal([retention, customRow, NSView()])
        retentionHelp.font = .systemFont(ofSize: 12); retentionHelp.textColor = .secondaryLabelColor
        retentionEstimate.font = .systemFont(ofSize: 12); retentionEstimate.textColor = .secondaryLabelColor
        cleanupStatus.font = .systemFont(ofSize: 11)
        saveRetention.target = self; saveRetention.action = #selector(applyRetention)
        saveRetention.bezelStyle = .rounded; saveRetention.keyEquivalent = "\r"
        saveRetention.setAccessibilityIdentifier("settings-save-retention")
        cleanupNow.target = self; cleanupNow.action = #selector(cleanupImmediately)
        cleanupNow.bezelStyle = .rounded; cleanupNow.setAccessibilityIdentifier("settings-cleanup-now")
        cleanupNow.toolTip = "立即按已保存的保留时间清理到期录像"
        install(vertical([heading("录像"), field("保存位置", control: folder), metrics, field("保留时间", control: policy), retentionHelp, retentionEstimate, cleanupStatus, NSView(), horizontal([cleanupNow, NSView(), saveRetention])], spacing: 20), in: recordingPage)
    }

    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSTextField {
            if field === password { revealedPassword.stringValue = password.stringValue }
            if field === revealedPassword { password.stringValue = revealedPassword.stringValue }
        }
        validateConnection(); changeRetention()
    }

    private func validateConnection() {
        let valid = UInt16(port.stringValue).map { $0 > 0 } == true && password.stringValue.utf8.count >= 12
        saveConnection.isEnabled = valid && (port.stringValue != String(settings.port) || password.stringValue != settings.password)
        connectionError.stringValue = valid ? "" : "端口需为 1–65535，密码至少 12 个字符。"
        connectionError.isHidden = valid
    }

    @objc private func toggleService() {
        var value = settings
        if service.state == .off { value.enabled = false; onChange?(value); return }
        guard let port = UInt16(port.stringValue), port > 0, password.stringValue.utf8.count >= 12 else { service.state = .off; validateConnection(); return }
        value.enabled = true; value.port = port; value.password = password.stringValue
        onChange?(value)
    }

    @objc private func applyConnection() {
        guard let port = UInt16(port.stringValue), port > 0, password.stringValue.utf8.count >= 12 else { validateConnection(); return }
        var value = settings; value.port = port; value.password = password.stringValue
        onChange?(value)
    }

    @objc private func changeRetention() {
        customRow.isHidden = retention.selectedItem?.tag != -1
        let days = selectedDays()
        saveRetention.isEnabled = days != nil && days != settings.retentionDays
        cleanupNow.isEnabled = settings.retentionDays > 0 && days == settings.retentionDays && !cleaning
        retentionHelp.stringValue = days == nil ? "请输入 1–3650 天。" : (days == 0 ? "录像持续保留，不自动清理。" : "自动删除更早的已完成录像和人物索引，正在录制或回放的录像不受影响。")
        retentionHelp.textColor = days == nil ? .systemOrange : .secondaryLabelColor
        if let days, days > 0, let daily = summary?.dailyBytes { retentionEstimate.stringValue = "按近期录像估算，\(days) 天约需 " + Self.bytes(daily * Double(days)) }
        else { retentionEstimate.stringValue = "" }
        retentionEstimate.isHidden = retentionEstimate.stringValue.isEmpty
    }

    private func selectedDays() -> Int? {
        let value = retention.selectedItem?.tag ?? 0
        if value != -1 { return value }
        guard let days = Int(customDays.stringValue), (1...3650).contains(days) else { return nil }
        return days
    }

    @objc private func applyRetention() { if let days = selectedDays() { onRetention?(days) } }
    @objc private func cleanupImmediately() { if cleanupNow.isEnabled { onCleanupNow?() } }
    @objc private func revealPassword() { password.isHidden.toggle(); revealedPassword.isHidden = !password.isHidden; eye.image = NSImage(systemSymbolName: password.isHidden ? "eye.slash" : "eye", accessibilityDescription: nil); eye.setAccessibilityLabel(password.isHidden ? "隐藏密码" : "显示密码") }
    @objc private func copyAddress() { copy(address.titleOfSelectedItem ?? "") }
    @objc private func copyPassword() { copy(password.stringValue) }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    @objc private func openRecordings() { if let directory = summary?.directory { NSWorkspace.shared.open(directory) } }

    @objc private func resetPassword() {
        let alert = NSAlert()
        alert.messageText = "重置连接密码？"
        alert.informativeText = "已配对的手机需要使用新密码重新连接。"
        alert.addButton(withTitle: "重置密码"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { var value = self.settings; value.password = String(CameraRemoteCoding.randomSecret().prefix(24)); self.onChange?(value) }
        }
    }

    @objc private func renderQR() {
        qr.image = nil; qr.isHidden = !settings.enabled
        qrPlaceholder.isHidden = settings.enabled; qrCaption.isHidden = !settings.enabled
        qrCard.layer?.backgroundColor = (settings.enabled ? NSColor.white : NSColor(calibratedWhite: 0.14, alpha: 1)).cgColor
        guard settings.enabled, let host = address.titleOfSelectedItem, Self.addresses().contains(host) else { return }
        var url = URLComponents()
        url.scheme = "wirecamera"; url.host = "pair"
        url.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "port", value: String(settings.port)), URLQueryItem(name: "password", value: settings.password)]
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data((url.string ?? "").utf8), forKey: "inputMessage")
        if let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), let image = CIContext().createCGImage(output, from: output.extent) { qr.image = NSImage(cgImage: image, size: NSSize(width: 176, height: 176)) }
    }

    private func heading(_ text: String) -> NSTextField { let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 22, weight: .semibold); return label }
    private func field(_ title: String, control: NSView) -> NSStackView { let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 12, weight: .medium); label.textColor = .secondaryLabelColor; return vertical([label, control], spacing: 7) }
    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView { let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing; stack.detachesHiddenViews = true; for view in views { view.translatesAutoresizingMaskIntoConstraints = false; if view is NSStackView { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true } }; return stack }
    private func horizontal(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView { let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = spacing; return stack }
    private func install(_ stack: NSStackView, in page: NSView) { stack.translatesAutoresizingMaskIntoConstraints = false; page.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: page.leadingAnchor), stack.trailingAnchor.constraint(equalTo: page.trailingAnchor), stack.topAnchor.constraint(equalTo: page.topAnchor), stack.bottomAnchor.constraint(equalTo: page.bottomAnchor)]) }
    private func configureIcon(_ button: NSButton, symbol: String, label: String, action: Selector) { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label); button.imagePosition = .imageOnly; button.bezelStyle = .inline; button.isBordered = false; button.target = self; button.action = action; button.toolTip = label; button.setAccessibilityLabel(label); button.widthAnchor.constraint(equalToConstant: 24).isActive = true }
    private func icon(_ symbol: String, label: String, action: Selector) -> NSButton { let button = NSButton(); configureIcon(button, symbol: symbol, label: label, action: action); return button }
    private static func bytes(_ value: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(min(Double(Int64.max), max(0, value))), countStyle: .file) }

    static func addresses() -> [String] {
        var primary = ""
        if let store = SCDynamicStoreCreate(nil, "WireCamera.Settings" as CFString, nil, nil), let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] { primary = value["PrimaryInterface"] as? String ?? "" }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }
        var values: [(String, String)] = []
        var next = interfaces
        while let current = next {
            defer { next = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), current.pointee.ifa_flags & UInt32(IFF_UP) != 0, current.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { values.append((String(cString: current.pointee.ifa_name), String(cString: host))) }
        }
        return values.sorted { left, right in
            if (left.0 == primary) != (right.0 == primary) { return left.0 == primary }
            if left.0.hasPrefix("en") != right.0.hasPrefix("en") { return left.0.hasPrefix("en") }
            return left.0 < right.0
        }.map { $0.1 }
    }
}
