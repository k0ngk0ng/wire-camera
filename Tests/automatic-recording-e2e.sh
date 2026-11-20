#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
RUN_DIR="$PWD/.build/automatic-recording-e2e/$(date +%Y%m%d-%H%M%S)"
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
mkdir -p "$RUN_DIR" "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"
INTERFACE_NAME="$(route -n get default | awk '$1 == "interface:" {print $2}')"
FIXTURE_ADDRESS="$(ipconfig getifaddr "$INTERFACE_NAME")"
xcrun swiftc -swift-version 5 -module-cache-path "$CLANG_MODULE_CACHE_PATH" -framework CoreMedia -framework VideoToolbox \
  Sources/CameraModuleProtocol.swift Sources/CameraModuleNetwork.swift Sources/CameraModuleVideoSampler.swift Sources/CameraModuleAudioSampler.swift Tests/CameraModuleManualFixture.swift -o "$RUN_DIR/fixture"
"$RUN_DIR/fixture" "$FIXTURE_ADDRESS" "$RUN_DIR" "$PWD/Tests/Fixtures/module-jpeg-frame.jpg" --audio > "$RUN_DIR/fixture.log" 2>&1 &
FIXTURE_PID=$!
trap 'kill "$FIXTURE_PID" 2>/dev/null || true' EXIT
python3 - "$RUN_DIR/modules.json" "$FIXTURE_ADDRESS" <<'PY'
import json,pathlib,sys
pathlib.Path(sys.argv[1]).write_text(json.dumps([{'deviceID':'fixture-manual-device','address':sys.argv[2]}]))
PY
for attempt in {1..10}; do
  if [[ -f "$RUN_DIR/ready" ]]; then break; fi
  sleep 1
done
open -n --stderr "$RUN_DIR/app.log" "${1:-$PWD/WireCamera.app}" --args --record-camera fixture-manual-device --add-camera --module-device-id fixture-manual-device --automatic-recording-e2e "$RUN_DIR" --module-store-path "$RUN_DIR/modules.json" --recordings-path "$RUN_DIR/library" --disable-module-scan
for attempt in {1..30}; do
  if [[ -f "$RUN_DIR/app-result.json" ]]; then break; fi
  sleep 1
done
python3 - "$RUN_DIR" <<'PY'
import json,pathlib,subprocess,sys
directory=pathlib.Path(sys.argv[1])
report=json.loads((directory/'app-result.json').read_text())
assert report['passed'],report
movie=next((directory/'library').glob('*.mov'))
probe=subprocess.run(['ffprobe','-v','error','-show_streams','-of','json',str(movie)],capture_output=True,text=True,check=True)
(directory/'tracks.json').write_text(probe.stdout)
assert {item['codec_type'] for item in json.loads(probe.stdout)['streams']}=={'video','audio'}
decoded=subprocess.run(['ffmpeg','-v','error','-xerror','-i',str(movie),'-f','null','-'],capture_output=True,text=True)
(directory/'decode.log').write_text(decoded.stderr)
assert decoded.returncode==0,decoded.stderr
report['fullyDecoded']=True
(directory/'report.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
print('Artifacts: '+str(directory))
PY
