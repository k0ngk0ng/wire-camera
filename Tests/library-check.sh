#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
RUN_DIR="$PWD/.build/library-check/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH" "$RUN_DIR"
xcrun swiftc -swift-version 5 -module-cache-path "$CLANG_MODULE_CACHE_PATH" -framework Vision -framework AVFoundation \
  Shared/CameraRemoteCoding.swift Sources/CameraMotionDetector.swift Sources/CameraRecordingLibrary.swift Tests/CameraLibraryCheck.swift -o "$RUN_DIR/check"
"$RUN_DIR/check" "$RUN_DIR/library"
