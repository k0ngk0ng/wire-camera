import Foundation

@main
struct CameraPlaybackDayCheck {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
        }
        func recording(_ start: Date, _ duration: Double) -> CameraRecording {
            CameraRecording(id: UUID().uuidString, sourceID: "wifi:fixture", sourceName: "Fixture", startedAt: start, duration: duration, events: [], indexState: "ready")
        }
        var checks: [[String: Any]] = []
        func check(_ name: String, _ result: Bool) { checks.append(["name": name, "passed": result]) }
        let first = recording(date(2026, 11, 21, 12), 60)
        let second = recording(date(2026, 11, 21, 12, 1), 30)
        let later = recording(date(2026, 11, 21, 13), 60)
        let day = CameraPlaybackDay(date: first.startedAt, recordings: [later, second, first], calendar: calendar)
        check("ordinary_day_is_24_hours", day.interval.duration == 86400)
        check("first_segment_offset", day.position(at: first.startedAt.addingTimeInterval(12))?.offset == 12)
        check("boundary_selects_next_segment", day.position(at: second.startedAt)?.recording.id == second.id)
        check("gap_returns_no_recording", day.position(at: date(2026, 11, 21, 12, 5)) == nil)
        check("gap_can_find_next_recording", day.position(at: date(2026, 11, 21, 12, 5), snapForward: true)?.recording.id == later.id)
        check("after_final_segment_is_empty", day.position(at: date(2026, 11, 21, 14), snapForward: true) == nil)
        let overlap = recording(first.startedAt.addingTimeInterval(30), 60)
        let overlapping = CameraPlaybackDay(date: first.startedAt, recordings: [overlap, first], calendar: calendar)
        check("overlap_uses_latest_start", overlapping.position(at: first.startedAt.addingTimeInterval(40))?.recording.id == overlap.id)
        let midnight = recording(date(2026, 11, 21, 23, 59, 58), 4)
        let nextDay = CameraPlaybackDay(date: date(2026, 11, 22), recordings: [midnight], calendar: calendar)
        check("cross_midnight_offset", nextDay.position(at: nextDay.interval.start)?.offset == 2)
        check("cross_midnight_lists_both_dates", CameraPlaybackDay.availableDates(recordings: [midnight], calendar: calendar).count == 2)
        let endingAtMidnight = recording(date(2026, 11, 21, 23, 59), 60)
        check("exclusive_midnight_end", CameraPlaybackDay.availableDates(recordings: [endingAtMidnight], calendar: calendar).count == 1)
        check("spring_day_is_23_hours", CameraPlaybackDay(date: date(2026, 3, 8), recordings: [], calendar: calendar).interval.duration == 23 * 3600)
        check("fall_day_is_25_hours", CameraPlaybackDay(date: date(2026, 11, 1), recordings: [], calendar: calendar).interval.duration == 25 * 3600)
        let legacy = Data("{\"id\":\"2E510A05-F12B-47B7-9263-A464B0876DB4\",\"sourceID\":\"wifi:legacy\",\"sourceName\":\"Legacy\",\"startedAt\":0,\"duration\":60,\"events\":[{\"start\":2,\"end\":3}],\"indexState\":\"ready\"}".utf8)
        let decoded = try JSONDecoder().decode(CameraRecording.self, from: legacy)
        check("legacy_metadata_remains_readable", decoded.sourceID == "wifi:legacy" && decoded.events.first?.start == 2)
        let report: [String: Any] = ["passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print(String(data: try JSONSerialization.data(withJSONObject: report), encoding: .utf8)!)
        if report["passed"] as? Bool != true { exit(1) }
    }
}
