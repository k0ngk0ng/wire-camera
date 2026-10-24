#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
APP_PATH="${1:-$PWD/WireCamera.app}"
if pgrep -f '/WireCamera.app/Contents/MacOS/WireCamera' >/dev/null; then
  printf '请先退出所有 WireCamera 实例，再运行画面比例测试。\n' >&2
  exit 1
fi
RUN_DIR="$PWD/.build/picture-mode-e2e/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
command -v ffprobe >/dev/null
command -v ffmpeg >/dev/null
open -n --stderr "$RUN_DIR/app.log" "$APP_PATH" --args --picture-mode-e2e "$RUN_DIR"
for attempt in {1..180}; do
  if [[ -f "$RUN_DIR/app-result.json" ]]; then break; fi
  sleep 1
done
python3 - "$RUN_DIR" <<'PY'
import json, pathlib, subprocess, sys
from fractions import Fraction
directory = pathlib.Path(sys.argv[1])
application = json.loads((directory / 'app-result.json').read_text())
assert application['passed'], application
recordings = []
for name, width, height in [('standard.mov', 1280, 960), ('wide.mov', 1280, 720), ('standard-again.mov', 1280, 960)]:
    path = directory / name
    result = subprocess.run(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(path)], capture_output=True, text=True, check=True)
    metadata = json.loads(result.stdout)
    (directory / (name + '.json')).write_text(result.stdout)
    video = [track for track in metadata['streams'] if track['codec_type'] == 'video']
    audio = [track for track in metadata['streams'] if track['codec_type'] == 'audio']
    assert len(video) == 1 and (video[0]['width'], video[0]['height']) == (width, height), metadata
    pixel_aspect = Fraction(video[0].get('sample_aspect_ratio', '1:1').replace(':', '/'))
    display_aspect = Fraction(width, height) * pixel_aspect
    assert pixel_aspect == 1 and display_aspect == (Fraction(16, 9) if height == 720 else Fraction(4, 3)), metadata
    if video[0].get('display_aspect_ratio'):
        assert Fraction(video[0]['display_aspect_ratio'].replace(':', '/')) == display_aspect, metadata
    assert len(audio) == 1, metadata
    assert float(metadata['format']['duration']) >= 1, metadata
    decoded = subprocess.run(['ffmpeg', '-v', 'error', '-xerror', '-i', str(path), '-f', 'null', '-'], capture_output=True, text=True)
    (directory / (name + '.decode.log')).write_text(decoded.stderr)
    assert decoded.returncode == 0, decoded.stderr
    recordings.append({'file': name, 'width': width, 'height': height, 'audioTracks': len(audio), 'fullyDecoded': True})
report = {'passed': True, 'application': application, 'recordings': recordings}
(directory / 'report.json').write_text(json.dumps(report, indent=2, ensure_ascii=False))
print(json.dumps(report, indent=2, ensure_ascii=False))
print('Artifacts: ' + str(directory))
PY
