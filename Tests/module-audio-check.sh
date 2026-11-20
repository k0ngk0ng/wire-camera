#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
RUN_DIR="$PWD/.build/module-audio-check"
mkdir -p "$RUN_DIR" "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"
xcrun swiftc -swift-version 5 -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -framework CoreMedia -framework VideoToolbox -framework AudioToolbox \
  Sources/CameraModuleProtocol.swift Sources/CameraModuleNetwork.swift Sources/CameraModuleVideoSampler.swift Sources/CameraModuleAudioSampler.swift Tests/CameraModuleAudioCheck.swift \
  -o "$RUN_DIR/check"
"$RUN_DIR/check" "$RUN_DIR/report.json"
