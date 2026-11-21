#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
RUN_DIR="${WIRECAMERA_REMOTE_RUN_DIR:-$PWD/.build/remote-e2e/$(date +%Y%m%d-%H%M%S)}"
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
mkdir -p "$RUN_DIR/library" "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"
xcrun swiftc -swift-version 5 -module-cache-path "$CLANG_MODULE_CACHE_PATH" -framework CoreMedia -framework VideoToolbox Sources/CameraModuleProtocol.swift Sources/CameraModuleNetwork.swift Sources/CameraModuleVideoSampler.swift Sources/CameraModuleAudioSampler.swift Tests/CameraModuleManualFixture.swift -o "$RUN_DIR/fixture"
INTERFACE_NAME="$(route -n get default | awk '$1 == "interface:" {print $2}')"
FIXTURE_ADDRESS="$(ipconfig getifaddr "$INTERFACE_NAME")"
FIXTURE_PID=0
if [[ "${WIRECAMERA_FIXTURE_SHARED:-0}" != 1 ]]; then
  "$RUN_DIR/fixture" "$FIXTURE_ADDRESS" "$RUN_DIR" "$PWD/Tests/Fixtures/person-frame.jpg" --audio --multi-camera --keep-second-online --long-lived > "$RUN_DIR/fixture.log" 2>&1 &
  FIXTURE_PID=$!
  printf '%s\n' "$FIXTURE_PID" > "$RUN_DIR/fixture.pid"
fi
APP_PID=0
trap 'if (( FIXTURE_PID > 0 )); then kill "$FIXTURE_PID" 2>/dev/null || true; fi; if (( APP_PID > 0 )); then kill "$APP_PID" 2>/dev/null || true; fi' EXIT
python3 - "$RUN_DIR" "$FIXTURE_ADDRESS" <<'PY'
import json,pathlib,subprocess,sys,uuid,datetime
root=pathlib.Path(sys.argv[1])
(root/'modules.json').write_text(json.dumps([{'deviceID':name,'address':sys.argv[2]} for name in ['fixture-manual-device','fixture-preview-device']]))
identifier=str(uuid.uuid4()).upper()
movie=root/'library'/(identifier+'.mov')
subprocess.run(['ffmpeg','-v','error','-loop','1','-i','Tests/Fixtures/person-frame.jpg','-f','lavfi','-i','sine=frequency=700:sample_rate=8000','-t','3','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac',str(movie)],check=True)
started=datetime.datetime.now().timestamp()-86400
(movie.with_suffix('.json')).write_text(json.dumps({'id':identifier,'sourceID':'offline:fixture','sourceName':'离线摄像头','startedAt':started-978307200,'duration':3,'events':[{'start':0,'end':2}],'indexState':'ready'}))
(root/'offline-id').write_text(identifier)
outside_id=str(uuid.uuid4()).upper()
outside=root/'outside.mov'
outside.write_bytes(movie.read_bytes())
(root/'library'/(outside_id+'.mov')).symlink_to(outside)
entry=json.loads(movie.with_suffix('.json').read_text())
entry.update(id=outside_id,sourceID='outside:fixture',sourceName='目录外测试')
(root/'library'/(outside_id+'.json')).write_text(json.dumps(entry))
(root/'outside-id').write_text(outside_id)
PY
for attempt in {1..10}; do
  if [[ "${WIRECAMERA_FIXTURE_SHARED:-0}" == 1 ]]; then break; fi
  if [[ -f "$RUN_DIR/ready" ]]; then break; fi
  sleep 1
done
TEST_APP="$RUN_DIR/WireCamera Test.app"
ditto "${1:-$PWD/WireCamera.app}" "$TEST_APP"
TEST_APP_ID="${WIRECAMERA_TEST_BUNDLE_ID:-com.wirecamera.remote-e2e}"
plutil -replace CFBundleIdentifier -string "$TEST_APP_ID" "$TEST_APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "WireCamera Test" "$TEST_APP/Contents/Info.plist"
codesign --force --sign - "$TEST_APP" > "$RUN_DIR/sign.log" 2>&1
"$TEST_APP/Contents/MacOS/WireCamera" --remote-server-test "$RUN_DIR" --verify-background --record-camera fixture-manual-device --module-store-path "$RUN_DIR/modules.json" --recordings-path "$RUN_DIR/library" --disable-module-scan > "$RUN_DIR/app.log" 2>&1 &
APP_PID=$!
printf '%s\n' "$APP_PID" > "$RUN_DIR/app.pid"
for attempt in {1..30}; do
  if [[ -f "$RUN_DIR/server-ready.json" ]]; then break; fi
  sleep 1
done
python3 Tests/remote-client-e2e.py "$RUN_DIR"
printf 'Artifacts: %s\n' "$RUN_DIR"
if [[ "${WIRECAMERA_REMOTE_KEEP_ALIVE:-0}" == 1 ]]; then
  wait "$APP_PID"
fi
