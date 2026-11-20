#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
: "${WIRECAMERA_MODULE_DEVICE_ID:?需要 WIRECAMERA_MODULE_DEVICE_ID}"
: "${WIRECAMERA_MODULE_ADDRESS:?需要 WIRECAMERA_MODULE_ADDRESS}"
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
RUN_DIR="$PWD/.build/module-audio-e2e/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR" "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"
xcrun swiftc -swift-version 5 -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -framework CoreMedia -framework VideoToolbox -framework AudioToolbox \
  Sources/CameraModuleProtocol.swift Sources/CameraModuleNetwork.swift Sources/CameraModuleVideoSampler.swift Sources/CameraModuleAudioSampler.swift Tests/CameraModuleAudioE2E.swift \
  -o "$RUN_DIR/check"
"$RUN_DIR/check" "$WIRECAMERA_MODULE_DEVICE_ID" "$WIRECAMERA_MODULE_ADDRESS" "$RUN_DIR"
ffprobe -v error -show_streams -show_format -of json "$RUN_DIR/audio.wav" > "$RUN_DIR/audio.probe.json"
ffmpeg -v error -xerror -i "$RUN_DIR/audio.wav" -f null - > "$RUN_DIR/audio.decode.log" 2>&1
printf 'Artifacts: %s\n' "$RUN_DIR"
