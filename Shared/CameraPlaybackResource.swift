import AVFoundation
import Foundation

private final class CameraPlaybackRead {
    let request: AVAssetResourceLoadingRequest
    var offset: Int64 = 0
    var limit: Int64 = 0
    var prepared = false
    var taskID: Int?
    init(_ request: AVAssetResourceLoadingRequest) { self.request = request }
}

private final class CameraPlaybackTransfer {
    enum Kind { case lease, head, renew, range(ObjectIdentifier) }
    let kind: Kind
    var body = Data()
    var expected: Int64 = 0
    var received: Int64 = 0
    init(_ kind: Kind) { self.kind = kind }
}

final class CameraPlaybackResource: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    let asset: AVURLAsset
    private let original: URLRequest
    private let fingerprint: String
    private let trust: CameraRemoteTrust
    private let queue = DispatchQueue(label: "camera.playback-resource")
    private var session: URLSession?
    private var transfers: [Int: CameraPlaybackTransfer] = [:]
    private var tasks: [Int: URLSessionDataTask] = [:]
    private var reads: [ObjectIdentifier: CameraPlaybackRead] = [:]
    private var ticket: CameraPlaybackTicket?
    private var length: Int64?
    private var heartbeat: DispatchSourceTimer?
    private var closed = false
    private var suspended = false
    private var keepLease = true
    var onError: ((Error) -> Void)?

    init(request: URLRequest, fingerprint: String) {
        original = request
        self.fingerprint = fingerprint
        trust = CameraRemoteTrust(fingerprint: fingerprint)
        asset = AVURLAsset(url: URL(string: "wirecamera-playback://asset/\(UUID().uuidString).mov")!, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    func makeItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 3
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        return item
    }

    func close() { queue.async { self.finish(error: nil) } }

    func setSuspended(_ value: Bool, keepLease: Bool = true) {
        queue.async {
            guard !self.closed else { return }
            self.suspended = value; self.keepLease = keepLease
            if value {
                for read in self.reads.values {
                    if let id = read.taskID { self.tasks.removeValue(forKey: id)?.cancel(); self.transfers.removeValue(forKey: id); read.taskID = nil }
                }
                if !keepLease { self.heartbeat?.cancel(); self.heartbeat = nil; if let ticket = self.ticket { self.release(ticket.id) }; self.ticket = nil }
            } else { self.pump() }
        }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !closed else { loadingRequest.finishLoading(with: failure("回放已关闭。")); return true }
        reads[ObjectIdentifier(loadingRequest)] = CameraPlaybackRead(loadingRequest)
        pump()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        if let read = reads.removeValue(forKey: ObjectIdentifier(loadingRequest)), let id = read.taskID { transfers.removeValue(forKey: id); tasks.removeValue(forKey: id)?.cancel() }
    }

    private func network() -> URLSession {
        if let session { return session }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.httpMaximumConnectionsPerHost = 4
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1; delegateQueue.underlyingQueue = queue
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        return session
    }

    private func start(_ request: URLRequest, kind: CameraPlaybackTransfer.Kind, expected: Int64 = 0) -> Int {
        let task = network().dataTask(with: request)
        let transfer = CameraPlaybackTransfer(kind); transfer.expected = expected
        transfers[task.taskIdentifier] = transfer; tasks[task.taskIdentifier] = task
        task.resume()
        return task.taskIdentifier
    }

    private func control(_ suffix: String, method: String) -> URLRequest {
        var request = original
        request.httpMethod = method
        request.url = original.url!.deletingLastPathComponent().appendingPathComponent(suffix)
        return request
    }

    private func ticketRequest(_ id: String, method: String) -> URLRequest {
        var request = original
        var url = URLComponents(url: original.url!, resolvingAgainstBaseURL: false)!
        url.path = "/v1/playback/" + id; url.query = nil
        request.url = url.url; request.httpMethod = method
        return request
    }

    private func pump() {
        guard !closed, !suspended, !reads.isEmpty else { return }
        if ticket == nil {
            guard !transfers.values.contains(where: { if case .lease = $0.kind { return true }; return false }) else { return }
            _ = start(control("playback", method: "POST"), kind: .lease)
            return
        }
        if length == nil {
            guard !transfers.values.contains(where: { if case .head = $0.kind { return true }; return false }) else { return }
            var request = original; request.httpMethod = "HEAD"
            request.setValue(ticket!.id, forHTTPHeaderField: "X-WireCamera-Playback")
            _ = start(request, kind: .head)
            return
        }
        for (id, read) in Array(reads) {
            if read.request.isCancelled { reads.removeValue(forKey: id); continue }
            if !read.prepared {
                if let information = read.request.contentInformationRequest {
                    information.contentType = AVFileType.mov.rawValue
                    information.contentLength = length!
                    information.isByteRangeAccessSupported = true
                    information.isEntireLengthAvailableOnDemand = false
                }
                guard let data = read.request.dataRequest else { read.request.finishLoading(); reads.removeValue(forKey: id); continue }
                guard data.requestedOffset >= 0, data.requestedLength >= 0, data.requestedOffset <= length! else { finish(error: failure("录像读取位置超出范围。")); return }
                read.offset = max(data.requestedOffset, data.currentOffset)
                let end = data.requestedOffset.addingReportingOverflow(Int64(data.requestedLength))
                read.limit = data.requestsAllDataToEndOfResource || end.overflow ? length! : min(length!, end.partialValue)
                read.prepared = true
            }
            if read.offset >= read.limit { read.request.finishLoading(); reads.removeValue(forKey: id); continue }
            guard read.taskID == nil else { continue }
            let last = min(read.limit - 1, read.offset + 256 * 1024 - 1)
            var request = original
            request.setValue("bytes=\(read.offset)-\(last)", forHTTPHeaderField: "Range")
            request.setValue(ticket!.id, forHTTPHeaderField: "X-WireCamera-Playback")
            read.taskID = start(request, kind: .range(id), expected: last - read.offset + 1)
        }
    }

    private func startHeartbeat() {
        guard heartbeat == nil, !closed else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self, let ticket = self.ticket, !self.closed, !self.suspended || self.keepLease else { return }
            if !self.transfers.values.contains(where: { if case .renew = $0.kind { return true }; return false }) { _ = self.start(self.ticketRequest(ticket.id, method: "PUT"), kind: .renew) }
        }
        timer.resume(); heartbeat = timer
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) { trust.urlSession(session, didReceive: challenge, completionHandler: completionHandler) }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let transfer = transfers[dataTask.taskIdentifier], let response = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        if closed { completionHandler({ if case .lease = transfer.kind { return .allow }; return .cancel }()); return }
        guard (200..<300).contains(response.statusCode) else {
            let message: String
            if response.statusCode == 401 { message = "连接凭据已过期，请重新连接 Mac。" }
            else if response.statusCode == 404 || response.statusCode == 405, case .lease = transfer.kind { message = "请先更新 Mac 端 WireCamera，以使用流式回放。" }
            else { message = "录像暂时无法读取（\(response.statusCode)），请刷新后重试。" }
            completionHandler(.cancel); finish(error: failure(message)); return
        }
        switch transfer.kind {
        case .head:
            guard response.expectedContentLength > 0, response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes" else { completionHandler(.cancel); finish(error: failure("Mac 未提供可定位的录像数据。")); return }
            length = response.expectedContentLength
        case .range(let id):
            guard let read = reads[id], response.statusCode == 206,
                  response.expectedContentLength == transfer.expected,
                  response.value(forHTTPHeaderField: "Content-Range") == "bytes \(read.offset)-\(read.offset + transfer.expected - 1)/\(length!)" else { completionHandler(.cancel); finish(error: failure("录像范围响应不正确，请重新连接。")); return }
        default: break
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfers[dataTask.taskIdentifier] else { return }
        switch transfer.kind {
        case .range(let id):
            guard !closed, let read = reads[id], read.taskID == dataTask.taskIdentifier, !read.request.isCancelled else { return }
            guard transfer.received + Int64(data.count) <= transfer.expected else { finish(error: failure("录像数据超出请求范围。")); return }
            read.request.dataRequest?.respond(with: data)
            transfer.received += Int64(data.count); read.offset += Int64(data.count)
        case .lease:
            guard transfer.body.count + data.count <= 4096 else { finish(error: failure("播放连接响应过大。")); return }
            transfer.body.append(data)
        default: break
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = transfers.removeValue(forKey: task.taskIdentifier) else { return }
        tasks.removeValue(forKey: task.taskIdentifier)
        if closed {
            if case .lease = transfer.kind {
                if error == nil, let ticket = try? JSONDecoder().decode(CameraPlaybackTicket.self, from: transfer.body) { release(ticket.id) }
                session.invalidateAndCancel(); self.session = nil
            }
            return
        }
        if let error { finish(error: error); return }
        switch transfer.kind {
        case .lease:
            guard let value = try? JSONDecoder().decode(CameraPlaybackTicket.self, from: transfer.body), !value.id.isEmpty else { finish(error: failure("播放连接响应不正确。")); return }
            if suspended && !keepLease { release(value.id) }
            else { ticket = value; startHeartbeat() }
        case .range(let id):
            guard let read = reads[id] else { return }
            read.taskID = nil
            guard transfer.received == transfer.expected else { finish(error: failure("录像传输中断，请重新定位播放。")); return }
        default: break
        }
        pump()
    }

    private func finish(error: Error?) {
        guard !closed else { return }
        closed = true
        heartbeat?.cancel(); heartbeat = nil
        for read in reads.values where !read.request.isCancelled && !read.request.isFinished { read.request.finishLoading(with: error ?? failure("播放已取消。")) }
        reads.removeAll()
        var awaitingLease = false
        for (id, transfer) in Array(transfers) {
            if case .lease = transfer.kind { awaitingLease = true; continue }
            tasks.removeValue(forKey: id)?.cancel(); transfers.removeValue(forKey: id)
        }
        if let ticket { release(ticket.id); self.ticket = nil }
        if !awaitingLease { session?.invalidateAndCancel(); session = nil }
        if let error { onError?(error) }
        onError = nil
    }

    private func release(_ id: String) {
        let request = ticketRequest(id, method: "DELETE")
        let delegate = CameraRemoteTrust(fingerprint: fingerprint)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        session.dataTask(with: request) { _, _, _ in session.finishTasksAndInvalidate() }.resume()
    }

    private func failure(_ message: String) -> NSError { NSError(domain: "WireCamera.Playback", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
