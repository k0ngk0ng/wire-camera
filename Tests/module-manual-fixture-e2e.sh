#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
RUN_DIR="$PWD/.build/module-manual-fixture-e2e/$(date +%Y%m%d-%H%M%S)"
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
mkdir -p "$RUN_DIR" "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"
INTERFACE_NAME="$(route -n get default | awk '$1 == "interface:" {print $2}')"
export WIRECAMERA_MODULE_ADDRESS="$(ipconfig getifaddr "$INTERFACE_NAME")"
export WIRECAMERA_MODULE_STORE="$RUN_DIR/modules.json"
xcrun swiftc -swift-version 5 -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -framework CoreMedia -framework VideoToolbox \
  Sources/CameraModuleProtocol.swift Sources/CameraModuleNetwork.swift Sources/CameraModuleVideoSampler.swift Sources/CameraModuleAudioSampler.swift Tests/CameraModuleManualFixture.swift \
  -o "$RUN_DIR/fixture"
"$RUN_DIR/fixture" "$WIRECAMERA_MODULE_ADDRESS" "$RUN_DIR" "$PWD/Tests/Fixtures/module-jpeg-frame.jpg" > "$RUN_DIR/fixture.log" 2>&1 &
FIXTURE_PID=$!
trap 'kill "$FIXTURE_PID" 2>/dev/null || true' EXIT
for attempt in {1..10}; do
  if [[ -f "$RUN_DIR/ready" ]]; then break; fi
  sleep 1
done
[[ -f "$RUN_DIR/ready" ]]
zsh Tests/module-manual-e2e.sh "${1:-$PWD/WireCamera.app}" > "$RUN_DIR/manual.log" 2>&1
zsh Tests/module-saved-e2e.sh "${1:-$PWD/WireCamera.app}" > "$RUN_DIR/saved.log" 2>&1
python3 - "$RUN_DIR" <<'PY'
import json,pathlib,sys
directory=pathlib.Path(sys.argv[1])
report=json.loads((directory/'server.json').read_text())
assert report['connections']>=4,report
report['passed']=True
(directory/'report.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
print('Artifacts: '+str(directory))
PY
