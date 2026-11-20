#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
: "${WIRECAMERA_MODULE_DEVICE_ID:?请设置实机设备 ID}"
: "${WIRECAMERA_MODULE_ADDRESS:?请设置实机 IP}"
RUN_DIR="$PWD/.build/wifi-recording-e2e/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
for pass_name in record restore; do
  open -n --stderr "$RUN_DIR/$pass_name.log" "${1:-$PWD/WireCamera.app}" --args --library-e2e "$RUN_DIR" --library-pass "$pass_name" --fixture-address "$WIRECAMERA_MODULE_ADDRESS" --library-device-id "$WIRECAMERA_MODULE_DEVICE_ID" --allow-any-scene --recordings-path "$RUN_DIR/library" --module-store-path "$RUN_DIR/modules.json" --disable-module-scan
  for attempt in {1..140}; do
    if [[ -f "$RUN_DIR/$pass_name-result.json" ]]; then break; fi
    sleep 1
  done
  python3 - "$RUN_DIR/$pass_name-result.json" <<'PY'
import json,pathlib,sys
report=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert report['passed'],report
PY
done
python3 - "$RUN_DIR" <<'PY'
import json,pathlib,subprocess,sys
directory=pathlib.Path(sys.argv[1])
movies=list((directory/'library').glob('*.mov'))
assert len(movies)>=2,movies
recordings=[]
for movie in movies:
    probe=subprocess.run(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(movie)],capture_output=True,text=True,check=True)
    metadata=json.loads(probe.stdout)
    movie.with_suffix('.probe.json').write_text(probe.stdout)
    video=next(x for x in metadata['streams'] if x['codec_type']=='video')
    audio=next(x for x in metadata['streams'] if x['codec_type']=='audio')
    assert abs(float(video['duration'])-float(audio['duration']))<1,metadata
    decoded=subprocess.run(['ffmpeg','-v','error','-xerror','-i',str(movie),'-f','null','-'],capture_output=True,text=True)
    movie.with_suffix('.decode.log').write_text(decoded.stderr)
    assert decoded.returncode==0,decoded.stderr
    recordings.append({'file':movie.name,'audio':True,'fullyDecoded':True})
report={'passed':True,'scope':'real_wifi_camera_direct','directNetworkVerified':True,'recordings':recordings,'record':json.loads((directory/'record-result.json').read_text()),'restore':json.loads((directory/'restore-result.json').read_text())}
(directory/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps(report,ensure_ascii=False,indent=2))
print('Artifacts: '+str(directory))
PY
