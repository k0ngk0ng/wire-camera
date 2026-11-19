#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
: "${WIRECAMERA_MODULE_STORE:?请设置手动查找测试保存的设备文件路径。}"
APP_PATH="${1:-$PWD/WireCamera.app}"
RUN_DIR="$PWD/.build/module-saved-e2e/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
open -n --stderr "$RUN_DIR/app.log" "$APP_PATH" --args --module-saved-e2e "$RUN_DIR" --module-store-path "$WIRECAMERA_MODULE_STORE"
for attempt in {1..160}; do
  if [[ -f "$RUN_DIR/app-result.json" ]]; then break; fi
  sleep 1
done
python3 - "$RUN_DIR" <<'PY'
import json,pathlib,subprocess,sys
directory=pathlib.Path(sys.argv[1])
result=json.loads((directory/'app-result.json').read_text())
assert result['passed'] and result['moduleSaved'] and result['restoredWithoutDiscovery'],result
assert result['manualAddressUsed'] and result['retryKeptModule'],result
decoded=subprocess.run(['ffmpeg','-v','error','-xerror','-i',str(directory/'frame.png'),'-frames:v','1','-f','null','-'],capture_output=True,text=True)
(directory/'frame.decode.log').write_text(decoded.stderr)
assert decoded.returncode==0,decoded.stderr
(directory/'report.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
print(json.dumps(result,ensure_ascii=False,indent=2))
print('Artifacts: '+str(directory))
PY
