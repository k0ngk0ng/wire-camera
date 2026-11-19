#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
: "${WIRECAMERA_MODULE_ADDRESS:?请设置需要手动查找的摄像头模块 IPv4 地址。}"
APP_PATH="${1:-$PWD/WireCamera.app}"
if pgrep -f '/WireCamera.app/Contents/MacOS/WireCamera' >/dev/null; then
  printf '请先退出 WireCamera，再运行手动 IP 查找测试。\n' >&2
  exit 1
fi
RUN_DIR="$PWD/.build/module-manual-e2e/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
STORE_PATH="${WIRECAMERA_MODULE_STORE:-$RUN_DIR/modules.json}"
open -n --stderr "$RUN_DIR/app.log" "$APP_PATH" --args --module-manual-e2e "$RUN_DIR" --module-address "$WIRECAMERA_MODULE_ADDRESS" --module-store-path "$STORE_PATH"
for attempt in {1..160}; do
  if [[ -f "$RUN_DIR/app-result.json" ]]; then break; fi
  sleep 1
done
python3 - "$RUN_DIR" "$WIRECAMERA_MODULE_ADDRESS" <<'PY'
import json,pathlib,subprocess,sys
directory=pathlib.Path(sys.argv[1])
result=json.loads((directory/'app-result.json').read_text())
assert result['passed'],result
assert result['address']==sys.argv[2] and result['manualAddressUsed'],result
assert result['visibleRenderer'] and result['previewSeconds']>=12 and result['retryKeptModule'],result
assert result['moduleSaved'],result
checks=json.loads((directory/'manual-controls.json').read_text())
assert checks['passed'],checks
for filename in ['frame.png','manual-window.png']:
    decoded=subprocess.run(['ffmpeg','-v','error','-xerror','-i',str(directory/filename),'-frames:v','1','-f','null','-'],capture_output=True,text=True)
    (directory/(filename+'.decode.log')).write_text(decoded.stderr)
    assert decoded.returncode==0,decoded.stderr
(directory/'report.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
print(json.dumps(result,ensure_ascii=False,indent=2))
print('Artifacts: '+str(directory))
PY
