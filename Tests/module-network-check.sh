#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
RUN_DIR="$PWD/.build/module-network-check"
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
mkdir -p "$RUN_DIR" "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"
xcrun swiftc -swift-version 5 -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -framework CoreMedia -framework VideoToolbox \
  Sources/CameraModuleDiscovery.swift Sources/CameraModuleProtocol.swift Sources/CameraModuleNetwork.swift Sources/CameraModuleVideoSampler.swift Sources/CameraModuleAudioSampler.swift Tests/CameraModuleNetworkCheck.swift \
  -o "$RUN_DIR/check"
"$RUN_DIR/check" "$PWD" "$RUN_DIR/report.json"
