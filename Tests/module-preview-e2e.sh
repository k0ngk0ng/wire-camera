#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
: "${WIRECAMERA_MODULE_DEVICE_ID:?请设置已经配网的摄像头模块设备 ID。}"
APP_PATH="${1:-$PWD/WireCamera.app}"
if pgrep -f '/WireCamera.app/Contents/MacOS/WireCamera' >/dev/null; then
  printf '请先退出 WireCamera，再运行模块预览测试。\n' >&2
  exit 1
fi
RUN_DIR="$PWD/.build/module-preview-e2e/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
open -n --stderr "$RUN_DIR/app.log" "$APP_PATH" --args --module-preview-e2e "$RUN_DIR" --module-device-id "$WIRECAMERA_MODULE_DEVICE_ID"
for attempt in {1..160}; do
  if [[ -f "$RUN_DIR/app-result.json" ]]; then break; fi
  sleep 1
done
python3 - "$RUN_DIR" "$WIRECAMERA_MODULE_DEVICE_ID" <<'PY'
import json,pathlib,subprocess,sys
directory=pathlib.Path(sys.argv[1])
result=json.loads((directory/'app-result.json').read_text())
assert result['passed'],result
assert result['deviceID']==sys.argv[2],result
assert result['width']>0 and result['height']>0 and result['frameReports']>=3,result
assert result['visibleRenderer'],result
assert result['previewSeconds']>=12,result
assert result['retryKeptModule'] and result['moduleListed'],result
frame=directory/'frame.png'
assert frame.stat().st_size>1000
decoded=subprocess.run(['ffmpeg','-v','error','-xerror','-i',str(frame),'-frames:v','1','-f','null','-'],capture_output=True,text=True)
(directory/'frame.decode.log').write_text(decoded.stderr)
assert decoded.returncode==0,decoded.stderr
(directory/'report.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
print(json.dumps(result,ensure_ascii=False,indent=2))
print('Artifacts: '+str(directory))
PY
