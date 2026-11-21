import SwiftUI

@main
struct WireCameraApp: App {
    var body: some Scene { WindowGroup { CameraPhoneView().environment(\.locale, Locale(identifier: "zh_CN")) } }
}
