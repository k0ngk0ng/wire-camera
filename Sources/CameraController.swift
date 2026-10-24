import AVFoundation
import CoreMedia

enum RecordingEvent {
    case starting
    case recording
    case finishing
    case finished(URL?, String?)
}

final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera.session")
    private let frameQueue = DispatchQueue(label: "camera.frames")
    private let movie = AVCaptureMovieFileOutput()
    private var audioInput: AVCaptureDeviceInput?
    private var audioPreview: AVCaptureAudioPreviewOutput?
    private var monitoring = false
    private var volume: Float = 0.25
    private var destination: URL?
    private var stagingURL: URL?
    private var stopRequested = false
    private var lastReport = 0.0
    private var count = 0
    var onFrame: ((Int32, Int32, Double) -> Void)?
    var onRecording: ((RecordingEvent) -> Void)?

    private func failure(_ message: String) -> NSError {
        NSError(domain: "WireCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func publish(_ event: RecordingEvent) {
        DispatchQueue.main.async { self.onRecording?(event) }
    }

    func start(device: AVCaptureDevice, completion: @escaping (String?) -> Void) {
        queue.async {
            guard self.destination == nil else {
                DispatchQueue.main.async { completion("请先停止录制。") }
                return
            }
            self.session.stopRunning()
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            self.audioInput = nil
            self.audioPreview = nil
            self.monitoring = false
            var errorMessage: String?
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else { throw self.failure("无法连接此摄像头，请检查 USB 连接。") }
                self.session.addInput(input)
                if self.session.canSetSessionPreset(.hd1920x1080) {
                    self.session.sessionPreset = .hd1920x1080
                } else if self.session.canSetSessionPreset(.high) {
                    self.session.sessionPreset = .high
                }
                let frames = AVCaptureVideoDataOutput()
                frames.alwaysDiscardsLateVideoFrames = true
                frames.setSampleBufferDelegate(self, queue: self.frameQueue)
                guard self.session.canAddOutput(frames) else { throw self.failure("无法读取摄像头画面。") }
                self.session.addOutput(frames)
                guard self.session.canAddOutput(self.movie) else { throw self.failure("当前摄像头无法建立录制输出。") }
                self.session.addOutput(self.movie)
                self.movie.minFreeDiskSpaceLimit = 50 * 1024 * 1024
                self.movie.movieFragmentInterval = .invalid
            } catch { errorMessage = error.localizedDescription }
            self.session.commitConfiguration()
            self.frameQueue.sync { self.lastReport = 0; self.count = 0 }
            if errorMessage == nil {
                self.session.startRunning()
                if !self.session.isRunning { errorMessage = "摄像头未能启动，请关闭占用摄像头的其他应用后重试。" }
            }
            let result = errorMessage
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func configureAudio(_ device: AVCaptureDevice?) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if audioInput?.device.uniqueID != device?.uniqueID {
            if let input = audioInput { session.removeInput(input) }
            audioInput = nil
            if let device {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw failure("无法连接摄像头自带的声音输入。") }
                session.addInput(input)
                audioInput = input
            }
        }
        if device != nil && audioPreview == nil {
            let preview = AVCaptureAudioPreviewOutput()
            preview.volume = 0
            guard session.canAddOutput(preview) else { throw failure("无法建立声音监听输出。") }
            session.addOutput(preview)
            audioPreview = preview
        } else if device == nil, let preview = audioPreview {
            session.removeOutput(preview)
            audioPreview = nil
        }
        audioPreview?.volume = monitoring ? volume : 0
    }

    func setMonitoring(_ device: AVCaptureDevice?, volume: Float, completion: @escaping (String?) -> Void) {
        queue.async {
            guard self.destination == nil else {
                DispatchQueue.main.async { completion("录制期间不能更换声音输入。") }
                return
            }
            self.monitoring = device != nil
            self.volume = volume
            var message: String?
            do { try self.configureAudio(device) }
            catch {
                self.monitoring = false
                try? self.configureAudio(nil)
                message = error.localizedDescription
            }
            let result = message
            DispatchQueue.main.async { completion(result) }
        }
    }

    func setVolume(_ volume: Float) {
        queue.async {
            self.volume = volume
            self.audioPreview?.volume = self.monitoring ? volume : 0
        }
    }

    private func configureRecordedAudio(enabled: Bool) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if !enabled {
            if let connection = movie.connection(with: .audio) { session.removeConnection(connection) }
        } else if movie.connection(with: .audio) == nil {
            guard let input = audioInput else { throw failure("摄像头声音未连接。") }
            let ports = input.ports.filter { $0.mediaType == .audio }
            guard !ports.isEmpty else { throw failure("摄像头没有可录制的声音端口。") }
            let connection = AVCaptureConnection(inputPorts: ports, output: movie)
            guard session.canAddConnection(connection) else { throw failure("无法将摄像头声音接入录制文件。") }
            session.addConnection(connection)
        }
    }

    func startRecording(to target: URL, audioDevice: AVCaptureDevice?, mirrored: Bool) {
        queue.async {
            guard self.destination == nil else { return }
            self.publish(.starting)
            do {
                guard self.session.isRunning else { throw self.failure("摄像头尚未就绪。") }
                let parent = target.deletingLastPathComponent()
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: target.path, isDirectory: &directory), directory.boolValue {
                    throw self.failure("保存目标是文件夹，请选择 MOV 文件。")
                }
                guard FileManager.default.isWritableFile(atPath: parent.path) else { throw self.failure("保存位置不可写，请选择其他文件夹。") }
                try self.configureAudio(audioDevice ?? (self.monitoring ? self.audioInput?.device : nil))
                try self.configureRecordedAudio(enabled: audioDevice != nil)
                guard let connection = self.movie.connection(with: .video), connection.isActive else {
                    throw self.failure("摄像头没有可录制的视频连接。")
                }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = mirrored
                }
                self.movie.setOutputSettings(nil, for: connection)
                NSLog("Recording video settings: %@", self.movie.outputSettings(for: connection))
                self.destination = target
                self.stagingURL = parent.appendingPathComponent(".WireCamera-\(UUID().uuidString).mov")
                self.stopRequested = false
                self.movie.startRecording(to: self.stagingURL!, recordingDelegate: self)
            } catch {
                if !self.monitoring { try? self.configureAudio(nil) }
                self.destination = nil
                self.stagingURL = nil
                self.publish(.finished(nil, error.localizedDescription))
            }
        }
    }

    func stopRecording() {
        queue.async {
            guard self.destination != nil else { return }
            self.stopRequested = true
            self.publish(.finishing)
            if self.movie.isRecording { self.movie.stopRecording() }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        queue.async {
            if self.stopRequested {
                self.publish(.finishing)
                self.movie.stopRecording()
            } else { self.publish(.recording) }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            guard let target = self.destination else { return }
            let captureError = error as NSError?
            if let captureError { NSLog("Recording output error: %@", captureError) }
            let successful = captureError == nil || (captureError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
            var saved: URL?
            var message: String?
            if successful {
                do {
                    if FileManager.default.fileExists(atPath: target.path) {
                        _ = try FileManager.default.replaceItemAt(target, withItemAt: fileURL)
                    } else { try FileManager.default.moveItem(at: fileURL, to: target) }
                    saved = target
                    if let captureError { message = "录制提前结束，已保存可用视频：\(captureError.localizedDescription)" }
                } catch {
                    message = "视频已录制，但无法保存到目标位置。临时文件：\(fileURL.path)\n\(error.localizedDescription)"
                }
            } else {
                message = "录制失败：\(captureError?.localizedDescription ?? "未生成可用视频")"
                if FileManager.default.fileExists(atPath: fileURL.path) { message! += "\n可检查临时文件：\(fileURL.path)" }
            }
            self.destination = nil
            self.stagingURL = nil
            self.stopRequested = false
            if !self.monitoring { try? self.configureAudio(nil) }
            self.publish(.finished(saved, message))
        }
    }

    func stop() {
        queue.async {
            guard self.destination == nil else { return }
            self.audioPreview?.volume = 0
            self.session.stopRunning()
        }
    }

    func shutdown() {
        queue.sync {
            self.audioPreview?.volume = 0
            self.session.stopRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let size = CMVideoFormatDescriptionGetDimensions(format)
        let now = ProcessInfo.processInfo.systemUptime
        count += 1
        if lastReport == 0 || now - lastReport >= 1 {
            let fps = lastReport == 0 ? 0 : Double(count) / (now - lastReport)
            lastReport = now
            count = 0
            DispatchQueue.main.async { self.onFrame?(size.width, size.height, fps) }
        }
    }
}
