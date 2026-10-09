import AppKit
import AVFoundation
import CoreMedia

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

final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera.session")
    private let frameQueue = DispatchQueue(label: "camera.frames")
    private var lastReport = 0.0
    private var count = 0
    var onFrame: ((Int32, Int32, Double) -> Void)?

    func start(device: AVCaptureDevice, completion: @escaping (String?) -> Void) {
        queue.async {
            self.session.stopRunning()
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            var failure: String?
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else {
                    throw NSError(domain: "WireCamera", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "无法连接此摄像头，请检查 USB 连接。"])
                }
                self.session.addInput(input)
                if self.session.canSetSessionPreset(.hd1920x1080) {
                    self.session.sessionPreset = .hd1920x1080
                } else if self.session.canSetSessionPreset(.high) {
                    self.session.sessionPreset = .high
                }
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: self.frameQueue)
                guard self.session.canAddOutput(output) else {
                    throw NSError(domain: "WireCamera", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "无法读取摄像头画面，请重试。"])
                }
                self.session.addOutput(output)
            } catch {
                failure = error.localizedDescription
            }
            self.session.commitConfiguration()
            self.frameQueue.sync { self.lastReport = 0; self.count = 0 }
            if failure == nil {
                self.session.startRunning()
                if !self.session.isRunning { failure = "摄像头未能启动，请关闭可能正在使用它的其他应用后重试。" }
            }
            let result = failure
            DispatchQueue.main.async { completion(result) }
        }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    func shutdown() {
        queue.sync { self.session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let size = CMVideoFormatDescriptionGetDimensions(format)
        let now = ProcessInfo.processInfo.systemUptime
        count += 1
        if lastReport == 0 || now - lastReport >= 1 {
            let fps = lastReport == 0 ? 0 : Double(count) / (now - lastReport)
            lastReport = now
            count = 0
            DispatchQueue.main.async { self.onFrame?(size.width, size.height, fps) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let camera = CameraController()
    private let preview = PreviewView(frame: .zero)
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let mirror = NSButton(checkboxWithTitle: "镜像", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "正在准备摄像头…")
    private let detail = NSTextField(labelWithString: "本地实时预览 · 无录制")
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
        buildMenu()
        buildWindow()
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
                self?.showMessage("摄像头暂时不可用", error?.localizedDescription ?? "请检查连接，然后点击重试。")
        })
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.selectedID != nil, Date().timeIntervalSince(self.lastFrameAt) > 8 else { return }
            self.showMessage("暂未收到画面", "请检查 USB 连接，或关闭正在使用摄像头的其他应用，然后点击重试。")
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        requestCamera()
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
        window.minSize = NSSize(width: 780, height: 500)
        window.collectionBehavior = [.fullScreenPrimary]
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 1)
        window.center()
        guard let root = window.contentView else { return }

        let header = NSView()
        let footer = NSView()
        for view in [header, preview, footer] {
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
            preview.bottomAnchor.constraint(equalTo: footer.topAnchor),
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
        devices = cameraDevices()
        picker.removeAllItems()
        devices.forEach { picker.addItem(withTitle: $0.localizedName) }
        picker.isEnabled = !devices.isEmpty
        guard !devices.isEmpty else {
            generation += 1
            selectedID = nil
            camera.stop()
            picker.addItem(withTitle: "未检测到摄像头")
            showMessage("连接你的摄像头", "请插入 USB 摄像头，连接后会自动显示画面。")
            return
        }
        let index = devices.firstIndex { $0.uniqueID == selectedID } ?? 0
        picker.selectItem(at: index)
        if force || devices[index].uniqueID != selectedID { startCamera(devices[index]) }
    }

    private func startCamera(_ device: AVCaptureDevice) {
        generation += 1
        let request = generation
        selectedID = device.uniqueID
        awaitingFrames = true
        lastFrameAt = Date()
        showMessage("正在连接摄像头", device.localizedName, canRetry: false)
        camera.start(device: device) { [weak self] error in
            guard let self, self.generation == request else { return }
            if let error {
                self.selectedID = nil
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
        detail.stringValue = "本地实时预览 · 无录制"
    }

    @objc private func selectCamera() {
        guard devices.indices.contains(picker.indexOfSelectedItem) else { return }
        startCamera(devices[picker.indexOfSelectedItem])
    }
    @objc private func reconnect() { requestCamera() }
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
            .applicationName: "WireCamera", .applicationVersion: "1.0.0",
            .credits: NSAttributedString(string: "即开即看的本地摄像头预览工具。\n画面仅在本机显示，不录制、不上传。")
        ])
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        camera.shutdown()
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
    app.run()
}
