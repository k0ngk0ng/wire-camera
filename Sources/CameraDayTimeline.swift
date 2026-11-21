import AppKit

final class CameraDayTimeline: NSControl {
    private(set) var dayStart = Calendar.current.startOfDay(for: Date())
    private(set) var dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
    private(set) var visibleDuration: TimeInterval = 86400
    private var visibleStart: TimeInterval = 0
    private var position: Double = 0
    private var recordedIntervals: [DateInterval] = []
    private(set) var personIntervals: [DateInterval] = []
    private(set) var isTracking = false
    var followsPlayback = true
    private var hover: Date?
    private let tickFormatter: DateFormatter = {
        let value = DateFormatter()
        value.dateFormat = "HH:mm"
        return value
    }()

    override var acceptsFirstResponder: Bool { isEnabled }
    override var doubleValue: Double {
        get { position }
        set { position = min(dayEnd.timeIntervalSince(dayStart), max(0, newValue)); needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("全天回放时间轴")
        setAccessibilityIdentifier("playback-progress")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(day: CameraPlaybackDay, reset: Bool) {
        dayStart = day.interval.start
        dayEnd = day.interval.end
        recordedIntervals = day.recordings.compactMap {
            let start = max(dayStart, $0.startedAt)
            let end = min(dayEnd, $0.startedAt.addingTimeInterval($0.duration))
            return start < end ? DateInterval(start: start, end: end) : nil
        }
        personIntervals = day.personIntervals
        if reset { visibleStart = 0; visibleDuration = day.interval.duration; position = 0; followsPlayback = true }
        isEnabled = !day.recordings.isEmpty
        needsDisplay = true
    }

    func zoom(to duration: TimeInterval, around date: Date) {
        setRange(duration: duration, anchor: date.timeIntervalSince(dayStart), fraction: 0.5)
    }

    private func setRange(duration: TimeInterval, anchor: TimeInterval, fraction: Double) {
        let total = dayEnd.timeIntervalSince(dayStart)
        visibleDuration = min(total, max(60, duration))
        visibleStart = min(max(0, total - visibleDuration), max(0, anchor - visibleDuration * fraction))
        needsDisplay = true
    }

    func pan(by fraction: Double) {
        visibleStart = min(max(0, dayEnd.timeIntervalSince(dayStart) - visibleDuration), max(0, visibleStart + visibleDuration * fraction))
        followsPlayback = false
        needsDisplay = true
    }

    func reveal(_ date: Date) {
        let seconds = date.timeIntervalSince(dayStart)
        if seconds < visibleStart || seconds > visibleStart + visibleDuration { zoom(to: visibleDuration, around: date) }
    }

    func x(for date: Date) -> CGFloat {
        16 + CGFloat((date.timeIntervalSince(dayStart) - visibleStart) / visibleDuration) * max(1, bounds.width - 32)
    }

    private func date(at x: CGFloat) -> Date {
        let fraction = min(1, max(0, Double((x - 16) / max(1, bounds.width - 32))))
        return dayStart.addingTimeInterval(min(dayEnd.timeIntervalSince(dayStart) - 0.001, visibleStart + fraction * visibleDuration))
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        isTracking = true
        followsPlayback = true
        select(event)
    }

    override func mouseDragged(with event: NSEvent) { guard isEnabled else { return }; select(event) }
    override func mouseUp(with event: NSEvent) { isTracking = false }

    private func select(_ event: NSEvent) {
        let date = date(at: convert(event.locationInWindow, from: nil).x)
        doubleValue = date.timeIntervalSince(dayStart)
        sendAction(action, to: target)
    }

    override func scrollWheel(with event: NSEvent) {
        guard isEnabled else { return }
        followsPlayback = false
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            pan(by: Double(event.scrollingDeltaX) / max(1, Double(bounds.width)))
        } else {
            let point = convert(event.locationInWindow, from: nil).x
            setRange(duration: visibleDuration * exp(Double(event.scrollingDeltaY) * 0.04), anchor: date(at: point).timeIntervalSince(dayStart), fraction: Double((point - 16) / max(1, bounds.width - 32)))
        }
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil).x
        setRange(duration: visibleDuration * exp(-Double(event.magnification) * 2), anchor: date(at: point).timeIntervalSince(dayStart), fraction: Double((point - 16) / max(1, bounds.width - 32)))
    }

    override func keyDown(with event: NSEvent) {
        guard [123, 124].contains(event.keyCode) else { super.keyDown(with: event); return }
        doubleValue += event.keyCode == 123 ? -10 : 10
        reveal(dayStart.addingTimeInterval(doubleValue))
        sendAction(action, to: target)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hover = date(at: convert(event.locationInWindow, from: nil).x); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let width = max(1, bounds.width - 32)
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 16, y: 27, width: width, height: 13), xRadius: 3, yRadius: 3).fill()
        for interval in recordedIntervals {
            let left = max(16, x(for: interval.start)), right = min(bounds.width - 16, x(for: interval.end))
            guard right > left else { continue }
            NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
            NSRect(x: left, y: 27, width: max(2, right - left), height: 13).fill()
        }
        for interval in personIntervals {
            let left = max(16, x(for: interval.start)), right = min(bounds.width - 16, x(for: interval.end))
            guard right >= left, x(for: interval.end) >= 16, x(for: interval.start) <= bounds.width - 16 else { continue }
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: left - 3, y: 45, width: 6, height: 6)).fill()
        }
        let desired = visibleDuration / max(1, Double(width / 90))
        let steps: [Double] = [5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800]
        let step = steps.first(where: { $0 >= desired }) ?? 10800
        tickFormatter.dateFormat = step < 60 ? "HH:mm:ss" : "HH:mm"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        for seconds in stride(from: ceil(visibleStart / step) * step, through: visibleStart + visibleDuration + 0.01, by: step) {
            let date = dayStart.addingTimeInterval(seconds)
            let point = x(for: date)
            NSColor.separatorColor.setFill()
            NSRect(x: point, y: 18, width: 1, height: 7).fill()
            let text = abs(seconds - dayEnd.timeIntervalSince(dayStart)) < 0.1 ? "24:00" : tickFormatter.string(from: date)
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: min(bounds.width - size.width, max(0, point - size.width / 2)), y: 2), withAttributes: attributes)
        }
        NSColor.white.setFill()
        let cursor = x(for: dayStart.addingTimeInterval(position))
        if cursor >= 16 && cursor <= bounds.width - 16 { NSRect(x: cursor, y: 18, width: 2, height: 24).fill() }
        let legendAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        NSColor.controlAccentColor.setFill(); NSRect(x: 16, y: 63, width: 8, height: 5).fill()
        ("录像" as NSString).draw(at: NSPoint(x: 29, y: 58), withAttributes: legendAttributes)
        NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: NSRect(x: 66, y: 62, width: 6, height: 6)).fill()
        ("有人" as NSString).draw(at: NSPoint(x: 77, y: 58), withAttributes: legendAttributes)
        if let hover {
            let text = hover.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: min(bounds.width - size.width - 4, max(115, x(for: hover) - size.width / 2)), y: 58), withAttributes: attributes)
        }
    }
}
