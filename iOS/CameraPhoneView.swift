import AVFoundation
import SwiftUI
import VisionKit

struct CameraPhoneView: View {
    @StateObject private var model = CameraPhoneModel()
    @StateObject private var discovery = CameraPhoneDiscovery()
    @Environment(\.scenePhase) private var scenePhase
    @State private var scanning = false
    @State private var settings = false
    @State private var fullscreen = false
    @State private var choosingCamera = false

    var body: some View {
        NavigationStack {
            Group {
                if model.connected { connectedView }
                else { connectionView }
            }
            .navigationTitle("WireCamera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.connected { ToolbarItem(placement: .topBarTrailing) { Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("连接设置") } }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.cyan)
        .task {
            discovery.start()
            if CommandLine.arguments.contains("--reset-test-connections") { CameraRemoteKeychain.remove() }
            await model.restore()
        }
        .onChange(of: scenePhase) { _, value in
            if value == .background { model.setActive(false) }
            else if value == .active { model.setActive(true) }
        }
        .onOpenURL { url in _ = model.applyPairingURL(url) }
        .sheet(isPresented: $scanning) {
            NavigationStack {
                CameraPhoneScanner { value in
                    guard let url = URL(string: value), model.applyPairingURL(url) else { return }
                    scanning = false
                }
                .ignoresSafeArea()
                .navigationTitle("扫描 Mac 二维码")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { scanning = false } } }
            }
        }
        .sheet(isPresented: $settings) {
            NavigationStack {
                Form {
                    LabeledContent("Mac", value: model.host + ":" + model.port)
                    Button("断开连接") { settings = false; model.disconnect() }
                    Button("忘记这台 Mac", role: .destructive) { settings = false; model.forgetCurrentNode() }
                }
                .navigationTitle("连接设置")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { settings = false } } }
            }.presentationDetents([.medium])
        }
        .sheet(isPresented: $choosingCamera) {
            NavigationStack {
                List { cameraChoices }
                    .navigationTitle("摄像头")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { choosingCamera = false } } }
            }.presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $fullscreen) {
            VStack(spacing: 0) {
                HStack { Button { fullscreen = false } label: { Image(systemName: "xmark") }.accessibilityLabel("退出全屏"); Spacer() }.padding()
                Spacer(minLength: 0)
                video
                Spacer(minLength: 0)
                controls.padding()
            }.background(.black).preferredColorScheme(.dark)
        }
    }

    private var connectionView: some View {
        Form {
            if !model.savedNodes.isEmpty {
                Section("已保存的 Mac") {
                    ForEach(model.savedNodes) { node in
                        Button { model.useSavedNode(node) } label: { Label(node.host + ":" + String(node.port), systemImage: "desktopcomputer") }
                    }
                }
            }
            if !discovery.servers.isEmpty {
                Section("附近的 Mac") {
                    ForEach(discovery.servers) { server in
                        Button {
                            if let saved = model.savedNodes.first(where: { $0.host.lowercased() == server.host.lowercased() && $0.port == server.port }) { model.useSavedNode(saved) }
                            else { model.host = server.host; model.port = String(server.port); model.password = "" }
                        } label: {
                            HStack { Image(systemName: "desktopcomputer"); Text(server.name); Spacer(); if model.host == server.host { Image(systemName: "checkmark") } }
                        }
                    }
                }
            }
            Section {
                TextField("Mac 地址", text: $model.host).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Mac 地址")
                TextField("端口", text: $model.port).keyboardType(.numberPad).accessibilityLabel("端口")
                SecureField("连接密码", text: $model.password).textContentType(.password).accessibilityLabel("连接密码")
                Button { model.connect() } label: { HStack { Text("连接 Mac"); Spacer(); if model.connecting { ProgressView() } } }.disabled(model.connecting || model.host.isEmpty || model.password.isEmpty)
            } header: { Text("Mac 连接") } footer: { Text("在 Mac 的 WireCamera 菜单中打开「iPhone 连接」。") }
            if DataScannerViewController.isSupported {
                Section { Button { scanning = true } label: { Label("扫描 Mac 二维码", systemImage: "qrcode.viewfinder") } }
            }
            if let error = model.error { Section { Text(error).foregroundStyle(.orange) } }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var connectedView: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760
            ScrollView {
                VStack(spacing: 18) {
                    Picker("模式", selection: $model.playbackMode) { Text("实时").tag(false); Text("回放").tag(true) }.pickerStyle(.segmented)
                        .onChange(of: model.playbackMode) { _, _ in model.changeMode() }
                    if wide {
                        let videoHeight = max(180, geometry.size.height - (model.playbackMode ? 260 : 160))
                        HStack(alignment: .top, spacing: 24) {
                            VStack(spacing: 18) {
                                if model.playbackMode { cameraButton.frame(maxWidth: .infinity, alignment: .leading) }
                                video.frame(height: videoHeight).clipShape(RoundedRectangle(cornerRadius: 12))
                                controls
                            }.frame(maxWidth: .infinity)
                            VStack(alignment: .leading, spacing: 18) {
                                if model.playbackMode { datePicker; personList }
                                else { cameraChoices }
                            }.frame(width: model.playbackMode ? min(200, geometry.size.width * 0.22) : min(300, geometry.size.width * 0.32)).frame(maxHeight: videoHeight + 50, alignment: .top)
                        }
                        if model.playbackMode { CameraPhoneTimeline(model: model, showsEvents: false) }
                    } else {
                        HStack { cameraButton; Spacer(minLength: 4); if model.playbackMode { datePicker } }
                        video.aspectRatio(4 / 3, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                        controls
                        if model.playbackMode { playbackTimeline }
                    }
                    if let error = model.error { Text(error).font(.footnote).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading) }
                }.padding(20)
            }
            .refreshable { do { try await model.refresh() } catch { model.error = error.localizedDescription } }
            .accessibilityIdentifier(wide ? "展开布局" : "折叠布局")
        }
        .background(Color(red: 0.055, green: 0.065, blue: 0.08))
    }

    private var cameraButton: some View {
        Button { choosingCamera = true } label: {
            HStack(spacing: 8) {
                if model.selectedCamera?.recording == true { Circle().fill(.red).frame(width: 7, height: 7) }
                Text(model.selectedCamera?.name ?? "选择摄像头").lineLimit(1)
                Image(systemName: "chevron.down").font(.caption)
            }
        }.accessibilityLabel("选择摄像头")
    }

    private var cameraChoices: some View {
        ForEach(model.cameras) { camera in
            Button { model.selectCamera(camera.id); choosingCamera = false } label: {
                HStack(spacing: 10) {
                    Image(systemName: camera.online ? "video" : "video.slash").foregroundStyle(.secondary)
                    Text(camera.name).font(.subheadline).lineLimit(2)
                    Spacer(minLength: 0)
                    if camera.recording { Circle().fill(.red).frame(width: 7, height: 7) }
                    if model.selectedID == camera.id { Image(systemName: "checkmark") }
                }.padding(.vertical, 10)
            }.accessibilityLabel(camera.name)
        }
    }

    private var datePicker: some View { DatePicker("日期", selection: $model.date, displayedComponents: .date).labelsHidden().onChange(of: model.date) { _, _ in model.selectDate() } }

    @ViewBuilder private var playbackTimeline: some View {
        if model.day.recordings.isEmpty { ContentUnavailableView("当天没有录像", systemImage: "film", description: Text("选择其他日期或摄像头。")) }
        else { CameraPhoneTimeline(model: model) }
    }

    private var personList: some View {
        VStack(spacing: 10) {
            CameraPhoneEventFilter(model: model)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.activityEvents.isEmpty { Text("没有匹配的活动").font(.footnote).foregroundStyle(.secondary).padding(.vertical) }
                    ForEach(model.activityEvents, id: \.start) { event in
                        Button { model.seek(event.start) } label: {
                            HStack(spacing: 10) {
                                Circle().fill(event.isPerson ? .orange : .purple).frame(width: 7, height: 7)
                                Text(event.start, format: .dateTime.hour().minute().second()).monospacedDigit()
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }.padding(12).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }.foregroundStyle(.white).accessibilityLabel(event.label + "，" + event.start.formatted(date: .omitted, time: .standard))
                    }
                }
            }.accessibilityLabel("活动列表")
        }
    }

    private var video: some View {
        ZStack {
            Color.black
            if model.playbackMode { CameraPhonePlayer(player: model.player) }
            else if let image = model.image { Image(uiImage: image).resizable().scaledToFit() }
            if model.loading { ProgressView().tint(.white) }
            if !model.playbackMode, let error = model.liveError {
                VStack(spacing: 16) {
                    Image(systemName: "video.slash").font(.title)
                    Text(error).font(.footnote).multilineTextAlignment(.center)
                    Button("重新连接") { model.startLive() }.buttonStyle(.bordered)
                }.padding(24).foregroundStyle(.secondary)
            }
            if !model.playbackMode, model.image != nil {
                VStack {
                    HStack {
                        TimelineView(.periodic(from: .now, by: 1)) { context in Text(context.date, format: .dateTime.year().month().day().hour().minute().second()).font(.caption.monospacedDigit()).padding(8).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6)) }
                        Spacer()
                    }
                    Spacer()
                }.padding(10).allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if model.playbackMode { model.togglePlayback() } }
        .accessibilityLabel(model.playbackMode ? "回放画面" : "实时画面")
        .accessibilityValue(model.playing ? "正在播放" : "等待画面")
        .accessibilityAddTraits(model.playbackMode ? .isButton : .isImage)
        .accessibilityAction { if model.playbackMode { model.togglePlayback() } }
    }

    private var controls: some View {
        HStack(spacing: 28) {
            if model.playbackMode { Button { model.togglePlayback() } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 24) }.accessibilityLabel(model.playing ? "暂停" : "播放") }
            Button { model.toggleMute() } label: { Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 24) }.accessibilityLabel(model.muted ? "开启声音" : "静音")
            if model.playbackMode {
                Button { model.nextEvent() } label: { HStack(spacing: 6) { Image(systemName: "forward.end.fill"); Text("下一个活动").font(.footnote) } }.disabled(model.activityEvents.isEmpty)
            }
            Spacer(minLength: 0)
            Button { fullscreen.toggle() } label: { Image(systemName: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }.accessibilityLabel(fullscreen ? "退出全屏" : "全屏")
        }.font(.title3).foregroundStyle(.white)
    }
}

private final class CameraPhonePlayerSurface: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
}

private struct CameraPhonePlayer: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> CameraPhonePlayerSurface {
        let view = CameraPhonePlayerSurface()
        (view.layer as? AVPlayerLayer)?.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ view: CameraPhonePlayerSurface, context: Context) { (view.layer as? AVPlayerLayer)?.player = player }
}

private struct CameraPhoneScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { controller.stopScanning() }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems { if case .barcode(let code) = item, let value = code.payloadStringValue { onCode(value) } }
        }
        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) { if case .barcode(let code) = item, let value = code.payloadStringValue { onCode(value) } }
    }
}
