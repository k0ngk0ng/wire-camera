import AVFoundation
import Foundation

final class CameraNetworkRecorder {
    private let queue = DispatchQueue(label: "camera.network-recording")
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var target: URL?
    private var staging: URL?
    private var firstTime: CMTime?
    private var lastVideoTime = CMTime.invalid
    private var lastAudioTime = CMTime.invalid
    private var videoCount = 0
    private var audioCount = 0
    private var mirrored = false
    var onRecording: ((RecordingEvent) -> Void)?

    func start(to url: URL, mirrored: Bool) {
        queue.async {
            guard self.target == nil else { return }
            self.target = url
            self.staging = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial.mov")
            self.mirrored = mirrored
            self.videoCount = 0
            self.audioCount = 0
            self.firstTime = nil
            self.lastVideoTime = .invalid
            self.lastAudioTime = .invalid
            self.publish(.starting)
        }
    }

    func appendVideo(_ sample: CMSampleBuffer) { append(sample, isVideo: true) }
    func appendAudio(_ sample: CMSampleBuffer) { append(sample, isVideo: false) }

    private func append(_ sample: CMSampleBuffer, isVideo: Bool) {
        queue.async {
            guard self.target != nil else { return }
            do {
                if self.writer == nil {
                    guard isVideo, let format = CMSampleBufferGetFormatDescription(sample), let staging = self.staging else { return }
                    let size = CMVideoFormatDescriptionGetDimensions(format)
                    let writer = try AVAssetWriter(outputURL: staging, fileType: .mov)
                    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height])
                    video.expectsMediaDataInRealTime = true
                    if self.mirrored { video.transform = CGAffineTransform(translationX: CGFloat(size.width), y: 0).scaledBy(x: -1, y: 1) }
                    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 24000])
                    audio.expectsMediaDataInRealTime = true
                    guard writer.canAdd(video), writer.canAdd(audio) else { throw self.failure("无法建立带声音的录像。") }
                    writer.add(video)
                    writer.add(audio)
                    guard writer.startWriting() else { throw writer.error ?? self.failure("无法开始录制。") }
                    writer.startSession(atSourceTime: .zero)
                    self.writer = writer
                    self.video = video
                    self.audio = audio
                    self.firstTime = CMSampleBufferGetPresentationTimeStamp(sample)
                    self.publish(.recording)
                }
                guard let first = self.firstTime, let writer = self.writer, writer.status == .writing else {
                    if let error = self.writer?.error { throw error }
                    return
                }
                let time = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), first)
                guard time.isValid, time.seconds.isFinite, time.seconds >= 0 else { return }
                if isVideo {
                    let audioTime = self.lastAudioTime.isValid ? self.lastAudioTime.seconds : 0
                    if time.seconds - audioTime > 3 { throw self.failure("摄像头声音已中断，录制已停止。已保留中断前的可用录像。") }
                }
                let previous = isVideo ? self.lastVideoTime : self.lastAudioTime
                guard !previous.isValid || CMTimeCompare(time, previous) > 0 else { return }
                let input = isVideo ? self.video : self.audio
                guard let input, input.isReadyForMoreMediaData else { return }
                var timing = CMSampleTimingInfo()
                guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr else { throw self.failure("无法读取录像时间。") }
                timing.presentationTimeStamp = time
                timing.decodeTimeStamp = .invalid
                var copy: CMSampleBuffer?
                guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr, let copy else { throw self.failure("无法同步录像的图像与声音。") }
                guard input.append(copy) else { throw writer.error ?? self.failure("录像写入失败，请检查存储空间。") }
                if isVideo { self.videoCount += 1; self.lastVideoTime = time }
                else { self.audioCount += 1; self.lastAudioTime = time }
            } catch { self.finish(error: error.localizedDescription) }
        }
    }

    func stop(error: String? = nil) { queue.async { self.finish(error: error) } }

    private func finish(error: String?) {
        guard let target, let staging else { return }
        self.target = nil
        self.staging = nil
        let writer = self.writer
        self.writer = nil
        let valid = videoCount > 0 && audioCount > 0
        if writer?.status == .writing {
            video?.markAsFinished()
            audio?.markAsFinished()
        }
        video = nil
        audio = nil
        publish(.finishing)
        guard let writer, valid else {
            writer?.cancelWriting()
            publish(.finished(nil, error ?? "没有收到摄像头声音，录制未保存。请检查摄像头的音频连接。"))
            return
        }
        guard writer.status == .writing else {
            publish(.finished(nil, "录像写入失败：\(writer.error?.localizedDescription ?? error ?? "无法完成文件")。临时文件：\(staging.path)"))
            return
        }
        writer.finishWriting {
            if writer.status == .completed {
                do {
                    try FileManager.default.moveItem(at: staging, to: target)
                    self.publish(.finished(target, error))
                } catch { self.publish(.finished(nil, "录像已保留：\(staging.path)\n\(error.localizedDescription)")) }
            } else { self.publish(.finished(nil, "录像保存失败：\(writer.error?.localizedDescription ?? "无法完成文件")。临时文件：\(staging.path)")) }
        }
    }

    private func publish(_ event: RecordingEvent) { DispatchQueue.main.async { self.onRecording?(event) } }
    private func failure(_ message: String) -> NSError { NSError(domain: "WireCamera.NetworkRecording", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
