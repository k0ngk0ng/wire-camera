#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
RUN_DIR="$PWD/.build/recording-index-e2e/$(date +%Y%m%d-%H%M%S)"
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
mkdir -p "$RUN_DIR/library" "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"
MOVIE_ID="$(uuidgen)"
ffmpeg -v error -loop 1 -framerate 10 -i Tests/Fixtures/person-frame.jpg -f lavfi -i 'sine=frequency=440:sample_rate=8000:duration=3.2' \
  -filter_complex '[0:v]trim=duration=0.8,setpts=PTS-STARTPTS[v]' -map '[v]' -map 1:a -c:v libx264 -pix_fmt yuv420p -c:a aac -t 3.2 "$RUN_DIR/library/$MOVIE_ID.mov"
xcrun swiftc -swift-version 5 -module-cache-path "$CLANG_MODULE_CACHE_PATH" -framework AVFoundation -framework Vision \
  Shared/CameraRemoteCoding.swift Sources/CameraRecordingLibrary.swift Tests/CameraRecordingIndexE2E.swift -o "$RUN_DIR/check"
"$RUN_DIR/check" "$RUN_DIR" "$RUN_DIR/library/$MOVIE_ID.mov"
printf 'Artifacts: %s\n' "$RUN_DIR"
