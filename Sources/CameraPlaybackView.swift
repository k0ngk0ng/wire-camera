import AppKit
import AVKit

private final class CameraPlaybackList: NSStackView {
    override var isFlipped: Bool { true }
}

private final class CameraPlaybackSurface: AVPlayerView {
    var onSingleClick: (() -> Void)?
    private var pressedAt: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseDown(with event: NSEvent) { pressedAt = event.locationInWindow }
    override func mouseUp(with event: NSEvent) {
        defer { pressedAt = nil }
        guard let pressedAt, event.clickCount == 1,
              hypot(event.locationInWindow.x - pressedAt.x, event.locationInWindow.y - pressedAt.y) < 4,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onSingleClick?()
    }
}

final class CameraPlaybackView: NSView {
    let player = AVPlayer()
    private let playerView = CameraPlaybackSurface(frame: .zero)
    private let datePicker = NSPopUpButton()
    private let eventList = CameraPlaybackList()
    private let eventFilter = NSSegmentedControl(labels: ["全部", "有人", "变化"], trackingMode: .selectOne, target: nil, action: nil)
    private var filteredEvents: [CameraPlaybackEvent] { schedule?.events(matching: CameraPlaybackEventFilter(rawValue: eventFilter.selectedSegment) ?? .all) ?? [] }
    private let timeline = CameraDayTimeline(frame: .zero)
    private let zoomPicker = NSSegmentedControl(labels: ["全天", "6 小时", "1 小时", "15 分钟"], trackingMode: .selectOne, target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "00:00:00")
    private let playPause = NSButton()
    private let skipBackward = NSButton()
    private let skipForward = NSButton()
    private let mute = NSButton()
    private let fullscreen = NSButton()
    private let panBackward = NSButton()
    private let panForward = NSButton()
    private let playbackVolume = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let speedPicker = NSPopUpButton()
    private let playbackRates: [Float] = [0.5, 1, 1.5, 2, 4]
    private var playerStateObservation: NSKeyValueObservation?
    var onToggleFullscreen: (() -> Void)?
    private let empty = NSTextField(wrappingLabelWithString: "开启录制后，可在这里查看回放")
    private let eventStatus = NSTextField(wrappingLabelWithString: "")
    private var library: CameraRecordingLibrary?
    private var sourceID: String?
    private var recordingActive = false
    private var visible: [CameraRecording] = []
    private var selected: CameraRecording?
    private var dates: [Date] = []
    private var day: Date?
    private var schedule: CameraPlaybackDay?
    private var cursor: Date?
    private var seekGeneration = 0
    private var seeking = false
    private var wantsPlayback = false
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    var visibleRecordingCount: Int { visible.count }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
        playerView.player = player
        playerView.onSingleClick = { [weak self] in self?.togglePlayback() }
        playerView.controlsStyle = .none
        playerView.allowsVideoFrameAnalysis = false
        playerView.videoGravity = .resizeAspect
        let toolbar = NSView()
        let eventsPanel = NSView()
        let transport = NSView()
        let eventsTitle = eventFilter
        eventFilter.selectedSegment = 0
        eventFilter.segmentStyle = .rounded
        eventFilter.target = self
        eventFilter.action = #selector(changeEventFilter)
        eventFilter.setAccessibilityLabel("活动筛选")
        eventFilter.setAccessibilityIdentifier("playback-event-filter")
        datePicker.target = self
        datePicker.action = #selector(changeDate)
        datePicker.setAccessibilityLabel("回放日期")
        zoomPicker.target = self
        zoomPicker.action = #selector(changeZoom)
        zoomPicker.selectedSegment = 0
        zoomPicker.segmentStyle = .rounded
        zoomPicker.setAccessibilityLabel("时间轴范围")
        zoomPicker.setAccessibilityIdentifier("playback-zoom")
        eventList.orientation = .vertical
        eventList.alignment = .leading
        eventList.spacing = 8
        let eventsScroll = NSScrollView()
        eventsScroll.drawsBackground = false
        eventsScroll.hasVerticalScroller = true
        eventsScroll.documentView = eventList
        eventList.translatesAutoresizingMaskIntoConstraints = false
        eventStatus.textColor = .secondaryLabelColor
        eventStatus.font = .systemFont(ofSize: 12)
        timeline.target = self
        timeline.action = #selector(seekTimeline)
        configure(playPause, symbol: "play.fill", label: "播放回放", action: #selector(togglePlayback), identifier: "playback-play-pause")
        configure(skipBackward, symbol: "gobackward.10", label: "后退 10 秒", action: #selector(skipBackwardTenSeconds), identifier: "playback-backward")
        configure(skipForward, symbol: "goforward.10", label: "前进 10 秒", action: #selector(skipForwardTenSeconds), identifier: "playback-forward")
        configure(mute, symbol: "speaker.wave.2.fill", label: "静音回放", action: #selector(toggleMute), identifier: "playback-mute")
        configure(fullscreen, symbol: "arrow.up.left.and.arrow.down.right", label: "切换全屏", action: #selector(toggleFullscreen), identifier: "playback-fullscreen")
        configure(panBackward, symbol: "chevron.left", label: "前一时段", action: #selector(panEarlier), identifier: "playback-pan-earlier")
        configure(panForward, symbol: "chevron.right", label: "后一时段", action: #selector(panLater), identifier: "playback-pan-later")
        playbackVolume.target = self
        playbackVolume.action = #selector(changePlaybackVolume)
        playbackVolume.isContinuous = true
        playbackVolume.setAccessibilityLabel("回放音量")
        playbackVolume.setAccessibilityIdentifier("playback-volume")
        speedPicker.addItems(withTitles: ["0.5×", "1×", "1.5×", "2×", "4×"])
        speedPicker.selectItem(at: 1)
        speedPicker.target = self
        speedPicker.action = #selector(changePlaybackSpeed)
        speedPicker.setAccessibilityLabel("回放倍速")
        speedPicker.setAccessibilityIdentifier("playback-speed")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [skipBackward, playPause, skipForward, timeLabel, spacer, mute, playbackVolume, speedPicker, fullscreen])
        controls.spacing = 8
        controls.alignment = .centerY
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.setAccessibilityLabel("播放时间")
        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 15)
        for view in [playerView, eventsPanel, transport, empty] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        transport.addSubview(toolbar)
        for view in [datePicker, zoomPicker, panBackward, panForward] { view.translatesAutoresizingMaskIntoConstraints = false; toolbar.addSubview(view) }
        for view in [eventsTitle, eventStatus, eventsScroll] { view.translatesAutoresizingMaskIntoConstraints = false; eventsPanel.addSubview(view) }
        for view in [timeline, controls] { view.translatesAutoresizingMaskIntoConstraints = false; transport.addSubview(view) }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: transport.topAnchor), toolbar.leadingAnchor.constraint(equalTo: leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: trailingAnchor), toolbar.heightAnchor.constraint(equalToConstant: 36),
            datePicker.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 20), datePicker.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor), datePicker.widthAnchor.constraint(equalToConstant: 185),
            zoomPicker.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor), zoomPicker.trailingAnchor.constraint(equalTo: panBackward.leadingAnchor, constant: -12),
            panBackward.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor), panForward.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor), panBackward.trailingAnchor.constraint(equalTo: panForward.leadingAnchor, constant: -4), panForward.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -20),
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor), playerView.trailingAnchor.constraint(equalTo: eventsPanel.leadingAnchor), playerView.topAnchor.constraint(equalTo: topAnchor), playerView.bottomAnchor.constraint(equalTo: transport.topAnchor),
            eventsPanel.trailingAnchor.constraint(equalTo: trailingAnchor), eventsPanel.topAnchor.constraint(equalTo: topAnchor), eventsPanel.bottomAnchor.constraint(equalTo: transport.topAnchor), eventsPanel.widthAnchor.constraint(equalToConstant: 210),
            eventsTitle.topAnchor.constraint(equalTo: eventsPanel.topAnchor, constant: 20), eventsTitle.leadingAnchor.constraint(equalTo: eventsPanel.leadingAnchor, constant: 16),
            eventStatus.topAnchor.constraint(equalTo: eventsTitle.bottomAnchor, constant: 12), eventStatus.leadingAnchor.constraint(equalTo: eventsTitle.leadingAnchor), eventStatus.trailingAnchor.constraint(equalTo: eventsPanel.trailingAnchor, constant: -16),
            eventsScroll.topAnchor.constraint(equalTo: eventStatus.bottomAnchor, constant: 16), eventsScroll.leadingAnchor.constraint(equalTo: eventsTitle.leadingAnchor), eventsScroll.trailingAnchor.constraint(equalTo: eventsPanel.trailingAnchor, constant: -16), eventsScroll.bottomAnchor.constraint(equalTo: eventsPanel.bottomAnchor, constant: -12), eventList.widthAnchor.constraint(equalTo: eventsScroll.widthAnchor, constant: -8),
            transport.leadingAnchor.constraint(equalTo: leadingAnchor), transport.trailingAnchor.constraint(equalTo: trailingAnchor), transport.bottomAnchor.constraint(equalTo: bottomAnchor), transport.heightAnchor.constraint(equalToConstant: 160),
            timeline.leadingAnchor.constraint(equalTo: transport.leadingAnchor), timeline.trailingAnchor.constraint(equalTo: transport.trailingAnchor), timeline.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 4), timeline.heightAnchor.constraint(equalToConstant: 76),
            controls.leadingAnchor.constraint(equalTo: transport.leadingAnchor, constant: 16), controls.trailingAnchor.constraint(equalTo: transport.trailingAnchor, constant: -16), controls.bottomAnchor.constraint(equalTo: transport.bottomAnchor, constant: -12), controls.heightAnchor.constraint(equalToConstant: 28),
            playbackVolume.widthAnchor.constraint(equalToConstant: 80), speedPicker.widthAnchor.constraint(equalToConstant: 64), timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
            empty.centerXAnchor.constraint(equalTo: playerView.centerXAnchor), empty.centerYAnchor.constraint(equalTo: playerView.centerYAnchor), empty.widthAnchor.constraint(lessThanOrEqualTo: playerView.widthAnchor, constant: -32)
        ])
        updateControls()
        playerStateObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in DispatchQueue.main.async { self?.updatePlayButton() } }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self, let selected = self.selected, !self.seeking, !self.timeline.isTracking, time.seconds.isFinite else { return }
            let date = selected.startedAt.addingTimeInterval(time.seconds)
            if let end = self.schedule?.interval.end, date >= end { self.pause(); self.cursor = end }
            else { self.cursor = date }
            self.updateCursor()
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem, self.wantsPlayback, !self.seeking, let selected = self.selected, let schedule = self.schedule else { return }
            guard self.player.currentTime().seconds >= selected.duration - 0.1 else { return }
            let end = selected.startedAt.addingTimeInterval(selected.duration)
            if let next = schedule.position(at: end, snapForward: true) { self.seek(to: next.recording.startedAt.addingTimeInterval(next.offset)) }
            else { self.pause(); self.cursor = min(schedule.interval.end, end); self.updateCursor() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { if let observer { player.removeTimeObserver(observer) }; if let endObserver { NotificationCenter.default.removeObserver(endObserver) } }

    func update(library: CameraRecordingLibrary, sourceID: String?, recordingActive: Bool? = nil) {
        if let recordingActive { self.recordingActive = recordingActive }
        self.library = library
        let changedSource = self.sourceID != sourceID
        if changedSource { self.sourceID = sourceID; day = nil; cursor = nil; clearSelection() }
        let entries = library.entries.filter { sourceID == nil || $0.sourceID == sourceID }
        dates = CameraPlaybackDay.availableDates(recordings: entries)
        let oldDay = schedule?.interval.start
        if day == nil || !dates.contains(day!) { day = dates.first }
        datePicker.removeAllItems()
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy 年 M 月 d 日"
        dates.forEach { datePicker.addItem(withTitle: formatter.string(from: $0)) }
        if let day, let index = dates.firstIndex(of: day) { datePicker.selectItem(at: index) }
        if dates.isEmpty { datePicker.addItem(withTitle: "暂无录像") }
        datePicker.isEnabled = !dates.isEmpty
        let model = CameraPlaybackDay(date: day ?? Date(), recordings: entries)
        schedule = model
        visible = model.recordings
        let changedDay = changedSource || oldDay != model.interval.start
        timeline.configure(day: model, reset: changedDay)
        if changedDay { zoomPicker.selectedSegment = 0; cursor = nil; clearSelection() }
        if let selected, !visible.contains(where: { $0.id == selected.id }) { clearSelection() }
        if selected == nil {
            empty.isHidden = false
            empty.stringValue = visible.isEmpty ? (self.recordingActive ? "正在录制，片段保存后可回放" : "这天没有录像") : (cursor == nil ? "点击时间轴中的蓝色时段开始回放" : "此时段没有录像")
        }
        updateEvents()
        updateControls()
        updateCursor()
    }

    func pause() { wantsPlayback = false; player.pause(); updatePlayButton() }

    func selectFirstRecording() {
        guard let schedule, let first = schedule.recordings.first else { return }
        seek(to: max(schedule.interval.start, first.startedAt))
    }

    func performFirstEventJump() -> Bool {
        guard let event = filteredEvents.first, let button = eventList.arrangedSubviews.compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityIdentifier() == "playback-event" }) else { return false }
        button.performClick(nil)
        return abs(timeline.doubleValue - event.start.timeIntervalSince(timeline.dayStart)) < 0.01
    }

    private func seek(to date: Date, snapForward: Bool = false, autoplay: Bool = true) {
        guard let schedule else { return }
        seekGeneration += 1
        let request = seekGeneration
        cursor = date
        timeline.followsPlayback = true
        guard let position = schedule.position(at: date, snapForward: snapForward) else {
            clearSelection()
            cursor = date
            empty.isHidden = false
            empty.stringValue = "此时段没有录像"
            updateCursor()
            return
        }
        guard let library, let access = library.access(position.recording) else {
            clearSelection()
            cursor = date
            empty.isHidden = false
            empty.stringValue = "这段录像已到期或正在清理"
            updateCursor()
            return
        }
        cursor = position.recording.startedAt.addingTimeInterval(position.offset)
        wantsPlayback = autoplay
        seeking = true
        selected = position.recording
        if (player.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent != position.recording.filename {
            player.pause()
            player.replaceCurrentItem(with: AVPlayerItem(url: access.url))
        }
        empty.isHidden = true
        updateCursor()
        updateControls()
        let item = player.currentItem
        player.seek(to: CMTime(seconds: position.offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            DispatchQueue.main.async {
                guard let self, request == self.seekGeneration, item === self.player.currentItem else { return }
                self.seeking = false
                if completed && self.wantsPlayback { self.player.playImmediately(atRate: self.selectedRate) }
                self.updatePlayButton()
            }
        }
    }

    private func clearSelection() {
        seekGeneration += 1
        seeking = false
        selected = nil
        pause()
        player.replaceCurrentItem(with: nil)
        updateControls()
    }

    private func updateCursor() {
        guard let schedule else { return }
        let date = cursor ?? schedule.interval.start
        timeline.doubleValue = date.timeIntervalSince(schedule.interval.start)
        if timeline.followsPlayback { timeline.reveal(date) }
        timeLabel.stringValue = date == schedule.interval.end ? "24:00:00" : Self.clock(date)
    }

    private func updateEvents() {
        for view in eventList.arrangedSubviews { eventList.removeArrangedSubview(view); view.removeFromSuperview() }
        guard schedule != nil else { return }
        let pending = visible.contains { $0.indexState == "processing" || $0.motionIndexState == nil || $0.motionIndexState == "processing" }
        let failed = visible.contains { $0.indexState == "failed" || $0.motionIndexState == "failed" }
        let events = filteredEvents
        eventStatus.stringValue = events.isEmpty ? (pending ? "正在分析…" : (failed ? "分析未完成" : "没有匹配的活动")) : "\(events.count) 段活动" + (pending ? " · 分析中" : "")
        if failed { eventList.addArrangedSubview(NSButton(title: "重新分析", target: self, action: #selector(retryIndex))) }
        for (index, event) in events.enumerated() {
            let button = NSButton(title: Self.clock(event.start) + " – " + Self.clock(event.end), target: self, action: #selector(jumpToEvent(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            let color: NSColor = event.isPerson ? .systemOrange : .systemPurple
            button.image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
                color.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill(); return true
            }
            button.imagePosition = .imageLeading
            button.toolTip = event.label
            button.setAccessibilityLabel(event.label + "，跳转至 " + Self.clock(event.start))
            button.setAccessibilityIdentifier("playback-event")
            eventList.addArrangedSubview(button)
        }
    }

    @objc private func changeEventFilter() {
        timeline.eventFilter = CameraPlaybackEventFilter(rawValue: eventFilter.selectedSegment) ?? .all
        updateEvents()
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector, identifier: String) {
        button.target = self; button.action = action
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageOnly; button.isBordered = false; button.contentTintColor = .labelColor
        button.toolTip = label; button.setAccessibilityLabel(label); button.setAccessibilityIdentifier(identifier)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    private var selectedRate: Float { playbackRates[speedPicker.indexOfSelectedItem] }

    private func updateControls() {
        let enabled = !visible.isEmpty
        for button in [playPause, skipBackward, skipForward, mute, panBackward, panForward] { button.isEnabled = enabled }
        timeline.isEnabled = enabled; zoomPicker.isEnabled = enabled; playbackVolume.isEnabled = enabled; speedPicker.isEnabled = enabled
        updatePlayButton()
    }

    private func updatePlayButton() {
        let playing = wantsPlayback && (player.rate > 0 || seeking)
        playPause.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        playPause.setAccessibilityLabel(playing ? "暂停回放" : "播放回放")
        playPause.toolTip = playing ? "暂停回放" : "播放回放"
    }

    @objc private func togglePlayback() {
        if wantsPlayback && (player.rate > 0 || seeking) { pause(); return }
        if let selected, player.currentTime().seconds < selected.duration - 0.05 { wantsPlayback = true; player.playImmediately(atRate: selectedRate); updatePlayButton(); return }
        guard let schedule else { return }
        if let cursor {
            if schedule.position(at: cursor, snapForward: true) != nil { seek(to: cursor, snapForward: true) }
            else { pause(); empty.isHidden = false; empty.stringValue = "该时间之后没有录像" }
        } else { selectFirstRecording() }
    }

    private func skip(_ seconds: Double) {
        guard let schedule else { return }
        let date = (cursor ?? schedule.interval.start).addingTimeInterval(seconds)
        seek(to: min(schedule.interval.end.addingTimeInterval(-0.001), max(schedule.interval.start, date)), snapForward: true, autoplay: wantsPlayback)
    }

    @objc private func changeZoom() {
        guard let schedule else { return }
        let spans = [schedule.interval.duration, 21600, 3600, 900]
        timeline.followsPlayback = true
        timeline.zoom(to: spans[zoomPicker.selectedSegment], around: cursor ?? visible.first?.startedAt ?? schedule.interval.start)
    }
    @objc private func panEarlier() { timeline.pan(by: -0.75) }
    @objc private func panLater() { timeline.pan(by: 0.75) }
    @objc private func skipBackwardTenSeconds() { skip(-10) }
    @objc private func skipForwardTenSeconds() { skip(10) }
    @objc private func changePlaybackSpeed() { if player.rate > 0 { player.rate = selectedRate } }
    @objc private func toggleFullscreen() { onToggleFullscreen?() }
    @objc private func toggleMute() { player.isMuted.toggle(); updateMuteButton() }
    @objc private func changePlaybackVolume() { player.volume = Float(playbackVolume.doubleValue); player.isMuted = false; updateMuteButton() }
    private func updateMuteButton() {
        let muted = player.isMuted || player.volume == 0
        mute.image = NSImage(systemSymbolName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", accessibilityDescription: nil)
        mute.setAccessibilityLabel(muted ? "取消回放静音" : "静音回放")
    }
    @objc private func changeDate() {
        guard dates.indices.contains(datePicker.indexOfSelectedItem), let library else { return }
        day = dates[datePicker.indexOfSelectedItem]; cursor = nil; clearSelection(); update(library: library, sourceID: sourceID); selectFirstRecording()
    }
    @objc private func seekTimeline() { seek(to: timeline.dayStart.addingTimeInterval(timeline.doubleValue)) }
    @objc private func jumpToEvent(_ sender: NSButton) { let events = filteredEvents; guard events.indices.contains(sender.tag) else { return }; seek(to: events[sender.tag].start, snapForward: true) }
    @objc private func retryIndex() { for entry in visible where entry.indexState == "failed" || entry.motionIndexState == "failed" { library?.index(entry) } }
    private static func clock(_ date: Date) -> String { let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"; return formatter.string(from: date) }
}
