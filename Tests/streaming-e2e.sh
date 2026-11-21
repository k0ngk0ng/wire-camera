#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
RUN_DIR="$PWD/.build/streaming-e2e/$(date +%Y%m%d-%H%M%S)"
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
mkdir -p "$RUN_DIR" "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"
ffmpeg -v error -f lavfi -i testsrc2=size=640x480:rate=10 -f lavfi -i sine=frequency=500:sample_rate=8000 -t 60 -c:v libx264 -preset ultrafast -b:v 2000k -minrate 2000k -maxrate 2000k -bufsize 4000k -x264-params nal-hrd=cbr:force-cfr=1 -g 20 -bf 0 -pix_fmt yuv420p -c:a aac -b:a 24k "$RUN_DIR/first.mov"
ffmpeg -v error -f lavfi -i color=c=blue:size=640x480:rate=10 -f lavfi -i sine=frequency=1000:sample_rate=8000 -t 6 -c:v libx264 -preset ultrafast -g 10 -pix_fmt yuv420p -c:a aac -b:a 24k "$RUN_DIR/second.mov"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$RUN_DIR/key.pem" -out "$RUN_DIR/cert.pem" -days 1 -subj /CN=WireCamera.Streaming.Test > "$RUN_DIR/certificate.log" 2>&1
python3 Tests/streaming-fixture.py "$RUN_DIR" > "$RUN_DIR/server.log" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
for attempt in {1..20}; do
  if [[ -f "$RUN_DIR/ready.json" ]]; then break; fi
  sleep 0.2
done
xcrun swiftc -swift-version 5 -module-cache-path "$CLANG_MODULE_CACHE_PATH" -framework AppKit -framework AVFoundation -framework CoreImage -framework Security \
  Shared/CameraRemoteCoding.swift Shared/CameraRemoteTrust.swift Shared/CameraPlaybackResource.swift Tests/CameraStreamingE2E.swift -o "$RUN_DIR/player"
"$RUN_DIR/player" "$RUN_DIR" > "$RUN_DIR/player.log" 2>&1
python3 - "$RUN_DIR" <<'PY'
import json,pathlib,subprocess,sys
root=pathlib.Path(sys.argv[1])
report=json.loads((root/'player-result.json').read_text())
assert report['passed'],report
for name in ['first','second']:
    metadata=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-of','json',str(root/(name+'.mov'))],text=True))
    assert any(track['codec_type']=='audio' for track in metadata['streams'])
events=[json.loads(line) for line in (root/'requests.jsonl').read_text().splitlines()]
ranges=[item for item in events if item.get('method')=='GET']
assert ranges and all(item.get('range','').startswith('bytes=') for item in ranges),ranges
assert any(item.get('start',0)>int((root/'first.mov').stat().st_size*0.55) for item in ranges),ranges
report['allMovieRequestsUseRanges']=True
report['farSeekUsesNonzeroOffsets']=True
(root/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print('Artifacts: '+str(root))
PY
