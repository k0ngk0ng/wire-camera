# Wi-Fi 模块声音验收

实现前列出的失败场景：AudioPlay 被拒绝、响应缺少编码或采样参数、采样率为零或超出范围、位深不受支持、声道数不受支持、未知音频编码、音频载荷为空、分片尚未组装、载荷未按声道数对齐、时间戳溢出、历史流混入实时流、重复或倒序音频包、网络断开、模块不返回声音。音频失败不得中断实时画面，也不得伪造声音或自动使用 Mac 麦克风。

`zsh Tests/module-audio-check.sh` 验证固定 A-law 向量、PCM 格式与时间戳、参数校验、错误帧拒绝以及音视频分类。报告写入 `.build/module-audio-check/report.json`；该检查不代表硬件验收。

本次协议依据为项目内官方 APK：SHA-256 `007df6c985ef9ea6ca318e78d646d90333646c4c42a2a439c75b0aa6ddb1f528`。`classes6.dex` 的 `C_STREAM_TYPE` 常量确认 G711A 为 21；原生 `audioPlayClient.PPCall` 在地址 `0x124b648` 使用命令 2614。Req 的 channel 是 protobuf 字段 1；Resp 的 code、codec、rate、bit、track 分别是字段 1、5、6、7、8。

已验证的 HA10 实机在取流中返回编码 21、8000 Hz、16 位、单声道，收到真实音频载荷。原始取流报告与解码产物保存在 `.build/module-audio/`。REA 的原生分析 provider 当前不可用；本次使用项目内已有 Go 元数据、Capstone 和 Androguard 离线检查工件，并通过真实网络响应交叉验证。

本次真实声音样片长 7.1 秒，共 56800 个 PCM 采样，存在 32 种采样值，最小值 −344、最大值 152，RMS 为 −59.70 dBFS。26175 个采样超过 A-law 的静音量化幅度，确认收到并解码了非恒定的实际麦克风信号；当前环境声音较低，此项不代表已验证清晰语音。可检查 `.build/module-audio/real-audio.wav`、`real-audio.probe.json`、`real-audio.decode.log` 和 `waveform-report.json`。

发现报文必须先发送二进制请求；需要兼容旧模块时，在下一轮发送 JSON 请求。同一个 UDP socket 连续先发 JSON、紧接二进制请求时，本次 HA10 实机会不返回发现响应。最小 Python 比对确认：仅二进制、先二进制后 JSON 均收到 906 字节响应，先 JSON 后二进制超时。请求字节与产品实现一致，比对报告位于 `.build/udp-compare/python-order-report.json`。

产品改为每轮交替单发二进制 / JSON、优先二进制后，应用内真实 Wi-Fi 录制 E2E 通过。`.build/wifi-recording-e2e/20261121-023145/report.json` 保存了直连实机的分段、回放、重启恢复结果；640 × 480 画面和 AAC 声音均完整解码，音视频时长差小于 1 秒。此运行未使用网络中继。

`WIRECAMERA_MODULE_DEVICE_ID="设备ID" WIRECAMERA_MODULE_ADDRESS="模块IP" zsh Tests/module-audio-e2e.sh` 使用产品网络实现同时接收画面与声音，并校验帧数、PCM 时长与模块时间戳。本次独立 Swift 命令行进程未通过发现阶段，失败报告位于 `.build/module-audio-e2e/`。最小独立 C、Swift 程序均存在收包差异，而相同 C 函数由 Python 承载可收到响应；这是独立命令行验证的环境限制，未确定最终原因，不能据此认定应用的权限或过滤器存在问题。应用验收以上述真实 `.app` E2E 报告为准。
