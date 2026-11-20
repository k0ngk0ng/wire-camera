import AppKit
import AVKit

final class CameraEventTimeline: NSSlider {
    var events: [CameraPersonEvent] = []

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard maxValue > 0 else { return }
        NSColor.systemOrange.withAlphaComponent(0.9).setFill()
        for event in events {
            let start = 8 + CGFloat(event.start / maxValue) * (bounds.width - 16)
            let width = max(3, CGFloat((event.end - event.start) / maxValue) * (bounds.width - 16))
            NSBezierPath(roundedRect: NSRect(x: start, y: 1, width: width, height: 4), xRadius: 2, yRadius: 2).fill()
        }
    }
}

private final class CameraPlaybackList: NSStackView {
    override var isFlipped: Bool { true }
}

final class CameraPlaybackView: NSView {
    let player = AVPlayer()
    private let playerView = AVPlayerView()
    private let datePicker = NSPopUpButton()
    private let recordings = CameraPlaybackList()
    private let eventList = CameraPlaybackList()
    private let timeline = CameraEventTimeline(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "00:00 / 00:00")
    private let empty = NSTextField(wrappingLabelWithString: "开启录制后，可在这里查看回放")
    private let eventStatus = NSTextField(wrappingLabelWithString: "选择一段录像")
    private var library: CameraRecordingLibrary?
    private var sourceID: String?
    private var recordingActive = false
    private var visible: [CameraRecording] = []
    private var selected: CameraRecording?
    private var dates: [Date] = []
    private var day: Date?
    private var observer: Any?
    var visibleRecordingCount: Int { recordings.arrangedSubviews.count }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        let sidebar = NSView()
        let eventsPanel = NSView()
        let transport = NSView()
        let listTitle = Self.label("录像", size: 17, weight: .semibold)
        let eventsTitle = Self.label("人物出现", size: 15, weight: .semibold)
        datePicker.target = self
        datePicker.action = #selector(changeDate)
        datePicker.setAccessibilityLabel("回放日期")
        recordings.orientation = .vertical
        recordings.alignment = .leading
        recordings.spacing = 8
        eventList.orientation = .vertical
        eventList.alignment = .leading
        eventList.spacing = 8
        let listScroll = Self.scroll(recordings)
        let eventsScroll = Self.scroll(eventList)
        eventStatus.textColor = .secondaryLabelColor
        eventStatus.font = .systemFont(ofSize: 12)
        timeline.target = self
        timeline.action = #selector(seek)
        timeline.isContinuous = true
        timeline.setAccessibilityLabel("回放时间轴")
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 15)
        for view in [sidebar, playerView, eventsPanel, transport, empty] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        for view in [listTitle, datePicker, listScroll] { view.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(view) }
        for view in [eventsTitle, eventStatus, eventsScroll] { view.translatesAutoresizingMaskIntoConstraints = false; eventsPanel.addSubview(view) }
        for view in [timeline, timeLabel] { view.translatesAutoresizingMaskIntoConstraints = false; transport.addSubview(view) }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor), sidebar.topAnchor.constraint(equalTo: topAnchor), sidebar.bottomAnchor.constraint(equalTo: bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 220),
            listTitle.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 24), listTitle.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            datePicker.topAnchor.constraint(equalTo: listTitle.bottomAnchor, constant: 16), datePicker.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16), datePicker.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),
            listScroll.topAnchor.constraint(equalTo: datePicker.bottomAnchor, constant: 16), listScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -16), listScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16), listScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),
            recordings.widthAnchor.constraint(equalTo: listScroll.widthAnchor, constant: -8),
            eventsPanel.trailingAnchor.constraint(equalTo: trailingAnchor), eventsPanel.topAnchor.constraint(equalTo: topAnchor), eventsPanel.bottomAnchor.constraint(equalTo: bottomAnchor), eventsPanel.widthAnchor.constraint(equalToConstant: 190),
            eventsTitle.topAnchor.constraint(equalTo: eventsPanel.topAnchor, constant: 24), eventsTitle.leadingAnchor.constraint(equalTo: eventsPanel.leadingAnchor, constant: 16),
            eventStatus.topAnchor.constraint(equalTo: eventsTitle.bottomAnchor, constant: 16), eventStatus.leadingAnchor.constraint(equalTo: eventsTitle.leadingAnchor), eventStatus.trailingAnchor.constraint(equalTo: eventsPanel.trailingAnchor, constant: -16),
            eventsScroll.topAnchor.constraint(equalTo: eventStatus.bottomAnchor, constant: 16), eventsScroll.leadingAnchor.constraint(equalTo: eventsTitle.leadingAnchor), eventsScroll.trailingAnchor.constraint(equalTo: eventsPanel.trailingAnchor, constant: -16), eventsScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            eventList.widthAnchor.constraint(equalTo: eventsScroll.widthAnchor, constant: -8),
            playerView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), playerView.trailingAnchor.constraint(equalTo: eventsPanel.leadingAnchor), playerView.topAnchor.constraint(equalTo: topAnchor), playerView.bottomAnchor.constraint(equalTo: transport.topAnchor),
            transport.leadingAnchor.constraint(equalTo: playerView.leadingAnchor), transport.trailingAnchor.constraint(equalTo: playerView.trailingAnchor), transport.bottomAnchor.constraint(equalTo: bottomAnchor), transport.heightAnchor.constraint(equalToConstant: 64),
            timeline.leadingAnchor.constraint(equalTo: transport.leadingAnchor, constant: 16), timeline.trailingAnchor.constraint(equalTo: transport.trailingAnchor, constant: -16), timeline.topAnchor.constraint(equalTo: transport.topAnchor, constant: 8),
            timeLabel.leadingAnchor.constraint(equalTo: timeline.leadingAnchor), timeLabel.topAnchor.constraint(equalTo: timeline.bottomAnchor, constant: 4),
            empty.centerXAnchor.constraint(equalTo: playerView.centerXAnchor), empty.centerYAnchor.constraint(equalTo: playerView.centerYAnchor), empty.widthAnchor.constraint(lessThanOrEqualTo: playerView.widthAnchor, constant: -32)
        ])
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self, let selected = self.selected else { return }
            if !self.timeline.isHighlighted { self.timeline.doubleValue = time.seconds.isFinite ? time.seconds : 0 }
            self.timeLabel.stringValue = Self.clock(max(0, time.seconds.isFinite ? time.seconds : 0)) + " / " + Self.clock(selected.duration)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { if let observer { player.removeTimeObserver(observer) } }

    func update(library: CameraRecordingLibrary, sourceID: String?, recordingActive: Bool? = nil) {
        if let recordingActive { self.recordingActive = recordingActive }
        self.library = library
        if self.sourceID != sourceID { self.sourceID = sourceID; day = nil; clearSelection() }
        let entries = library.entries.filter { sourceID == nil || $0.sourceID == sourceID }
        dates = Array(Set(entries.map { Calendar.current.startOfDay(for: $0.startedAt) })).sorted(by: >)
        if day == nil { day = dates.first }
        datePicker.removeAllItems()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy 年 M 月 d 日"
        dates.forEach { datePicker.addItem(withTitle: formatter.string(from: $0)) }
        if let day, let index = dates.firstIndex(of: day) { datePicker.selectItem(at: index) }
        if dates.isEmpty { datePicker.addItem(withTitle: "暂无录像"); datePicker.isEnabled = false } else { datePicker.isEnabled = true }
        visible = entries.filter { day == nil || Calendar.current.isDate($0.startedAt, inSameDayAs: day!) }
        Self.clear(recordings)
        for (index, entry) in visible.enumerated() {
            let date = DateFormatter()
            date.dateFormat = "HH:mm:ss"
            let title = date.string(from: entry.startedAt) + "   ·   " + Self.clock(entry.duration)
            let button = NSButton(title: title, target: self, action: #selector(selectRecording(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.alignment = .left
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.contentTintColor = entry.id == selected?.id ? .controlAccentColor : .labelColor
            button.setAccessibilityLabel("回放 " + title)
            recordings.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: recordings.widthAnchor).isActive = true
        }
        if let selected, let updated = visible.first(where: { $0.id == selected.id }) { self.selected = updated; updateEvents() }
        else if selected != nil { clearSelection() }
        empty.isHidden = selected != nil
        empty.stringValue = visible.isEmpty ? (self.recordingActive ? "正在录制，片段保存后可回放" : "开启录制后，可在这里查看回放") : "选择左侧录像开始回放"
        timeline.isEnabled = selected != nil
    }

    func pause() { player.pause() }
    func selectFirstRecording() { if !visible.isEmpty { select(index: 0) } }

    func performFirstEventJump() -> Bool {
        guard let button = eventList.arrangedSubviews.first as? NSButton, let event = selected?.events.first else { return false }
        button.performClick(nil)
        return abs(timeline.doubleValue - event.start) < 0.01
    }

    private func select(index: Int) {
        guard visible.indices.contains(index), let library else { return }
        selected = visible[index]
        player.pause()
        player.replaceCurrentItem(with: AVPlayerItem(url: library.movieURL(visible[index])))
        timeline.maxValue = visible[index].duration
        timeline.doubleValue = 0
        empty.isHidden = true
        player.play()
        update(library: library, sourceID: sourceID)
    }

    private func clearSelection() {
        selected = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        Self.clear(eventList)
        eventStatus.stringValue = "选择一段录像"
        timeline.events = []
        timeline.needsDisplay = true
    }

    private func updateEvents() {
        Self.clear(eventList)
        guard let selected else { return }
        timeline.events = selected.events
        timeline.needsDisplay = true
        switch selected.indexState {
        case "processing": eventStatus.stringValue = "正在识别人物…"
        case "failed":
            eventStatus.stringValue = "人物识别未完成"
            let retry = NSButton(title: "重新识别", target: self, action: #selector(retryIndex))
            eventList.addArrangedSubview(retry)
        default: eventStatus.stringValue = selected.events.isEmpty ? "未检测到人物" : "\(selected.events.count) 段人物活动"
        }
        for (index, event) in selected.events.enumerated() {
            let button = NSButton(title: Self.clock(event.start) + " – " + Self.clock(event.end), target: self, action: #selector(jumpToEvent(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.image = NSImage(systemSymbolName: "figure.walk", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.contentTintColor = .systemOrange
            button.setAccessibilityLabel("人物出现，跳转至 " + Self.clock(event.start))
            eventList.addArrangedSubview(button)
        }
    }

    @objc private func selectRecording(_ sender: NSButton) { select(index: sender.tag) }
    @objc private func changeDate() { guard dates.indices.contains(datePicker.indexOfSelectedItem), let library else { return }; day = dates[datePicker.indexOfSelectedItem]; clearSelection(); update(library: library, sourceID: sourceID) }
    @objc private func seek() { player.seek(to: CMTime(seconds: timeline.doubleValue, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    @objc private func jumpToEvent(_ sender: NSButton) { guard let selected, selected.events.indices.contains(sender.tag) else { return }; timeline.doubleValue = selected.events[sender.tag].start; seek(); player.play() }
    @objc private func retryIndex() { if let selected { library?.index(selected) } }

    private static func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
    }

    private static func clock(_ time: Double) -> String { let value = Int(time); return String(format: "%02d:%02d", value / 60, value % 60) }
    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField { let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: size, weight: weight); return label }
    private static func scroll(_ content: NSView) -> NSScrollView { let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.documentView = content; content.translatesAutoresizingMaskIntoConstraints = false; return scroll }
}
