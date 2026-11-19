import AppKit
import CoreBluetooth
import CoreLocation
import CoreWLAN

final class CameraModuleConnection: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, CLLocationManagerDelegate, NSWindowDelegate, NSTextFieldDelegate, NSComboBoxDelegate {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 390), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let modulePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scanButton = NSButton(title: "重新扫描", target: nil, action: nil)
    private let wifiName = NSComboBox()
    private let wifiRefresh = NSButton(title: "刷新", target: nil, action: nil)
    private let password = WiFiPasswordField(frame: .zero)
    private let status = NSTextField(wrappingLabelWithString: "正在准备蓝牙…")
    private let connectButton = NSButton(title: "连接 Wi-Fi", target: nil, action: nil)
    private let cancelButton = NSButton(title: "关闭", target: nil, action: nil)
    private var manager: CBCentralManager?
    private let location = CLLocationManager()
    private var locationRequested = false
    private var modules: [CBPeripheral] = []
    private var moduleNames: [UUID: String] = [:]
    private var networkModules: [CameraModuleNetworkDevice] = []
    private var selectedNetworkCandidate: CameraModuleNetworkDevice?
    private let networkScanner = CameraModuleNetwork()
    private var networkScanning = false
    private var bluetoothIssue: String?
    private var selected: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var subscriptions: Set<String> = []
    private var ready = false
    private var busy = false
    private var networkConnecting = false
    private var configured = false
    private var configuredIdentity: CameraModuleIdentity?
    private var scanning = false
    private var pendingPackets: [Data] = []
    private var assembler = CameraModulePacketAssembler()
    private var request = 0
    private var scanRequest = 0
    private var wifiRequest = 0
    private var writes = 0
    private var testTimer: Timer?
    private var testOpenedFromMainWindow = false
    private var presented = false
    private let knownIdentifiers: [UUID]
    var onConfigured: ((CameraModuleIdentity) -> Void)?
    var onCancelNetwork: (() -> Void)?
    var onNetworkFound: ((CameraModuleNetworkDevice) -> Void)?

    init(knownIdentifiers: [UUID] = []) {
        self.knownIdentifiers = knownIdentifiers
        super.init()
        location.delegate = self
        buildPanel()
    }

    func present(for parent: NSWindow, existingDeviceID: String? = nil) {
        presented = true
        if panel.sheetParent == nil { parent.beginSheet(panel) }
        panel.makeKeyAndOrderFront(nil)
        if let existingDeviceID {
            modulePicker.removeAllItems()
            modulePicker.addItem(withTitle: existingDeviceID)
            beginNetworkConnection(CameraModuleIdentity(deviceID: existingDeviceID, salt: ""))
            return
        }
        if manager == nil {
            manager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        startScan()
        refreshWiFi()
    }

    private func buildPanel() {
        panel.title = "添加摄像头"
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        guard let root = panel.contentView else { return }
        let title = NSTextField(labelWithString: "连接摄像头模块")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let moduleLabel = NSTextField(labelWithString: "摄像头")
        let wifiLabel = NSTextField(labelWithString: "Wi-Fi")
        let passwordLabel = NSTextField(labelWithString: "密码")
        for label in [moduleLabel, wifiLabel, passwordLabel] {
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 13)
        }
        modulePicker.addItem(withTitle: "正在扫描…")
        modulePicker.isEnabled = false
        modulePicker.target = self
        modulePicker.action = #selector(selectModule)
        modulePicker.setAccessibilityLabel("摄像头模块")
        scanButton.target = self
        scanButton.action = #selector(scanAgain)
        wifiName.isEditable = true
        wifiName.completes = true
        wifiName.delegate = self
        wifiName.placeholderString = "选择或输入 2.4 GHz Wi-Fi 名称"
        wifiName.setAccessibilityLabel("Wi-Fi 名称")
        wifiRefresh.target = self
        wifiRefresh.action = #selector(refreshWiFi)
        password.delegate = self
        password.placeholderString = "Wi-Fi 密码"
        password.setAccessibilityLabel("Wi-Fi 密码")
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        status.setAccessibilityLabel("模块连接状态")
        connectButton.target = self
        connectButton.action = #selector(connectWiFi)
        connectButton.keyEquivalent = "\r"
        connectButton.isEnabled = false
        cancelButton.target = self
        cancelButton.action = #selector(closePanel)
        cancelButton.keyEquivalent = "\u{1b}"
        for view in [title, moduleLabel, modulePicker, scanButton, wifiLabel, wifiName, wifiRefresh, passwordLabel, password, status, cancelButton, connectButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            moduleLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            moduleLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 26),
            modulePicker.leadingAnchor.constraint(equalTo: moduleLabel.leadingAnchor),
            modulePicker.topAnchor.constraint(equalTo: moduleLabel.bottomAnchor, constant: 8),
            modulePicker.trailingAnchor.constraint(equalTo: scanButton.leadingAnchor, constant: -12),
            scanButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            scanButton.widthAnchor.constraint(equalToConstant: 88),
            scanButton.centerYAnchor.constraint(equalTo: modulePicker.centerYAnchor),
            wifiLabel.leadingAnchor.constraint(equalTo: moduleLabel.leadingAnchor),
            wifiLabel.topAnchor.constraint(equalTo: modulePicker.bottomAnchor, constant: 23),
            wifiName.leadingAnchor.constraint(equalTo: wifiLabel.leadingAnchor),
            wifiName.topAnchor.constraint(equalTo: wifiLabel.bottomAnchor, constant: 8),
            wifiName.widthAnchor.constraint(equalToConstant: 300),
            wifiRefresh.leadingAnchor.constraint(equalTo: wifiName.trailingAnchor, constant: 8),
            wifiRefresh.centerYAnchor.constraint(equalTo: wifiName.centerYAnchor),
            passwordLabel.leadingAnchor.constraint(equalTo: password.leadingAnchor),
            passwordLabel.centerYAnchor.constraint(equalTo: wifiLabel.centerYAnchor),
            password.leadingAnchor.constraint(equalTo: wifiRefresh.trailingAnchor, constant: 18),
            password.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            password.centerYAnchor.constraint(equalTo: wifiName.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            status.topAnchor.constraint(equalTo: wifiName.bottomAnchor, constant: 26),
            connectButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            connectButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            cancelButton.trailingAnchor.constraint(equalTo: connectButton.leadingAnchor, constant: -12),
            cancelButton.centerYAnchor.constraint(equalTo: connectButton.centerYAnchor)
        ])
    }

    func controlTextDidChange(_ notification: Notification) {
        configured = false
        if ready, !busy {
            status.stringValue = CameraModuleProtocol.validateCredentials(ssid: wifiName.stringValue, password: password.stringValue) ?? "蓝牙已连接，可以发送 Wi-Fi 配置。"
        }
        updateControls()
    }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { self.updateControls() }
    }

    private func updateControls() {
        modulePicker.isEnabled = !busy && (!modules.isEmpty || !networkModules.isEmpty)
        scanButton.isEnabled = !busy
        wifiName.isEnabled = !busy && configuredIdentity == nil && selectedNetworkCandidate == nil
        password.isEnabled = !busy && configuredIdentity == nil && selectedNetworkCandidate == nil
        wifiRefresh.isEnabled = !busy && configuredIdentity == nil && selectedNetworkCandidate == nil
        connectButton.isEnabled = !busy && !configured && (selectedNetworkCandidate != nil || configuredIdentity != nil || (ready && CameraModuleProtocol.validateCredentials(ssid: wifiName.stringValue, password: password.stringValue) == nil))
        connectButton.title = configured ? "Wi-Fi 已连接" : (busy ? "正在连接…" : (configuredIdentity != nil ? "重新连接模块" : (selectedNetworkCandidate != nil ? "打开画面" : "连接 Wi-Fi")))
    }

    @objc private func refreshWiFi() {
        guard !networkConnecting, configuredIdentity == nil else { return }
        if location.authorizationStatus == .notDetermined, !locationRequested {
            locationRequested = true
            location.requestWhenInUseAuthorization()
        }
        wifiRequest += 1
        let current = wifiRequest
        wifiRefresh.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async {
            let interface = CWWiFiClient.shared().interface()
            let connected = interface?.ssid()
            let networks = (try? interface?.scanForNetworks(withSSID: nil)) ?? []
            let sorted = networks.filter { $0.wlanChannel?.channelBand == .band2GHz }.sorted { $0.rssiValue > $1.rssiValue }
            var names: [String] = []
            for network in sorted {
                if let name = network.ssid, !name.isEmpty, !name.hasPrefix("LLM_"), !name.hasPrefix("AXH_"), !names.contains(name) { names.append(name) }
            }
            NSLog("Wi-Fi scan: %ld networks, %ld visible 2.4 GHz names", networks.count, names.count)
            DispatchQueue.main.async {
                guard current == self.wifiRequest else { return }
                let previous = self.wifiName.stringValue
                self.wifiName.removeAllItems()
                self.wifiName.addItems(withObjectValues: names)
                self.wifiName.stringValue = previous.isEmpty ? (connected.flatMap { names.contains($0) ? $0 : nil } ?? names.first ?? "") : previous
                self.updateControls()
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard panel.isVisible else { return }
        if manager.authorizationStatus == .authorizedAlways { refreshWiFi() }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard presented else { return }
        NSLog("Module Bluetooth state=%ld authorization=%ld", central.state.rawValue, CBManager.authorization.rawValue)
        switch central.state {
        case .poweredOn: beginBluetoothScan()
        case .unauthorized: bluetoothUnavailable("需要蓝牙权限。请在「隐私与安全性 → 蓝牙」中允许 WireCamera；已联网模块仍可通过局域网找到。")
        case .poweredOff: bluetoothUnavailable("蓝牙已关闭；正在搜索已联网的模块。")
        case .unsupported: bluetoothUnavailable("这台 Mac 不支持蓝牙配网；仍可连接已联网的模块。")
        default:
            if modules.isEmpty && networkModules.isEmpty { status.stringValue = bluetoothPreparationMessage() }
        }
    }

    @objc private func scanAgain() { startScan() }

    private func startScan() {
        guard !busy else { return }
        if manager == nil { manager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false]) }
        guard let manager else { return }
        request += 1
        scanRequest += 1
        manager.stopScan()
        let preserved = ready && selected?.state == .connected ? selected : nil
        let previous = selected
        selected = preserved
        if preserved == nil, let previous { manager.cancelPeripheralConnection(previous) }
        configured = false
        configuredIdentity = nil
        selectedNetworkCandidate = nil
        ready = preserved != nil
        if preserved == nil { writeCharacteristic = nil; subscriptions.removeAll() }
        modules = preserved.map { [$0] } ?? []
        networkModules.removeAll()
        bluetoothIssue = nil
        modulePicker.removeAllItems()
        modulePicker.addItem(withTitle: "正在扫描…")
        scanning = false
        networkScanning = true
        status.stringValue = manager.state == .poweredOn ? "正在搜索蓝牙和局域网模块…" : bluetoothPreparationMessage()
        if preserved != nil { rebuildModulePicker() }
        updateControls()
        let currentScan = scanRequest
        networkScanner.scanNearby(onDevice: { [weak self] device in
            guard let self, currentScan == self.scanRequest, self.presented else { return }
            if let index = self.networkModules.firstIndex(where: { $0.deviceID == device.deviceID }) { self.networkModules[index] = device }
            else { self.networkModules.append(device) }
            self.onNetworkFound?(device)
            self.rebuildModulePicker()
        }, completion: { [weak self] error in
            guard let self, currentScan == self.scanRequest else { return }
            self.networkScanning = false
            if let error, self.modules.isEmpty && self.networkModules.isEmpty { self.status.stringValue = error }
            else { self.finishScanningIfEmpty() }
        })
        switch manager.state {
        case .poweredOn: beginBluetoothScan()
        case .unauthorized: bluetoothUnavailable("需要蓝牙权限。请在「隐私与安全性 → 蓝牙」中允许 WireCamera；已联网模块仍可通过局域网找到。")
        case .poweredOff: bluetoothUnavailable("蓝牙已关闭；正在搜索已联网的模块。")
        default: break
        }
    }

    private func beginBluetoothScan() {
        guard !busy, presented, let manager, manager.state == .poweredOn else { return }
        bluetoothIssue = nil
        scanning = true
        let currentScan = scanRequest
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        for peripheral in manager.retrievePeripherals(withIdentifiers: knownIdentifiers) {
            if let name = CameraModuleDiscovery.bluetoothName(advertised: nil, cached: peripheral.name) { registerModule(peripheral, name: name) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            guard currentScan == self.scanRequest, self.scanning else { return }
            self.manager?.stopScan()
            self.scanning = false
            self.finishScanningIfEmpty()
            self.updateControls()
        }
    }

    private func bluetoothUnavailable(_ message: String) {
        scanning = false
        ready = false
        bluetoothIssue = message
        if modules.isEmpty && networkModules.isEmpty { status.stringValue = message }
        updateControls()
    }

    private func finishScanningIfEmpty() {
        guard !scanning, !networkScanning, modules.isEmpty, networkModules.isEmpty else { return }
        modulePicker.removeAllItems()
        if CBManager.authorization == .notDetermined, manager?.state != .poweredOff {
            modulePicker.addItem(withTitle: "等待蓝牙授权")
            status.stringValue = bluetoothPreparationMessage()
        } else {
            modulePicker.addItem(withTitle: "未发现摄像头模块")
            status.stringValue = bluetoothIssue ?? "未发现模块。已联网模块需与 Mac 网络互通；蓝牙配网时请保持蓝灯闪烁，然后重新扫描。"
        }
        updateControls()
    }

    private func bluetoothPreparationMessage() -> String {
        CBManager.authorization == .notDetermined ? "请在系统提示中允许 WireCamera 使用蓝牙；同时正在搜索已联网模块。" : "正在准备蓝牙并搜索局域网模块…"
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        guard scanning, let name = CameraModuleDiscovery.bluetoothName(advertised: advertisementData[CBAdvertisementDataLocalNameKey] as? String, cached: peripheral.name) else { return }
        registerModule(peripheral, name: name)
    }

    private func registerModule(_ peripheral: CBPeripheral, name: String) {
        if !modules.contains(where: { $0.identifier == peripheral.identifier }) {
            modules.append(peripheral)
            NSLog("Camera module Bluetooth discovered: %@", name)
        } else if moduleNames[peripheral.identifier] == name { return }
        moduleNames[peripheral.identifier] = name
        rebuildModulePicker()
    }

    private func rebuildModulePicker() {
        let previous = modulePicker.selectedItem?.representedObject as? String
        modulePicker.removeAllItems()
        for peripheral in modules {
            modulePicker.addItem(withTitle: "蓝牙 · \(moduleNames[peripheral.identifier] ?? peripheral.name ?? "摄像头模块")")
            modulePicker.lastItem?.representedObject = "bluetooth:\(peripheral.identifier.uuidString)"
        }
        for device in networkModules {
            modulePicker.addItem(withTitle: "Wi-Fi · \(device.deviceID)")
            modulePicker.lastItem?.representedObject = "network:\(device.deviceID)"
        }
        if let index = modulePicker.itemArray.firstIndex(where: { $0.representedObject as? String == previous }), previous != nil {
            modulePicker.selectItem(at: index)
        } else if modulePicker.numberOfItems > 0 {
            modulePicker.selectItem(at: 0)
            selectModule()
        }
        updateControls()
    }

    @objc private func selectModule() {
        guard !busy, let key = modulePicker.selectedItem?.representedObject as? String else { return }
        if let device = networkModules.first(where: { "network:\($0.deviceID)" == key }) {
            request += 1
            let previous = selected
            selected = nil
            if let previous { manager?.cancelPeripheralConnection(previous) }
            selectedNetworkCandidate = device
            configured = false
            configuredIdentity = nil
            ready = false
            password.stringValue = ""
            status.stringValue = "已发现联网模块，可直接打开画面，无需再次配网。"
            updateControls()
            return
        }
        guard let device = modules.first(where: { "bluetooth:\($0.identifier.uuidString)" == key }), let manager else { return }
        guard manager.state == .poweredOn else { bluetoothUnavailable("蓝牙暂不可用，请检查蓝牙权限或开关。已联网模块可直接从 Wi-Fi 选项连接。"); return }
        if selected?.identifier == device.identifier, selected?.state != .disconnected { return }
        request += 1
        let current = request
        let previous = selected
        selected = nil
        if let previous { manager.cancelPeripheralConnection(previous) }
        selected = device
        selectedNetworkCandidate = nil
        configuredIdentity = nil
        configured = false
        ready = false
        writeCharacteristic = nil
        subscriptions.removeAll()
        selected?.delegate = self
        status.stringValue = "正在检查模块连接…"
        updateControls()
        if let selected { manager.connect(selected) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            guard current == self.request, !self.ready else { return }
            self.fail("模块连接超时，请保持蓝灯闪烁并重新扫描。")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == selected?.identifier else { return }
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == selected?.identifier else { return }
        fail("无法连接模块，请重新扫描。")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == selected?.identifier else { return }
        guard peripheral.state == .disconnected else { return }
        if networkConnecting || configuredIdentity != nil { ready = false; updateControls(); return }
        fail(busy ? "模块连接已断开，请检查指示灯后重试。" : "蓝牙连接已断开，请重新扫描。")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral.identifier == selected?.identifier else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: "FFFF") }) else {
            fail("模块没有提供受支持的配网服务。")
            return
        }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral.identifier == selected?.identifier else { return }
        let characteristics = service.characteristics ?? []
        guard error == nil,
              let writer = characteristics.first(where: { $0.uuid == CBUUID(string: "FF01") && $0.properties.contains(.write) }) else {
            fail("模块缺少可用的配网写入通道。")
            return
        }
        let receivers = characteristics.filter { $0.uuid == CBUUID(string: "FF02") || $0.uuid == CBUUID(string: "FF03") }
        guard receivers.contains(where: { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }) else {
            fail("模块缺少配网响应通道。")
            return
        }
        writeCharacteristic = writer
        subscriptions = Set(receivers.map { $0.uuid.uuidString })
        for receiver in receivers { peripheral.setNotifyValue(true, for: receiver) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == selected?.identifier else { return }
        guard error == nil, characteristic.isNotifying else { fail("无法接收模块响应，请重新扫描。"); return }
        subscriptions.remove(characteristic.uuid.uuidString)
        if subscriptions.isEmpty {
            ready = true
            status.stringValue = "蓝牙已连接。选择 2.4 GHz Wi-Fi 后输入密码。"
            updateControls()
        }
    }

    @objc private func connectWiFi() {
        guard !busy else { return }
        if let device = selectedNetworkCandidate { beginNetworkConnection(CameraModuleIdentity(deviceID: device.deviceID, salt: "")); return }
        if let configuredIdentity { beginNetworkConnection(configuredIdentity); return }
        guard ready, selected != nil else { return }
        if let message = CameraModuleProtocol.validateCredentials(ssid: wifiName.stringValue, password: password.stringValue) {
            status.stringValue = message
            return
        }
        do {
            pendingPackets = try CameraModuleProtocol.configurationPackets(ssid: wifiName.stringValue, password: password.stringValue)
            assembler.reset()
            request += 1
            let current = request
            busy = true
            status.stringValue = "正在向模块发送 Wi-Fi 配置…"
            updateControls()
            sendNextPacket()
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                guard current == self.request, self.busy else { return }
                self.fail("模块尚未确认配置。请检查指示灯和 Wi-Fi 信息后重试。")
            }
        } catch { fail("无法生成模块配置，请检查 Wi-Fi 名称和密码。") }
    }

    private func sendNextPacket() {
        guard busy, !networkConnecting, let selected, let writeCharacteristic, !pendingPackets.isEmpty else { return }
        let packet = pendingPackets.removeFirst()
        writes += 1
        selected.writeValue(packet, for: writeCharacteristic, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == selected?.identifier, busy, !networkConnecting else { return }
        guard error == nil else { fail("发送 Wi-Fi 配置失败，请重新连接模块。"); return }
        let current = request
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard current == self.request else { return }
            self.sendNextPacket()
        }
        if pendingPackets.isEmpty { status.stringValue = "配置已发送，正在等待模块确认…" }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == selected?.identifier, busy, !networkConnecting else { return }
        guard error == nil, let value = characteristic.value else { fail("读取模块响应失败，请重试。"); return }
        do {
            guard let response = try assembler.append(value) else { return }
            let identity = try CameraModuleProtocol.decodeResponse(response)
            request += 1
            pendingPackets.removeAll()
            password.stringValue = ""
            beginNetworkConnection(identity)
        } catch { fail("模块响应未通过校验，配置结果尚未确认，请重试。") }
    }

    private func beginNetworkConnection(_ identity: CameraModuleIdentity) {
        configuredIdentity = identity
        manager?.stopScan()
        networkScanner.stop()
        networkScanning = false
        scanning = false
        networkConnecting = true
        busy = true
        status.stringValue = "正在查找已配网的模块并验证连接…"
        updateControls()
        onConfigured?(identity)
    }

    func networkConnectionFinished(_ result: Result<CameraModuleNetworkDevice, Error>) {
        networkConnecting = false
        busy = false
        switch result {
        case .success(let device):
            configured = true
            status.stringValue = "Wi-Fi 已连接 · \(device.address)"
        case .failure(let error):
            configured = false
            status.stringValue = error.localizedDescription
        }
        updateControls()
    }

    func finishPreview() { closePanel() }

    private func fail(_ message: String) {
        request += 1
        scanRequest += 1
        ready = false
        busy = false
        networkConnecting = false
        pendingPackets.removeAll()
        manager?.stopScan()
        networkScanner.stop()
        networkScanning = false
        scanning = false
        status.stringValue = message
        updateControls()
    }

    @objc private func closePanel() {
        presented = false
        request += 1
        scanRequest += 1
        wifiRequest += 1
        manager?.stopScan()
        networkScanner.stop()
        networkScanning = false
        scanning = false
        ready = false
        busy = false
        if networkConnecting { onCancelNetwork?() }
        networkConnecting = false
        pendingPackets.removeAll()
        password.stringValue = ""
        let previous = selected
        selected = nil
        if let previous { manager?.cancelPeripheralConnection(previous) }
        if let parent = panel.sheetParent { parent.endSheet(panel) }
        panel.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { closePanel(); return true }

    func runE2E(to directory: URL) {
        testOpenedFromMainWindow = panel.sheetParent != nil && panel.isVisible
        let started = Date()
        testTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            if self.selectedNetworkCandidate != nil, let first = self.modules.first,
               let index = self.modulePicker.itemArray.firstIndex(where: { $0.representedObject as? String == "bluetooth:\(first.identifier.uuidString)" }) {
                self.modulePicker.selectItem(at: index)
                self.selectModule()
            }
            guard (self.ready && self.wifiName.numberOfItems > 0) || Date().timeIntervalSince(started) > 110 else { return }
            timer.invalidate()
            self.wifiName.stringValue = ""
            self.password.stringValue = ""
            self.updateControls()
            let rejectedEmpty = !self.connectButton.isEnabled
            self.wifiName.stringValue = "WireCamera-E2E"
            self.password.stringValue = "WireCamera-E2E-not-a-password"
            self.updateControls()
            let valid = self.connectButton.isEnabled
            let checks: [[String: Any]] = [
                ["name": "main_window_action", "passed": self.testOpenedFromMainWindow],
                ["name": "module_discovered", "passed": self.selected != nil],
                ["name": "module_gatt_verified", "passed": self.ready && self.writeCharacteristic?.uuid == CBUUID(string: "FF01")],
                ["name": "wifi_field_editable", "passed": self.wifiName.isEditable],
                ["name": "wifi_networks_discovered", "passed": self.wifiName.numberOfItems > 0],
                ["name": "password_field_secure", "passed": self.password.isKind(of: NSSecureTextField.self)],
                ["name": "empty_ssid_rejected", "passed": rejectedEmpty],
                ["name": "credentials_validated", "passed": valid],
                ["name": "no_configuration_sent", "passed": self.writes == 0]
            ]
            let report: [String: Any] = ["passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks, "moduleName": self.selected.flatMap { self.moduleNames[$0.identifier] ?? $0.name } ?? "", "moduleIdentifier": self.selected?.identifier.uuidString ?? "", "status": self.status.stringValue, "timestamp": ISO8601DateFormatter().string(from: Date())]
            do {
                if let root = self.panel.contentView {
                    root.layoutSubtreeIfNeeded()
                    if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                        root.cacheDisplay(in: root.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("connection.png"))
                    }
                }
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("app-result.json"), options: .atomic)
            } catch { NSLog("Module E2E report failed: %@", error.localizedDescription) }
            self.closePanel()
            NSApp.terminate(nil)
        }
    }

    func runDiscoveryE2E() {
        testTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            guard let device = self.networkModules.first,
                  let index = self.modulePicker.itemArray.firstIndex(where: { $0.representedObject as? String == "network:\(device.deviceID)" }) else { return }
            self.modulePicker.selectItem(at: index)
            self.modulePicker.sendAction(self.modulePicker.action, to: self.modulePicker.target)
            guard self.connectButton.isEnabled else { return }
            timer.invalidate()
            self.connectButton.performClick(nil)
        }
    }
}
