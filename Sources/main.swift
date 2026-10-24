import AppKit
import AVFoundation
import CoreMedia
import UniformTypeIdentifiers

func cameraDevices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
        deviceTypes: [.external, .builtInWideAngleCamera],
        mediaType: .video, position: .unspecified
    ).devices.sorted {
        if ($0.deviceType == .external) != ($1.deviceType == .external) {
            return $0.deviceType == .external
        }
        return $0.localizedName < $1.localizedName
    }
}

final class PreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspect
        layer?.addSublayer(previewLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let camera = CameraController()
    private let preview = PreviewView(frame: .zero)
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let mirror = NSButton(checkboxWithTitle: "镜像", target: nil, action: nil)
    private let recordButton = NSButton(title: "开始录制", target: nil, action: nil)
    private let recordAudio = NSButton(checkboxWithTitle: "录入声音", target: nil, action: nil)
    private let listen = NSButton(checkboxWithTitle: "监听声音", target: nil, action: nil)
    private let volume = NSSlider(value: 0.25, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let recordingTime = NSTextField(labelWithString: "00:00")
    private let revealButton = NSButton(title: "显示文件", target: nil, action: nil)
    private var audioDevice: AVCaptureDevice?
    private var audioChanging = false
    private var recordingBusy = false
    private var recordingPreparing = false
    private var recordingFinishing = false
    private var recordingStarted: Date?
    private var lastRecording: URL?
    private var lastRecordingError: String?
    private var savedRecordings = 0
    private var pendingRefresh = false
    private var pendingTermination = false
    private var recordingTestURL: URL?
    private var recordingTestDirectory: URL?
    private var testChecks: [[String: Any]] = []
    private var testFailure: String?
    private var recordingTimer: Timer?
    private let status = NSTextField(labelWithString: "正在准备摄像头…")
    private let detail = NSTextField(labelWithString: "本地预览")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let messageTitle = NSTextField(labelWithString: "正在连接")
    private let overlay = NSStackView()
    private let retry = NSButton(title: "重试", target: nil, action: nil)
    private let settings = NSButton(title: "打开摄像头权限设置", target: nil, action: nil)
    private var devices: [AVCaptureDevice] = []
    private var selectedID: String?
    private var observers: [NSObjectProtocol] = []
    private var generation = 0
    private var awaitingFrames = false
    private var lastFrameAt = Date.distantPast
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("WireCamera launched; camera permission=%ld audio permission=%ld", AVCaptureDevice.authorizationStatus(for: .video).rawValue, AVCaptureDevice.authorizationStatus(for: .audio).rawValue)
        buildMenu()
        buildWindow()
        camera.onRecording = { [weak self] event in self?.recordingChanged(event) }
        if let index = CommandLine.arguments.firstIndex(of: "--recording-e2e"), CommandLine.arguments.indices.contains(index + 1) {
            recordingTestDirectory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        if let index = CommandLine.arguments.firstIndex(of: "--check-ui"),
           CommandLine.arguments.indices.contains(index + 1) {
            let root = window.contentView!
            root.layoutSubtreeIfNeeded()
            let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
            root.cacheDisplay(in: root.bounds, to: bitmap)
            do {
                try bitmap.representation(using: .png, properties: [:])!.write(
                    to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                print("UI render OK: \(Int(root.bounds.width)) × \(Int(root.bounds.height)); preview: \(Int(preview.bounds.width)) × \(Int(preview.bounds.height))")
                exit(0)
            } catch {
                fputs("UI render failed: \(error)\n", stderr)
                exit(1)
            }
        }
        preview.previewLayer.session = camera.session
        camera.onFrame = { [weak self] width, height, fps in
            guard let self, self.selectedID != nil else { return }
            if self.awaitingFrames { NSLog("Camera preview verified: %d x %d; first video frame received.", width, height) }
            self.lastFrameAt = Date()
            self.awaitingFrames = false
            self.updateRecordingControls()
            self.overlay.isHidden = true
            self.status.stringValue = "●  实时画面"
            self.status.textColor = NSColor(calibratedRed: 0.38, green: 0.86, blue: 0.68, alpha: 1)
            self.detail.stringValue = "\(width) × \(height)" + (fps > 0 ? "  ·  \(Int(fps.rounded())) fps" : "") + "  ·  本地预览"
        }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshDevices()
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
            object: camera.session, queue: .main) { [weak self] note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                if self?.recordingBusy == true { self?.camera.stopRecording() }
                self?.showMessage("摄像头暂时不可用", error?.localizedDescription ?? "请检查连接，然后点击重试。")
        })
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.selectedID != nil, Date().timeIntervalSince(self.lastFrameAt) > 8 else { return }
            self.showMessage("暂未收到画面", "请检查 USB 连接，或关闭正在使用摄像头的其他应用，然后点击重试。")
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        requestCamera()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let started = self.recordingStarted else { return }
            let seconds = Int(Date().timeIntervalSince(started))
            self.recordingTime.stringValue = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        if recordingTestDirectory != nil { runRecordingE2E() }
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 WireCamera", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 WireCamera", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        let fullscreen = viewMenu.addItem(withTitle: "切换全屏", action: #selector(toggleFullscreen), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(withTitle: "重新连接", action: #selector(reconnect), keyEquivalent: "r")
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)
        NSApp.mainMenu = menu
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "WireCamera"
        window.delegate = self
        window.minSize = NSSize(width: 780, height: 500)
        window.collectionBehavior = [.fullScreenPrimary]
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 1)
        window.center()
        guard let root = window.contentView else { return }

        let header = NSView()
        let footer = NSView()
        let recordingBar = NSView()
        for view in [header, preview, recordingBar, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let title = NSTextField(labelWithString: "WireCamera")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "即开即看")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        let brand = NSStackView(views: [title, subtitle])
        brand.orientation = .vertical
        brand.alignment = .leading
        brand.spacing = 3
        picker.target = self
        picker.action = #selector(selectCamera)
        picker.toolTip = "选择摄像头，默认优先使用外接 USB 摄像头"
        picker.setAccessibilityLabel("摄像头")
        mirror.target = self
        mirror.action = #selector(toggleMirror)
        let fullscreen = NSButton(title: "全屏", target: self, action: #selector(toggleFullscreen))
        fullscreen.bezelStyle = .rounded
        let controls = NSStackView(views: [picker, mirror, fullscreen])
        controls.spacing = 16
        for view in [brand, controls] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        status.font = .systemFont(ofSize: 12, weight: .medium)
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        for label in [status, detail] {
            label.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(label)
        }
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        recordButton.bezelStyle = .rounded
        recordButton.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        recordButton.imagePosition = .imageLeading
        recordButton.contentTintColor = .systemRed
        recordButton.isEnabled = false
        recordAudio.state = .on
        recordAudio.isEnabled = false
        recordAudio.toolTip = "将当前摄像头自带的声音写入视频，与监听开关独立"
        recordingTime.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        recordingTime.textColor = .secondaryLabelColor
        revealButton.target = self
        revealButton.action = #selector(revealRecording)
        revealButton.bezelStyle = .rounded
        revealButton.isEnabled = false
        listen.target = self
        listen.action = #selector(toggleListening)
        listen.isEnabled = false
        listen.toolTip = "仅控制本机播放；建议使用耳机避免回声"
        volume.target = self
        volume.action = #selector(changeVolume)
        volume.isContinuous = true
        volume.isEnabled = false
        volume.setAccessibilityLabel("监听音量")
        let recordingControls = NSStackView(views: [recordButton, recordAudio, recordingTime, revealButton])
        recordingControls.spacing = 14
        let soundControls = NSStackView(views: [listen, volume])
        soundControls.spacing = 12
        for controls in [recordingControls, soundControls] {
            controls.translatesAutoresizingMaskIntoConstraints = false
            recordingBar.addSubview(controls)
        }
        NSLayoutConstraint.activate([
            recordingControls.leadingAnchor.constraint(equalTo: recordingBar.leadingAnchor, constant: 24),
            recordingControls.centerYAnchor.constraint(equalTo: recordingBar.centerYAnchor),
            soundControls.trailingAnchor.constraint(equalTo: recordingBar.trailingAnchor, constant: -24),
            soundControls.centerYAnchor.constraint(equalTo: recordingBar.centerYAnchor),
            soundControls.leadingAnchor.constraint(greaterThanOrEqualTo: recordingControls.trailingAnchor, constant: 16),
            volume.widthAnchor.constraint(equalToConstant: 90),
            recordingTime.widthAnchor.constraint(greaterThanOrEqualToConstant: 64)
        ])
        let symbol = NSImageView(image: NSImage(systemSymbolName: "video", accessibilityDescription: "摄像头")!)
        symbol.contentTintColor = .secondaryLabelColor
        symbol.symbolConfiguration = .init(pointSize: 40, weight: .light)
        messageTitle.font = .systemFont(ofSize: 22, weight: .medium)
        message.alignment = .center
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 13)
        retry.target = self
        retry.action = #selector(reconnect)
        retry.bezelStyle = .rounded
        settings.target = self
        settings.action = #selector(openSettings)
        settings.bezelStyle = .rounded
        let actions = NSStackView(views: [retry, settings])
        actions.spacing = 12
        overlay.setViews([symbol, messageTitle, message, actions], in: .center)
        overlay.orientation = .vertical
        overlay.spacing = 18
        overlay.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(overlay)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 76),
            brand.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 24),
            brand.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            controls.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -24),
            controls.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            controls.leadingAnchor.constraint(greaterThanOrEqualTo: brand.trailingAnchor, constant: 24),
            picker.widthAnchor.constraint(equalToConstant: 290),
            preview.topAnchor.constraint(equalTo: header.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: recordingBar.topAnchor),
            recordingBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            recordingBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            recordingBar.bottomAnchor.constraint(equalTo: footer.topAnchor),
            recordingBar.heightAnchor.constraint(equalToConstant: 52),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 38),
            status.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 24),
            status.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            detail.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -24),
            detail.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            overlay.centerXAnchor.constraint(equalTo: preview.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
            overlay.widthAnchor.constraint(equalToConstant: 460),
            message.widthAnchor.constraint(equalTo: overlay.widthAnchor)
        ])
    }

    private func requestCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: refreshDevices(force: true)
        case .notDetermined:
            showMessage("允许访问摄像头", "请在系统弹窗中点击“允许”，即可显示实时画面。", canRetry: false)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                DispatchQueue.main.async { self?.requestCamera() }
            }
        case .denied, .restricted:
            showMessage("需要摄像头权限", "在“系统设置 → 隐私与安全性 → 摄像头”中允许 WireCamera 访问，然后重新打开应用。", permission: true)
        @unknown default:
            showMessage("无法访问摄像头", "请检查系统的摄像头权限设置。", permission: true)
        }
    }

    private func refreshDevices(force: Bool = false) {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        if recordingBusy {
            let connected = cameraDevices().contains { $0.uniqueID == selectedID }
            if !connected || (recordAudio.state == .on && audioDevice?.isConnected == false) {
                pendingRefresh = true
                camera.stopRecording()
            }
            return
        }
        devices = cameraDevices()
        picker.removeAllItems()
        devices.forEach { picker.addItem(withTitle: $0.localizedName) }
        picker.isEnabled = !devices.isEmpty
        guard !devices.isEmpty else {
            generation += 1
            selectedID = nil
            audioDevice = nil
            listen.state = .off
            updateRecordingControls()
            camera.stop()
            picker.addItem(withTitle: "未检测到摄像头")
            showMessage("连接你的摄像头", "请插入 USB 摄像头，连接后会自动显示画面。")
            return
        }
        let index = devices.firstIndex { $0.uniqueID == selectedID } ?? 0
        picker.selectItem(at: index)
        if force || devices[index].uniqueID != selectedID { startCamera(devices[index]) }
        else { refreshAudioDevice() }
    }

    private func startCamera(_ device: AVCaptureDevice) {
        guard !recordingBusy else { return }
        generation += 1
        let request = generation
        selectedID = device.uniqueID
        listen.state = .off
        awaitingFrames = true
        refreshAudioDevice()
        lastFrameAt = Date()
        showMessage("正在连接摄像头", device.localizedName, canRetry: false)
        camera.start(device: device) { [weak self] error in
            guard let self, self.generation == request else { return }
            if let error {
                self.selectedID = nil
                self.updateRecordingControls()
                self.showMessage("连接失败", error)
            } else {
                self.toggleMirror()
                // A sample may arrive before startRunning returns.
                if !self.awaitingFrames { self.overlay.isHidden = true }
            }
        }
    }

    private func showMessage(_ title: String, _ body: String, permission: Bool = false, canRetry: Bool = true) {
        messageTitle.stringValue = title
        message.stringValue = body
        settings.isHidden = !permission
        retry.isHidden = !canRetry
        overlay.isHidden = false
        status.stringValue = title
        status.textColor = .secondaryLabelColor
        detail.stringValue = "本地预览"
    }

    @objc private func selectCamera() {
        guard devices.indices.contains(picker.indexOfSelectedItem) else { return }
        startCamera(devices[picker.indexOfSelectedItem])
    }
    @objc private func reconnect() { if !recordingBusy && !recordingPreparing { requestCamera() } }
    @objc private func toggleMirror() {
        guard let connection = preview.previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirror.state == .on
    }
    @objc private func toggleFullscreen() { window.toggleFullScreen(nil) }
    @objc private func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "WireCamera", .applicationVersion: "1.3.1",
            .credits: NSAttributedString(string: "摄像头预览、声音监听与本地录制。\n音视频仅在本机处理，不上传。")
        ])
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        recordingTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        camera.shutdown()
    }

    private func refreshAudioDevice() {
        let next = devices.first { $0.uniqueID == selectedID }.flatMap { cameraAudioDevice(for: $0) }
        if next?.uniqueID != audioDevice?.uniqueID {
            if listen.state == .on {
                listen.state = .off
                camera.setMonitoring(nil, volume: 0) { _ in }
            }
            recordAudio.state = next == nil ? .off : .on
        }
        audioDevice = next
        if next == nil { recordAudio.state = .off }
        recordAudio.toolTip = next.map { "录入 \($0.localizedName) 的声音" } ?? "未找到当前摄像头对应的声音输入"
        updateRecordingControls()
    }

    private func updateRecordingControls() {
        let locked = recordingBusy || recordingPreparing
        picker.isEnabled = !locked && !devices.isEmpty
        mirror.isEnabled = !locked
        retry.isEnabled = !locked
        recordAudio.isEnabled = !locked && audioDevice != nil && !audioChanging
        listen.isEnabled = !locked && audioDevice != nil && !audioChanging
        volume.isEnabled = listen.state == .on
        recordButton.isEnabled = !recordingPreparing && !recordingFinishing && !audioChanging && (recordingBusy || (selectedID != nil && !awaitingFrames))
        recordButton.title = recordingFinishing ? "正在保存…" : (recordingBusy ? "停止录制" : "开始录制")
        revealButton.isEnabled = lastRecording != nil
    }

    private func audioPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { allowed in DispatchQueue.main.async { completion(allowed) } }
        default: completion(false)
        }
    }

    private func showRecordingError(_ message: String) {
        lastRecordingError = message
        guard recordingTestDirectory == nil else { return }
        let alert = NSAlert()
        alert.messageText = "录制或声音操作未完成"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    @objc private func toggleListening() {
        guard !recordingBusy, !recordingPreparing else { return }
        let enabled = listen.state == .on
        let request = generation
        audioChanging = true
        updateRecordingControls()
        let apply: (Bool) -> Void = { [weak self] allowed in
            guard let self else { return }
            guard request == self.generation else { self.audioChanging = false; self.updateRecordingControls(); return }
            guard allowed || !enabled else {
                self.listen.state = .off
                self.audioChanging = false
                self.updateRecordingControls()
                self.showRecordingError("请在系统设置 → 隐私与安全性 → 麦克风中允许 WireCamera 访问摄像头声音。")
                return
            }
            self.camera.setMonitoring(enabled ? self.audioDevice : nil, volume: Float(self.volume.doubleValue)) { error in
                guard request == self.generation else { self.audioChanging = false; self.updateRecordingControls(); return }
                self.audioChanging = false
                if let error { self.listen.state = .off; self.showRecordingError(error) }
                self.updateRecordingControls()
            }
        }
        if enabled { audioPermission(apply) } else { apply(true) }
    }

    @objc private func changeVolume() { camera.setVolume(Float(volume.doubleValue)) }

    @objc private func toggleRecording() {
        if recordingBusy { camera.stopRecording(); return }
        guard !recordingPreparing, selectedID != nil, !awaitingFrames else { return }
        if let target = recordingTestURL { beginRecording(to: target); return }
        recordingPreparing = true
        updateRecordingControls()
        let panel = NSSavePanel()
        panel.title = "保存录制视频"
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        panel.nameFieldStringValue = "WireCamera \(formatter.string(from: Date())).mov"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.recordingPreparing = false
            self.updateRecordingControls()
            if response == .OK, let target = panel.url { self.beginRecording(to: target) }
        }
    }

    private func beginRecording(to target: URL) {
        let request = generation
        let source = recordAudio.state == .on ? audioDevice : nil
        recordingPreparing = true
        lastRecordingError = nil
        updateRecordingControls()
        let begin: (Bool) -> Void = { [weak self] allowed in
            guard let self else { return }
            self.recordingPreparing = false
            guard request == self.generation, self.selectedID != nil else { self.updateRecordingControls(); return }
            guard allowed else {
                self.updateRecordingControls()
                self.showRecordingError("需要麦克风权限才能录入摄像头声音。请在系统设置中允许，或取消「录入声音」后录制无声视频。")
                return
            }
            self.recordingBusy = true
            self.recordingTime.stringValue = "准备录制…"
            self.updateRecordingControls()
            self.camera.startRecording(to: target, audioDevice: source, mirrored: self.mirror.state == .on)
        }
        if source != nil { audioPermission(begin) } else { begin(true) }
    }

    private func recordingChanged(_ event: RecordingEvent) {
        switch event {
        case .starting:
            recordingBusy = true
        case .recording:
            recordingStarted = Date()
            recordingTime.textColor = .systemRed
        case .finishing:
            recordingFinishing = true
            recordingStarted = nil
            recordingTime.stringValue = "正在保存…"
        case .finished(let url, let error):
            recordingBusy = false
            recordingPreparing = false
            recordingFinishing = false
            recordingStarted = nil
            recordingTime.textColor = .secondaryLabelColor
            recordingTime.stringValue = url == nil ? "保存失败" : "已保存"
            if let url { lastRecording = url; savedRecordings += 1 }
            lastRecordingError = error
            if pendingTermination {
                if recordingTestDirectory != nil { writeRecordingTestResult(error: error) }
                if let error, recordingTestDirectory == nil {
                    pendingTermination = false
                    NSApp.reply(toApplicationShouldTerminate: false)
                    showRecordingError(error)
                } else { NSApp.reply(toApplicationShouldTerminate: true) }
            } else if let error { showRecordingError(error) }
            if pendingRefresh { pendingRefresh = false; refreshDevices(force: true) }
        }
        updateRecordingControls()
    }

    @objc private func revealRecording() {
        if let lastRecording { NSWorkspace.shared.activateFileViewerSelecting([lastRecording]) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if recordingBusy { NSApp.terminate(nil); return false }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if recordingBusy {
            pendingTermination = true
            camera.stopRecording()
            return .terminateLater
        }
        return .terminateNow
    }
}

extension AppDelegate {
    private func writeRecordingTestResult(error: String?) {
        guard let directory = recordingTestDirectory else { return }
        let failure = testFailure ?? error
        let checks = testChecks + [["name": "three_recordings_saved", "passed": savedRecordings == 3]]
        let result: [String: Any] = [
            "passed": failure == nil && checks.allSatisfy { $0["passed"] as? Bool == true },
            "error": failure ?? "", "checks": checks, "savedRecordings": savedRecordings,
            "camera": selectedID ?? "", "audio": audioDevice?.uniqueID ?? "",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        do {
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("app-result.json"), options: .atomic)
        } catch { NSLog("Recording E2E report failed: %@", error.localizedDescription) }
    }

    private func runRecordingE2E() {
        guard let directory = recordingTestDirectory else { return }
        let started = Date()
        var phase = 0
        let previousContents = Data("Existing file must survive until recording finishes.".utf8)
        let testTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            if Date().timeIntervalSince(started) > 300 {
                self.testFailure = "Timed out during phase \(phase). Status: \(self.status.stringValue). Camera permission: \(AVCaptureDevice.authorizationStatus(for: .video).rawValue); audio permission: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)."
                self.writeRecordingTestResult(error: self.testFailure)
                timer.invalidate()
                NSApp.terminate(nil)
                return
            }
            if phase > 1, let error = self.lastRecordingError {
                self.testFailure = error
                self.writeRecordingTestResult(error: error)
                timer.invalidate()
                NSApp.terminate(nil)
                return
            }
            switch phase {
            case 0:
                guard !self.awaitingFrames, self.audioDevice != nil, self.recordButton.isEnabled else { return }
                self.testChecks.append(["name": "real_camera_and_matched_audio", "passed": true])
                self.recordAudio.state = .off
                self.recordingTestURL = directory
                self.recordButton.performClick(nil)
                phase = 1
            case 1:
                guard !self.recordingBusy, self.lastRecordingError != nil else { return }
                self.testChecks.append(["name": "invalid_destination_rejected", "passed": true])
                self.lastRecordingError = nil
                self.volume.doubleValue = 0.05
                self.listen.performClick(nil)
                phase = 2
            case 2:
                guard !self.audioChanging, self.listen.state == .on else { return }
                do { try previousContents.write(to: directory.appendingPathComponent("silent.mov")) }
                catch { self.lastRecordingError = error.localizedDescription; return }
                self.recordingTestURL = directory.appendingPathComponent("silent.mov")
                self.recordButton.performClick(nil)
                phase = 3
            case 3:
                guard let recordingStarted = self.recordingStarted, Date().timeIntervalSince(recordingStarted) > 2 else { return }
                let preserved = (try? Data(contentsOf: directory.appendingPathComponent("silent.mov"))) == previousContents
                self.testChecks.append(["name": "existing_file_preserved_until_stop", "passed": preserved])
                self.testChecks.append(["name": "controls_locked_while_recording", "passed": !self.picker.isEnabled && !self.mirror.isEnabled && !self.recordAudio.isEnabled])
                self.recordButton.performClick(nil)
                phase = 4
            case 4:
                guard !self.recordingBusy, self.savedRecordings == 1 else { return }
                self.testChecks.append(["name": "silent_recording_saved", "passed": true])
                self.testChecks.append(["name": "preview_continues_after_stop", "passed": Date().timeIntervalSince(self.lastFrameAt) < 3])
                phase = 5
            case 5:
                guard !self.audioChanging else { return }
                self.recordAudio.state = .on
                self.recordingTestURL = directory.appendingPathComponent("sound.mov")
                self.recordButton.performClick(nil)
                phase = 6
            case 6:
                guard let recordingStarted = self.recordingStarted, Date().timeIntervalSince(recordingStarted) > 2 else { return }
                self.recordButton.performClick(nil)
                phase = 7
            case 7:
                guard !self.recordingBusy, self.savedRecordings == 2 else { return }
                self.testChecks.append(["name": "sound_recording_with_monitoring", "passed": self.listen.state == .on])
                self.listen.performClick(nil)
                phase = 8
            case 8:
                guard !self.audioChanging else { return }
                self.testChecks.append(["name": "sound_recording_without_monitoring", "passed": self.listen.state == .off])
                self.recordingTestURL = directory.appendingPathComponent("quit.mov")
                self.recordButton.performClick(nil)
                phase = 9
            default:
                guard let recordingStarted = self.recordingStarted, Date().timeIntervalSince(recordingStarted) > 2 else { return }
                self.testChecks.append(["name": "quit_requested_during_recording", "passed": true])
                timer.invalidate()
                NSApp.terminate(nil)
            }
        }
        RunLoop.main.add(testTimer, forMode: .common)
    }
}

if CommandLine.arguments.contains("--diagnose") {
    let cameras = cameraDevices()
    print("Camera authorization: \(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
    for device in cameras {
        print("\(device.deviceType == .external ? "USB / External" : "Built-in"): \(device.localizedName)")
        print("  ID: \(device.uniqueID); formats: \(device.formats.count)")
    }
    print("Discovered \(cameras.count) camera(s).")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
