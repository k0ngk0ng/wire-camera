import AVFoundation
import Foundation
import Vision

final class CameraRecordingLibrary {
    let directory: URL
    private(set) var entries: [CameraRecording] = []
    private let queue = DispatchQueue(label: "camera.person-index", qos: .utility)
    private var indexing: Set<String> = []
    var onChange: (() -> Void)?

    init(directory: URL) {
        self.directory = directory
        reload()
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        entries = urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(CameraRecording.self, from: data),
                  UUID(uuidString: entry.id) != nil, entry.duration.isFinite, entry.duration > 0,
                  entry.events.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.start < $0.end && $0.end <= entry.duration }),
                  FileManager.default.fileExists(atPath: movieURL(entry).path) else { return nil }
            return entry
        }.sorted { $0.startedAt > $1.startedAt }
        onChange?()
    }

    func movieURL(_ entry: CameraRecording) -> URL { directory.appendingPathComponent(entry.filename) }

    func nextURL() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let capacity, capacity < 100 * 1024 * 1024 { throw failure("存储空间不足，请释放至少 100 MB 后重试。") }
        return directory.appendingPathComponent(UUID().uuidString + ".mov")
    }

    func add(_ url: URL, sourceID: String, sourceName: String, startedAt: Date) throws {
        let asset = AVURLAsset(url: url)
        let duration = asset.duration.seconds
        guard duration.isFinite, duration > 0, !asset.tracks(withMediaType: .video).isEmpty, !asset.tracks(withMediaType: .audio).isEmpty else {
            throw failure("录像缺少可用的图像或声音，文件已保留：\(url.path)")
        }
        guard url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path else { return }
        let entry = CameraRecording(id: url.deletingPathExtension().lastPathComponent, sourceID: sourceID, sourceName: sourceName, startedAt: startedAt, duration: duration, events: [], indexState: "processing")
        try persist(entry)
        entries.insert(entry, at: 0)
        onChange?()
        index(entry)
    }

    func resumeIndexing() {
        for entry in entries where entry.indexState == "processing" || entry.indexState == "failed" { index(entry) }
    }

    func index(_ entry: CameraRecording) {
        guard !indexing.contains(entry.id) else { return }
        indexing.insert(entry.id)
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index].indexState = "processing"; onChange?() }
        let url = movieURL(entry)
        queue.async {
            var updated = entry
            do {
                let asset = AVURLAsset(url: url)
                guard let video = asset.tracks(withMediaType: .video).first else { throw self.failure("录像没有可分析的视频画面。") }
                let analysisDuration = min(entry.duration, video.timeRange.end.seconds)
                guard analysisDuration.isFinite, analysisDuration > 0 else { throw self.failure("录像的视频时长不正确。") }
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 640, height: 640)
                generator.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
                var detected: [Double] = []
                for second in stride(from: 0.0, to: analysisDuration, by: 1) {
                    try autoreleasepool {
                        let image = try generator.copyCGImage(at: CMTime(seconds: second, preferredTimescale: 600), actualTime: nil)
                        let request = VNDetectHumanRectanglesRequest()
                        request.upperBodyOnly = true
                        try VNImageRequestHandler(cgImage: image).perform([request])
                        if request.results?.contains(where: { $0.confidence >= 0.6 }) == true { detected.append(second) }
                    }
                }
                updated.events = Self.personEvents(times: detected, duration: analysisDuration)
                updated.indexState = "ready"
            } catch { updated.indexState = "failed" }
            let result = updated
            DispatchQueue.main.async {
                self.indexing.remove(entry.id)
                do { try self.persist(result) }
                catch {
                    if let index = self.entries.firstIndex(where: { $0.id == result.id }) { self.entries[index].indexState = "failed" }
                    self.onChange?()
                    return
                }
                if let index = self.entries.firstIndex(where: { $0.id == result.id }) { self.entries[index] = result }
                self.onChange?()
            }
        }
    }

    static func personEvents(times: [Double], duration: Double) -> [CameraPersonEvent] {
        var events: [CameraPersonEvent] = []
        for time in times.sorted() where time.isFinite && time >= 0 && time < duration {
            let start = max(0, time - 1)
            let end = min(duration, time + 2)
            if let last = events.last, start <= last.end {
                events[events.count - 1].end = max(last.end, end)
            } else { events.append(CameraPersonEvent(start: start, end: end)) }
        }
        return events
    }

    private func persist(_ entry: CameraRecording) throws {
        try JSONEncoder().encode(entry).write(to: directory.appendingPathComponent(entry.id + ".json"), options: .atomic)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "WireCamera.Library", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
