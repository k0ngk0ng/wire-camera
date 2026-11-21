import AVFoundation
import Foundation
import Vision

private final class CameraLibraryTask {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func perform(_ action: () throws -> Void) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        try action()
        return true
    }
}

final class CameraRecordingAccess {
    let url: URL
    private let release: () -> Void
    init(url: URL, release: @escaping () -> Void) { self.url = url; self.release = release }
    deinit { let release = release; DispatchQueue.main.async { release() } }
}

struct CameraRetentionResult {
    let removed: Int
    let errors: [String]
}

struct CameraStorageSummary {
    let directory: URL
    let usedBytes: Int64
    let dailyBytes: Double?
    let sourceCount: Int

    static func inspect(directory: URL, entries: [CameraRecording], sourceIDs: Set<String>? = nil) -> CameraStorageSummary {
        var used: Int64 = 0
        var samples: [String: [(Double, Int64)]] = [:]
        for entry in entries.sorted(by: { $0.startedAt > $1.startedAt }) {
            let movie = directory.appendingPathComponent(entry.filename)
            guard movie.resolvingSymlinksInPath().deletingLastPathComponent().path == directory.resolvingSymlinksInPath().path,
                  let bytes = (try? movie.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { continue }
            used += Int64(bytes)
            if let sidecar = (try? directory.appendingPathComponent(entry.id + ".json").resourceValues(forKeys: [.fileSizeKey]))?.fileSize { used += Int64(sidecar) }
            if (sourceIDs == nil || sourceIDs!.contains(entry.sourceID)), (55...70).contains(entry.duration), samples[entry.sourceID, default: []].count < 120 { samples[entry.sourceID, default: []].append((entry.duration, Int64(bytes))) }
        }
        let daily = samples.values.map { items in Double(items.reduce(0) { $0 + $1.1 }) / items.reduce(0) { $0 + $1.0 } * 86400 }.reduce(0, +)
        return CameraStorageSummary(directory: directory, usedBytes: used, dailyBytes: samples.isEmpty ? nil : daily, sourceCount: samples.count)
    }
}

final class CameraRecordingLibrary {
    let directory: URL
    private(set) var entries: [CameraRecording] = []
    private let queue = DispatchQueue(label: "camera.person-index", qos: .utility)
    private var indexing: [String: CameraLibraryTask] = [:]
    private var readers: [String: Int] = [:]
    private var deleting: Set<String> = []
    private let cleanupQueue = DispatchQueue(label: "camera.retention", qos: .utility)
    private var cleanupTask: CameraLibraryTask?
    private var retentionDays = 0
    private var lastCleanup: Date?
    var isCleaning: Bool { cleanupTask != nil }
    var onChange: (() -> Void)?
    var onCleanup: ((CameraRetentionResult) -> Void)?

    init(directory: URL) {
        self.directory = directory
        reload()
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        entries = urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let entry = Self.metadata(at: url, directory: directory),
                  FileManager.default.fileExists(atPath: movieURL(entry).path) else { return nil }
            return entry
        }.sorted { $0.startedAt > $1.startedAt }
        onChange?()
    }

    func movieURL(_ entry: CameraRecording) -> URL { directory.appendingPathComponent(entry.filename) }

    func access(_ entry: CameraRecording) -> CameraRecordingAccess? {
        let url = movieURL(entry).resolvingSymlinksInPath()
        guard !deleting.contains(entry.id), entries.contains(where: { $0.id == entry.id }),
              url.deletingLastPathComponent().path == directory.resolvingSymlinksInPath().path,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        readers[entry.id, default: 0] += 1
        return CameraRecordingAccess(url: url) { [weak self] in
            guard let self else { return }
            let count = self.readers[entry.id, default: 1] - 1
            if count <= 0 { self.readers.removeValue(forKey: entry.id) } else { self.readers[entry.id] = count }
        }
    }

    func activeReaders(_ id: String) -> Int { readers[id, default: 0] }

    func enforceRetention(days: Int, now: Date = Date(), protecting: Set<String> = [], force: Bool = false) {
        guard (0...3650).contains(days) else { return }
        if retentionDays != days { cleanupTask?.cancel(); retentionDays = days; lastCleanup = nil }
        guard days > 0, cleanupTask == nil, force || lastCleanup == nil || now.timeIntervalSince(lastCleanup!) >= 300 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        let protected = protecting.union(readers.keys)
        let candidates = entries.filter { $0.startedAt.addingTimeInterval($0.duration) <= cutoff && !protected.contains($0.id) }
        let identifiers = Set(candidates.map { $0.id })
        deleting.formUnion(identifiers)
        for id in identifiers { indexing.removeValue(forKey: id)?.cancel() }
        let task = CameraLibraryTask()
        cleanupTask = task
        lastCleanup = now
        let directory = directory
        cleanupQueue.async {
            var removed: Set<String> = []
            var errors: [String] = []
            for entry in candidates {
                if task.isCancelled { break }
                let movie = directory.appendingPathComponent(entry.filename)
                let metadata = directory.appendingPathComponent(entry.id + ".json")
                guard movie.resolvingSymlinksInPath().deletingLastPathComponent().path == directory.resolvingSymlinksInPath().path,
                      let current = Self.metadata(at: metadata, directory: directory), current.startedAt.addingTimeInterval(current.duration) <= cutoff else { continue }
                do {
                    _ = try task.perform {
                        if FileManager.default.fileExists(atPath: movie.path) { try FileManager.default.removeItem(at: movie) }
                        removed.insert(entry.id)
                        try FileManager.default.removeItem(at: metadata)
                    }
                } catch { errors.append(entry.filename + "：" + error.localizedDescription) }
            }
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension == "json" {
                if task.isCancelled { break }
                guard let entry = Self.metadata(at: url, directory: directory), !protected.contains(entry.id), entry.startedAt.addingTimeInterval(entry.duration) <= cutoff,
                      !FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.filename).path) else { continue }
                do { _ = try task.perform { try FileManager.default.removeItem(at: url) } }
                catch { errors.append(url.lastPathComponent + "：" + error.localizedDescription) }
            }
            let result = CameraRetentionResult(removed: removed.count, errors: errors)
            let removedIDs = removed
            DispatchQueue.main.async {
                guard self.cleanupTask === task else { return }
                self.cleanupTask = nil
                self.deleting.subtract(identifiers)
                self.entries.removeAll { removedIDs.contains($0.id) }
                self.onChange?()
                self.onCleanup?(result)
                self.resumeIndexing()
            }
        }
    }

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
        guard indexing[entry.id] == nil, !deleting.contains(entry.id) else { return }
        let task = CameraLibraryTask()
        indexing[entry.id] = task
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index].indexState = "processing"; onChange?() }
        let url = movieURL(entry)
        queue.async {
            guard !task.isCancelled else { return }
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
                    if task.isCancelled { throw CancellationError() }
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
                guard self.indexing[entry.id] === task, !task.isCancelled, self.entries.contains(where: { $0.id == entry.id }) else { return }
                self.indexing.removeValue(forKey: entry.id)
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

    private static func metadata(at url: URL, directory: URL) -> CameraRecording? {
        guard url.resolvingSymlinksInPath().deletingLastPathComponent().path == directory.resolvingSymlinksInPath().path,
              let data = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(CameraRecording.self, from: data),
              UUID(uuidString: entry.id) != nil, url.deletingPathExtension().lastPathComponent == entry.id,
              entry.startedAt.timeIntervalSince1970.isFinite, entry.duration.isFinite, entry.duration > 0,
              entry.events.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.start < $0.end && $0.end <= entry.duration }) else { return nil }
        return entry
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "WireCamera.Library", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
