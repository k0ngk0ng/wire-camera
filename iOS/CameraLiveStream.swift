import AVFoundation
import Foundation
import UIKit

final class CameraLiveStream: NSObject, URLSessionDataDelegate {
    private let trust: CameraRemoteTrust
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private let engine = AVAudioEngine()
    private let audioPlayer = AVAudioPlayerNode()
    private let audioLock = NSLock()
    private var queuedAudio = 0
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false)!
    var onImage: ((UIImage) -> Void)?
    var onError: ((String) -> Void)?

    init(fingerprint: String) { trust = CameraRemoteTrust(fingerprint: fingerprint); super.init() }

    func start(client: CameraRemoteClient, sourceID: String) throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try AVAudioSession.sharedInstance().setActive(true)
        engine.attach(audioPlayer)
        engine.connect(audioPlayer, to: engine.mainMixerNode, format: format)
        try engine.start()
        audioPlayer.play()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 86400
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        task = session.dataTask(with: try client.request("/v1/live", query: [URLQueryItem(name: "sourceID", value: sourceID)]))
        task?.resume()
    }

    func stop() {
        onImage = nil; onError = nil
        task?.cancel(); session?.invalidateAndCancel()
        task = nil; session = nil
        audioPlayer.stop(); engine.stop()
    }

    func setMuted(_ muted: Bool) { audioPlayer.volume = muted ? 0 : 1 }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) { trust.urlSession(session, didReceive: challenge, completionHandler: completionHandler) }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do { try CameraRemoteClient.validate(response); completionHandler(.allow) }
        catch { onError?(error.localizedDescription); completionHandler(.cancel) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        while buffer.count >= 5 {
            let kind = buffer[buffer.startIndex]
            let count = buffer.dropFirst().prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard count <= 4 * 1024 * 1024 else { onError?("实时数据格式不正确，请重新连接。"); task?.cancel(); return }
            guard buffer.count >= count + 5 else { break }
            let payload = Data(buffer.dropFirst(5).prefix(count))
            buffer.removeFirst(count + 5)
            if kind == 1, let image = UIImage(data: payload) { onImage?(image) }
            else if kind == 2 { playAudio(payload) }
            else if kind == 3, let message = String(data: payload, encoding: .utf8), !message.isEmpty { onError?(message) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled { onError?("实时连接已断开：" + error.localizedDescription) }
        else if error == nil { onError?("实时连接已结束，请重试。") }
    }

    private func playAudio(_ data: Data) {
        let frames = data.count / 2
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)), let channel = pcm.floatChannelData?.pointee else { return }
        audioLock.lock()
        guard queuedAudio + frames <= 8000 else { audioLock.unlock(); return }
        queuedAudio += frames
        audioLock.unlock()
        pcm.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { bytes in
            for index in 0..<frames { channel[index] = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768 }
        }
        audioPlayer.scheduleBuffer(pcm) { [weak self] in
            guard let self else { return }
            self.audioLock.lock(); self.queuedAudio -= frames; self.audioLock.unlock()
        }
    }
}
