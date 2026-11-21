import AVFoundation
import Foundation

@main
struct CameraRecordingIndexE2E {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let movie = URL(fileURLWithPath: CommandLine.arguments[2])
        let library = CameraRecordingLibrary(directory: movie.deletingLastPathComponent())
        try library.add(movie, sourceID: "fixture:person", sourceName: "Fixture", startedAt: Date())
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline && library.entries.first?.indexState == "processing" { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        let entry = library.entries.first!
        let end = AVURLAsset(url: movie).tracks(withMediaType: .video).first!.timeRange.end.seconds
        let passed = entry.indexState == "ready" && !entry.events.isEmpty && entry.events.allSatisfy { $0.end <= end + 0.001 }
        let report: [String: Any] = ["passed": passed, "state": entry.indexState, "videoSeconds": end, "movieSeconds": entry.duration, "personEvents": entry.events.count]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("report.json"))
        print(String(data: data, encoding: .utf8)!)
        if !passed { exit(1) }
    }
}
