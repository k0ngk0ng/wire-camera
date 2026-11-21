import AppKit
import CoreImage
import Darwin

final class CameraRemotePanel: NSObject {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let address = NSTextField(labelWithString: "")
    private let port = NSTextField(string: "")
    private let password = NSTextField(string: "")
    private let state = NSTextField(wrappingLabelWithString: "")
    private let toggle = NSButton(title: "开启连接", target: nil, action: nil)
    private let qr = NSImageView()
    private var settings = CameraRemoteSettings()
    var onChange: ((CameraRemoteSettings) -> Void)?

    override init() {
        super.init()
        panel.title = "iPhone 连接"
        panel.appearance = NSAppearance(named: .darkAqua)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        address.isSelectable = true
        address.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        port.placeholderString = "端口"
        port.setAccessibilityLabel("端口")
        password.setAccessibilityLabel("连接密码")
        password.isSelectable = true
        qr.imageScaling = .scaleProportionallyUpOrDown
        toggle.target = self
        toggle.action = #selector(apply)
        let reset = NSButton(title: "重置密码", target: self, action: #selector(resetPassword))
        let actions = NSStackView(views: [toggle, reset])
        for view in [address, NSTextField(labelWithString: "端口"), port, NSTextField(labelWithString: "连接密码"), password, qr, state, actions] { stack.addArrangedSubview(view) }
        panel.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 24),
            qr.heightAnchor.constraint(equalToConstant: 180),
            qr.widthAnchor.constraint(equalToConstant: 180),
            port.widthAnchor.constraint(equalToConstant: 100),
            password.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    func show(settings: CameraRemoteSettings, status: String) {
        self.settings = settings
        port.stringValue = String(settings.port)
        password.stringValue = settings.password
        state.stringValue = status
        toggle.title = settings.enabled ? "关闭连接" : "开启连接"
        address.stringValue = Self.addresses().map { "\($0):\(settings.port)" }.joined(separator: "\n")
        qr.image = nil
        if settings.enabled, let host = Self.addresses().first {
            var components = URLComponents()
            components.scheme = "wirecamera"
            components.host = "pair"
            components.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "port", value: String(settings.port)), URLQueryItem(name: "password", value: settings.password)]
            let filter = CIFilter(name: "CIQRCodeGenerator")!
            filter.setValue(Data((components.string ?? "").utf8), forKey: "inputMessage")
            if let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), let cgImage = CIContext().createCGImage(image, from: image.extent) { qr.image = NSImage(cgImage: cgImage, size: NSSize(width: 180, height: 180)) }
        }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func apply() {
        guard let value = UInt16(port.stringValue), value > 0, password.stringValue.utf8.count >= 12 else { state.stringValue = "请输入 1–65535 的端口，密码至少 12 个字符。"; return }
        settings.port = value
        settings.password = password.stringValue
        settings.enabled.toggle()
        onChange?(settings)
    }

    @objc private func resetPassword() {
        settings.password = String(CameraRemoteCoding.randomSecret().prefix(24))
        password.stringValue = settings.password
        onChange?(settings)
    }

    static func addresses() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }
        var values: [String] = []
        var next = interfaces
        while let current = next {
            defer { next = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), current.pointee.ifa_flags & UInt32(IFF_UP) != 0, current.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { values.append(String(cString: host)) }
        }
        return values.sorted { $0.hasPrefix("192.168.") && !$1.hasPrefix("192.168.") }
    }
}
