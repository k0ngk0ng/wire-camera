#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
RUN_DIR="$PWD/.build/settings-e2e/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR/library" "$RUN_DIR/remote"
python3 - "$RUN_DIR" <<'PY'
import json,pathlib,secrets,socket,stat,struct,subprocess,sys,time,uuid
root=pathlib.Path(sys.argv[1])
now=int(time.time())
cutoff=now-7*86400
with socket.socket() as endpoint:
    endpoint.bind(('127.0.0.1',0))
    port=endpoint.getsockname()[1]
(root/'remote/settings.json').write_text(json.dumps({'enabled':False,'port':port,'password':secrets.token_urlsafe(24),'identityPassword':secrets.token_urlsafe(24)}))
(root/'modules.json').write_text('[]')
base=root/'base.mov'
subprocess.run(['ffmpeg','-v','error','-loop','1','-i','Tests/Fixtures/person-frame.jpg','-f','lavfi','-i','sine=frequency=500:sample_rate=8000','-t','3','-r','5','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac',str(base)],check=True)
movies={}
offsets={'old':cutoff-4,'exact':cutoff-3,'cross':cutoff-2,'recent':now-3600,'future':now+86400,'playing':cutoff-86400,'downloading':cutoff-86400,'leased':cutoff-86400,'indexing':cutoff-86400,'locked':cutoff-86400,'symlink':cutoff-86400}
for name,started in offsets.items():
    identifier=str(uuid.uuid4()).upper()
    movie=root/'library'/(identifier+'.mov')
    movie.write_bytes(base.read_bytes())
    duration=3
    if name=='indexing':
        movie.unlink()
        subprocess.run(['ffmpeg','-v','error','-stream_loop','19','-i',str(base),'-t','60','-c','copy',str(movie)],check=True)
        duration=60
    if name=='downloading':
        with movie.open('ab') as output:
            output.write(struct.pack('>I4s',32*1024*1024+8,b'free'))
            output.write(bytes(32*1024*1024))
    if name=='locked':
        import os
        os.chflags(movie,stat.UF_IMMUTABLE)
    if name=='symlink':
        outside=root/'outside.mov'
        outside.write_bytes(movie.read_bytes())
        movie.unlink()
        movie.symlink_to(outside)
    entry={'id':identifier,'sourceID':'wifi:settings-fixture','sourceName':'Wi-Fi 摄像头','startedAt':started-978307200,'duration':duration,'events':[{'start':0,'end':2}],'indexState':'ready'}
    movie.with_suffix('.json').write_text(json.dumps(entry))
    movies[name]=identifier
orphan=str(uuid.uuid4()).upper()
entry.update(id=orphan,startedAt=cutoff-86400-978307200)
(root/'library'/(orphan+'.json')).write_text(json.dumps(entry))
movies['orphan']=orphan
(root/'library/.active.partial.mov').write_bytes(base.read_bytes())
(root/'library/notes.json').write_text('{"note":"preserve"}')
(root/'manifest.json').write_text(json.dumps({'now':now,'movies':movies,'outsideBytes':base.stat().st_size}))
PY
TEST_APP="$RUN_DIR/WireCamera Settings Test.app"
ditto "${1:-$PWD/WireCamera.app}" "$TEST_APP"
plutil -replace CFBundleIdentifier -string com.wirecamera.settings-e2e "$TEST_APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "WireCamera Settings Test" "$TEST_APP/Contents/Info.plist"
codesign --force --sign - "$TEST_APP" > "$RUN_DIR/sign.log" 2>&1
APP_PID=0
trap 'if (( APP_PID > 0 )); then kill "$APP_PID" 2>/dev/null || true; fi; chflags -R nouchg "$RUN_DIR/library" 2>/dev/null || true' EXIT
for pass_name in first restore; do
  "$TEST_APP/Contents/MacOS/WireCamera" --settings-e2e "$RUN_DIR" --settings-pass "$pass_name" --recordings-path "$RUN_DIR/library" --module-store-path "$RUN_DIR/modules.json" --disable-module-scan > "$RUN_DIR/$pass_name.log" 2>&1 &
  APP_PID=$!
  python3 Tests/settings-client-e2e.py "$RUN_DIR" "$pass_name"
  wait "$APP_PID"
  APP_PID=0
done
python3 - "$RUN_DIR" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
reports={name:json.loads((root/(name+'-result.json')).read_text()) for name in ['first','restore']}
assert all(value['passed'] for value in reports.values()),reports
(root/'report.json').write_text(json.dumps({'passed':True,'passes':reports},ensure_ascii=False,indent=2))
print('Artifacts: '+str(root))
PY
