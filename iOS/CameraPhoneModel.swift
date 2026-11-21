import AVFoundation
import Combine
import Foundation
import UIKit

@MainActor
final class CameraPhoneModel: ObservableObject {
    @Published var host = ""
    @Published var port = "48760"
    @Published var password = ""
    @Published var connected = false
    @Published var savedNodes: [CameraRemoteCredentials] = []
    @Published var connecting = false
    @Published var error: String?
    @Published var cameras: [CameraRemoteDevice] = []
    @Published var recordings: [CameraRecording] = []
    @Published var selectedID = ""
    @Published var playbackMode = false
    @Published var date = Date()
    @Published var cursor = Date()
    @Published var image: UIImage?
    @Published var liveError: String?
    @Published var loading = false
    @Published var playing = false
    @Published var muted = false
    @Published var timelineSpan = 86400.0
    let player = AVQueuePlayer()
    private var client: CameraRemoteClient?
    private var stream: CameraLiveStream?
    private var loadTask: Task<Void, Never>?
    private var nextTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var generation = UUID()
    private var itemEntries: [ObjectIdentifier: CameraRecording] = [:]
    private var itemObserver: NSKeyValueObservation?
    private var timeObserver: Any?
    private var currentRecording: CameraRecording?
    private var lastImageAt = Date()
    private var active = true

    var selectedCamera: CameraRemoteDevice? { cameras.first { $0.id == selectedID } }
    var day: CameraPlaybackDay { CameraPlaybackDay(date: date, recordings: recordings.filter { $0.sourceID == selectedID }) }
    var availableDates: [Date] { CameraPlaybackDay.availableDates(recordings: recordings.filter { $0.sourceID == selectedID }) }

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                if let item = self.player.currentItem, let recording = self.itemEntries[ObjectIdentifier(item)], time.seconds.isFinite { self.cursor = recording.startedAt.addingTimeInterval(time.seconds) }
                self.playing = self.player.rate > 0
            }
        }
        itemObserver = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, let item = player.currentItem, let recording = self.itemEntries[ObjectIdentifier(item)] else { return }
                self.currentRecording = recording
                self.queueNext(after: recording)
            }
        }
    }

    func restore() async {
        savedNodes = CameraRemoteKeychain.loadAll()
        guard let saved = CameraRemoteKeychain.load() else { return }
        await useNode(saved)
    }

    func useSavedNode(_ saved: CameraRemoteCredentials) { Task { await useNode(saved) } }

    private func useNode(_ saved: CameraRemoteCredentials) async {
        guard !connecting else { return }
        host = saved.host; port = String(saved.port)
        stopLive(); clearPlayback()
        self.client?.close()
        let client = CameraRemoteClient(credentials: saved)
        self.client = client
        connecting = true
        do {
            do { try await refresh() }
            catch CameraRemoteFailure.expired {
                guard let password = saved.password else { throw CameraRemoteFailure.expired }
                client.close()
                self.client = try await CameraRemoteClient.pair(host: saved.host, port: saved.port, password: password, fingerprint: saved.fingerprint)
                try await refresh()
            }
            if let credentials = self.client?.credentials { try CameraRemoteKeychain.save(credentials) }
            savedNodes = CameraRemoteKeychain.loadAll()
            connected = true; error = nil; startRefreshLoop(); startLive()
        }
        catch { self.error = "无法连接 Mac：" + error.localizedDescription; self.client?.close(); self.client = nil }
        connecting = false
    }

    func connect() {
        guard !connecting else { return }
        connecting = true; error = nil
        Task {
            do {
                let client = try await CameraRemoteClient.pair(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: Int(port) ?? 0, password: password)
                self.client?.close(); self.client = client
                try await refresh()
                do { try CameraRemoteKeychain.save(client.credentials) } catch { self.error = error.localizedDescription }
                savedNodes = CameraRemoteKeychain.loadAll()
                password = ""; connected = true
                startRefreshLoop(); startLive()
            } catch { self.error = error.localizedDescription }
            connecting = false
        }
    }

    func disconnect() {
        stopLive(); clearPlayback(); refreshTask?.cancel(); refreshTask = nil
        client?.close(); client = nil
        connected = false; cameras = []; recordings = []; selectedID = ""; error = nil
        savedNodes = CameraRemoteKeychain.loadAll()
    }

    func forgetCurrentNode() {
        let id = client?.credentials.id ?? host.lowercased() + ":" + port
        do { try CameraRemoteKeychain.forget(id); disconnect() } catch { self.error = error.localizedDescription }
    }

    func refresh() async throws {
        guard let client else { return }
        async let devices: [CameraRemoteDevice] = client.fetch("/v1/cameras")
        async let movies: [CameraRecording] = client.fetch("/v1/recordings")
        let result = try await (devices, movies)
        cameras = result.0; recordings = result.1
        if !cameras.contains(where: { $0.id == selectedID }) { selectedID = cameras.first(where: { $0.recording })?.id ?? cameras.first(where: { $0.online })?.id ?? cameras.first?.id ?? "" }
    }

    func selectCamera(_ id: String) {
        selectedID = id; error = nil; image = nil
        clearPlayback(); stopLive()
        if playbackMode { date = availableDates.first ?? Date(); selectDate() } else { startLive() }
    }

    func changeMode() {
        error = nil
        if playbackMode { stopLive(); date = availableDates.first ?? Date(); selectDate() }
        else { clearPlayback(); startLive() }
    }

    func selectDate() {
        clearPlayback()
        cursor = day.recordings.first?.startedAt ?? day.interval.start
        if let first = day.recordings.first { play(first, offset: 0) }
    }

    func seek(_ target: Date) {
        if let position = day.position(at: target, snapForward: true) { play(position.recording, offset: position.offset) }
        else { cursor = target; error = "这个时间之后没有已保存的录像。" }
    }

    func nextPerson() {
        if let event = day.personIntervals.first(where: { $0.start > cursor.addingTimeInterval(1) }) { seek(event.start) }
        else if let first = day.personIntervals.first { seek(first.start) }
    }

    func togglePlayback() {
        if playbackMode {
            if player.rate > 0 { player.pause(); playing = false }
            else if player.currentItem != nil { player.play(); playing = true }
        } else if stream != nil { stopLive() }
        else { startLive() }
    }

    func toggleMute() { muted.toggle(); stream?.setMuted(muted); player.isMuted = muted }

    func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        if !value { stopLive(); player.pause(); playing = false }
        else if connected && !playbackMode { startLive() }
    }

    func applyPairingURL(_ url: URL) -> Bool {
        guard url.scheme == "wirecamera", url.host == "pair", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.queryItems?.first(where: { $0.name == "host" })?.value,
              let port = components.queryItems?.first(where: { $0.name == "port" })?.value,
              let password = components.queryItems?.first(where: { $0.name == "password" })?.value else { return false }
        self.host = host; self.port = port; self.password = password
        connect()
        return true
    }

    func startLive() {
        stopLive()
        guard active, !playbackMode, let client, selectedCamera?.online == true else { liveError = selectedCamera == nil ? "暂无摄像头" : "摄像头离线，可以在回放中查看录像。"; return }
        image = nil; liveError = nil; loading = true; lastImageAt = Date()
        let stream = CameraLiveStream(fingerprint: client.credentials.fingerprint)
        let id = selectedID
        stream.onImage = { [weak self, weak stream] image in
            Task { @MainActor in
                guard let self, let stream, self.stream === stream, self.selectedID == id else { return }
                self.image = image; self.lastImageAt = Date(); self.loading = false; self.playing = true; self.liveError = nil
            }
        }
        stream.onError = { [weak self, weak stream] message in
            Task { @MainActor in
                guard let self, let stream, self.stream === stream else { return }
                self.stopLive(); self.liveError = message
            }
        }
        self.stream = stream
        do { try stream.start(client: client, sourceID: id); stream.setMuted(muted) }
        catch { stopLive(); liveError = error.localizedDescription }
    }

    private func stopLive() { stream?.stop(); stream = nil; if !playbackMode { playing = false; loading = false } }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task {
            var ticks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)); try Task.checkCancellation() } catch { return }
                if !playbackMode && stream != nil && Date().timeIntervalSince(lastImageAt) > 12 { stopLive(); liveError = "没有收到摄像头画面，请检查连接后重试。" }
                ticks += 1
                if ticks % 5 == 0 && active {
                    do { try await refresh(); error = nil } catch { self.error = "无法刷新 Mac 数据：" + error.localizedDescription }
                }
            }
        }
    }

    private func clearPlayback() {
        generation = UUID(); loadTask?.cancel(); nextTask?.cancel()
        player.pause(); player.removeAllItems(); itemEntries.removeAll(); currentRecording = nil
        playing = false; loading = false
    }

    private func play(_ recording: CameraRecording, offset: Double) {
        guard let client else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { self.error = "无法播放摄像头声音：" + error.localizedDescription; return }
        if currentRecording?.id == recording.id {
            player.seek(to: CMTime(seconds: offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            player.play(); playing = true; error = nil; return
        }
        clearPlayback(); loading = true; error = nil
        let current = generation
        loadTask = Task {
            do {
                let url = try await client.download(recording)
                try Task.checkCancellation()
                guard generation == current else { return }
                let item = AVPlayerItem(url: url)
                itemEntries[ObjectIdentifier(item)] = recording
                currentRecording = recording
                player.insert(item, after: nil)
                await player.seek(to: CMTime(seconds: offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                guard generation == current else { return }
                player.isMuted = muted; player.play(); playing = true; loading = false
                queueNext(after: recording)
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                loading = false; self.error = "录像加载失败：" + error.localizedDescription
            }
        }
    }

    private func queueNext(after recording: CameraRecording) {
        guard let client, let next = day.recordings.first(where: { $0.startedAt > recording.startedAt }), player.items().count < 2 else { return }
        nextTask?.cancel()
        let current = generation
        nextTask = Task {
            do {
                let url = try await client.download(next)
                try Task.checkCancellation()
                guard generation == current, currentRecording?.id == recording.id, player.items().count < 2 else { return }
                let item = AVPlayerItem(url: url)
                itemEntries[ObjectIdentifier(item)] = next
                player.insert(item, after: player.items().last)
            } catch { if !Task.isCancelled && generation == current { self.error = "下一段录像加载失败，可点击时间轴重试。" } }
        }
    }
}
