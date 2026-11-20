#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
RUN_DIR="$PWD/.build/library-e2e/$(date +%Y%m%d-%H%M%S)"
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
mkdir -p "$RUN_DIR" "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"
command -v ffprobe >/dev/null
command -v ffmpeg >/dev/null
xcrun swiftc -swift-version 5 -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -framework CoreMedia -framework VideoToolbox \
  Sources/CameraModuleProtocol.swift Sources/CameraModuleNetwork.swift Sources/CameraModuleVideoSampler.swift Sources/CameraModuleAudioSampler.swift Tests/CameraModuleManualFixture.swift \
  -o "$RUN_DIR/fixture"
INTERFACE_NAME="$(route -n get default | awk '$1 == "interface:" {print $2}')"
FIXTURE_ADDRESS="$(ipconfig getifaddr "$INTERFACE_NAME")"
SCENE="${WIRECAMERA_E2E_SCENE:-person}"
SCENE_ARGUMENTS=()
SCENE_FRAME="$PWD/Tests/Fixtures/person-frame.jpg"
if [[ "$SCENE" == empty ]]; then
  SCENE_FRAME="$PWD/Tests/Fixtures/module-jpeg-frame.jpg"
  SCENE_ARGUMENTS+=(--expect-no-people)
fi
"$RUN_DIR/fixture" "$FIXTURE_ADDRESS" "$RUN_DIR" "$SCENE_FRAME" --audio > "$RUN_DIR/fixture.log" 2>&1 &
FIXTURE_PID=$!
trap 'kill "$FIXTURE_PID" 2>/dev/null || true' EXIT
for attempt in {1..10}; do
  if [[ -f "$RUN_DIR/ready" ]]; then break; fi
  sleep 1
done
[[ -f "$RUN_DIR/ready" ]]
for pass_name in record restore; do
  open -n --stderr "$RUN_DIR/$pass_name.log" "${1:-$PWD/WireCamera.app}" --args --library-e2e "$RUN_DIR" --fixture-address "$FIXTURE_ADDRESS" --library-pass "$pass_name" --recordings-path "$RUN_DIR/library" --module-store-path "$RUN_DIR/modules.json" --disable-module-scan "${SCENE_ARGUMENTS[@]}"
  for attempt in {1..150}; do
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
    assert len([x for x in metadata['streams'] if x['codec_type']=='video'])==1,metadata
    assert len([x for x in metadata['streams'] if x['codec_type']=='audio'])==1,metadata
    assert float(metadata['format']['duration'])>=1,metadata
    video=next(x for x in metadata['streams'] if x['codec_type']=='video')
    audio=next(x for x in metadata['streams'] if x['codec_type']=='audio')
    assert abs(float(video['duration'])-float(audio['duration']))<1,metadata
    decoded=subprocess.run(['ffmpeg','-v','error','-xerror','-i',str(movie),'-f','null','-'],capture_output=True,text=True)
    movie.with_suffix('.decode.log').write_text(decoded.stderr)
    assert decoded.returncode==0,decoded.stderr
    recordings.append({'file':movie.name,'audio':True,'fullyDecoded':True})
report={'passed':True,'scope':'synthetic_wifi_module','recordings':recordings,'record':json.loads((directory/'record-result.json').read_text()),'restore':json.loads((directory/'restore-result.json').read_text())}
(directory/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps(report,ensure_ascii=False,indent=2))
print('Artifacts: '+str(directory))
PY
