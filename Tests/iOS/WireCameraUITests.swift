import XCTest

final class WireCameraUITests: XCTestCase {
    func testConnectionAndPlayback() throws {
        let app = XCUIApplication()
        if ProcessInfo.processInfo.environment["WIRECAMERA_TEST_ORIENTATION"] == "landscapeRight" { XCUIDevice.shared.orientation = .landscapeRight }
        app.launchArguments = ["--ui-test", "--reset-test-connections"]
        addUIInterruptionMonitor(withDescription: "局域网访问") { alert in
            if alert.buttons["允许"].exists { alert.buttons["允许"].tap(); return true }
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
            return false
        }
        app.launch()
        XCTAssertTrue(app.textFields["Mac 地址"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["端口"].exists)
        XCTAssertTrue(app.secureTextFields["连接密码"].exists)
        let initial = XCTAttachment(screenshot: app.screenshot())
        initial.name = "连接页面"
        initial.lifetime = .keepAlways
        add(initial)
        guard let host = ProcessInfo.processInfo.environment["WIRECAMERA_TEST_HOST"],
              let port = ProcessInfo.processInfo.environment["WIRECAMERA_TEST_PORT"],
              let password = ProcessInfo.processInfo.environment["WIRECAMERA_TEST_PASSWORD"] else { throw XCTSkip("需要运行中的 Mac 端 HTTPS 验收服务。") }
        let addressField = app.textFields["Mac 地址"]
        addressField.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) { addressField.tap() }
        addressField.typeText(host)
        let portField = app.textFields["端口"]
        portField.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) { portField.tap() }
        if let value = portField.value as? String { portField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)) }
        portField.typeText(port)
        app.secureTextFields["连接密码"].tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) { app.secureTextFields["连接密码"].tap() }
        app.secureTextFields["连接密码"].typeText(password)
        app.buttons["连接 Mac"].tap()
        XCTAssertTrue(app.buttons["实时"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["回放"].exists)
        if !app.buttons["Wi-Fi · fixture-manual-device"].exists { app.buttons["选择摄像头"].tap() }
        app.buttons["Wi-Fi · fixture-manual-device"].tap()
        let liveView = app.descendants(matching: .any).matching(identifier: "实时画面").firstMatch
        let liveReady = expectation(for: NSPredicate(format: "value == %@", "正在播放"), evaluatedWith: liveView)
        wait(for: [liveReady], timeout: 20)
        XCTAssertFalse(app.buttons["暂停"].exists)
        let live = XCTAttachment(screenshot: app.screenshot())
        live.name = "实时画面"
        live.lifetime = .keepAlways
        add(live)
        app.terminate()
        app.launchArguments = ["--ui-test"]
        app.launch()
        XCTAssertTrue(app.buttons["实时"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.secureTextFields["连接密码"].exists)
        app.buttons["回放"].tap()
        XCTAssertTrue(app.buttons["选择摄像头"].waitForExistence(timeout: 10))
        app.buttons["选择摄像头"].tap()
        app.buttons["离线摄像头"].tap()
        XCTAssertTrue(app.otherElements["全天时间轴"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["下一个人物"].exists)
        let layout = XCTAttachment(string: "window=\(app.frame); video=\(app.buttons["回放画面"].firstMatch.frame); timeline=\(app.otherElements["全天时间轴"].frame)")
        layout.name = "窗口与布局尺寸"
        layout.lifetime = .keepAlways
        add(layout)
        let playback = XCTAttachment(screenshot: app.screenshot())
        playback.name = "离线摄像头回放"
        playback.lifetime = .keepAlways
        add(playback)
    }
}
