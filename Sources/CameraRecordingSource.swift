import AVFoundation
import Foundation

final class CameraRecordingSource {
    let id: String
    let name: String
    let mirrored: Bool
    let camera: CameraController?
    let audioDevice: AVCaptureDevice?
    let pictureMode: CameraPictureMode?
    let identity: CameraModuleIdentity?
    let network: CameraModuleNetwork?
    var connected = false
    var lastVideoAt = Date()
    var failure: String?
    let recorder = CameraNetworkRecorder()
    var requested = false
    var busy = false
    var preparing = false
    var finishing = false
    var rotating = false
    var segmentStartedAt: Date?
    var segmentDate = Date()
    var sessionStartedUptime: TimeInterval?
    var frozenElapsed: TimeInterval = 0
    var startedAnySegment = false
    var savedCount = 0
    var lastRecordingURL: URL?
    var lastError: String?
    var status = "未录制"

    var isActive: Bool { requested || busy || preparing || finishing }
    var elapsedSeconds: TimeInterval { sessionStartedUptime.map { max(0, ProcessInfo.processInfo.systemUptime - $0) } ?? frozenElapsed }
    var elapsedText: String {
        let seconds = Int(elapsedSeconds)
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    func freezeClock() { frozenElapsed = elapsedSeconds; sessionStartedUptime = nil }

    init(id: String, name: String, mirrored: Bool, camera: CameraController? = nil, audioDevice: AVCaptureDevice? = nil, pictureMode: CameraPictureMode? = nil, identity: CameraModuleIdentity? = nil) {
        self.id = id
        self.name = name
        self.mirrored = mirrored
        self.camera = camera
        self.audioDevice = audioDevice
        self.pictureMode = pictureMode
        self.identity = identity
        network = identity == nil ? nil : CameraModuleNetwork()
    }
}
