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
