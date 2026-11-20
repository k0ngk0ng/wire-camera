# WireCamera

Mac 原生摄像头实时查看与本地回放工具。双击「应用程序」中的 **WireCamera.app**（安装路径：`/Applications/WireCamera.app`），或打开项目目录中的同名应用，首次运行在系统提示中允许摄像头访问，即可查看实时画面。

- 自动优先选择外接 USB 摄像头，可在右上角切换设备。
- 支持通过蓝牙为 HA10 摄像头模块配置 2.4 GHz Wi-Fi，自动发现或按 IP 查找模块，并在局域网内预览画面。
- 支持镜像、调整窗口大小、全屏（⌃⌘F），按原始比例显示画面。
- 支持切换摄像头原生 4:3 / 16:9 画面模式，预览与录制使用相同尺寸。
- 支持拔插设备自动重连；⌘R 重新连接。
- 底部显示实际画面分辨率与帧率。
- USB 和 HA10 Wi-Fi 摄像头统一使用「实时 / 回放」，录制自动包含摄像头声音。
- 开启录制后，每 60 秒自动保存一个片段，停止时保存剩余片段；录像自动出现在回放列表。
- 回放支持按日期查看、拖动时间轴和点击人物事件跳转。人物识别在本机执行。
- 支持声音监听和音量调节；监听与录入声音独立。
- 音视频仅在本机处理或保存，不上传。USB 摄像头录制或监听需要麦克风权限；Wi-Fi 声音直接来自模块。

如果没有画面，请检查 USB 连接、关闭其他使用摄像头的应用后点击“重试”。如果拒绝过授权，在“系统设置 → 隐私与安全性 → 摄像头”中开启“WireCamera”，然后重新打开应用。

## Wi-Fi 摄像头模块

已验证 HA10 模块的蓝牙配网及 640 × 480 MJPEG 实时预览，不需要安装「联了么」App。模块在此模式下通过 USB-C 供电，通过蓝牙配网，再通过 Wi-Fi 传输画面；不会作为普通 USB 摄像头出现在设备列表中。

已经配过 Wi-Fi 的模块不需要再次进入蓝牙配网状态。启动 WireCamera 后，可在右上角选择自动发现的 `Wi-Fi · 设备ID`；也可点击「添加摄像头」，选择 Wi-Fi 模块后点击「打开画面」。Mac 与模块所在网络需要互通。

程序通过局域网广播发现模块，按设备 ID 识别设备，并使用回复数据包的来源 IP 连接。IP 地址变化后会在下次发现时更新，不需要固定 IP、手动输入地址或保留上次的连接记录。

自动搜索无结果时，点击「添加摄像头」，在「IP 地址」中输入模块的 IPv4 地址，再点击「查找」。找到模块后，点击「打开画面」。此操作直接查询指定 IP，不需要蓝牙广播；Mac 必须能通过网络访问该地址。若模块离线或 IP 已变化，查找会显示失败，可修改地址后重试。

手动找到的模块和成功连接的模块会自动保存在本机。重新打开应用后，设备列表直接显示保存的模块；即使模块离线也会保留，选择设备即可按已保存的 IP 重新连接。相同设备 ID 的新地址会更新已有记录。记录位于 `~/Library/Application Support/WireCamera/modules.json`，仅保存设备 ID 和 IP，不保存 Wi-Fi 密码、设备签名或会话密钥。

首次配网：

1. 为模块供电，按模块说明长按按键，进入蓝灯闪烁的配网状态。
2. 点击右上角「添加摄像头」，允许 WireCamera 使用蓝牙。
3. 选择 `蓝牙 · 模块名称`，从自动搜索结果中选择 2.4 GHz Wi-Fi，输入密码，点击「连接 Wi-Fi」。Mac 与模块所在网络需要互通。
4. 等待模块接受配置、完成局域网连接并收到画面。收到第一帧后，配置窗口自动关闭，主界面显示 `Wi-Fi · 设备ID`。

macOS 要求定位权限才能让应用读取附近的 Wi-Fi 名称。如果列表为空，在「系统设置 → 隐私与安全性 → 定位服务」中开启定位服务并允许 WireCamera，然后刷新列表。WireCamera 不请求定位坐标。局域网连接还需要在「隐私与安全性 → 本地网络」中允许 WireCamera。

密码使用遮罩输入，不启用系统密码自动填充，不保存到偏好设置或日志。配网后蓝牙断开时，可直接重新连接已经配网的模块。预览中的「重试」会重连当前模块，并保留设备选项；设备菜单也可切回 USB 摄像头。

HA10 Wi-Fi 模块支持实时预览、镜像、全屏和带声音录制。当前支持模块返回的 G.711 A-law 声音；实时声音监听仍只适用于 USB 摄像头。WireCamera 使用局域网直连，不使用厂商账号。其他模块型号尚未进行实机验证。

已知设备 ID 时，可以直接连接已经配网的模块：

```sh
open "WireCamera.app" --args --add-camera --module-device-id "设备ID"
```

## 画面比例与镜头控制

在「实时」页的「画面比例」下拉框中选择模式。连接的 USB 摄像头支持 `4:3 · 1280 × 960` 和 `16:9 · 1280 × 720`；列表仅显示设备提供的模式。切换时会重新连接摄像头并关闭监听，录制期间不能切换比例。

16:9 使用摄像头原生宽屏输出，预览保持比例，不拉伸画面。这台摄像头的 16:9 模式会减少上下可视内容，不会增加镜头的光学视角；要保留更多画面，请使用 4:3。窗口比例与画面不同时仍可能出现黑边。

重复打开应用会激活已有窗口，避免多个实例争用摄像头格式。

已读取当前 VID 1133、PID 2085 设备的 UVC 摄像头终端描述符：未开放软件调焦、自动对焦或光学变焦控制，因此应用不提供这些调节功能。数字放大也不等同于调整镜头焦距。

## 实时与回放

顶部切换「实时 / 回放」，右侧选择摄像头。「实时」画面右上角显示本机当前日期与时间。

1. 在「实时」页等待画面出现，点击「开始录制」。录像自动保存到 `~/Movies/WireCamera/`，无需选择文件和声音选项。
2. 切换到「回放」，选择日期和录像。录制会继续运行，每 60 秒保存一个片段；当前片段在完成保存后可播放。
3. 点击「停止录制」，保存剩余片段。点击「录像文件夹」可在 Finder 中查看文件。

录制计时显示本次连续录制的累计时长，自动分段时不归零。停止后保留总时长，再次手动开始录制时从零计时。

USB 和 HA10 Wi-Fi 录制始终包含摄像头声音。USB 首次录制需要麦克风权限；未找到摄像头对应的声音输入、权限被拒绝或 Wi-Fi 声音尚未连接时，应用会提示并停止开始录制。应用不会自动使用 Mac 或 iPhone 麦克风。

回放的播放、暂停、进度、音量、倍速和全屏控件统一位于视频底部，画面中不显示悬浮控制器。橙色标记和右侧「人物出现」列出检测到的人物活动，点击事件从对应位置播放。索引每秒抽取一帧，合并相邻的人物活动，并保留前后画面；识别可能漏检或误检，仍可查看完整录像。索引未完成时显示「正在识别人物…」，失败后可点击「重新识别」。录像与索引保存在同一目录，重启后自动恢复未完成的索引任务。

录制使用摄像头原生画面尺寸，镜像与开始录制时一致。录制期间不能切换摄像头、画面比例和镜像。USB 的「监听声音」只控制实时播放，不影响录像声音；建议使用耳机避免回声。

录制先写入临时文件，片段完成后才加入回放列表。录制时退出应用或关闭窗口，会等待当前片段保存。设备断开、声音中断或存储空间不足时，应用会停止录制并提示结果；保存失败的临时文件位置会显示在错误提示中。意外断电或强制结束进程不保证临时文件可恢复。录像不会自动清理，请留意存储空间。

## 从源码构建

适用于 Apple Silicon Mac，macOS 14 及以上。构建需要 Apple Command Line Tools；运行已构建的应用不需要开发工具或其他依赖。

```sh
zsh scripts/build.sh
open "WireCamera.app"
```

应用使用 AppKit、AVFoundation、AVKit 和 Vision，无第三方运行依赖。构建产物与缓存都在项目内；使用本机临时签名，供当前 Mac 直接运行。跨机器分发需另行开发者签名及公证。

只读设备诊断（不请求权限、不打开预览）：

```sh
"WireCamera.app/Contents/MacOS/WireCamera" --diagnose
```

## 录制端到端验证

连接带声音输入的 USB 摄像头，并安装 ffmpeg（含 ffprobe）后运行：

```sh
zsh scripts/build.sh
zsh Tests/recording-e2e.sh
```

测试会保存真实摄像头的图像和声音样片。样片、轨道信息、解码日志和报告均位于 `.build/recording-e2e/`，不会上传。测试通过真实应用控件录制三段带声音 MOV（含退出时保存），再用 ffprobe 检查音视频轨和时长，用 ffmpeg 完整解码。失败场景和人工验收项见 [录制验收](Tests/recording-scenarios.md)。

画面比例验证：

```sh
zsh Tests/picture-mode-e2e.sh
```

测试在当前 USB 摄像头上依次切换 4:3、16:9、4:3，检查实时预览及带声音录像的实际尺寸。样片、JSON 报告和解码日志保存在 `.build/picture-mode-e2e/`。场景说明见 [画面比例验收](Tests/picture-mode-scenarios.md)。

## 实时与回放端到端验证

```sh
zsh scripts/build.sh
zsh Tests/library-e2e.sh
WIRECAMERA_E2E_SCENE=empty zsh Tests/library-e2e.sh
zsh Tests/recording-interruption-e2e.sh
zsh Tests/library-check.sh
zsh Tests/module-audio-check.sh
```

人物场景使用 NASA 宇航员照片，无人场景使用合成测试画面。测试通过真实应用控件连接本机模拟模块、录制带声音片段、切换回放、点击人物事件并重启检查恢复；同时使用 ffprobe 检查音视频轨与同步，使用 ffmpeg 完整解码。报告、截图、MOV 和解码日志位于 `.build/library-e2e/`。声音断流测试验证自动停止及可用文件保留，产物位于 `.build/recording-interruption-e2e/`。

真实 HA10 录制验收：

```sh
WIRECAMERA_MODULE_DEVICE_ID="设备ID" WIRECAMERA_MODULE_ADDRESS="模块IP" zsh Tests/wifi-recording-e2e.sh
```

该测试直接使用摄像头的图像与声音，产物位于 `.build/wifi-recording-e2e/`。测试通过不代表人物识别能覆盖所有环境。场景及失败边界见 [实时与回放验收](Tests/library-scenarios.md)，音频协议与已验证范围见 [Wi-Fi 声音验收](Tests/module-audio-scenarios.md)。所有测试使用项目内独立录像目录和设备文件，不修改日常使用的记录。

## 模块验证与开发检查

配网窗口验证需要模块处于蓝灯闪烁状态；预览验证需要模块已经配网：

```sh
zsh Tests/module-connection-e2e.sh
WIRECAMERA_MODULE_DEVICE_ID="设备ID" zsh Tests/module-discovery-e2e.sh
WIRECAMERA_MODULE_DEVICE_ID="设备ID" zsh Tests/module-preview-e2e.sh
WIRECAMERA_MODULE_ADDRESS="模块IP" zsh Tests/module-manual-e2e.sh
zsh Tests/module-manual-fixture-e2e.sh
zsh Tests/module-store-check.sh
zsh Tests/module-scan-e2e.sh
zsh Tests/password-field-e2e.sh
zsh Tests/module-protocol-check.sh
zsh Tests/module-network-check.sh
zsh Tests/module-video-check.sh
```

模块预览 E2E 验证真实视频解码与主界面显示，实际执行一次「重试」，再次持续显示 12 秒后才通过。实际画面、JSON 报告和日志位于 `.build/module-preview-e2e/`。配网、报文和网络失败场景分别见 `Tests/module-connection-scenarios.md`、`Tests/module-protocol-scenarios.md`、`Tests/module-network-scenarios.md` 和 `Tests/module-preview-scenarios.md`。

无记录发现 E2E 不向应用传入 IP、设备 ID 或蓝牙标识，通过实际连接窗口发现局域网模块、打开画面并执行重试。环境变量中的设备 ID 仅用于核对结果；可将应用路径作为第一个参数，以验证已安装版本。画面、JSON 报告和日志位于 `.build/module-discovery-e2e/`。扫描 E2E 使用真实网络套接字验证超时和取消后的回调行为，报告位于 `.build/module-scan-e2e/`；此项不要求发现真实模块。

手动 IP E2E 通过真实窗口输入地址，验证输入校验、查找、预览和重试，产物位于 `.build/module-manual-e2e/`。模拟模块 E2E 在本机网络地址提供合成 MJPEG，执行相同流程后退出应用，再关闭自动扫描、重启应用并从保存的设备列表连接；产物位于 `.build/module-manual-fixture-e2e/` 和 `.build/module-saved-e2e/`。模拟测试不代表摄像头实机已在线。测试使用项目内独立设备文件，不修改日常使用的设备记录。

Swift 命名与禁用写法由 `.swiftlint.yml` 检查，目录、文件命名和 Zsh 语法由 `scripts/lint.sh` 检查。安装 SwiftLint 后运行 `zsh scripts/lint.sh`，或通过 `WIRECAMERA_SWIFTLINT` 指定其路径。
