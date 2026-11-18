#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
RUN_DIR="$PWD/.build/password-field-e2e/$(date +%Y%m%d-%H%M%S)"
APP="$PWD/.build/password-field-e2e/PasswordFieldCheck.app"
mkdir -p "$RUN_DIR" "$APP/Contents/MacOS" "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$CLANG_MODULE_CACHE_PATH" -framework AppKit Sources/WiFiPasswordField.swift Tests/password-field-check.swift -o "$APP/Contents/MacOS/PasswordFieldCheck"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>PasswordFieldCheck</string><key>CFBundleIdentifier</key><string>com.wirecamera.passwordcheck</string><key>CFBundleName</key><string>WireCamera Password Check</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
codesign --force --sign - --identifier com.wirecamera.passwordcheck "$APP"
open -n --stderr "$RUN_DIR/app.log" "$APP" --args "$RUN_DIR" --automated
for attempt in {1..30}; do
  if [[ -f "$RUN_DIR/report.json" ]]; then break; fi
  sleep 1
done
python3 - "$RUN_DIR" <<'PY'
import json,pathlib,sys
path=pathlib.Path(sys.argv[1])/'report.json'
report=json.loads(path.read_text())
assert report['passed'],report
print(json.dumps(report,ensure_ascii=False,indent=2))
print('Artifacts: '+str(path.parent))
PY
