# WireCamera

Mac 原生摄像头预览工具。双击「应用程序」中的 **WireCamera.app**（安装路径：`/Applications/WireCamera.app`），或打开项目目录中的同名应用，首次运行在系统提示中允许摄像头访问，即可查看实时画面。

- 自动优先选择外接 USB 摄像头，可在右上角切换设备。
- 支持镜像、调整窗口大小、全屏（⌃⌘F），按原始比例显示画面。
- 支持拔插设备自动重连；⌘R 重新连接。
- 底部显示实际画面分辨率与帧率；关闭窗口即退出并释放摄像头。
- 仅本地预览，不录制、不上传，不请求麦克风权限。

如果没有画面，请检查 USB 连接、关闭其他使用摄像头的应用后点击“重试”。如果拒绝过授权，在“系统设置 → 隐私与安全性 → 摄像头”中开启“WireCamera”，然后重新打开应用。

## 从源码构建

适用于 Apple Silicon Mac，macOS 14 及以上。构建需要 Apple Command Line Tools；运行已构建的应用不需要开发工具或其他依赖。

```sh
zsh scripts/build.sh
open "WireCamera.app"
```

应用使用 AppKit 与 AVFoundation，无第三方依赖。构建产物与缓存都在项目内；使用本机临时签名，供当前 Mac 直接运行。跨机器分发需另行开发者签名及公证。

只读设备诊断（不请求权限、不打开预览）：

```sh
"WireCamera.app/Contents/MacOS/WireCamera" --diagnose
```
