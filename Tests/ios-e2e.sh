#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export TMPDIR="$PWD/.build/tmp"
RUN_DIR="$PWD/.build/ios-e2e/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR" "$TMPDIR"
export WIRECAMERA_REMOTE_RUN_DIR="$RUN_DIR/server"
WIRECAMERA_REMOTE_KEEP_ALIVE=1 zsh Tests/remote-e2e.sh > "$RUN_DIR/server.log" 2>&1 &
SERVER_PID=$!
trap 'if [[ -f "$RUN_DIR/server/app.pid" ]]; then kill "$(cat "$RUN_DIR/server/app.pid")" 2>/dev/null || true; fi; if [[ -f "$RUN_DIR/server/fixture.pid" ]]; then kill "$(cat "$RUN_DIR/server/fixture.pid")" 2>/dev/null || true; fi; kill "$SERVER_PID" 2>/dev/null || true' EXIT
for attempt in {1..60}; do
  if [[ -f "$RUN_DIR/server/report.json" ]]; then break; fi
  sleep 1
done
python3 - "$RUN_DIR" <<'PY'
import json,os,pathlib,subprocess,sys
root=pathlib.Path(sys.argv[1])
settings=json.loads((root/'server/server-ready.json').read_text())
assert json.loads((root/'server/report.json').read_text())['passed']
environment=dict(os.environ)
environment['TEST_RUNNER_WIRECAMERA_TEST_HOST']=subprocess.check_output(['ipconfig','getifaddr',subprocess.check_output(['route','-n','get','default'],text=True).split('interface: ')[1].splitlines()[0].strip()],text=True).strip()
environment['TEST_RUNNER_WIRECAMERA_TEST_PORT']=str(settings['port'])
environment['TEST_RUNNER_WIRECAMERA_TEST_PASSWORD']=settings['password']
environment['TEST_RUNNER_WIRECAMERA_TEST_ORIENTATION']=os.environ.get('WIRECAMERA_TEST_ORIENTATION','')
device=os.environ.get('WIRECAMERA_DEVICE_ID')
team=os.environ.get('WIRECAMERA_TEAM_ID')
assert device and team,'需要 WIRECAMERA_DEVICE_ID 和 WIRECAMERA_TEAM_ID。'
command=['xcodebuild','-project','iOS/WireCamera.xcodeproj','-scheme','WireCamera','-configuration','Debug','-destination','id='+device,'-derivedDataPath',str(pathlib.Path.cwd()/'.build/ios-derived'),'-resultBundlePath',str(root/'WireCamera.xcresult'),'-allowProvisioningUpdates','-allowProvisioningDeviceRegistration','DEVELOPMENT_TEAM='+team,'test']
with (root/'test.log').open('w') as output:
    result=subprocess.run(command,env=environment,stdout=output,stderr=subprocess.STDOUT)
assert result.returncode==0,'真机 E2E 失败，请查看 '+str(root/'test.log')
(root/'report.json').write_text(json.dumps({'passed':True,'scope':'physical_iphone','resultBundle':str(root/'WireCamera.xcresult')}))
PY
xcrun xcresulttool export attachments --path "$RUN_DIR/WireCamera.xcresult" --output-path "$RUN_DIR/screenshots"
printf 'Artifacts: %s\n' "$RUN_DIR"
