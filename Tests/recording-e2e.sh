#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
APP_PATH="${1:-$PWD/WireCamera.app}"
RUN_DIR="$PWD/.build/recording-e2e/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
command -v ffprobe >/dev/null
command -v ffmpeg >/dev/null
open -n --stderr "$RUN_DIR/app.log" "$APP_PATH" --args --recording-e2e "$RUN_DIR"
for attempt in {1..320}; do
  if [[ -f "$RUN_DIR/app-result.json" ]]; then break; fi
  sleep 1
done
python3 - "$RUN_DIR" <<'PY'
import json, pathlib, subprocess, sys
directory = pathlib.Path(sys.argv[1])
application = json.loads((directory / 'app-result.json').read_text())
assert application['passed'], application
results = []
for name, expected_audio in [('silent.mov', False), ('sound.mov', True), ('quit.mov', True)]:
    movie = directory / name
    probe = subprocess.run(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(movie)], capture_output=True, text=True, check=True)
    metadata = json.loads(probe.stdout)
    (directory / (name + '.json')).write_text(probe.stdout)
    video = [track for track in metadata['streams'] if track['codec_type'] == 'video']
    audio = [track for track in metadata['streams'] if track['codec_type'] == 'audio']
    assert len(video) == 1 and video[0]['width'] > 0 and video[0]['height'] > 0, metadata
    assert bool(audio) == expected_audio, metadata
    assert float(metadata['format']['duration']) >= 1, metadata
    if expected_audio:
        assert len(audio) == 1 and audio[0]['channels'] >= 1, metadata
        assert int(audio[0]['sample_rate']) > 0, metadata
        assert float(audio[0]['duration']) >= 1, metadata
        assert abs(float(audio[0]['duration']) - float(video[0]['duration'])) < 1, metadata
    decoded = subprocess.run(['ffmpeg', '-v', 'error', '-xerror', '-i', str(movie), '-f', 'null', '-'], capture_output=True, text=True)
    (directory / (name + '.decode.log')).write_text(decoded.stderr)
    assert decoded.returncode == 0, decoded.stderr
    results.append({'file': name, 'videoCodec': video[0]['codec_name'], 'audioTracks': len(audio), 'audioCodec': audio[0]['codec_name'] if audio else None, 'audioSampleRate': int(audio[0]['sample_rate']) if audio else None, 'seconds': float(metadata['format']['duration']), 'fullyDecoded': True})
report = {'passed': True, 'application': application, 'recordings': results}
(directory / 'report.json').write_text(json.dumps(report, indent=2, ensure_ascii=False))
print(json.dumps(report, indent=2, ensure_ascii=False))
print('Artifacts: ' + str(directory))
PY
