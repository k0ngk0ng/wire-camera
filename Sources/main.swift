import AppKit
import AVFoundation
import CoreMedia
import CoreImage
import UniformTypeIdentifiers
import AVKit

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
    let displayLayer = AVSampleBufferDisplayLayer()
    private let sampleLock = NSLock()
    private var pendingSample: CMSampleBuffer?
    private var presentationSize = CGSize.zero

    var displayedVideoRect: CGRect {
        guard presentationSize.width > 0, presentationSize.height > 0 else { return .zero }
        return AVMakeRect(aspectRatio: presentationSize, insideRect: bounds)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func enqueue(_ sample: CMSampleBuffer) {
        sampleLock.lock()
        let schedule = pendingSample == nil
        pendingSample = sample
        sampleLock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sampleLock.lock()
            let latest = self.pendingSample
            self.pendingSample = nil
            self.sampleLock.unlock()
            guard let latest, let format = CMSampleBufferGetFormatDescription(latest) else { return }
            let renderer = self.displayLayer.sampleBufferRenderer
            if renderer.status == .failed {
                renderer.flush(removingDisplayedImage: true, completionHandler: nil)
                return
            }
            guard renderer.isReadyForMoreMediaData else { return }
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: latest, sampleBufferOut: &copy) == noErr, let copy else { return }
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(copy, createIfNecessary: true) as? [NSMutableDictionary] {
                attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
            }
            self.presentationSize = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: true, useCleanAperture: true)
            renderer.enqueue(copy)
        }
    }

    func setMirrored(_ enabled: Bool) {
        displayLayer.setAffineTransform(enabled ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
    }

    func reset() {
        sampleLock.lock()
        pendingSample = nil
        sampleLock.unlock()
        presentationSize = .zero
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var window: NSWindow!
    private var statusItem: NSStatusItem?
    private let trayMenu = NSMenu()
    private var previewSuspended = false
    private var backgroundActivity: NSObjectProtocol?
    private var camera = CameraController()
    private let modePicker = NSSegmentedControl(labels: ["实时", "回放"], trackingMode: .selectOne, target: nil, action: nil)
    private let playback = CameraPlaybackView(frame: .zero)
    private let liveTools = NSStackView()
    private var libraryTestDirectory: URL?
    private var automaticRecordingDeviceID: String?
    private lazy var library: CameraRecordingLibrary = {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--recordings-path"), arguments.indices.contains(index + 1) {
            return CameraRecordingLibrary(directory: URL(fileURLWithPath: arguments[index + 1]))
        }
        return CameraRecordingLibrary(directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/WireCamera"))
    }()
    private var recordingSources: [String: CameraRecordingSource] = [:]
    private let remoteServer = CameraRemoteServer()
    private let remoteMedia = CameraRemoteMedia()
    private let remotePanel = CameraRemotePanel()
    private var remoteViewers: Set<String> = []
    private var remoteNetworks: [String: CameraModuleNetwork] = [:]
    private var remoteCameras: [String: CameraController] = [:]
    private var remoteVideoPermissionPending = false
    private var remoteState = "仅允许已配对的手机访问。Mac 需要保持运行。"
    private lazy var remoteIdentity: CameraRemoteIdentity = {
        if let index = CommandLine.arguments.firstIndex(of: "--remote-server-test"), CommandLine.arguments.indices.contains(index + 1) { return CameraRemoteIdentity(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1]).appendingPathComponent("remote")) }
        return CameraRemoteIdentity(directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WireCamera/remote"))
    }()
    private var recordingSource: CameraRecordingSource? { liveSourceID.flatMap { recordingSources[$0] } }
    private var activeRecordingSources: [CameraRecordingSource] { recordingSources.values.filter { $0.isActive } }
    private var recordingRequested: Bool {
        get { recordingSource?.requested ?? false }
        set { recordingSource?.requested = newValue }
    }
    private var recordingBusy: Bool { recordingSource?.busy ?? false }
    private var recordingPreparing: Bool { recordingSource?.preparing ?? false }
    private var recordingFinishing: Bool { recordingSource?.finishing ?? false }
    private var recordingStarted: Date? { recordingSource?.segmentStartedAt }
    private var recordingSourceID: String { recordingSource?.id ?? "" }
    private var recordingSourceName: String { recordingSource?.name ?? "" }
    private var controlledSourceID: String? { modePicker.selectedSegment == 1 ? selectedPlaybackSourceID : liveSourceID }
    private let recordingIndicator: NSImage? = {
        let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "正在录制")?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
        image?.isTemplate = false
        return image
    }()
    private var lastNetworkAudioAt = Date.distantPast

    private let preview = PreviewView(frame: .zero)
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let picturePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let playbackPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private var playbackSources: [(id: String, name: String)] = []
    private var selectedPlaybackSourceID: String?
    private var playbackSourceChosen = false
    private let recordingTarget = NSTextField(labelWithString: "")
    private var pictureModes: [CameraPictureMode] = []
    private var selectedPictureMode: CameraPictureMode?
    private var latestVideoWidth: Int32 = 0
    private var latestVideoHeight: Int32 = 0
    private var pictureTestDirectory: URL?
    private var moduleTestDirectory: URL?
    private var moduleConnection: CameraModuleConnection?
    private let moduleNetwork = CameraModuleNetwork()
    private let moduleScanner = CameraModuleNetwork()
    private var discoveredModuleIDs: Set<String> = []
    private var discoveryTesting = false
    private var savedModuleTesting = false
    private var selectedNetworkModule: CameraModuleNetworkDevice?
    private var networkModules: [CameraModuleNetworkDevice] = []
    private lazy var moduleStore: CameraModuleStore = {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--module-store-path"), arguments.indices.contains(index + 1) {
            return CameraModuleStore(fileURL: URL(fileURLWithPath: arguments[index + 1]))
        }
        return CameraModuleStore(fileURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WireCamera/modules.json"))
    }()
    private var moduleIdentity: CameraModuleIdentity?
    private var modulePreviewTestDirectory: URL?
    private var modulePreviewSample: CMSampleBuffer?
    private var modulePreviewStarted: Date?
    private var modulePreviewReports = 0
    private var moduleLastError: String?
    private let addModule = NSButton(title: "添加摄像头", target: nil, action: nil)
    private let mirror = NSButton(checkboxWithTitle: "镜像", target: nil, action: nil)
    private let recordButton = NSButton(title: "开始录制", target: nil, action: nil)
    private let listen = NSButton(checkboxWithTitle: "监听声音", target: nil, action: nil)
    private let volume = NSSlider(value: 0.25, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let recordingTime = NSTextField(labelWithString: "00:00")
    private let revealButton = NSButton(title: "显示文件", target: nil, action: nil)
    private var audioDevice: AVCaptureDevice?
    private var audioChanging = false
    private let liveClock = NSTextField(labelWithString: "")
    private let liveClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    private var lastRecording: URL?
    private var lastRecordingError: String?
    private var savedRecordings = 0
    private var pendingTermination = false
    private var terminationErrors: [String] = []
    private var terminationTestCompletion: (([String]) -> Void)?
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
        if let index = CommandLine.arguments.firstIndex(of: "--record-camera"), CommandLine.arguments.indices.contains(index + 1) {
            automaticRecordingDeviceID = CommandLine.arguments[index + 1]
        }
        buildMenu()
        buildWindow()
        buildTray()
        bindCamera(camera)
        if let index = CommandLine.arguments.firstIndex(of: "--library-e2e"), CommandLine.arguments.indices.contains(index + 1) {
            libraryTestDirectory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        library.onChange = { [weak self] in self?.refreshPlayback() }
        library.resumeIndexing()
        refreshPlayback()
        if let index = CommandLine.arguments.firstIndex(of: "--recording-e2e"), CommandLine.arguments.indices.contains(index + 1) {
            recordingTestDirectory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        if let index = CommandLine.arguments.firstIndex(of: "--picture-mode-e2e"), CommandLine.arguments.indices.contains(index + 1) {
            pictureTestDirectory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        if let index = CommandLine.arguments.firstIndex(of: "--module-connection-e2e"), CommandLine.arguments.indices.contains(index + 1) {
            moduleTestDirectory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        if let index = CommandLine.arguments.firstIndex(of: "--module-preview-e2e"), CommandLine.arguments.indices.contains(index + 1) {
            modulePreviewTestDirectory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        if let index = CommandLine.arguments.firstIndex(of: "--module-discovery-e2e"), CommandLine.arguments.indices.contains(index + 1) {
            modulePreviewTestDirectory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            discoveryTesting = true
        }
        if let index = CommandLine.arguments.firstIndex(of: "--module-manual-e2e"), CommandLine.arguments.indices.contains(index + 1) {
            modulePreviewTestDirectory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        if let index = CommandLine.arguments.firstIndex(of: "--module-saved-e2e"), CommandLine.arguments.indices.contains(index + 1) {
            modulePreviewTestDirectory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            savedModuleTesting = true
        }
        networkModules = moduleStore.devices
        updateNetworkPicker()
        updateRecordingControls()
        if let index = CommandLine.arguments.firstIndex(of: "--check-ui"),
           CommandLine.arguments.indices.contains(index + 1) {
            let root = window.contentView!
            root.layoutSubtreeIfNeeded()
            let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
            window.effectiveAppearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: bitmap) }
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
        moduleNetwork.onSampleBuffer = { [weak self] sample in
            DispatchQueue.main.async {
                guard let self, !self.previewSuspended, self.selectedNetworkModule != nil else { return }
                self.preview.enqueue(sample)
                if self.modulePreviewTestDirectory != nil { self.modulePreviewSample = sample }
            }
        }
        moduleNetwork.onAudioSampleBuffer = { [weak self] sample in
            DispatchQueue.main.async {
                guard let self else { return }
                let wasDisconnected = Date().timeIntervalSince(self.lastNetworkAudioAt) > 3
                self.lastNetworkAudioAt = Date()
                if wasDisconnected { self.updateRecordingControls() }
                self.startAutomaticRecordingIfReady()
            }
        }
        moduleNetwork.onAudioError = { [weak self] message in
            guard let self else { return }
            self.lastNetworkAudioAt = .distantPast
            self.recordButton.toolTip = message
            self.updateRecordingControls()

        }
        moduleNetwork.onFrame = { [weak self] width, height, fps in self?.moduleFrame(width: width, height: height, fps: fps) }
        moduleNetwork.onError = { [weak self] message in
            guard let self, self.selectedNetworkModule != nil else { return }
            self.moduleLastError = message
            self.showMessage("模块画面连接中断", message)
        }
        configureRemoteAccess()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshDevices()
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshRemoteFeeds()
            for source in self.activeRecordingSources where source.busy && !source.finishing && source.segmentStartedAt != nil {
                if Date().timeIntervalSince(source.lastVideoAt) > 8 { self.stopRecording(source, error: "录制摄像头的画面已中断，当前片段正在保存。", recovering: true) }
            }
            guard !self.previewSuspended, self.selectedID != nil || self.selectedNetworkModule != nil, Date().timeIntervalSince(self.lastFrameAt) > 8 else { return }
            self.showMessage("暂未收到画面", self.selectedNetworkModule == nil ? "请检查 USB 连接，或关闭正在使用摄像头的其他应用，然后点击重试。" : "请确认模块保持供电、Wi-Fi 连接正常，然后重新连接模块。")
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if automaticRecordingDeviceID == nil && !savedModuleTesting && libraryTestDirectory == nil && !CommandLine.arguments.contains("--disable-module-scan") { moduleScanner.scanNearby(onDevice: { [weak self] device in self?.registerNearbyModule(device) }, completion: { _ in }) }
        if automaticRecordingDeviceID == nil && libraryTestDirectory == nil && moduleTestDirectory == nil && modulePreviewTestDirectory == nil && !CommandLine.arguments.contains("--add-camera") { requestCamera() }
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.previewSuspended { self.liveClock.stringValue = self.liveClockFormatter.string(from: Date()) }
            let segmentSeconds: Double = (self.libraryTestDirectory == nil && !CommandLine.arguments.contains("--verify-background")) || CommandLine.arguments.contains("--expect-audio-interruption") ? 60 : 4
            for source in self.activeRecordingSources {
                if source.requested && !source.busy && !source.preparing && !source.finishing, let retryAt = source.retryAt, retryAt <= Date() { self.retryRecording(source) }
                if source.requested && !source.finishing, let started = source.segmentStartedAt, Date().timeIntervalSince(started) >= segmentSeconds { self.stopRecording(source, rotating: true) }
            }
            self.updateRecordingControls()
        }
        if let recordingTimer { RunLoop.main.add(recordingTimer, forMode: .common) }
        if let deviceID = automaticRecordingDeviceID {
            let address = moduleStore.devices.first(where: { $0.deviceID == deviceID })?.address
            beginModuleConnection(CameraModuleIdentity(deviceID: deviceID, salt: "", address: address))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--automatic-recording-e2e"), CommandLine.arguments.indices.contains(index + 1) {
            runAutomaticRecordingE2E(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        if libraryTestDirectory != nil {
            if CommandLine.arguments.contains("--recording-recovery-e2e") { runRecordingRecoveryE2E() }
            else if CommandLine.arguments.contains("--multi-recording-e2e") { runMultiRecordingE2E() }
            else if CommandLine.arguments.contains("--record-preview-e2e") { runRecordPreviewE2E() }
            else { runLibraryE2E() }
        }
        if recordingTestDirectory != nil { runRecordingE2E() }
        if pictureTestDirectory != nil { runPictureModeE2E() }
        if let directory = moduleTestDirectory {
            addModule.performClick(nil)
            moduleConnection?.runE2E(to: directory)
        } else if automaticRecordingDeviceID == nil && CommandLine.arguments.contains("--add-camera") {
            addModule.performClick(nil)
        }
        if modulePreviewTestDirectory != nil {
            if savedModuleTesting, !networkModules.isEmpty {
                picker.selectItem(at: 0)
                picker.sendAction(picker.action, to: picker.target)
            } else { addModule.performClick(nil) }
            if discoveryTesting { moduleConnection?.runDiscoveryE2E() }
            if CommandLine.arguments.contains("--module-manual-e2e"), let directory = modulePreviewTestDirectory,
               let index = CommandLine.arguments.firstIndex(of: "--module-address"), CommandLine.arguments.indices.contains(index + 1) {
                moduleConnection?.runManualE2E(address: CommandLine.arguments[index + 1], directory: directory)
            }
            runModulePreviewE2E()
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 WireCamera", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(withTitle: "iPhone 连接…", action: #selector(showRemoteAccess), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 WireCamera", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        let fullscreen = viewMenu.addItem(withTitle: "切换全屏", action: #selector(toggleFullscreen), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(withTitle: "重新连接", action: #selector(reconnect), keyEquivalent: "r")
        viewMenu.addItem(withTitle: "添加摄像头…", action: #selector(showModuleConnection), keyEquivalent: "n")
        viewMenu.addItem(withTitle: "收起到菜单栏", action: #selector(hideMainWindow), keyEquivalent: "w")
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)
        NSApp.mainMenu = menu
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "WireCamera"
        window.delegate = self
        window.minSize = NSSize(width: 1000, height: 620)
        window.collectionBehavior = [.fullScreenPrimary]
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.085, alpha: 1)
        window.center()
        guard let root = window.contentView else { return }
        let header = NSView()
        let footer = NSView()
        let recordingBar = NSView()
        for surface in [header, recordingBar, footer] {
            surface.wantsLayer = true
            surface.layer?.backgroundColor = NSColor(calibratedWhite: 0.085, alpha: 1).cgColor
        }
        for view in [header, liveTools, preview, playback, recordingBar, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        playback.isHidden = true
        playback.onToggleFullscreen = { [weak self] in self?.toggleFullscreen() }
        let title = NSTextField(labelWithString: "WireCamera")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        modePicker.selectedSegment = 0
        modePicker.target = self
        modePicker.action = #selector(changeMode)
        modePicker.segmentStyle = .rounded
        modePicker.setWidth(80, forSegment: 0)
        modePicker.setWidth(80, forSegment: 1)
        modePicker.setAccessibilityLabel("实时与回放")
        picker.target = self
        picker.action = #selector(selectCamera)
        picker.setAccessibilityLabel("摄像头")
        picker.lineBreakMode = .byTruncatingMiddle
        playbackPicker.target = self
        playbackPicker.action = #selector(selectPlaybackCamera)
        playbackPicker.setAccessibilityLabel("回放摄像头")
        playbackPicker.setAccessibilityIdentifier("playback-camera")
        playbackPicker.lineBreakMode = .byTruncatingMiddle
        playbackPicker.isHidden = true
        addModule.target = self
        addModule.action = #selector(showModuleConnection)
        addModule.bezelStyle = .rounded
        addModule.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        let devices = NSStackView(views: [picker, playbackPicker, addModule])
        devices.detachesHiddenViews = true
        devices.spacing = 12
        for view in [title, modePicker, devices] { view.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(view) }
        picturePicker.target = self
        picturePicker.action = #selector(selectPictureMode)
        picturePicker.setAccessibilityLabel("画面比例")
        picturePicker.addItem(withTitle: "原生画面比例")
        picturePicker.isEnabled = false
        mirror.target = self
        mirror.action = #selector(toggleMirror)
        let fullscreen = NSButton(title: "全屏", target: self, action: #selector(toggleFullscreen))
        fullscreen.bezelStyle = .rounded
        listen.target = self
        listen.action = #selector(toggleListening)
        listen.toolTip = "仅控制实时监听，录制始终包含摄像头声音"
        volume.target = self
        volume.action = #selector(changeVolume)
        volume.isContinuous = true
        volume.setAccessibilityLabel("监听音量")
        liveTools.setViews([picturePicker, mirror, fullscreen, listen, volume], in: .center)
        liveTools.spacing = 18
        liveTools.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 0, right: 24)
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        recordButton.bezelStyle = .rounded
        recordButton.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        recordButton.imagePosition = .imageLeading
        recordButton.contentTintColor = .systemRed
        recordingTime.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        recordingTime.textColor = .secondaryLabelColor
        revealButton.title = "录像文件夹"
        revealButton.target = self
        revealButton.action = #selector(revealRecording)
        revealButton.bezelStyle = .rounded
        recordingTarget.font = .systemFont(ofSize: 11)
        recordingTarget.textColor = .secondaryLabelColor
        recordingTarget.lineBreakMode = .byTruncatingMiddle
        recordingTarget.isHidden = true
        let recordControls = NSStackView(views: [recordButton, recordingTime, recordingTarget])
        recordControls.spacing = 16
        for view in [recordControls, revealButton] { view.translatesAutoresizingMaskIntoConstraints = false; recordingBar.addSubview(view) }
        status.font = .systemFont(ofSize: 12, weight: .medium)
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        for label in [status, detail] { label.translatesAutoresizingMaskIntoConstraints = false; footer.addSubview(label) }
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
        let clockBadge = NSView()
        clockBadge.wantsLayer = true
        clockBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        clockBadge.layer?.cornerRadius = 6
        clockBadge.translatesAutoresizingMaskIntoConstraints = false
        liveClock.translatesAutoresizingMaskIntoConstraints = false
        liveClock.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        liveClock.textColor = .white
        liveClock.setAccessibilityLabel("当前时间")
        liveClock.stringValue = liveClockFormatter.string(from: Date())
        clockBadge.addSubview(liveClock)
        preview.addSubview(clockBadge)
        NSLayoutConstraint.activate([
            clockBadge.topAnchor.constraint(equalTo: preview.topAnchor, constant: 16),
            clockBadge.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -16),
            liveClock.leadingAnchor.constraint(equalTo: clockBadge.leadingAnchor, constant: 10),
            liveClock.trailingAnchor.constraint(equalTo: clockBadge.trailingAnchor, constant: -10),
            liveClock.topAnchor.constraint(equalTo: clockBadge.topAnchor, constant: 7),
            liveClock.bottomAnchor.constraint(equalTo: clockBadge.bottomAnchor, constant: -7),
            header.topAnchor.constraint(equalTo: root.topAnchor), header.leadingAnchor.constraint(equalTo: root.leadingAnchor), header.trailingAnchor.constraint(equalTo: root.trailingAnchor), header.heightAnchor.constraint(equalToConstant: 72),
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 24), title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            modePicker.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 36), modePicker.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            devices.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -24), devices.centerYAnchor.constraint(equalTo: header.centerYAnchor), devices.leadingAnchor.constraint(greaterThanOrEqualTo: modePicker.trailingAnchor, constant: 24), picker.widthAnchor.constraint(equalToConstant: 270), playbackPicker.widthAnchor.constraint(equalToConstant: 270), recordingTarget.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            liveTools.topAnchor.constraint(equalTo: header.bottomAnchor), liveTools.leadingAnchor.constraint(equalTo: root.leadingAnchor), liveTools.trailingAnchor.constraint(equalTo: root.trailingAnchor), liveTools.heightAnchor.constraint(equalToConstant: 48), picturePicker.widthAnchor.constraint(equalToConstant: 190), volume.widthAnchor.constraint(equalToConstant: 90),
            preview.topAnchor.constraint(equalTo: liveTools.bottomAnchor), preview.leadingAnchor.constraint(equalTo: root.leadingAnchor), preview.trailingAnchor.constraint(equalTo: root.trailingAnchor), preview.bottomAnchor.constraint(equalTo: recordingBar.topAnchor),
            playback.topAnchor.constraint(equalTo: header.bottomAnchor), playback.leadingAnchor.constraint(equalTo: root.leadingAnchor), playback.trailingAnchor.constraint(equalTo: root.trailingAnchor), playback.bottomAnchor.constraint(equalTo: recordingBar.topAnchor),
            recordingBar.leadingAnchor.constraint(equalTo: root.leadingAnchor), recordingBar.trailingAnchor.constraint(equalTo: root.trailingAnchor), recordingBar.bottomAnchor.constraint(equalTo: footer.topAnchor), recordingBar.heightAnchor.constraint(equalToConstant: 60),
            recordControls.leadingAnchor.constraint(equalTo: recordingBar.leadingAnchor, constant: 24), recordControls.centerYAnchor.constraint(equalTo: recordingBar.centerYAnchor),
            revealButton.trailingAnchor.constraint(equalTo: recordingBar.trailingAnchor, constant: -24), revealButton.centerYAnchor.constraint(equalTo: recordingBar.centerYAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor), footer.heightAnchor.constraint(equalToConstant: 32),
            status.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 24), status.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            detail.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -24), detail.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            overlay.centerXAnchor.constraint(equalTo: preview.centerXAnchor), overlay.centerYAnchor.constraint(equalTo: preview.centerYAnchor), overlay.widthAnchor.constraint(equalToConstant: 460), message.widthAnchor.constraint(equalTo: overlay.widthAnchor)
        ])
    }

    @objc private func changeMode() {
        let isPlayback = modePicker.selectedSegment == 1
        preview.isHidden = isPlayback
        liveTools.isHidden = isPlayback
        playback.isHidden = !isPlayback
        if !isPlayback { playback.pause() }
        refreshPlayback()
    }

    private var liveSourceID: String? {
        selectedNetworkModule.map { "wifi:" + $0.deviceID } ?? selectedID.map { "usb:" + $0 }
    }

    private func refreshPlayback() {
        var seen: Set<String> = []
        playbackSources = library.entries.compactMap { entry in
            guard seen.insert(entry.sourceID).inserted else { return nil }
            return (id: entry.sourceID, name: entry.sourceName.isEmpty ? entry.sourceID : entry.sourceName)
        }
        for source in activeRecordingSources where seen.insert(source.id).inserted { playbackSources.append((id: source.id, name: source.name)) }
        if let source = liveSourceID, !seen.contains(source) {
            playbackSources.append((id: source, name: picker.titleOfSelectedItem ?? "摄像头"))
        }
        playbackSources.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !playbackSourceChosen || !playbackSources.contains(where: { $0.id == selectedPlaybackSourceID }) {
            selectedPlaybackSourceID = playbackSources.contains(where: { $0.id == liveSourceID }) ? liveSourceID : library.entries.first?.sourceID ?? playbackSources.first?.id
        }
        playbackPicker.removeAllItems()
        for source in playbackSources {
            let sameName = playbackSources.filter { $0.name == source.name }.count > 1
            playbackPicker.addItem(withTitle: sameName ? source.name + " · " + source.id.suffix(6) : source.name)
            playbackPicker.lastItem?.representedObject = source.id
        }
        if let index = playbackSources.firstIndex(where: { $0.id == selectedPlaybackSourceID }) { playbackPicker.selectItem(at: index) }
        if playbackSources.isEmpty { playbackPicker.addItem(withTitle: "暂无录像的摄像头") }
        let currentRecording = selectedPlaybackSourceID.flatMap { recordingSources[$0] }?.isActive ?? false
        playback.update(library: library, sourceID: selectedPlaybackSourceID, recordingActive: currentRecording)
        updateRecordingControls()
    }

    @objc private func selectPlaybackCamera() {
        guard playbackSources.indices.contains(playbackPicker.indexOfSelectedItem) else { return }
        selectedPlaybackSourceID = playbackSources[playbackPicker.indexOfSelectedItem].id
        playbackSourceChosen = true
        refreshPlayback()
    }

    private func bindCamera(_ controller: CameraController) {
        controller.onRecording = { [weak self, weak controller] event in
            guard let self, let controller, let source = self.sourceForCamera(controller) else { return }
            self.recordingChanged(event, source: source)
        }
        controller.onSampleBuffer = { [weak self, weak controller] sample in
            if let self, let controller, let id = controller.deviceID { self.remoteMedia.video(sample, sourceID: "usb:" + id, mirrored: false) }
            DispatchQueue.main.async {
                guard let self, let controller, !self.previewSuspended, self.camera === controller, self.selectedNetworkModule == nil, self.selectedID != nil else { return }
                self.preview.enqueue(sample)
            }
        }
        controller.onAudioSampleBuffer = { [weak self, weak controller] sample in
            if let self, let id = controller?.deviceID { self.remoteMedia.audio(sample, sourceID: "usb:" + id) }
        }
        controller.onFrame = { [weak self, weak controller] width, height, fps in
            guard let self, let controller else { return }
            self.sourceForCamera(controller)?.lastVideoAt = Date()
            guard self.camera === controller, self.selectedID != nil, self.selectedNetworkModule == nil else { return }
            if let expected = self.selectedPictureMode?.dimensions, expected.width != width || expected.height != height { return }
            self.latestVideoWidth = width
            self.latestVideoHeight = height
            self.lastFrameAt = Date()
            self.awaitingFrames = false
            self.overlay.isHidden = true
            self.status.stringValue = "●  实时画面"
            self.status.textColor = NSColor(calibratedRed: 0.38, green: 0.86, blue: 0.68, alpha: 1)
            self.detail.stringValue = "\(width) × \(height)" + (fps > 0 ? "  ·  \(Int(fps.rounded())) fps" : "") + "  ·  本地预览"
            self.updateRecordingControls()
        }
        controller.onError = { [weak self, weak controller] message in
            guard let self, let controller else { return }
            if let id = controller.deviceID { self.remoteServer.publish(Data(message.utf8), kind: 3, sourceID: "usb:" + id) }
            if let source = self.sourceForCamera(controller), source.requested { self.stopRecording(source, error: message, recovering: true) }
            if self.camera === controller && self.selectedNetworkModule == nil && self.selectedID != nil { self.showMessage("摄像头暂时不可用", message) }
        }
    }

    private func sourceForCamera(_ controller: CameraController) -> CameraRecordingSource? { activeRecordingSources.first { $0.camera === controller } }

    private func leaveCameraPreview() {
        if let id = camera.deviceID, remoteViewers.contains("usb:" + id) { remoteCameras["usb:" + id] = camera; camera.setVolume(0) }
        else if sourceForCamera(camera) != nil { camera.setVolume(0) }
        else { camera.stop() }
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
        let connectedDevices = cameraDevices()
        for source in activeRecordingSources where source.camera != nil {
            let found = connectedDevices.contains { "usb:" + $0.uniqueID == source.id }
            if (!found || source.audioDevice?.isConnected == false) && !source.recovering { stopRecording(source, error: "录制摄像头或它的声音设备已断开。", recovering: true) }
        }
        if selectedNetworkModule != nil {
            if !force { devices = cameraDevices(); updateNetworkPicker(); updateRecordingControls(); return }
            moduleNetwork.stop()
            selectedNetworkModule = nil
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        devices = cameraDevices()
        picker.removeAllItems()
        networkModules.forEach { picker.addItem(withTitle: "Wi-Fi · \($0.deviceID)") }
        devices.forEach { picker.addItem(withTitle: $0.localizedName) }
        picker.isEnabled = !devices.isEmpty
        guard !devices.isEmpty else {
            generation += 1
            selectedID = nil
            audioDevice = nil
            listen.state = .off
            updateRecordingControls()
            leaveCameraPreview()
            picker.addItem(withTitle: "未检测到摄像头")
            showMessage("连接你的摄像头", "请插入 USB 摄像头，连接后会自动显示画面。")
            return
        }
        let index = devices.firstIndex { $0.uniqueID == selectedID } ?? 0
        picker.selectItem(at: index + networkModules.count)
        if force || devices[index].uniqueID != selectedID { startCamera(devices[index]) }
        else { refreshAudioDevice() }
    }

    private func startCamera(_ device: AVCaptureDevice) {
        let retained = recordingSources["usb:" + device.uniqueID].flatMap { $0.isActive ? $0 : nil }
        leaveCameraPreview()
        if let retained, let controller = retained.camera { camera = controller }
        else if let controller = remoteCameras["usb:" + device.uniqueID] { camera = controller }
        else { camera = CameraController(); bindCamera(camera) }
        if selectedNetworkModule != nil { moduleNetwork.stop(); selectedNetworkModule = nil; preview.reset() }
        recordButton.toolTip = nil
        generation += 1
        let request = generation
        let previousMode = retained?.pictureMode?.identifier ?? (selectedID == device.uniqueID ? selectedPictureMode?.identifier : nil)
        pictureModes = CameraPictureMode.available(for: device)
        picturePicker.removeAllItems()
        pictureModes.forEach { picturePicker.addItem(withTitle: $0.title) }
        let selectedIndex = pictureModes.firstIndex { $0.identifier == previousMode } ?? 0
        selectedPictureMode = pictureModes[selectedIndex]
        picturePicker.selectItem(at: selectedIndex)
        selectedID = device.uniqueID
        if !networkModules.isEmpty { updateNetworkPicker() }
        listen.state = .off
        awaitingFrames = true
        refreshAudioDevice()
        refreshPlayback()
        lastFrameAt = Date()
        showMessage("正在连接摄像头", device.localizedName, canRetry: false)
        if retained != nil || remoteCameras["usb:" + device.uniqueID] === camera {
            if let retained { mirror.state = retained.mirrored ? .on : .off }
            toggleMirror()
            updateRecordingControls()
            return
        }
        camera.start(device: device, format: selectedPictureMode?.format) { [weak self] error in
            guard let self, self.generation == request else { return }
            if let error {
                self.selectedID = nil
                self.updateRecordingControls()
                self.showMessage("连接失败", error)
            } else {
                self.toggleMirror()
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
        if !networkModules.isEmpty {
            if networkModules.indices.contains(picker.indexOfSelectedItem) {
                let device = networkModules[picker.indexOfSelectedItem]
                let address = moduleStore.devices.contains(where: { $0.deviceID == device.deviceID }) ? device.address : nil
                beginModuleConnection(CameraModuleIdentity(deviceID: device.deviceID, salt: "", address: address))
                return
            }
            let index = picker.indexOfSelectedItem - networkModules.count
            guard devices.indices.contains(index) else { return }
            let device = devices[index]
            moduleNetwork.stop()
            selectedNetworkModule = nil
            selectedID = device.uniqueID
            updateNetworkPicker()
            if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { startCamera(device) }
            else { requestCamera() }
            return
        }
        guard devices.indices.contains(picker.indexOfSelectedItem) else { return }
        startCamera(devices[picker.indexOfSelectedItem])
    }
    @objc private func selectPictureMode() {
        guard sourceForCamera(camera) == nil, !audioChanging,
              pictureModes.indices.contains(picturePicker.indexOfSelectedItem),
              let device = devices.first(where: { $0.uniqueID == selectedID }) else { return }
        selectedPictureMode = pictureModes[picturePicker.indexOfSelectedItem]
        startCamera(device)
    }
    @objc private func reconnect() {
        guard !(sourceForCamera(camera) != nil && selectedNetworkModule == nil) else { return }
        if selectedNetworkModule != nil, let moduleIdentity { beginModuleConnection(moduleIdentity) }
        else { requestCamera() }
    }
    @objc private func showModuleConnection() {
        if moduleConnection == nil {
            var knownIdentifiers: [UUID] = []
            if let index = CommandLine.arguments.firstIndex(of: "--module-identifier"), CommandLine.arguments.indices.contains(index + 1),
               let identifier = UUID(uuidString: CommandLine.arguments[index + 1]) { knownIdentifiers.append(identifier) }
            moduleConnection = CameraModuleConnection(knownIdentifiers: knownIdentifiers)
            moduleConnection?.onConfigured = { [weak self] identity in
                self?.beginModuleConnection(identity)
            }
            moduleConnection?.onCancelNetwork = { [weak self] in self?.moduleNetwork.stop() }
            moduleConnection?.onNetworkFound = { [weak self] device, address in self?.registerNearbyModule(device, address: address) }
        }
        let arguments = CommandLine.arguments
        var existingDeviceID: String?
        if let index = arguments.firstIndex(of: "--module-device-id"), arguments.indices.contains(index + 1) { existingDeviceID = arguments[index + 1] }
        moduleConnection?.present(for: window, existingDeviceID: existingDeviceID, savedDevices: moduleStore.devices)
    }
    @objc private func toggleMirror() {
        preview.setMirrored(mirror.state == .on)
    }

    private func updateNetworkPicker() {
        guard !networkModules.isEmpty else { return }
        picker.removeAllItems()
        networkModules.forEach { picker.addItem(withTitle: "Wi-Fi · \($0.deviceID)") }
        devices.forEach { picker.addItem(withTitle: $0.localizedName) }
        if let selectedNetworkModule, let index = networkModules.firstIndex(where: { $0.deviceID == selectedNetworkModule.deviceID }) { picker.selectItem(at: index) }
        else if let index = devices.firstIndex(where: { $0.uniqueID == selectedID }) { picker.selectItem(at: index + networkModules.count) }
    }

    private func registerNearbyModule(_ device: CameraModuleNetworkDevice, address: String? = nil) {
        discoveredModuleIDs.insert(device.deviceID)
        if let index = networkModules.firstIndex(where: { $0.deviceID == device.deviceID }) { networkModules[index] = device }
        else { networkModules.append(device) }
        if address != nil || moduleStore.devices.contains(where: { $0.deviceID == device.deviceID && $0.address != device.address }) { saveModule(device) }
        if let selectedNetworkModule, selectedNetworkModule.deviceID == device.deviceID, moduleIdentity?.address != nil { moduleIdentity = CameraModuleIdentity(deviceID: device.deviceID, salt: "", address: device.address) }
        updateNetworkPicker(); updateRecordingControls()
    }

    private func saveModule(_ device: CameraModuleNetworkDevice) {
        do { try moduleStore.save(device) }
        catch {
            let message = "模块未能保存到本地：\(error.localizedDescription)"
            moduleLastError = message
            showMessage("无法保存摄像头模块", message)
        }
    }

    private func beginModuleConnection(_ identity: CameraModuleIdentity) {
        moduleIdentity = identity
        moduleLastError = nil
        let device = CameraModuleNetworkDevice(deviceID: identity.deviceID, address: identity.address ?? "", port: 20190)
        moduleConnected(device)
        moduleNetwork.connect(identity: identity) { [weak self] result in
            guard let self else { return }
            self.moduleConnection?.networkConnectionFinished(result)
            switch result {
            case .success(let device):
                self.moduleConnected(device)
                self.saveModule(device)
            case .failure(let error):
                self.moduleLastError = error.localizedDescription
                self.showMessage("模块连接未完成", error.localizedDescription)
            }
        }
    }

    private func moduleConnected(_ device: CameraModuleNetworkDevice) {
        leaveCameraPreview()
        generation += 1
        selectedNetworkModule = device
        if let index = networkModules.firstIndex(where: { $0.deviceID == device.deviceID }) { networkModules[index] = device }
        else { networkModules.append(device) }
        selectedID = nil
        audioDevice = nil
        listen.state = .off
        selectedPictureMode = nil
        pictureModes.removeAll()
        picturePicker.removeAllItems()
        picturePicker.addItem(withTitle: "原生画面比例")
        devices = cameraDevices()
        updateNetworkPicker()
        awaitingFrames = true
        lastFrameAt = Date()
        latestVideoWidth = 0
        latestVideoHeight = 0
        modulePreviewStarted = nil
        modulePreviewReports = 0
        modulePreviewSample = nil
        moduleLastError = nil
        preview.reset()
        toggleMirror()
        lastNetworkAudioAt = .distantPast
        refreshPlayback()
        updateRecordingControls()
        showMessage(device.address.isEmpty ? "正在连接模块" : "正在读取模块画面", device.deviceID, canRetry: false)
    }

    private func moduleFrame(width: Int32, height: Int32, fps: Double) {
        guard selectedNetworkModule != nil, width > 0, height > 0 else { return }
        if awaitingFrames { moduleConnection?.finishPreview() }
        awaitingFrames = false
        lastFrameAt = Date()
        latestVideoWidth = width
        latestVideoHeight = height
        if modulePreviewStarted == nil { modulePreviewStarted = Date() }
        modulePreviewReports += 1
        overlay.isHidden = true
        status.stringValue = "●  实时画面"
        status.textColor = NSColor(calibratedRed: 0.38, green: 0.86, blue: 0.68, alpha: 1)
        detail.stringValue = "\(width) × \(height)" + (fps > 0 ? "  ·  \(Int(fps.rounded())) fps" : "") + "  ·  局域网预览"
        updateRecordingControls()
        startAutomaticRecordingIfReady()
    }
    @objc private func toggleFullscreen() { window.toggleFullScreen(nil) }
    @objc private func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "WireCamera", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            .credits: NSAttributedString(string: "摄像头预览、声音监听与本地录制。\n音视频仅在本机处理，不上传。")
        ])
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        recordingTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        var stopped: Set<ObjectIdentifier> = []
        for controller in [camera] + recordingSources.values.compactMap({ $0.camera }) where stopped.insert(ObjectIdentifier(controller)).inserted { controller.shutdown() }
        for source in recordingSources.values { source.network?.stop() }
        moduleNetwork.stop()
        moduleScanner.stop()
        remoteServer.stop()
        remoteNetworks.values.forEach { $0.stop() }
        if let backgroundActivity { ProcessInfo.processInfo.endActivity(backgroundActivity) }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        for controller in remoteCameras.values where stopped.insert(ObjectIdentifier(controller)).inserted { controller.shutdown() }
    }

    private func refreshAudioDevice() {
        let next = devices.first { $0.uniqueID == selectedID }.flatMap { cameraAudioDevice(for: $0) }
        if next?.uniqueID != audioDevice?.uniqueID {
            if listen.state == .on {
                listen.state = .off
                camera.setMonitoring(nil, volume: 0) { _ in }
            }
        }
        audioDevice = next
        updateRecordingControls()
    }

    private func updateRecordingControls() {
        let keepAwake = !activeRecordingSources.isEmpty || remoteIdentity.settings.enabled
        if keepAwake && backgroundActivity == nil { backgroundActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "保持摄像头录制和手机连接") }
        else if !keepAwake, let backgroundActivity { ProcessInfo.processInfo.endActivity(backgroundActivity); self.backgroundActivity = nil }
        if previewSuspended { return }
        let isPlayback = modePicker.selectedSegment == 1
        let source = controlledSourceID.flatMap { recordingSources[$0] }
        let active = source?.isActive ?? false
        let captureLocked = liveSourceID.flatMap { recordingSources[$0] }?.isActive ?? false
        picker.isHidden = isPlayback
        playbackPicker.isHidden = !isPlayback
        playbackPicker.isEnabled = !playbackSources.isEmpty
        addModule.isHidden = isPlayback
        let others = activeRecordingSources.filter { $0.id != controlledSourceID }.count
        recordingTarget.stringValue = "另有 \(others) 台摄像头录制中"
        recordingTarget.isHidden = others == 0
        picker.isEnabled = !devices.isEmpty || !networkModules.isEmpty
        picturePicker.isEnabled = !captureLocked && !audioChanging && selectedID != nil && pictureModes.count > 1
        mirror.isEnabled = !captureLocked
        retry.isEnabled = !(sourceForCamera(camera) != nil && selectedNetworkModule == nil)
        addModule.isEnabled = true
        listen.isEnabled = sourceForCamera(camera) == nil && audioDevice != nil && !audioChanging
        volume.isEnabled = listen.state == .on
        let soundReady = selectedNetworkModule != nil ? Date().timeIntervalSince(lastNetworkAudioAt) < 3 : audioDevice != nil
        let canStart = controlledSourceID == liveSourceID && liveSourceID != nil && !awaitingFrames && soundReady
        recordButton.isEnabled = !(source?.preparing ?? false) && !(source?.finishing ?? false) && !audioChanging && (active || canStart)
        recordButton.title = source?.finishing == true ? "正在保存…" : (active ? "停止录制" : "开始录制")
        if !active && controlledSourceID == liveSourceID && liveSourceID != nil && !soundReady && !awaitingFrames { recordButton.title = selectedNetworkModule == nil ? "摄像头声音未连接" : "正在连接声音…" }
        if let source {
            if active { recordingTime.stringValue = source.recovering ? source.elapsedText + " · 等待重连" : (source.startedAnySegment ? source.elapsedText : "准备录制…") }
            else { recordingTime.stringValue = source.elapsedText + " · " + source.status }
        } else { recordingTime.stringValue = "00:00:00" }
        recordingTime.textColor = active ? .systemRed : .secondaryLabelColor
        revealButton.isEnabled = !library.entries.isEmpty
        updateRecordingIndicators()
    }

    private func updateRecordingIndicators() {
        let liveIDs = networkModules.map { "wifi:" + $0.deviceID } + devices.map { "usb:" + $0.uniqueID }
        for (index, id) in liveIDs.enumerated() where index < picker.numberOfItems {
            let image = recordingSources[id]?.isActive == true ? recordingIndicator : nil
            if picker.item(at: index)?.image !== image { picker.item(at: index)?.image = image }
        }
        for (index, source) in playbackSources.enumerated() where index < playbackPicker.numberOfItems {
            let image = recordingSources[source.id]?.isActive == true ? recordingIndicator : nil
            if playbackPicker.item(at: index)?.image !== image { playbackPicker.item(at: index)?.image = image }
        }
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
        guard libraryTestDirectory == nil && recordingTestDirectory == nil && pictureTestDirectory == nil else { return }
        let alert = NSAlert()
        alert.messageText = "录制或声音操作未完成"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    @objc private func toggleListening() {
        guard sourceForCamera(camera) == nil else { return }
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

    private func startAutomaticRecordingIfReady() {
        guard let deviceID = automaticRecordingDeviceID, selectedNetworkModule?.deviceID == deviceID,
              !awaitingFrames, Date().timeIntervalSince(lastNetworkAudioAt) < 3,
              !recordingBusy, !recordingPreparing else { return }
        automaticRecordingDeviceID = nil
        startRecordingLiveSource()
        NSLog("Automatic Wi-Fi recording started")
    }

    @objc private func toggleRecording() {
        if let id = controlledSourceID, let source = recordingSources[id], source.isActive { stopRecording(source); return }
        guard controlledSourceID == liveSourceID else { return }
        startRecordingLiveSource()
    }

    private func startRecordingLiveSource() {
        guard let id = liveSourceID, !awaitingFrames, recordingSources[id]?.isActive != true else { return }
        let source: CameraRecordingSource
        if let module = selectedNetworkModule {
            source = CameraRecordingSource(id: id, name: picker.titleOfSelectedItem ?? "摄像头", mirrored: mirror.state == .on, identity: CameraModuleIdentity(deviceID: module.deviceID, salt: "", address: module.address))
        } else {
            source = CameraRecordingSource(id: id, name: picker.titleOfSelectedItem ?? "摄像头", mirrored: mirror.state == .on, camera: camera, audioDevice: audioDevice, pictureMode: selectedPictureMode)
        }
        source.requested = true
        recordingSources[id] = source
        source.recorder.onRecording = { [weak self, weak source] event in
            guard let self, let source, self.recordingSources[source.id] === source else { return }
            self.recordingChanged(event, source: source)
        }
        do { try startNextRecording(source) }
        catch { source.requested = false; source.lastError = error.localizedDescription; source.status = "无法录制"; releaseRecordingMedia(source); showRecordingError(source.name + "：" + error.localizedDescription); updateRecordingControls() }
    }

    private func startNextRecording(_ source: CameraRecordingSource) throws {
        let target = try recordingTestURL ?? library.nextURL()
        beginRecording(to: target, source: source)
    }

    private func scheduleRecordingRetry(_ source: CameraRecordingSource, error: String?) {
        source.recovering = true; source.rotating = false
        source.freezeClock()
        source.lastError = error
        source.status = "等待重连"
        source.retryAttempt += 1
        source.retryAt = Date().addingTimeInterval(min(30, pow(2, Double(min(5, source.retryAttempt - 1)))))
        releaseRecordingMedia(source)
        updateRecordingControls()
    }

    private func retryRecording(_ source: CameraRecordingSource) {
        guard source.requested, !pendingTermination else { return }
        source.retryAt = nil; source.failure = nil; source.lastVideoAt = Date()
        let begin: () -> Void = { [weak self, weak source] in
            guard let self, let source, source.requested else { return }
            do { try self.startNextRecording(source) }
            catch { source.requested = false; source.recovering = false; source.lastError = error.localizedDescription; source.status = "无法录制"; self.releaseRecordingMedia(source); self.updateRecordingControls(); self.showRecordingError(source.name + "：" + error.localizedDescription) }
        }
        if let controller = source.camera {
            guard let device = cameraDevices().first(where: { "usb:" + $0.uniqueID == source.id }), let audio = cameraAudioDevice(for: device), audio.isConnected else { source.retryAt = Date().addingTimeInterval(2); return }
            source.audioDevice = audio
            source.pictureMode = CameraPictureMode.available(for: device).first { $0.identifier == source.pictureMode?.identifier }
            source.preparing = true
            controller.start(device: device, format: source.pictureMode?.format) { [weak self, weak source] error in
                guard let self, let source else { return }
                source.preparing = false
                guard source.requested else { self.releaseRecordingMedia(source); return }
                if let error { self.scheduleRecordingRetry(source, error: error) } else { begin() }
            }
        } else { begin() }
    }

    private func stopCurrentRecording(error: String? = nil) { if let source = recordingSource { stopRecording(source, error: error) } }

    private func stopRecording(_ source: CameraRecordingSource, rotating: Bool = false, error: String? = nil, recovering: Bool = false) {
        guard source.isActive else { return }
        if recovering && source.requested { source.recovering = true; source.rotating = false; source.freezeClock() }
        else if !rotating { source.cancelledWhileRecovering = source.recovering && source.segmentStartedAt == nil; source.requested = false; source.rotating = false; source.recovering = false; source.retryAt = nil; source.freezeClock() }
        else { source.rotating = true }
        if let error { source.failure = error }
        if source.finishing { return }
        if !source.busy && !source.preparing {
            if source.requested && source.recovering { scheduleRecordingRetry(source, error: error) }
            else { source.status = "已停止"; releaseRecordingMedia(source); updateRecordingControls() }
            return
        }
        if source.preparing && !source.busy {
            source.preparing = false; source.status = "已取消"; releaseRecordingMedia(source); updateRecordingControls(); return
        }
        source.finishing = true
        updateRecordingControls()
        if source.network != nil { source.recorder.stop(error: error) }
        else { source.camera?.stopRecording() }
    }

    private func connectRecordingNetwork(_ source: CameraRecordingSource) {
        guard let network = source.network, let identity = source.identity, !source.connected else { return }
        source.connected = true
        let recorder = source.recorder
        let sourceID = source.id, mirrored = source.mirrored
        network.onSampleBuffer = { [weak self] sample in recorder.appendVideo(sample); self?.remoteMedia.video(sample, sourceID: sourceID, mirrored: mirrored) }
        network.onAudioSampleBuffer = { [weak self] sample in recorder.appendAudio(sample); self?.remoteMedia.audio(sample, sourceID: sourceID) }
        network.onFrame = { [weak self, weak source] _, _, _ in
            guard let self, let source, self.recordingSources[source.id] === source else { return }
            source.lastVideoAt = Date()
        }
        let fail: (String) -> Void = { [weak self, weak source] message in
            guard let self, let source, self.recordingSources[source.id] === source, source.requested else { return }
            self.stopRecording(source, error: message, recovering: true)
        }
        network.onError = fail
        network.onAudioError = fail
        network.connect(identity: identity) { result in if case .failure(let error) = result { fail(error.localizedDescription) } }
    }

    private func releaseRecordingMedia(_ source: CameraRecordingSource) {
        source.network?.stop()
        source.connected = false
        if let controller = source.camera, controller !== camera || selectedNetworkModule != nil {
            if remoteViewers.contains(source.id) { remoteCameras[source.id] = controller } else { controller.stop() }
        }
        refreshRemoteFeeds()
    }

    private func beginRecording(to target: URL, source: CameraRecordingSource) {
        source.preparing = true
        source.lastError = nil
        lastRecordingError = nil
        updateRecordingControls()
        let begin: (Bool) -> Void = { [weak self, weak source] allowed in
            guard let self, let source, self.recordingSources[source.id] === source else { return }
            source.preparing = false
            guard source.requested else { self.updateRecordingControls(); return }
            guard allowed, source.network != nil || source.audioDevice != nil else {
                source.requested = false; source.status = "无法录制"
                source.lastError = allowed ? "没有找到录制摄像头的声音输入。" : "请在系统设置中允许 WireCamera 访问摄像头声音。"
                self.releaseRecordingMedia(source)
                self.updateRecordingControls()
                self.showRecordingError(source.name + "：" + source.lastError!)
                return
            }
            source.segmentDate = Date()
            source.busy = true
            self.updateRecordingControls()
            if source.network != nil { source.recorder.start(to: target, mirrored: source.mirrored); self.connectRecordingNetwork(source) }
            else if let audio = source.audioDevice { source.camera?.startRecording(to: target, audioDevice: audio, mirrored: source.mirrored) }
        }
        if source.network != nil { begin(true) } else { audioPermission(begin) }
    }

    private func recordingChanged(_ event: RecordingEvent, source: CameraRecordingSource) {
        switch event {
        case .starting: source.busy = true
        case .recording:
            source.segmentStartedAt = Date()
            source.startedAnySegment = true
            if source.requested && source.sessionStartedUptime == nil { source.sessionStartedUptime = ProcessInfo.processInfo.systemUptime - source.frozenElapsed }
            source.recovering = false; source.retryAt = nil; source.retryAttempt = 0; source.lastError = nil
        case .finishing:
            source.finishing = true; source.segmentStartedAt = nil
            if !source.requested { source.freezeClock() }
        case .finished(let url, let error):
            if source.requested && (error?.hasPrefix("摄像头声音已中断") == true || (source.camera != nil && (source.audioDevice?.isConnected == false || !cameraDevices().contains(where: { "usb:" + $0.uniqueID == source.id })))) {
                source.recovering = true; source.failure = error; source.freezeClock()
            }
            let cancelled = !source.requested && url == nil && (source.cancelledWhileRecovering || (!source.startedAnySegment && source.failure == nil))
            source.busy = false; source.preparing = false; source.finishing = false; source.segmentStartedAt = nil
            var completionError = cancelled ? nil : error ?? source.failure
            if let url {
                source.lastRecordingURL = url; source.savedCount += 1
                lastRecording = url; savedRecordings += 1
                do { try library.add(url, sourceID: source.id, sourceName: source.name, startedAt: source.segmentDate) }
                catch { completionError = error.localizedDescription }
            }
            if source.recovering && source.requested && !pendingTermination && (completionError == source.failure || completionError == nil) {
                scheduleRecordingRetry(source, error: completionError)
                refreshPlayback(); return
            }
            if source.rotating && source.requested && !pendingTermination && completionError == nil {
                source.rotating = false
                do { try startNextRecording(source) }
                catch { source.requested = false; source.freezeClock(); source.lastError = error.localizedDescription; source.status = "已保存"; releaseRecordingMedia(source); showRecordingError(source.name + "：" + error.localizedDescription) }
                refreshPlayback()
                return
            }
            source.rotating = false; source.requested = false; source.freezeClock()
            source.recovering = false; source.retryAt = nil
            source.lastError = completionError
            source.status = url != nil ? "已保存" : (cancelled ? "已取消" : "保存失败")
            releaseRecordingMedia(source)
            if let error = completionError {
                lastRecordingError = source.name + "：" + error
                if pendingTermination { terminationErrors.append(lastRecordingError!) }
                else { showRecordingError(lastRecordingError!) }
            }
            finishPendingTermination()
        }
        updateRecordingControls()
        refreshPlayback()
    }

    private func finishPendingTermination() {
        guard pendingTermination, activeRecordingSources.isEmpty else { return }
        if let completion = terminationTestCompletion { terminationTestCompletion = nil; completion(terminationErrors) }
        if recordingTestDirectory != nil { writeRecordingTestResult(error: terminationErrors.first) }
        if !terminationErrors.isEmpty && libraryTestDirectory == nil && recordingTestDirectory == nil {
            pendingTermination = false
            NSApp.reply(toApplicationShouldTerminate: false)
            showRecordingError(terminationErrors.joined(separator: "\n"))
        } else { NSApp.reply(toApplicationShouldTerminate: true) }
    }

    @objc private func revealRecording() {
        if FileManager.default.fileExists(atPath: library.directory.path) { NSWorkspace.shared.open(library.directory) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideMainWindow()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !activeRecordingSources.isEmpty else { return .terminateNow }
        pendingTermination = true
        terminationErrors = []
        for source in activeRecordingSources { stopRecording(source) }
        if activeRecordingSources.isEmpty { pendingTermination = false; return .terminateNow }
        return .terminateLater
    }
}

extension AppDelegate {
    private func runModulePreviewE2E() {
        guard let directory = modulePreviewTestDirectory else { return }
        let started = Date()
        var retried = false
        var retryKeptModule = false
        let testTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            let seconds = self.modulePreviewStarted.map { Date().timeIntervalSince($0) } ?? 0
            let rendered = self.preview.displayLayer.sampleBufferRenderer.status == .rendering
            let ready = self.selectedNetworkModule != nil && !self.awaitingFrames && self.modulePreviewReports >= 3 && seconds >= 12 && rendered
            if ready, !retried {
                let identifier = self.selectedNetworkModule?.deviceID
                self.reconnect()
                retryKeptModule = self.selectedNetworkModule?.deviceID == identifier && self.picker.selectedItem?.title == "Wi-Fi · \(identifier ?? "")"
                retried = true
                return
            }
            guard ready || self.moduleLastError != nil || Date().timeIntervalSince(started) > 140 else { return }
            timer.invalidate()
            var frameSaved = false
            var failure = self.moduleLastError
            do {
                if let sample = self.modulePreviewSample, let pixels = CMSampleBufferGetImageBuffer(sample) {
                    let image = CIImage(cvPixelBuffer: pixels)
                    if let cgImage = CIContext().createCGImage(image, from: image.extent),
                       let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) {
                        try png.write(to: directory.appendingPathComponent("frame.png"))
                        frameSaved = true
                    }
                }
            } catch { failure = error.localizedDescription }
            let report: [String: Any] = [
                "passed": ready && frameSaved && failure == nil && retryKeptModule,
                "deviceID": self.selectedNetworkModule?.deviceID ?? "",
                "address": self.selectedNetworkModule?.address ?? "",
                "width": self.latestVideoWidth, "height": self.latestVideoHeight,
                "frameReports": self.modulePreviewReports, "previewSeconds": seconds,
                "visibleRenderer": rendered, "frameSaved": frameSaved,
                "retryKeptModule": retryKeptModule,
                "manualAddressUsed": self.moduleIdentity?.address != nil && self.moduleIdentity?.address == self.selectedNetworkModule?.address,
                "moduleSaved": self.moduleStore.devices.contains(where: { $0.deviceID == self.selectedNetworkModule?.deviceID && $0.address == self.selectedNetworkModule?.address }),
                "restoredWithoutDiscovery": self.savedModuleTesting && self.discoveredModuleIDs.isEmpty,
                "discoveredWithoutHistory": !CommandLine.arguments.contains("--module-device-id") && !CommandLine.arguments.contains("--module-identifier") && self.discoveredModuleIDs.contains(self.selectedNetworkModule?.deviceID ?? ""),
                "moduleListed": self.picker.itemTitles.contains("Wi-Fi · \(self.selectedNetworkModule?.deviceID ?? "")"),
                "error": failure ?? (ready ? "" : self.status.stringValue),
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
            do {
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent("app-result.json"), options: .atomic)
            } catch { NSLog("Module preview E2E report failed: %@", error.localizedDescription) }
            self.moduleConnection?.finishPreview()
            NSApp.terminate(nil)
        }
        RunLoop.main.add(testTimer, forMode: .common)
    }

    private func runPictureModeE2E() {
        guard let directory = pictureTestDirectory else { return }
        let cases: [(String, Int32, Int32, String)] = [
            ("4:3", 1280, 960, "standard.mov"),
            ("16:9", 1280, 720, "wide.mov"),
            ("4:3", 1280, 960, "standard-again.mov")
        ]
        let started = Date()
        var caseIndex = 0
        var phase = 0
        var selectedAt = Date()
        var checks: [[String: Any]] = []
        func finish(_ error: String? = nil) {
            let result: [String: Any] = [
                "passed": error == nil && checks.allSatisfy { $0["passed"] as? Bool == true },
                "error": error ?? "", "checks": checks,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
            do {
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent("app-result.json"), options: .atomic)
            } catch { NSLog("Picture mode report failed: %@", error.localizedDescription) }
            NSApp.terminate(nil)
        }
        let testTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            if Date().timeIntervalSince(started) > 150 {
                timer.invalidate()
                finish("Timeout: \(self.status.stringValue), case \(caseIndex), phase \(phase)")
                return
            }
            if let error = self.lastRecordingError {
                timer.invalidate()
                finish(error)
                return
            }
            let current = cases[caseIndex]
            switch phase {
            case 0:
                guard !self.awaitingFrames, self.selectedID != nil else { return }
                guard let index = self.pictureModes.firstIndex(where: { $0.identifier == current.0 }), self.audioDevice != nil else {
                    timer.invalidate()
                    finish("Required native picture mode or matching camera audio unavailable")
                    return
                }
                self.picturePicker.selectItem(at: index)
                self.picturePicker.sendAction(self.picturePicker.action, to: self.picturePicker.target)
                selectedAt = Date()
                phase = 1
            case 1:
                guard !self.awaitingFrames, self.latestVideoWidth == current.1, self.latestVideoHeight == current.2, self.recordButton.isEnabled, Date().timeIntervalSince(selectedAt) > 2 else { return }
                checks.append(["name": "preview_\(caseIndex)_\(current.0)", "passed": true, "width": self.latestVideoWidth, "height": self.latestVideoHeight])
                let displayed = self.preview.displayedVideoRect
                let displayMatches = self.preview.displayLayer.sampleBufferRenderer.status == .rendering && displayed.height > 0 && abs(displayed.width / displayed.height - CGFloat(current.1) / CGFloat(current.2)) < 0.01
                checks.append(["name": "visible_preview_ratio_\(caseIndex)", "passed": displayMatches, "displayedWidth": displayed.width, "displayedHeight": displayed.height])
                self.recordingTestURL = directory.appendingPathComponent(current.3)
                self.recordButton.performClick(nil)
                phase = 2
            case 2:
                guard let recordingStarted = self.recordingStarted, Date().timeIntervalSince(recordingStarted) > 2 else { return }
                checks.append(["name": "mode_locked_during_recording_\(caseIndex)", "passed": !self.picturePicker.isEnabled])
                checks.append(["name": "preview_stays_selected_with_audio_\(caseIndex)", "passed": self.latestVideoWidth == current.1 && self.latestVideoHeight == current.2 && Date().timeIntervalSince(self.lastFrameAt) < 3])
                self.recordButton.performClick(nil)
                phase = 3
            default:
                guard !self.recordingBusy, self.savedRecordings == caseIndex + 1 else { return }
                checks.append(["name": "saved_\(current.3)", "passed": self.lastRecording?.lastPathComponent == current.3])
                caseIndex += 1
                if caseIndex == cases.count {
                    timer.invalidate()
                    finish()
                } else { phase = 0 }
            }
        }
        RunLoop.main.add(testTimer, forMode: .common)
    }

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
                do { try previousContents.write(to: directory.appendingPathComponent("first.mov")) }
                catch { self.lastRecordingError = error.localizedDescription; return }
                self.recordingTestURL = directory.appendingPathComponent("first.mov")
                self.recordButton.performClick(nil)
                phase = 3
            case 3:
                guard let recordingStarted = self.recordingStarted, Date().timeIntervalSince(recordingStarted) > 2 else { return }
                let preserved = (try? Data(contentsOf: directory.appendingPathComponent("first.mov"))) == previousContents
                self.testChecks.append(["name": "existing_file_preserved_until_stop", "passed": preserved])
                self.testChecks.append(["name": "controls_locked_while_recording", "passed": !self.picturePicker.isEnabled && !self.mirror.isEnabled])
                self.recordButton.performClick(nil)
                phase = 4
            case 4:
                guard !self.recordingBusy, self.savedRecordings == 1 else { return }
                self.testChecks.append(["name": "first_sound_recording_saved", "passed": true])
                self.testChecks.append(["name": "preview_continues_after_stop", "passed": Date().timeIntervalSince(self.lastFrameAt) < 3])
                phase = 5
            case 5:
                guard !self.audioChanging else { return }
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
    if !CommandLine.arguments.contains("--check-ui"), !CommandLine.arguments.contains("--library-e2e"), !CommandLine.arguments.contains("--automatic-recording-e2e"),
       let identifier = Bundle.main.bundleIdentifier,
       let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: {
           $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
       }) {
        existing.activate(options: [.activateAllWindows])
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}

extension AppDelegate {
    private func runLibraryE2E() {
        guard let directory = libraryTestDirectory else { return }
        let restoring = CommandLine.arguments.contains("restore")
        let expectsPeople = !CommandLine.arguments.contains("--expect-no-people")
        let verifyPeople = !CommandLine.arguments.contains("--allow-any-scene")
        let expectsAudioInterruption = CommandLine.arguments.contains("--expect-audio-interruption")
        let verifyClock = CommandLine.arguments.contains("--verify-recording-clock")
        let verifyControls = CommandLine.arguments.contains("--verify-playback-controls")
        let verifyOffline = CommandLine.arguments.contains("--verify-offline-playback")
        let verifyDayTimeline = CommandLine.arguments.contains("--verify-day-timeline")
        let offlineSourceID = "wifi:fixture-offline-archive"
        let offlineSourceName = "Wi-Fi · 离线摄像头"
        var offlineChecked = false
        var offlinePending = false
        let started = Date()
        var phase = 0
        var checks: [[String: Any]] = []
        var clockSamples: [[String: Any]] = []
        var previousClock = -1
        var clockMonotonic = true
        var initialWallClock = ""
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        func control(_ identifier: String) -> NSView? { descendants(playback).first { $0.accessibilityIdentifier() == identifier } }
        func historyPicker() -> NSPopUpButton? {
            guard let root = window.contentView else { return nil }
            return descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "playback-camera" }
        }
        func checkOfflineSelection() {
            let picker = historyPicker()
            check("offline_camera_available", picker?.itemTitles.contains(offlineSourceName) == true)
            let networkID = self.selectedNetworkModule?.deviceID
            let generation = self.generation
            picker?.selectItem(withTitle: offlineSourceName)
            if let picker { picker.sendAction(picker.action, to: picker.target) }
            check("offline_camera_filter", self.playback.visibleRecordingCount == self.library.entries.filter { $0.sourceID == offlineSourceID }.count && self.playback.visibleRecordingCount == 1)
            check("history_selection_does_not_reconnect", self.selectedNetworkModule?.deviceID == networkID && self.generation == generation)
            self.playback.selectFirstRecording()
            let url = (self.playback.player.currentItem?.asset as? AVURLAsset)?.url
            check("offline_recording_selected", url?.lastPathComponent == self.library.entries.first(where: { $0.sourceID == offlineSourceID })?.filename)
        }
        func wallClock() -> NSTextField? { descendants(preview).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "当前时间" } }
        func elapsed() -> Int? {
            let text = self.recordingSource?.elapsedText ?? self.recordingTime.stringValue.components(separatedBy: " · ").first ?? ""
            let parts = text.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        }
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        func checkPlaybackControls() {
            guard verifyControls else { return }
            let video = descendants(self.playback).compactMap { $0 as? AVPlayerView }.first
            check("no_system_floating_controls", video.map { $0.controlsStyle == .none } == true)
            let identifiers = ["playback-play-pause", "playback-progress", "playback-volume", "playback-mute", "playback-speed", "playback-fullscreen"]
            let bottom = video.map { $0.convert($0.bounds, to: self.playback).minY } ?? -1
            check("playback_controls_fixed_below_video", identifiers.allSatisfy { id in
                guard let view = control(id), !view.isHiddenOrHasHiddenAncestor else { return false }
                return view.convert(view.bounds, to: self.playback).maxY <= bottom + 1
            })
            if let button = control("playback-play-pause") as? NSButton {
                button.performClick(nil)
                check("bottom_pause_control", self.playback.player.rate == 0)
                button.performClick(nil)
                check("bottom_play_control", self.playback.player.rate > 0)
            }
            if let video {
                func clickVideo(_ moved: Bool = false) {
                    let center = NSPoint(x: video.bounds.midX, y: video.bounds.midY)
                    let point = video.convert(center, to: nil)
                    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                    let release = NSPoint(x: point.x + (moved ? 20 : 0), y: point.y)
                    let up = NSEvent.mouseEvent(with: .leftMouseUp, location: release, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
                    video.mouseDown(with: down)
                    video.mouseUp(with: up)
                }
                clickVideo()
                check("video_single_click_pauses", self.playback.player.rate == 0)
                clickVideo()
                check("video_single_click_resumes", self.playback.player.rate > 0)
                clickVideo(true)
                check("video_drag_does_not_toggle", self.playback.player.rate > 0)
            }
            if let speed = control("playback-speed") as? NSPopUpButton {
                speed.selectItem(withTitle: "2×")
                speed.sendAction(speed.action, to: speed.target)
                check("bottom_speed_control", self.playback.player.rate == 2)
            }
            if let mute = control("playback-mute") as? NSButton {
                mute.performClick(nil)
                check("bottom_mute_control", self.playback.player.isMuted)
            }
            if let volume = control("playback-volume") as? NSSlider {
                volume.doubleValue = 0.3
                volume.sendAction(volume.action, to: volume.target)
                check("bottom_volume_control", abs(self.playback.player.volume - 0.3) < 0.01 && !self.playback.player.isMuted)
            }
        }
        func checkDayTimeline(_ done: @escaping () -> Void) {
            guard verifyDayTimeline else { done(); return }
            do {
                guard let original = self.library.entries.max(by: { $0.duration < $1.duration }) else { done(); return }
                let start = Calendar.current.startOfDay(for: Date())
                let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: start)!
                let source = "wifi:fixture-day-timeline"
                let name = "Wi-Fi · 时间轴测试"
                func copy(_ date: Date) throws -> CameraRecording {
                    let entry = CameraRecording(id: UUID().uuidString, sourceID: source, sourceName: name, startedAt: date, duration: original.duration, events: original.events, indexState: "ready")
                    try FileManager.default.copyItem(at: self.library.movieURL(original), to: self.library.movieURL(entry))
                    try JSONEncoder().encode(entry).write(to: self.library.directory.appendingPathComponent(entry.id + ".json"), options: .atomic)
                    return entry
                }
                let first = try copy(noon)
                let second = try copy(noon.addingTimeInterval(first.duration))
                let later = try copy(noon.addingTimeInterval(600))
                _ = try copy(start.addingTimeInterval(-2))
                self.library.reload()
                if let picker = historyPicker() { picker.selectItem(withTitle: name); picker.sendAction(picker.action, to: picker.target) }
                guard let axis = control("playback-progress") as? CameraDayTimeline else { check("day_timeline_available", false); done(); return }
                self.window.contentView?.layoutSubtreeIfNeeded()
                check("day_timeline_spans_view_width", axis.bounds.width >= self.playback.bounds.width * 0.9)
                check("day_timeline_covers_local_day", axis.dayStart == start && axis.dayEnd == Calendar.current.date(byAdding: .day, value: 1, to: start))
                func click(_ date: Date) {
                    axis.zoom(to: 60, around: date)
                    let point = axis.convert(NSPoint(x: axis.x(for: date), y: 36), to: nil)
                    let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                    axis.mouseDown(with: event)
                    axis.mouseUp(with: event)
                }
                func currentFile() -> String? { (self.playback.player.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent }
                if verifyPeople && expectsPeople {
                    axis.zoom(to: 60, around: noon.addingTimeInterval(15))
                    if let bitmap = axis.bitmapImageRepForCachingDisplay(in: axis.bounds) {
                        self.window.effectiveAppearance.performAsCurrentDrawingAppearance { axis.cacheDisplay(in: axis.bounds, to: bitmap) }
                        let column = Int(axis.x(for: noon.addingTimeInterval(first.duration)))
                        let orange = (0..<bitmap.pixelsHigh).contains { y in
                            guard let color = bitmap.colorAt(x: column, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                            return color.redComponent > 0.85 && color.greenComponent > 0.3 && color.greenComponent < 0.8 && color.blueComponent < 0.3
                        }
                        check("person_marker_is_dot_without_bar", !orange)
                    }
                }
                click(first.startedAt.addingTimeInterval(1))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    check("timeline_click_selects_first_file", currentFile() == first.filename)
                    check("timeline_click_seeks_file_offset", abs(self.playback.player.currentTime().seconds - 1) < 1)
                    click(second.startedAt.addingTimeInterval(0.5))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        check("timeline_click_selects_other_file", currentFile() == second.filename)
                        click(noon.addingTimeInterval(100))
                        check("timeline_gap_is_empty", self.playback.player.currentItem == nil)
                        if let play = control("playback-play-pause") as? NSButton { play.performClick(nil) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            check("play_from_gap_finds_next_recording", currentFile() == later.filename)
                            click(noon.addingTimeInterval(1200))
                            if let play = control("playback-play-pause") as? NSButton { play.performClick(nil) }
                            check("after_last_recording_does_not_rewind", self.playback.player.currentItem == nil)
                            click(first.startedAt.addingTimeInterval(first.duration - 0.3))
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                                check("playback_automatically_advances_segment", currentFile() == second.filename)
                                let position = axis.doubleValue
                                if let zoom = control("playback-zoom") as? NSSegmentedControl { zoom.selectedSegment = 2; zoom.sendAction(zoom.action, to: zoom.target) }
                                check("timeline_one_hour_zoom", abs(axis.visibleDuration - 3600) < 0.1)
                                check("zoom_preserves_playback_position", abs(axis.doubleValue - position) < 0.1)
                                if verifyPeople { check("person_markers_match_scene", !axis.personIntervals.isEmpty == expectsPeople) }
                                self.saveExperienceScreenshot(directory.appendingPathComponent("day-timeline.png"))
                                if let zoom = control("playback-zoom") as? NSSegmentedControl { zoom.selectedSegment = 0; zoom.sendAction(zoom.action, to: zoom.target) }
                                check("timeline_full_day_zoom", abs(axis.visibleDuration - axis.dayEnd.timeIntervalSince(axis.dayStart)) < 0.1)
                                self.saveExperienceScreenshot(directory.appendingPathComponent("day-timeline-full.png"))
                                done()
                            }
                        }
                    }
                }
            } catch { check("day_timeline_fixture", false); done() }
        }
        func finish(_ error: String? = nil) {
            let report: [String: Any] = ["passed": error == nil && checks.allSatisfy { $0["passed"] as? Bool == true }, "error": error ?? "", "checks": checks, "clockSamples": clockSamples]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent(restoring ? "restore-result.json" : "record-result.json"))
            NSApp.terminate(nil)
        }
        if restoring {
            library.reload()
            check("recordings_restored", library.entries.count >= 2)
            check("person_index_restored", library.entries.allSatisfy { $0.indexState == "ready" } && (!verifyPeople || library.entries.contains { !$0.events.isEmpty } == expectsPeople))
            modePicker.selectedSegment = 1
            modePicker.sendAction(modePicker.action, to: modePicker.target)
            check("restored_playback_visible", !playback.isHidden)
            if verifyOffline { checkOfflineSelection() } else { playback.selectFirstRecording() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if verifyOffline {
                    check("offline_playback_without_connection", self.selectedNetworkModule == nil && self.selectedID == nil)
                    check("offline_playback_has_no_connection_blocker", self.recordButton.title == "开始录制")
                    check("offline_date_restored", self.playback.visibleRecordingCount == 1)
                }
                check("restored_video_playable", self.playback.player.currentItem?.status == .readyToPlay)
                checkPlaybackControls()
                self.saveExperienceScreenshot(directory.appendingPathComponent("restored.png"))
                finish()
            }
            return
        }
        let addressIndex = CommandLine.arguments.firstIndex(of: "--fixture-address")!
        let deviceIndex = CommandLine.arguments.firstIndex(of: "--library-device-id")
        let deviceID = deviceIndex.map { CommandLine.arguments[$0 + 1] } ?? "fixture-manual-device"
        beginModuleConnection(CameraModuleIdentity(deviceID: deviceID, salt: "", address: CommandLine.arguments[addressIndex + 1]))
        let testTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
            if verifyClock && (phase == 1 || phase == 2) {
                if let value = elapsed() {
                    if value < previousClock { clockMonotonic = false }
                    if value != previousClock { clockSamples.append(["phase": phase, "elapsed": value, "display": self.recordingTime.stringValue]); previousClock = value }
                } else if phase == 2 { clockMonotonic = false }
            }
            if expectsAudioInterruption && Date().timeIntervalSince(started) > 12 && self.lastRecordingError == nil {
                self.recordingRequested = false
                self.stopCurrentRecording()
                timer.invalidate()
                finish("Audio interruption was not detected within 12 seconds")
                return
            }
            if expectsAudioInterruption, self.lastRecordingError != nil, !self.recordingBusy {
                check("audio_interruption_stops_recording", !self.recordingRequested)
                check("usable_recording_preserved", self.savedRecordings == 1 && self.library.entries.count == 1)
                timer.invalidate()
                finish()
                return
            }
            if Date().timeIntervalSince(started) > 120 || self.lastRecordingError != nil || self.moduleLastError != nil {
                timer.invalidate()
                finish(self.lastRecordingError ?? self.moduleLastError ?? "Timed out in phase \(phase): \(self.status.stringValue)")
                return
            }
            switch phase {
            case 0:
                guard !self.awaitingFrames, self.recordButton.isEnabled, Date().timeIntervalSince(self.lastNetworkAudioAt) < 2 else { return }
                check("wifi_recording_enabled", true)
                if verifyClock {
                    let clock = wallClock()
                    initialWallClock = clock?.stringValue ?? ""
                    check("live_wall_clock_visible", clock != nil && clock?.isHiddenOrHasHiddenAncestor == false && initialWallClock.range(of: "^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}$", options: .regularExpression) != nil)
                }
                check("no_audio_choice", !self.window.contentView!.subviews.contains { ($0 as? NSButton)?.title == "录入声音" })
                self.recordButton.performClick(nil)
                phase = 1
            case 1:
                guard self.recordingStarted != nil else { return }
                check("recording_format_locked", !self.picturePicker.isEnabled)
                self.modePicker.selectedSegment = 1
                self.modePicker.sendAction(self.modePicker.action, to: self.modePicker.target)
                check("playback_while_recording", self.recordingBusy && !self.playback.isHidden && self.preview.isHidden)
                if verifyClock { check("live_wall_clock_hidden_in_playback", wallClock()?.isHiddenOrHasHiddenAncestor == true) }
                phase = 2
            case 2:
                if verifyOffline && !offlineChecked {
                    guard !offlinePending, self.savedRecordings >= 1, let original = self.library.entries.first, original.indexState == "ready" else { return }
                    offlinePending = true
                    do {
                        let id = UUID().uuidString
                        let entry = CameraRecording(id: id, sourceID: offlineSourceID, sourceName: offlineSourceName, startedAt: Calendar.current.date(byAdding: .day, value: -1, to: original.startedAt)!, duration: original.duration, events: original.events, indexState: "ready")
                        try FileManager.default.copyItem(at: self.library.movieURL(original), to: self.library.movieURL(entry))
                        try JSONEncoder().encode(entry).write(to: self.library.directory.appendingPathComponent(id + ".json"), options: .atomic)
                        self.library.reload()
                        let currentSource = self.recordingSourceID
                        let savedBefore = self.savedRecordings
                        let generation = self.generation
                        check("history_picker_enabled_during_recording", historyPicker()?.isEnabled == true)
                        checkOfflineSelection()
                        self.saveExperienceScreenshot(directory.appendingPathComponent("offline-during-recording.png"))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
                            check("offline_video_playable", self.playback.player.currentItem?.status == .readyToPlay)
                            check("background_recording_keeps_source", self.recordingRequested && self.recordingBusy && self.recordingSourceID == currentSource && self.generation == generation)
                            check("background_segment_saved_during_offline_playback", self.savedRecordings > savedBefore)
                            check("offline_selection_survives_new_segments", historyPicker()?.titleOfSelectedItem == offlineSourceName && self.playback.visibleRecordingCount == 1)
                            if let picker = historyPicker(), let source = self.library.entries.first(where: { $0.sourceID == currentSource }) {
                                picker.selectItem(withTitle: source.sourceName)
                                picker.sendAction(picker.action, to: picker.target)
                            }
                            offlineChecked = true
                            offlinePending = false
                        }
                    } catch {
                        timer.invalidate()
                        finish(error.localizedDescription)
                    }
                    return
                }
                guard self.savedRecordings >= 1, let date = self.recordingStarted, Date().timeIntervalSince(date) > 3 else { return }
                check("automatic_segment_saved", !self.library.entries.isEmpty)
                if verifyClock {
                    check("recording_time_accumulates_across_segments", (elapsed() ?? -1) >= 6)
                    check("recording_time_does_not_reset_during_save", clockMonotonic)
                    check("live_wall_clock_updates", wallClock() != nil && wallClock()?.stringValue != initialWallClock)
                }
                self.recordButton.performClick(nil)
                phase = 3
            case 4:
                guard let date = self.recordingStarted, Date().timeIntervalSince(date) >= 2.6 else { return }
                check("new_recording_session_starts_from_zero", (elapsed() ?? 100) <= 3)
                self.recordButton.performClick(nil)
                phase = 5
            default:
                guard !self.recordingBusy, self.savedRecordings >= 2, self.library.entries.allSatisfy({ $0.indexState == "ready" }) else { return }
                if verifyClock && phase == 3 {
                    check("stopped_recording_keeps_total_time", (elapsed() ?? -1) >= 6)
                    self.recordButton.performClick(nil)
                    phase = 4
                    return
                }
                check("recordings_visible_in_playback", self.playback.visibleRecordingCount == self.library.entries.filter { $0.sourceID == self.recordingSourceID }.count)
                if verifyPeople { check("human_detection_matches_scene", self.library.entries.contains { !$0.events.isEmpty } == expectsPeople) }
                self.playback.selectFirstRecording()
                self.saveExperienceScreenshot(directory.appendingPathComponent("playback.png"))
                phase = 4
                timer.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    check("video_playable", self.playback.player.currentItem?.status == .readyToPlay)
                    checkPlaybackControls()
                    checkDayTimeline {
                        if expectsPeople && verifyPeople { check("event_button_seek", self.playback.performFirstEventJump()) }
                        self.modePicker.selectedSegment = 0
                        self.modePicker.sendAction(self.modePicker.action, to: self.modePicker.target)
                        check("live_resumes", !self.preview.isHidden && Date().timeIntervalSince(self.lastFrameAt) < 3)
                        self.saveExperienceScreenshot(directory.appendingPathComponent("live.png"))
                        finish()
                    }
                }
            }
        }
        RunLoop.main.add(testTimer, forMode: .common)
    }

    private func saveExperienceScreenshot(_ url: URL) {
        guard let root = window.contentView else { return }
        root.layoutSubtreeIfNeeded()
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        window.effectiveAppearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: bitmap) }
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}


extension AppDelegate {
    private func runAutomaticRecordingE2E(directory: URL) {
        let started = Date()
        var stopped = false
        let testTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
            let ready = self.recordingStarted.map { Date().timeIntervalSince($0) >= 2 } ?? false
            if ready && !stopped {
                self.recordButton.performClick(nil)
                stopped = true
            }
            let completed = stopped && !self.recordingBusy && self.savedRecordings == 1 && self.library.entries.count == 1
            guard completed || Date().timeIntervalSince(started) > 12 || self.lastRecordingError != nil else { return }
            let passed = completed && self.selectedNetworkModule?.deviceID == "fixture-manual-device" && !self.camera.session.isRunning && self.lastRecordingError == nil
            let report: [String: Any] = ["passed": passed, "automaticallyStarted": stopped, "savedRecordings": self.savedRecordings, "usbSessionStarted": self.camera.session.isRunning, "error": self.lastRecordingError ?? (completed ? "" : "Automatic Wi-Fi recording did not start")]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("app-result.json"))
            timer.invalidate()
            NSApp.terminate(nil)
        }
        RunLoop.main.add(testTimer, forMode: .common)
    }
}


extension AppDelegate {
    private func runRecordPreviewE2E() {
        guard let directory = libraryTestDirectory, let index = CommandLine.arguments.firstIndex(of: "--fixture-address") else { return }
        let address = CommandLine.arguments[index + 1]
        let first = "fixture-manual-device"
        let second = "fixture-preview-device"
        let started = Date()
        var phase = 0
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        func finish(_ error: String? = nil) {
            let report: [String: Any] = ["passed": error == nil && checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks, "error": error ?? "", "savedRecordings": self.savedRecordings]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("app-result.json"))
            NSApp.terminate(nil)
        }
        beginModuleConnection(CameraModuleIdentity(deviceID: first, salt: "", address: address))
        let testTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
            if self.lastRecordingError != nil || Date().timeIntervalSince(started) > 45 {
                timer.invalidate(); finish(self.lastRecordingError ?? "Timed out at phase \(phase)"); return
            }
            switch phase {
            case 0:
                guard self.recordButton.isEnabled, Date().timeIntervalSince(self.lastNetworkAudioAt) < 2 else { return }
                self.recordButton.performClick(nil); phase = 1
            case 1:
                guard let date = self.recordingStarted, Date().timeIntervalSince(date) > 0.5 else { return }
                check("live_picker_enabled_while_recording", self.picker.isEnabled)
                guard self.picker.isEnabled else { timer.invalidate(); finish(); return }
                self.picker.selectItem(withTitle: "Wi-Fi · " + second)
                self.picker.sendAction(self.picker.action, to: self.picker.target)
                phase = 2
            case 2:
                guard self.selectedNetworkModule?.deviceID == second, self.latestVideoWidth == 64, self.latestVideoHeight == 48 else { return }
                check("preview_changed_to_second_camera", true)
                check("recording_keeps_first_camera", self.recordingSources["wifi:" + first]?.isActive == true)
                check("preview_camera_not_recording_shows_start", self.recordButton.title == "开始录制")
                self.saveExperienceScreenshot(directory.appendingPathComponent("record-a-view-b.png"))
                phase = 3
            case 3:
                guard self.moduleLastError != nil, self.savedRecordings >= 1, let source = self.recordingSources["wifi:" + first], let date = source.segmentStartedAt, Date().timeIntervalSince(date) > 1.5 else { return }
                check("preview_disconnection_does_not_stop_recording", source.requested && source.isActive)
                check("segments_keep_first_camera_metadata", self.library.entries.allSatisfy { $0.sourceID == "wifi:" + first })
                self.picker.selectItem(withTitle: "Wi-Fi · " + first)
                self.picker.sendAction(self.picker.action, to: self.picker.target)
                phase = 4
            case 4:
                guard self.selectedNetworkModule?.deviceID == first, !self.awaitingFrames, self.latestVideoWidth == 512 else { return }
                check("return_to_recorded_camera_preview", self.recordingBusy && Date().timeIntervalSince(self.lastFrameAt) < 2)
                check("stop_button_targets_selected_camera", self.recordingSourceID == "wifi:" + first)
                self.recordButton.performClick(nil); phase = 5
            default:
                guard !self.recordingBusy, self.savedRecordings >= 2 else { return }
                check("stop_saves_recorded_camera", self.library.entries.allSatisfy { $0.sourceID == "wifi:" + first })
                timer.invalidate(); finish()
            }
        }
        RunLoop.main.add(testTimer, forMode: .common)
    }
}


extension AppDelegate {
    private func buildTray() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "video", accessibilityDescription: "WireCamera")
        statusItem?.button?.toolTip = "WireCamera"
        trayMenu.delegate = self
        statusItem?.menu = trayMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === trayMenu else { return }
        menu.removeAllItems()
        menu.addItem(withTitle: "打开 WireCamera", action: #selector(showMainWindow), keyEquivalent: "")
        menu.addItem(withTitle: "iPhone 连接…", action: #selector(showRemoteAccess), keyEquivalent: "")
        if !activeRecordingSources.isEmpty {
            menu.addItem(.separator())
            for source in activeRecordingSources.sorted(by: { $0.name < $1.name }) {
                let item = menu.addItem(withTitle: source.name + " · " + (source.recovering ? "等待重连" : source.elapsedText), action: nil, keyEquivalent: "")
                item.isEnabled = false
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 WireCamera", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func hideMainWindow() { window.orderOut(nil); suspendPreview() }

    private func suspendPreview() {
        guard !previewSuspended else { return }
        previewSuspended = true
        moduleNetwork.stop()
        camera.setVolume(0)
        if sourceForCamera(camera) == nil && !remoteCameras.values.contains(where: { $0 === camera }) { camera.stop() }
        preview.reset()
    }

    @objc private func showMainWindow() {
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        resumePreview()
    }

    private func resumePreview() {
        guard previewSuspended else { return }
        previewSuspended = false
        if let module = selectedNetworkModule { beginModuleConnection(CameraModuleIdentity(deviceID: module.deviceID, salt: "", address: module.address)) }
        else if let device = cameraDevices().first(where: { $0.uniqueID == selectedID }) { startCamera(device) }
    }

    func windowWillMiniaturize(_ notification: Notification) { suspendPreview() }
    func windowDidDeminiaturize(_ notification: Notification) { resumePreview() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMainWindow(); return true }

    private func runBackgroundE2E(directory: URL) {
        var phase = 0
        let testTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
            guard let source = self.recordingSource, source.requested else { return }
            if phase == 0 {
                guard source.segmentStartedAt != nil else { return }
                self.window.performClose(nil); phase = 1
            } else if phase == 1 {
                guard source.savedCount >= 1 else { return }
                let report: [String: Any] = ["hidden": !self.window.isVisible && self.previewSuspended, "recording": source.requested, "savedCount": source.savedCount]
                try? JSONSerialization.data(withJSONObject: report).write(to: directory.appendingPathComponent("background-state.json"))
                phase = 2
            } else if FileManager.default.fileExists(atPath: directory.appendingPathComponent("reopen-request").path) {
                self.showMainWindow()
                let report: [String: Any] = ["visible": self.window.isVisible && !self.previewSuspended, "recording": source.requested]
                try? JSONSerialization.data(withJSONObject: report).write(to: directory.appendingPathComponent("reopened-state.json"))
                timer.invalidate()
            }
        }
        RunLoop.main.add(testTimer, forMode: .common)
    }

    private func runRecordingRecoveryE2E() {
        guard let directory = libraryTestDirectory, let index = CommandLine.arguments.firstIndex(of: "--fixture-address") else { return }
        let first = "fixture-manual-device", second = "fixture-preview-device"
        let firstID = "wifi:" + first, secondID = "wifi:" + second
        let outage = directory.appendingPathComponent("second-offline")
        let started = Date()
        var phase = 0
        var changedAt = Date()
        var frozen: Double = 0
        var firstCount = 0
        var stoppedCount = 0
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        func choose(_ id: String) { self.picker.selectItem(withTitle: "Wi-Fi · " + id); self.picker.sendAction(self.picker.action, to: self.picker.target) }
        func finish(_ error: String? = nil) {
            let report: [String: Any] = ["passed": error == nil && checks.allSatisfy { $0["passed"] as? Bool == true }, "error": error ?? "", "checks": checks, "firstCameraFiles": self.library.entries.filter { $0.sourceID == firstID }.count, "secondCameraFiles": self.library.entries.filter { $0.sourceID == secondID }.count]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("app-result.json"))
        }
        beginModuleConnection(CameraModuleIdentity(deviceID: first, salt: "", address: CommandLine.arguments[index + 1]))
        let testTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
            let a = self.recordingSources[firstID], b = self.recordingSources[secondID]
            if Date().timeIntervalSince(started) > 75 || a?.lastError != nil { timer.invalidate(); finish(a?.lastError ?? "Timed out at phase \(phase)"); NSApp.terminate(nil); return }
            switch phase {
            case 0:
                guard self.recordButton.isEnabled, Date().timeIntervalSince(self.lastNetworkAudioAt) < 2 else { return }
                self.recordButton.performClick(nil); phase = 1
            case 1:
                guard a?.segmentStartedAt != nil else { return }
                choose(second); phase = 2
            case 2:
                guard !self.awaitingFrames, Date().timeIntervalSince(self.lastNetworkAudioAt) < 2 else { return }
                self.recordButton.performClick(nil); phase = 3
            case 3:
                guard b?.segmentStartedAt != nil, (a?.savedCount ?? 0) >= 1 else { return }
                try? Data().write(to: outage)
                changedAt = Date(); choose(first); phase = 4
            case 4:
                guard let b, !b.busy, !b.finishing, b.lastError != nil else { return }
                check("power_loss_preserves_recording_intent", b.requested)
                if !b.requested { timer.invalidate(); finish("Recording intent was cleared on power loss"); NSApp.terminate(nil); return }
                frozen = b.elapsedSeconds; firstCount = a?.savedCount ?? 0; phase = 5
            case 5:
                guard Date().timeIntervalSince(changedAt) > 5 else { return }
                check("outage_does_not_count_as_recording_time", abs((b?.elapsedSeconds ?? -10) - frozen) < 0.5)
                check("other_camera_records_during_outage", (a?.savedCount ?? 0) > firstCount)
                try? FileManager.default.removeItem(at: outage)
                phase = 6
            case 6:
                guard let b, b.segmentStartedAt != nil, b.savedCount >= 2 else { return }
                check("power_restoration_resumes_automatically", b.requested && b.lastError == nil)
                check("recovery_keeps_cumulative_clock", b.elapsedSeconds >= frozen)
                self.saveExperienceScreenshot(directory.appendingPathComponent("recovered-recording.png"))
                try? Data().write(to: outage)
                choose(second); phase = 7
            case 7:
                guard let b, !b.busy, !b.finishing, b.lastError != nil else { return }
                check("stop_remains_available_while_offline", self.recordButton.title == "停止录制" && self.recordButton.isEnabled)
                self.recordButton.performClick(nil)
                stoppedCount = b.savedCount; changedAt = Date()
                try? FileManager.default.removeItem(at: outage)
                phase = 8
            default:
                guard Date().timeIntervalSince(changedAt) > 6 else { return }
                check("manual_stop_cancels_automatic_recovery", b?.isActive == false && b?.savedCount == stoppedCount)
                check("other_camera_still_records", a?.requested == true)
                self.terminationTestCompletion = { errors in check("quit_cancels_retries_and_saves_tail", errors.isEmpty); finish(errors.isEmpty ? nil : errors.joined(separator: "\n")) }
                timer.invalidate(); NSApp.terminate(nil)
            }
        }
        RunLoop.main.add(testTimer, forMode: .common)
    }
}

extension AppDelegate {
    @objc private func showRemoteAccess() { remotePanel.show(settings: remoteIdentity.settings, status: remoteState) }

    private func configureRemoteAccess() {
        remoteMedia.onPacket = { [weak self] data, kind, sourceID in self?.remoteServer.publish(data, kind: kind, sourceID: sourceID) }
        remoteServer.onCameras = { [weak self] in self?.remoteDevices() ?? [] }
        remoteServer.onRecordings = { [weak self] in self?.library.entries ?? [] }
        remoteServer.onMovieURL = { [weak self] entry in
            guard let self else { return nil }
            let movie = self.library.movieURL(entry).resolvingSymlinksInPath()
            guard movie.deletingLastPathComponent() == self.library.directory.resolvingSymlinksInPath() else { return nil }
            return movie
        }
        remoteServer.onViewersChanged = { [weak self] sources in
            guard let self else { return }
            self.remoteViewers = sources
            self.remoteMedia.setViewers(sources)
            self.refreshRemoteFeeds()
        }
        remoteServer.onState = { [weak self] message in self?.remoteState = message }
        remotePanel.onChange = { [weak self] settings in
            guard let self else { return }
            do {
                try self.remoteIdentity.save(settings)
                self.remoteServer.stop()
                if settings.enabled { self.startRemoteAccess(showPanel: true) }
                else { self.remoteState = "手机连接已关闭。"; self.showRemoteAccess() }
            } catch { self.remoteState = error.localizedDescription; self.showRemoteAccess() }
        }
        if CommandLine.arguments.contains("--remote-server-test") {
            window.title = "WireCamera Test"
            var settings = remoteIdentity.settings
            settings.enabled = true; settings.port = 0
            do { try remoteIdentity.save(settings) } catch { NSLog("Remote test setup failed: %@", error.localizedDescription); return }
        }
        if CommandLine.arguments.contains("--enable-remote") {
            var settings = remoteIdentity.settings
            settings.enabled = true
            do { try remoteIdentity.save(settings) } catch { remoteState = error.localizedDescription; return }
        }
        if remoteIdentity.settings.enabled { startRemoteAccess() }
    }

    private func startRemoteAccess(showPanel: Bool = false) {
        do {
            try remoteServer.start(identity: remoteIdentity) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let port):
                    self.remoteState = "已开启加密连接。手机与 Mac 连接同一局域网后，扫描二维码或输入地址与密码。"
                    if let index = CommandLine.arguments.firstIndex(of: "--remote-server-test"), CommandLine.arguments.indices.contains(index + 1) {
                        let report: [String: Any] = ["port": port, "password": self.remoteIdentity.settings.password, "fingerprint": self.remoteIdentity.fingerprint]
                        try? JSONSerialization.data(withJSONObject: report).write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]).appendingPathComponent("server-ready.json"))
                        if CommandLine.arguments.contains("--verify-background") { self.runBackgroundE2E(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
                    }
                case .failure(let error): self.remoteState = "连接服务未能开启：" + error.localizedDescription
                }
                if showPanel { self.showRemoteAccess() }
            }
        } catch { remoteState = error.localizedDescription; NSLog("Remote service setup failed: %@", error.localizedDescription); if showPanel { showRemoteAccess() } }
    }

    private func remoteDevices() -> [CameraRemoteDevice] {
        var values: [String: CameraRemoteDevice] = [:]
        for entry in library.entries { values[entry.sourceID] = CameraRemoteDevice(id: entry.sourceID, name: entry.sourceName, online: false, recording: false) }
        for module in networkModules {
            let id = "wifi:" + module.deviceID
            values[id] = CameraRemoteDevice(id: id, name: "Wi-Fi · " + module.deviceID, online: true, recording: recordingSources[id]?.isActive ?? false)
        }
        for device in cameraDevices() {
            let id = "usb:" + device.uniqueID
            values[id] = CameraRemoteDevice(id: id, name: device.localizedName, online: true, recording: recordingSources[id]?.isActive ?? false)
        }
        return values.values.sorted { $0.id < $1.id }
    }

    private func refreshRemoteFeeds() {
        for id in Array(remoteNetworks.keys) where !remoteViewers.contains(id) || recordingSources[id]?.isActive == true {
            remoteNetworks.removeValue(forKey: id)?.stop()
        }
        for id in Array(remoteCameras.keys) where !remoteViewers.contains(id) {
            guard let controller = remoteCameras.removeValue(forKey: id) else { continue }
            controller.setForwardingAudio(nil)
            if controller !== camera, sourceForCamera(controller) == nil { controller.stop() }
        }
        for id in remoteViewers where id.hasPrefix("wifi:") && remoteNetworks[id] == nil && recordingSources[id]?.isActive != true {
            guard let module = networkModules.first(where: { "wifi:" + $0.deviceID == id }) else { continue }
            let network = CameraModuleNetwork()
            remoteNetworks[id] = network
            network.onSampleBuffer = { [weak self] sample in self?.remoteMedia.video(sample, sourceID: id, mirrored: false) }
            network.onAudioSampleBuffer = { [weak self] sample in self?.remoteMedia.audio(sample, sourceID: id) }
            network.onError = { [weak self, weak network] message in
                guard let self, let network, self.remoteNetworks[id] === network else { return }
                self.remoteServer.publish(Data(message.utf8), kind: 3, sourceID: id)
            }
            network.connect(identity: CameraModuleIdentity(deviceID: module.deviceID, salt: "", address: module.address)) { [weak self] result in
                if case .failure(let error) = result { self?.remoteServer.publish(Data(error.localizedDescription.utf8), kind: 3, sourceID: id) }
            }
        }
        for id in remoteViewers where id.hasPrefix("usb:") && remoteCameras[id] == nil {
            guard let device = cameraDevices().first(where: { "usb:" + $0.uniqueID == id }) else { continue }
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                if !remoteVideoPermissionPending {
                    remoteVideoPermissionPending = true
                    AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in DispatchQueue.main.async { self?.remoteVideoPermissionPending = false; self?.refreshRemoteFeeds() } }
                }
                continue
            }
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { remoteServer.publish(Data("请在 Mac 的系统设置中允许 WireCamera 访问摄像头，再重新连接。".utf8), kind: 3, sourceID: id); continue }
            let existing = recordingSources[id]?.isActive == true ? recordingSources[id]?.camera : (camera.deviceID == device.uniqueID && selectedNetworkModule == nil && !previewSuspended ? camera : nil)
            let controller = existing ?? CameraController()
            remoteCameras[id] = controller
            if existing == nil { bindCamera(controller); controller.start(device: device, format: CameraPictureMode.available(for: device).first?.format) { [weak self] error in if let error { self?.remoteServer.publish(Data(error.utf8), kind: 3, sourceID: id) } } }
            audioPermission { [weak self, weak controller] allowed in
                guard self?.remoteViewers.contains(id) == true else { return }
                if allowed { controller?.setForwardingAudio(cameraAudioDevice(for: device)) }
            }
        }
    }
}

extension AppDelegate {
    private func runMultiRecordingE2E() {
        guard let directory = libraryTestDirectory, let index = CommandLine.arguments.firstIndex(of: "--fixture-address") else { return }
        let address = CommandLine.arguments[index + 1]
        let first = "fixture-manual-device", second = "fixture-preview-device"
        let firstID = "wifi:" + first, secondID = "wifi:" + second
        let expectsDrop = CommandLine.arguments.contains("--expect-second-drop")
        let started = Date()
        var phase = 0
        var checks: [[String: Any]] = []
        var stoppedAt = Date()
        var stoppedCount = 0
        var firstClock: TimeInterval?
        var restartChecked = false
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        func count(_ id: String) -> Int { self.library.entries.filter { $0.sourceID == id }.count }
        func choose(_ id: String) { self.picker.selectItem(withTitle: "Wi-Fi · " + id); self.picker.sendAction(self.picker.action, to: self.picker.target) }
        func finish(_ error: String? = nil) {
            let report: [String: Any] = ["passed": error == nil && checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks, "error": error ?? "", "firstCameraFiles": count(firstID), "secondCameraFiles": count(secondID)]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("app-result.json"))
        }
        beginModuleConnection(CameraModuleIdentity(deviceID: first, salt: "", address: address))
        let testTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
            let a = self.recordingSources[firstID], b = self.recordingSources[secondID]
            if Date().timeIntervalSince(started) > 75 || a?.lastError != nil || (!expectsDrop && b?.lastError != nil) {
                timer.invalidate(); finish(a?.lastError ?? b?.lastError ?? "Timed out at phase \(phase)"); NSApp.terminate(nil); return
            }
            switch phase {
            case 0:
                guard self.recordButton.isEnabled, Date().timeIntervalSince(self.lastNetworkAudioAt) < 2 else { return }
                self.recordButton.performClick(nil); phase = 1
            case 1:
                guard let a, a.segmentStartedAt != nil else { return }
                check("first_camera_shows_stop", self.recordButton.title == "停止录制")
                firstClock = a.sessionStartedUptime
                choose(second); phase = 2
            case 2:
                guard self.selectedNetworkModule?.deviceID == second, !self.awaitingFrames, Date().timeIntervalSince(self.lastNetworkAudioAt) < 2 else { return }
                check("idle_camera_shows_start", self.recordButton.title == "开始录制")
                self.recordButton.performClick(nil); phase = 3
            case 3:
                guard let a, let b, a.savedCount >= 1, b.savedCount >= 1 else { return }
                check("both_cameras_save_their_own_segments", count(firstID) >= 1 && count(secondID) >= 1)
                check("first_clock_not_reset_by_second_camera", a.sessionStartedUptime == firstClock)
                if expectsDrop {
                    guard b.lastError != nil, !b.isActive else { return }
                    check("second_camera_failure_is_isolated", a.isActive && a.requested)
                } else {
                    guard let date = b.segmentStartedAt, Date().timeIntervalSince(date) > 0.7 else { return }
                    check("two_cameras_record_simultaneously", a.isActive && b.isActive)
                    self.saveExperienceScreenshot(directory.appendingPathComponent("both-recording.png"))
                    self.recordButton.performClick(nil)
                }
                stoppedAt = Date(); phase = 4
            case 4:
                guard let a, let b, !b.isActive else { return }
                stoppedCount = count(secondID)
                check("stopped_camera_shows_start", self.recordButton.title == "开始录制")
                check("stopping_second_does_not_stop_first", a.isActive && a.requested)
                phase = 5
            case 5:
                guard self.library.entries.contains(where: { $0.sourceID == firstID && $0.startedAt > stoppedAt && $0.duration > 1 }) else { return }
                check("first_camera_saves_new_segment_after_second_stops", true)
                check("stopped_camera_does_not_create_more_segments", count(secondID) == stoppedCount)
                choose(first); phase = 6
            case 6:
                guard !self.awaitingFrames, self.latestVideoWidth == 512 else { return }
                check("switching_back_shows_first_camera_stop", self.recordButton.title == "停止录制")
                check("first_camera_clock_kept_running", (a?.elapsedSeconds ?? 0) > (b?.elapsedSeconds ?? 0))
                choose(second); phase = 7
            case 7:
                guard !self.awaitingFrames, Date().timeIntervalSince(self.lastNetworkAudioAt) < 2 else { return }
                check("second_camera_can_restart_independently", self.recordButton.title == "开始录制")
                self.recordButton.performClick(nil); phase = 8
            default:
                guard let a, let b, let aDate = a.segmentStartedAt, let bDate = b.segmentStartedAt else { return }
                if !restartChecked {
                    check("restarting_second_resets_only_its_clock", b.elapsedSeconds < 2 && a.sessionStartedUptime == firstClock)
                    restartChecked = true
                }
                let ageA = Date().timeIntervalSince(aDate), ageB = Date().timeIntervalSince(bDate)
                guard ageA > 0.8 && ageA < 3.3 && ageB > 1.3 && ageB < 3.3 else { return }
                let quittingAt = Date()
                self.terminationTestCompletion = { errors in
                    check("quit_waits_for_all_recordings", !self.recordingSources.values.contains(where: { $0.isActive }))
                    check("quit_saves_without_errors", errors.isEmpty)
                    for id in [firstID, secondID] {
                        let end = self.library.entries.filter { $0.sourceID == id }.map { $0.startedAt.addingTimeInterval($0.duration) }.max() ?? .distantPast
                        check("quit_preserves_tail_" + id, end.timeIntervalSince(quittingAt) > -2)
                    }
                    finish(errors.isEmpty ? nil : errors.joined(separator: "\n"))
                }
                timer.invalidate(); NSApp.terminate(nil)
            }
        }
        RunLoop.main.add(testTimer, forMode: .common)
    }
}
