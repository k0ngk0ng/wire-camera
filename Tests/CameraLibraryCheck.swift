import AVFoundation
import Foundation

@main
struct CameraLibraryCheck {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let library = CameraRecordingLibrary(directory: directory)
        var checks: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) { checks.append(["name": name, "passed": value]) }
        check("missing_directory_is_empty", library.entries.isEmpty)
        let events = CameraRecordingLibrary.personEvents(times: [1, 2, 3, 10, 11], duration: 12)
        check("nearby_detections_grouped", events.count == 2)
        check("events_in_video_range", events.allSatisfy { $0.start >= 0 && $0.end <= 12 && $0.start < $0.end })
        check("no_human_no_events", CameraRecordingLibrary.personEvents(times: [], duration: 10).isEmpty)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken metadata".utf8).write(to: directory.appendingPathComponent("broken.json"))
        try Data().write(to: directory.appendingPathComponent("unfinished.partial.mov"))
        library.reload()
        check("corrupt_metadata_and_partial_ignored", library.entries.isEmpty)
        let report: [String: Any] = ["passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.deletingLastPathComponent().appendingPathComponent("report.json"))
        print(String(data: data, encoding: .utf8)!)
        if report["passed"] as? Bool != true { exit(1) }
    }
}
