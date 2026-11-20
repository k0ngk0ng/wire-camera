#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
RUN_DIR="$PWD/.build/recording-interruption-e2e/$(date +%Y%m%d-%H%M%S)"
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
mkdir -p "$RUN_DIR" "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"
INTERFACE_NAME="$(route -n get default | awk '$1 == "interface:" {print $2}')"
FIXTURE_ADDRESS="$(ipconfig getifaddr "$INTERFACE_NAME")"
xcrun swiftc -swift-version 5 -module-cache-path "$CLANG_MODULE_CACHE_PATH" -framework CoreMedia -framework VideoToolbox \
  Sources/CameraModuleProtocol.swift Sources/CameraModuleNetwork.swift Sources/CameraModuleVideoSampler.swift Sources/CameraModuleAudioSampler.swift Tests/CameraModuleManualFixture.swift -o "$RUN_DIR/fixture"
"$RUN_DIR/fixture" "$FIXTURE_ADDRESS" "$RUN_DIR" "$PWD/Tests/Fixtures/module-jpeg-frame.jpg" --audio --audio-drop > "$RUN_DIR/fixture.log" 2>&1 &
FIXTURE_PID=$!
trap 'kill "$FIXTURE_PID" 2>/dev/null || true' EXIT
for attempt in {1..10}; do
  if [[ -f "$RUN_DIR/ready" ]]; then break; fi
  sleep 1
done
open -n --stderr "$RUN_DIR/app.log" "${1:-$PWD/WireCamera.app}" --args --library-e2e "$RUN_DIR" --fixture-address "$FIXTURE_ADDRESS" --expect-audio-interruption --recordings-path "$RUN_DIR/library" --module-store-path "$RUN_DIR/modules.json" --disable-module-scan
for attempt in {1..140}; do
  if [[ -f "$RUN_DIR/record-result.json" ]]; then break; fi
  sleep 1
done
python3 - "$RUN_DIR" <<'PY'
import json,pathlib,subprocess,sys
directory=pathlib.Path(sys.argv[1])
report=json.loads((directory/'record-result.json').read_text())
assert report['passed'],report
movies=list((directory/'library').glob('*.mov'))
assert len(movies)==1,movies
decoded=subprocess.run(['ffmpeg','-v','error','-xerror','-i',str(movies[0]),'-f','null','-'],capture_output=True,text=True)
(directory/'decode.log').write_text(decoded.stderr)
assert decoded.returncode==0,decoded.stderr
report['fullyDecoded']=True
(directory/'report.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
print('Artifacts: '+str(directory))
PY
