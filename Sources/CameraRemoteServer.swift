import Foundation
import Network

private final class CameraRemotePeer {
    let id = UUID()
    let connection: NWConnection
    var buffer = Data()
    var sourceID: String?
    var queuedBytes = 0
    var closed = false
    var file: FileHandle?
    var access: CameraRecordingAccess?

    init(_ connection: NWConnection) { self.connection = connection }
}

final class CameraRemoteServer {
    private let queue = DispatchQueue(label: "camera.remote-server")
    private var listener: NWListener?
    private var peers: [UUID: CameraRemotePeer] = [:]
    private var challenges: [String: Date] = [:]
    private var attempts: [String: [Date]] = [:]
    private var password = ""
    private var fingerprint = ""
    private var heartbeat: DispatchSourceTimer?
    private(set) var port: UInt16 = 0
    var onCameras: (() -> [CameraRemoteDevice])?
    var onRecordings: (() -> [CameraRecording])?
    var onMovieAccess: ((CameraRecording) -> CameraRecordingAccess?)?
    var onViewersChanged: ((Set<String>) -> Void)?
    var onState: ((String) -> Void)?

    func start(identity: CameraRemoteIdentity, completion: @escaping (Result<UInt16, Error>) -> Void) throws {
        let parameters = try identity.parameters()
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: identity.settings.port)!)
        password = identity.settings.password
        fingerprint = identity.fingerprint
        self.listener = listener
        listener.service = NWListener.Service(name: Host.current().localizedName ?? "WireCamera", type: "_wirecamera._tcp")
        var completed = false
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                self.port = listener.port?.rawValue ?? 0
                if !completed { completed = true; DispatchQueue.main.async { completion(.success(self.port)) } }
            case .failed(let error):
                if !completed { completed = true; DispatchQueue.main.async { completion(.failure(error)) } }
                DispatchQueue.main.async { self.onState?("手机连接服务已停止：" + error.localizedDescription) }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for peer in self.peers.values where peer.sourceID != nil { self.stream(Data(), kind: 0, to: peer) }
        }
        timer.resume()
        heartbeat = timer
    }

    func stop() {
        queue.sync {
            self.listener?.cancel(); self.listener = nil
            self.heartbeat?.cancel(); self.heartbeat = nil
            for peer in Array(self.peers.values) { self.close(peer) }
            self.challenges.removeAll()
        }
    }

    func publish(_ data: Data, kind: UInt8, sourceID: String) {
        queue.async {
            for peer in self.peers.values where peer.sourceID == sourceID { self.stream(data, kind: kind, to: peer) }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard peers.count < 32 else { connection.cancel(); return }
        let peer = CameraRemotePeer(connection)
        peers[peer.id] = peer
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            switch state {
            case .ready: self.receive(peer)
            case .failed, .cancelled: self.close(peer)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 12) { [weak self, weak peer] in
            if let peer, peer.sourceID == nil && peer.file == nil { self?.close(peer) }
        }
    }

    private func close(_ peer: CameraRemotePeer) {
        guard !peer.closed else { return }
        peer.closed = true
        try? peer.file?.close()
        peer.file = nil
        peer.access = nil
        peers.removeValue(forKey: peer.id)
        peer.connection.cancel()
        if peer.sourceID != nil { viewersChanged() }
    }

    private func viewersChanged() {
        let sources = Set(peers.values.compactMap { $0.sourceID })
        DispatchQueue.main.async { self.onViewersChanged?(sources) }
    }

    private func receive(_ peer: CameraRemotePeer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self, weak peer] data, _, complete, error in
            guard let self, let peer, !peer.closed else { return }
            if let data { peer.buffer.append(data) }
            guard peer.buffer.count <= 24 * 1024 else { self.respond(peer, status: 413); return }
            if let end = peer.buffer.range(of: Data("\r\n\r\n".utf8)) {
                guard let header = String(data: peer.buffer[..<end.lowerBound], encoding: .utf8) else { self.respond(peer, status: 400); return }
                let lines = header.components(separatedBy: "\r\n")
                let first = lines[0].split(separator: " ")
                guard first.count == 3, ["GET", "POST", "HEAD"].contains(String(first[0])), first[2] == "HTTP/1.1" else { self.respond(peer, status: 400); return }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { self.respond(peer, status: 400); return }
                    let name = line[..<colon].lowercased()
                    guard headers[name] == nil else { self.respond(peer, status: 400); return }
                    headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                guard headers["transfer-encoding"] == nil, let length = Int(headers["content-length"] ?? "0"), (0...8192).contains(length) else { self.respond(peer, status: 400); return }
                if peer.buffer.count >= end.upperBound + length {
                    let body = Data(peer.buffer[end.upperBound..<(end.upperBound + length)])
                    peer.buffer.removeAll()
                    self.route(peer, method: String(first[0]), target: String(first[1]), headers: headers, body: body)
                    return
                }
            }
            if complete || error != nil { self.close(peer) } else { self.receive(peer) }
        }
    }

    private func route(_ peer: CameraRemotePeer, method: String, target: String, headers: [String: String], body: Data) {
        guard target.hasPrefix("/"), !target.hasPrefix("//"), let url = URLComponents(string: "https://localhost" + target) else { respond(peer, status: 400); return }
        let path = url.path
        if path == "/v1/challenge", method == "GET" {
            challenges = challenges.filter { $0.value > Date() }
            guard challenges.count < 128 else { respond(peer, status: 429); return }
            let nonce = CameraRemoteCoding.randomSecret()
            challenges[nonce] = Date().addingTimeInterval(60)
            json(peer, value: CameraRemoteChallenge(nonce: nonce, proof: CameraRemoteCoding.proof("server|\(nonce)|\(fingerprint)", password: password)))
            return
        }
        if path == "/v1/pair", method == "POST" {
            let host: String
            if case .hostPort(let endpoint, _) = peer.connection.endpoint { host = String(describing: endpoint) } else { host = "unknown" }
            attempts[host] = attempts[host, default: []].filter { Date().timeIntervalSince($0) < 60 }
            guard attempts[host, default: []].count < 8 else { respond(peer, status: 429); return }
            attempts[host, default: []].append(Date())
            guard let request = try? JSONDecoder().decode(CameraRemotePairRequest.self, from: body),
                  let expires = challenges.removeValue(forKey: request.nonce), expires > Date(),
                  CameraRemoteCoding.matches(request.proof, message: "client|\(request.nonce)|\(fingerprint)", password: password) else { respond(peer, status: 401); return }
            let payload = CameraRemoteCoding.randomSecret() + "." + String(Int(Date().addingTimeInterval(30 * 86400).timeIntervalSince1970))
            json(peer, value: CameraRemotePairResult(token: payload + "." + CameraRemoteCoding.proof("token|" + payload, password: password)))
            return
        }
        guard let authorization = headers["authorization"], authorization.hasPrefix("Bearer "), validToken(String(authorization.dropFirst(7))) else { respond(peer, status: 401); return }
        guard method == "GET" || method == "HEAD" else { respond(peer, status: 405); return }
        let sourceID = url.queryItems?.first { $0.name == "sourceID" }?.value
        if path == "/v1/cameras" {
            DispatchQueue.main.async {
                let cameras = self.onCameras?() ?? []
                self.queue.async { self.json(peer, value: cameras) }
            }
        } else if path == "/v1/recordings" {
            DispatchQueue.main.async {
                let recordings = (self.onRecordings?() ?? []).filter { sourceID == nil || $0.sourceID == sourceID }
                self.queue.async { self.json(peer, value: recordings) }
            }
        } else if path == "/v1/live", let sourceID, method == "GET" {
            DispatchQueue.main.async {
                let available = self.onCameras?().contains { $0.id == sourceID && $0.online } ?? false
                self.queue.async {
                    guard !peer.closed else { return }
                    guard available else { self.respond(peer, status: 404); return }
                    guard self.peers.values.filter({ $0.sourceID != nil }).count < 8 else { self.respond(peer, status: 429); return }
                    peer.sourceID = sourceID
                    let header = "HTTP/1.1 200 OK\r\nContent-Type: application/x-wirecamera-stream\r\nTransfer-Encoding: chunked\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                    peer.connection.send(content: Data(header.utf8), completion: .contentProcessed { error in if error != nil { self.queue.async { self.close(peer) } } })
                    self.viewersChanged()
                    peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in self.queue.async { self.close(peer) } }
                }
            }
        } else {
            let components = path.split(separator: "/")
            guard components.count == 4, components[0] == "v1", components[1] == "recordings", components[3] == "movie", UUID(uuidString: String(components[2])) != nil else { respond(peer, status: 404); return }
            let id = String(components[2])
            DispatchQueue.main.async {
                let entry = self.onRecordings?().first { $0.id == id }
                let access = entry.flatMap { self.onMovieAccess?($0) ?? nil }
                self.queue.async {
                    guard !peer.closed else { return }
                    guard let access else { self.respond(peer, status: 404); return }
                    peer.access = access
                    self.movie(peer, url: access.url, range: headers["range"], head: method == "HEAD")
                }
            }
        }
    }

    private func validToken(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 43, let expires = TimeInterval(parts[1]), expires > Date().timeIntervalSince1970 else { return false }
        return CameraRemoteCoding.matches(String(parts[2]), message: "token|\(parts[0]).\(parts[1])", password: password)
    }

    private func json<Value: Encodable>(_ peer: CameraRemotePeer, value: Value) {
        guard let data = try? CameraRemoteCoding.encoder.encode(value) else { respond(peer, status: 500); return }
        respond(peer, status: 200, data: data, type: "application/json")
    }

    private func respond(_ peer: CameraRemotePeer, status: Int, data: Data = Data(), type: String = "text/plain", headers: String = "") {
        guard !peer.closed else { return }
        let response = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Response")\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\(headers)\r\n"
        peer.connection.send(content: Data(response.utf8) + data, completion: .contentProcessed { _ in self.queue.async { self.close(peer) } })
    }

    private func movie(_ peer: CameraRemotePeer, url: URL, range: String?, head: Bool) {
        do {
            let file = try FileHandle(forReadingFrom: url)
            peer.file = file
            let total = try file.seekToEnd()
            guard total > 0 else { respond(peer, status: 404); return }
            var first: UInt64 = 0, last = total - 1
            if let range {
                guard range.hasPrefix("bytes="), !range.contains(",") else { respond(peer, status: 416, headers: "Content-Range: bytes */\(total)\r\n"); return }
                let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                guard parts.count == 2 else { respond(peer, status: 416); return }
                if parts[0].isEmpty {
                    guard let suffix = UInt64(parts[1]), suffix > 0 else { respond(peer, status: 416); return }
                    first = total - min(total, suffix)
                } else {
                    guard let start = UInt64(parts[0]), start < total else { respond(peer, status: 416, headers: "Content-Range: bytes */\(total)\r\n"); return }
                    first = start
                    if !parts[1].isEmpty {
                        guard let end = UInt64(parts[1]), end >= first else { respond(peer, status: 416); return }
                        last = min(last, end)
                    }
                }
            }
            let length = last - first + 1
            var header = "HTTP/1.1 \(range == nil ? "200 OK" : "206 Partial Content")\r\nContent-Type: video/quicktime\r\nAccept-Ranges: bytes\r\nContent-Length: \(length)\r\nCache-Control: private, no-store\r\nConnection: close\r\n"
            if range != nil { header += "Content-Range: bytes \(first)-\(last)/\(total)\r\n" }
            header += "\r\n"
            try file.seek(toOffset: first)
            peer.connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
                self.queue.async {
                    if error != nil || head { self.close(peer) } else { self.sendFile(peer, remaining: length) }
                }
            })
        } catch { respond(peer, status: 404) }
    }

    private func sendFile(_ peer: CameraRemotePeer, remaining: UInt64) {
        guard !peer.closed, remaining > 0 else { close(peer); return }
        do {
            guard let data = try peer.file?.read(upToCount: Int(min(remaining, 128 * 1024))), !data.isEmpty else { close(peer); return }
            peer.connection.send(content: data, completion: .contentProcessed { error in
                self.queue.async {
                    if error != nil { self.close(peer) } else { self.sendFile(peer, remaining: remaining - UInt64(data.count)) }
                }
            })
        } catch { close(peer) }
    }

    private func stream(_ data: Data, kind: UInt8, to peer: CameraRemotePeer) {
        guard !peer.closed else { return }
        guard peer.queuedBytes < 512 * 1024 else { close(peer); return }
        var packet = Data([kind])
        var count = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &count) { packet.append(contentsOf: $0) }
        packet.append(data)
        let chunk = Data(String(packet.count, radix: 16).utf8) + Data("\r\n".utf8) + packet + Data("\r\n".utf8)
        peer.queuedBytes += chunk.count
        peer.connection.send(content: chunk, completion: .contentProcessed { error in
            self.queue.async { peer.queuedBytes -= chunk.count; if error != nil { self.close(peer) } }
        })
    }
}
