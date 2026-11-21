import SwiftUI

struct CameraPhoneTimeline: View {
    @ObservedObject var model: CameraPhoneModel
    var showsEvents = true
    @State private var center: Date?
    @State private var width: CGFloat = 1

    private var window: DateInterval {
        let day = model.day.interval
        let span = min(model.timelineSpan, day.duration)
        let middle = center ?? model.cursor
        let first = max(day.start, min(day.end.addingTimeInterval(-span), middle.addingTimeInterval(-span / 2)))
        return DateInterval(start: first, duration: span)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(model.cursor, format: .dateTime.hour().minute().second()).monospacedDigit()
                Spacer()
                Circle().fill(.orange).frame(width: 6, height: 6)
                Text("有人").font(.caption).foregroundStyle(.secondary)
                Circle().fill(.purple).frame(width: 6, height: 6)
                Text("画面变化").font(.caption).foregroundStyle(.secondary)
                Button { zoom(2) } label: { Image(systemName: "minus.magnifyingglass") }
                    .accessibilityLabel("缩小时间轴")
                Button { zoom(0.5) } label: { Image(systemName: "plus.magnifyingglass") }
                    .accessibilityLabel("放大时间轴")
            }
            Canvas { context, size in
                let interval = window
                func x(_ date: Date) -> CGFloat { CGFloat(date.timeIntervalSince(interval.start) / interval.duration) * size.width }
                let baseline = CGRect(x: 0, y: 20, width: size.width, height: 24)
                context.fill(Path(roundedRect: baseline, cornerRadius: 5), with: .color(.white.opacity(0.07)))
                for recording in model.day.recordings {
                    let first = max(0, x(recording.startedAt))
                    let last = min(size.width, x(recording.startedAt.addingTimeInterval(recording.duration)))
                    if last > first { context.fill(Path(CGRect(x: first, y: 22, width: max(2, last - first), height: 20)), with: .color(.cyan.opacity(0.65))) }
                }
                for event in model.activityEvents.reversed() where event.end >= interval.start && event.start <= interval.end {
                    let point = max(3, min(size.width - 3, x(event.start)))
                    context.fill(Path(ellipseIn: CGRect(x: point - 3, y: 8, width: 6, height: 6)), with: .color(event.isPerson ? .orange : .purple))
                }
                for step in 0...4 {
                    let date = interval.start.addingTimeInterval(Double(step) * interval.duration / 4)
                    let point = CGFloat(step) * size.width / 4
                    var tick = Path()
                    tick.move(to: CGPoint(x: point, y: 45)); tick.addLine(to: CGPoint(x: point, y: 50))
                    context.stroke(tick, with: .color(.secondary), lineWidth: 1)
                    let text = Text(date, format: .dateTime.hour().minute()).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    context.draw(text, at: CGPoint(x: point, y: 60), anchor: step == 0 ? .leading : (step == 4 ? .trailing : .center))
                }
                let point = x(model.cursor)
                if point >= 0 && point <= size.width {
                    var cursor = Path()
                    cursor.move(to: CGPoint(x: point, y: 16)); cursor.addLine(to: CGPoint(x: point, y: 47))
                    context.stroke(cursor, with: .color(.white), lineWidth: 2)
                }
            }
            .frame(height: 74)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max(1, $0) }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                if abs(value.translation.width) > 12 && model.timelineSpan < model.day.interval.duration {
                    center = window.start.addingTimeInterval(window.duration / 2 - Double(value.translation.width / width) * window.duration)
                } else { model.seek(window.start.addingTimeInterval(max(0, min(0.999999, Double(value.location.x / width))) * window.duration)) }
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("全天时间轴")
            .accessibilityIdentifier("全天时间轴")
            .accessibilityValue(model.cursor.formatted(date: .omitted, time: .standard))
            if showsEvents {
                CameraPhoneEventFilter(model: model)
            }
            if showsEvents && !model.activityEvents.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(model.activityEvents, id: \.start) { event in
                            Button { model.seek(event.start) } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(event.isPerson ? .orange : .purple).frame(width: 6, height: 6)
                                    Text(event.start, format: .dateTime.hour().minute().second()).font(.caption.monospacedDigit())
                                }.padding(.horizontal, 10).padding(.vertical, 8).background(.white.opacity(0.06), in: Capsule())
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: model.date) { _, _ in center = nil }
        .onChange(of: model.selectedID) { _, _ in center = nil }
    }

    private func zoom(_ factor: Double) {
        center = model.cursor
        model.timelineSpan = min(model.day.interval.duration, max(300, model.timelineSpan * factor))
    }
}


struct CameraPhoneEventFilter: View {
    @ObservedObject var model: CameraPhoneModel
    var body: some View {
        Picker("活动筛选", selection: $model.eventFilter) {
            ForEach(CameraPlaybackEventFilter.allCases, id: \.rawValue) { filter in Text(filter.title).tag(filter) }
        }.pickerStyle(.segmented).accessibilityIdentifier("活动筛选")
    }
}
