#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
RUN_DIR="$PWD/.build/day-timeline-check/$(date +%Y%m%d-%H%M%S)"
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
mkdir -p "$RUN_DIR" "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"
xcrun swiftc -swift-version 5 -module-cache-path "$CLANG_MODULE_CACHE_PATH" -framework AVFoundation -framework Vision \
  Shared/CameraRemoteCoding.swift Sources/CameraMotionDetector.swift Sources/CameraRecordingLibrary.swift Sources/CameraPlaybackDay.swift Tests/CameraPlaybackDayCheck.swift -o "$RUN_DIR/check"
"$RUN_DIR/check" "$RUN_DIR/report.json"
