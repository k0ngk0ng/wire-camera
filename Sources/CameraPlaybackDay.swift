import Foundation

struct CameraPlaybackPosition {
    let recording: CameraRecording
    let offset: Double
}

struct CameraPlaybackDay {
    let interval: DateInterval
    let recordings: [CameraRecording]
    let personIntervals: [DateInterval]

    init(date: Date, recordings: [CameraRecording], calendar: Calendar = .current) {
        let interval = calendar.dateInterval(of: .day, for: date)!
        self.interval = interval
        self.recordings = recordings.filter {
            $0.duration.isFinite && $0.duration > 0 && $0.startedAt < interval.end && $0.startedAt.addingTimeInterval($0.duration) > interval.start
        }.sorted {
            $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt
        }
        var events: [DateInterval] = []
        for recording in self.recordings {
            for event in recording.events {
                let start = max(interval.start, recording.startedAt.addingTimeInterval(event.start))
                let end = min(interval.end, recording.startedAt.addingTimeInterval(min(recording.duration, event.end)))
                if start < end { events.append(DateInterval(start: start, end: end)) }
            }
        }
        var merged: [DateInterval] = []
        for event in events.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, event.start.timeIntervalSince(last.end) <= 1 {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, event.end))
            } else { merged.append(event) }
        }
        personIntervals = merged
    }

    func position(at date: Date, snapForward: Bool = false) -> CameraPlaybackPosition? {
        guard date >= interval.start, date < interval.end else { return nil }
        if let recording = recordings.last(where: { $0.startedAt <= date && $0.startedAt.addingTimeInterval($0.duration) > date }) {
            return CameraPlaybackPosition(recording: recording, offset: max(0, date.timeIntervalSince(recording.startedAt)))
        }
        if snapForward, let recording = recordings.first(where: { $0.startedAt >= date }) {
            return CameraPlaybackPosition(recording: recording, offset: 0)
        }
        return nil
    }

    static func availableDates(recordings: [CameraRecording], calendar: Calendar = .current) -> [Date] {
        var dates: Set<Date> = []
        for recording in recordings where recording.duration.isFinite && recording.duration > 0 {
            var day = calendar.startOfDay(for: recording.startedAt)
            let end = recording.startedAt.addingTimeInterval(recording.duration)
            while day < end {
                dates.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
                day = next
            }
        }
        return dates.sorted(by: >)
    }
}
