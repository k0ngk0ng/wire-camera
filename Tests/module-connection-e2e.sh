#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
APP_PATH="${1:-$PWD/WireCamera.app}"
if pgrep -f '/WireCamera.app/Contents/MacOS/WireCamera' >/dev/null; then
  printf '请先退出 WireCamera，再运行模块连接测试。\n' >&2
  exit 1
fi
RUN_DIR="$PWD/.build/module-connection-e2e/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
MODULE_ARGUMENTS=()
if [[ -n "${WIRECAMERA_MODULE_IDENTIFIER:-}" ]]; then
  MODULE_ARGUMENTS=(--module-identifier "$WIRECAMERA_MODULE_IDENTIFIER")
fi
open -n --stderr "$RUN_DIR/app.log" "$APP_PATH" --args --module-connection-e2e "$RUN_DIR" "${MODULE_ARGUMENTS[@]}"
for attempt in {1..150}; do
  if [[ -f "$RUN_DIR/app-result.json" ]]; then break; fi
  sleep 1
done
python3 - "$RUN_DIR" <<'PY'
import json,pathlib,sys
directory=pathlib.Path(sys.argv[1])
result=json.loads((directory/'app-result.json').read_text())
assert result['passed'],result
checks={item['name']:item['passed'] for item in result['checks']}
for name in ['main_window_action','module_discovered','module_gatt_verified','wifi_field_editable','wifi_networks_discovered','password_field_secure','empty_ssid_rejected','credentials_validated','no_configuration_sent']:
    assert checks.get(name),name
assert result['moduleName'].startswith(('LLM_','AXH_')),result
assert (directory/'connection.png').stat().st_size>1000
assert 'WireCamera-E2E-not-a-password' not in (directory/'app.log').read_text()
(directory/'report.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
print(json.dumps(result,ensure_ascii=False,indent=2))
print('Artifacts: '+str(directory))
PY
