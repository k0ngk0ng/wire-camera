#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
RUN_DIR="$PWD/.build/motion-e2e/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR/library"
python3 - "$RUN_DIR" <<'PY'
import json,os,pathlib,subprocess,sys,time,uuid
root=pathlib.Path(sys.argv[1])
manifest={}
for name in ['static','exposure','moving','blurred','legacy']:
    identifier=str(uuid.uuid4()).upper()
    movie=root/'library'/(identifier+'.mov')
    command=['ffmpeg','-v','error','-f','lavfi','-i','color=c=gray:size=640x480:rate=10']
    if name in ['moving','blurred']:
        command+=['-f','lavfi','-i','color=c=0x182030:size=320x440:rate=10','-f','lavfi','-i','sine=frequency=500:sample_rate=8000']
        filter_value="[0:v][1:v]overlay=x='(W+w)*t/8-w':y=20:eval=frame"
        if name=='blurred':filter_value+=',gblur=sigma=16'
        command+=['-filter_complex',filter_value+'[video]','-map','[video]','-map','2:a:0']
    else:
        command+=['-f','lavfi','-i','sine=frequency=500:sample_rate=8000']
        if name=='exposure':command+=['-vf',"eq=brightness='0.2*sin(t*4)':eval=frame"]
    command+=['-t','8','-c:v','libx264','-preset','ultrafast','-pix_fmt','yuv420p','-c:a','aac',str(movie)]
    subprocess.run(command,check=True)
    entry={'id':identifier,'sourceID':'offline:motion-'+name,'sourceName':name,'startedAt':time.time()-3600-978307200,'duration':8,'events':[{'start':1,'end':2}] if name=='legacy' else [],'indexState':'ready' if name=='legacy' else 'processing'}
    movie.with_suffix('.json').write_text(json.dumps(entry))
    manifest[name]=identifier
for index in range(int(os.environ.get('WIRECAMERA_MOTION_BACKLOG','0'))):
    identifier=str(uuid.uuid4()).upper()
    movie=root/'library'/(identifier+'.mov')
    movie.write_bytes((root/'library'/(manifest['legacy']+'.mov')).read_bytes())
    entry={'id':identifier,'sourceID':'offline:backlog','sourceName':'backlog-'+str(index),'startedAt':time.time()-7200-index*10-978307200,'duration':8,'events':[],'indexState':'ready'}
    movie.with_suffix('.json').write_text(json.dumps(entry))
(root/'manifest.json').write_text(json.dumps(manifest))
(root/'modules.json').write_text('[]')
PY
TEST_APP="$RUN_DIR/WireCamera Motion Test.app"
ditto "${1:-$PWD/WireCamera.app}" "$TEST_APP"
plutil -replace CFBundleIdentifier -string com.wirecamera.motion-e2e "$TEST_APP/Contents/Info.plist"
codesign --force --sign - "$TEST_APP" > "$RUN_DIR/sign.log" 2>&1
for pass_name in first restore; do
  python3 - "$RUN_DIR" <<'PYTIME'
import pathlib,sys,time
(pathlib.Path(sys.argv[1])/'launch-start.txt').write_text(str(time.time()))
PYTIME
  "$TEST_APP/Contents/MacOS/WireCamera" --library-e2e "$RUN_DIR" --motion-e2e --motion-pass "$pass_name" --remote-server-test "$RUN_DIR" --recordings-path "$RUN_DIR/library" --module-store-path "$RUN_DIR/modules.json" --disable-module-scan > "$RUN_DIR/$pass_name.log" 2>&1 &
  APP_PID=$!
  trap 'kill "$APP_PID" 2>/dev/null || true' EXIT
  for attempt in {1..60}; do
    if [[ -f "$RUN_DIR/$pass_name-result.json" ]]; then break; fi
    sleep 1
  done
  wait "$APP_PID"
done
python3 - "$RUN_DIR" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
results={name:json.loads((root/(name+'-result.json')).read_text()) for name in ['first','restore']}
assert all(result['passed'] for result in results.values()),results
(root/'report.json').write_text(json.dumps({'passed':True,'passes':results},ensure_ascii=False,indent=2))
print('Artifacts: '+str(root))
PY
