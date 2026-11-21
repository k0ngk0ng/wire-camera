#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
RUN_DIR="$PWD/.build/record-preview-e2e/$(date +%Y%m%d-%H%M%S)"
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
mkdir -p "$RUN_DIR" "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"
INTERFACE_NAME="$(route -n get default | awk '$1 == "interface:" {print $2}')"
FIXTURE_ADDRESS="$(ipconfig getifaddr "$INTERFACE_NAME")"
xcrun swiftc -swift-version 5 -module-cache-path "$CLANG_MODULE_CACHE_PATH" -framework CoreMedia -framework VideoToolbox \
  Sources/CameraModuleProtocol.swift Sources/CameraModuleNetwork.swift Sources/CameraModuleVideoSampler.swift Sources/CameraModuleAudioSampler.swift Tests/CameraModuleManualFixture.swift -o "$RUN_DIR/fixture"
"$RUN_DIR/fixture" "$FIXTURE_ADDRESS" "$RUN_DIR" "$PWD/Tests/Fixtures/person-frame.jpg" --audio --multi-camera > "$RUN_DIR/fixture.log" 2>&1 &
FIXTURE_PID=$!
trap 'kill "$FIXTURE_PID" 2>/dev/null || true' EXIT
python3 - "$RUN_DIR/modules.json" "$FIXTURE_ADDRESS" <<'PY'
import json,pathlib,sys
pathlib.Path(sys.argv[1]).write_text(json.dumps([{'deviceID':name,'address':sys.argv[2]} for name in ['fixture-manual-device','fixture-preview-device']]))
PY
for attempt in {1..10}; do
  if [[ -f "$RUN_DIR/ready" ]]; then break; fi
  sleep 1
done
open -n --stderr "$RUN_DIR/app.log" "${1:-$PWD/WireCamera.app}" --args --library-e2e "$RUN_DIR" --record-preview-e2e --fixture-address "$FIXTURE_ADDRESS" --module-store-path "$RUN_DIR/modules.json" --recordings-path "$RUN_DIR/library" --disable-module-scan
for attempt in {1..60}; do
  if [[ -f "$RUN_DIR/app-result.json" ]]; then break; fi
  sleep 1
done
python3 - "$RUN_DIR" <<'PY'
import array,json,math,pathlib,subprocess,sys
directory=pathlib.Path(sys.argv[1])
report=json.loads((directory/'app-result.json').read_text())
assert report['passed'],report
movies=list((directory/'library').glob('*.mov'))
assert len(movies)>=2,movies
reference=subprocess.run(['ffmpeg','-v','error','-i','Tests/Fixtures/person-frame.jpg','-vf','scale=16:16','-pix_fmt','rgb24','-f','rawvideo','-'],capture_output=True,check=True).stdout
for movie in movies:
    probe=subprocess.run(['ffprobe','-v','error','-show_streams','-of','json',str(movie)],capture_output=True,text=True,check=True)
    metadata=json.loads(probe.stdout)
    movie.with_suffix('.tracks.json').write_text(probe.stdout)
    video=next(track for track in metadata['streams'] if track['codec_type']=='video')
    assert (video['width'],video['height'])==(512,512),metadata
    assert any(track['codec_type']=='audio' for track in metadata['streams']),metadata
    decoded=subprocess.run(['ffmpeg','-v','error','-xerror','-i',str(movie),'-map','0:v:0','-vf','scale=16:16','-pix_fmt','rgb24','-f','rawvideo','-'],capture_output=True,check=True)
    pixels=decoded.stdout
    assert pixels and len(pixels)%len(reference)==0,movie.name
    distances=[sum(abs(left-right) for left,right in zip(pixels[offset:offset+len(reference)],reference))/len(reference) for offset in range(0,len(pixels),len(reference))]
    assert max(distances)<25,{'file':movie.name,'wrongCameraFrameDistance':max(distances)}
    audio=subprocess.run(['ffmpeg','-v','error','-xerror','-i',str(movie),'-map','0:a:0','-ac','1','-ar','8000','-f','s16le','-'],capture_output=True,check=True)
    movie.with_suffix('.decode.log').write_bytes(decoded.stderr+audio.stderr)
    pcm=audio.stdout
    samples=array.array('h',pcm)
    if sys.byteorder!='little':samples.byteswap()
    def power(frequency):
        return sum(sample*math.cos(2*math.pi*frequency*index/8000) for index,sample in enumerate(samples))**2+sum(sample*math.sin(2*math.pi*frequency*index/8000) for index,sample in enumerate(samples))**2
    assert power(500)>power(1000)*2,{'file':movie.name,'recordedCameraAudioLost':True}
report['recordedCameraDimensionsVerified']=True
report['recordedCameraPixelsVerified']=True
report['recordedCameraAudioVerified']=True
(directory/'report.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
print('Artifacts: '+str(directory))
PY
