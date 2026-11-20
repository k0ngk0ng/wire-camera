#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"
APP="$PWD/WireCamera.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 \
  -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -framework AppKit -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework CoreImage -framework ImageIO -framework VideoToolbox -framework IOKit -framework UniformTypeIdentifiers -framework CoreBluetooth -framework CoreLocation -framework CoreWLAN -framework AVKit -framework Vision \
  Sources/CameraAudioDevice.swift Sources/CameraPictureMode.swift Sources/CameraController.swift Sources/CameraRecordingLibrary.swift Sources/CameraNetworkRecorder.swift Sources/CameraPlaybackView.swift Sources/CameraModuleAudioSampler.swift Sources/CameraModuleDiscovery.swift Sources/CameraModuleProtocol.swift Sources/CameraModuleVideoSampler.swift Sources/CameraModuleNetwork.swift Sources/CameraModuleStore.swift Sources/WiFiPasswordField.swift Sources/CameraModuleConnection.swift Sources/main.swift -o "$APP/Contents/MacOS/WireCamera"
cp Info.plist "$APP/Contents/Info.plist"
xcrun swift -module-cache-path "$CLANG_MODULE_CACHE_PATH" scripts/make-icon.swift "$PWD/.build"
iconutil -c icns "$PWD/.build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier com.wirecamera.viewer "$APP"
codesign --verify --deep --strict "$APP"
printf '已构建：%s\n' "$APP"
