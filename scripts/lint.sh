#!/bin/zsh
set -euo pipefail
setopt extendedglob
cd "${0:A:h:h}"
SWIFT_LINTER="${WIRECAMERA_SWIFTLINT:-$PWD/.build/tools/swiftlint/swiftlint}"
if [[ ! -x "$SWIFT_LINTER" ]]; then
  SWIFT_LINTER="$(command -v swiftlint || true)"
fi
if [[ -z "$SWIFT_LINTER" || ! -x "$SWIFT_LINTER" ]]; then
  printf '需要 SwiftLint；可通过 WIRECAMERA_SWIFTLINT 指定可执行文件。\n' >&2
  exit 1
fi
for source_file in ${(f)"$(rg --files Sources Tests scripts -g '*.swift' -g '*.sh')"}; do
  case "$source_file" in
    Sources/main.swift|Sources/[A-Z][A-Za-z0-9]##.swift|Tests/[A-Z][A-Za-z0-9]##.swift|Tests/[a-z][a-z0-9-]##.swift|scripts/[a-z][a-z0-9-]##.swift)
      ;;
    Tests/[a-z][a-z0-9-]##.sh|scripts/[a-z][a-z0-9-]##.sh)
      zsh -n "$source_file"
      if rg -n '^\s*#[^!]' "$source_file"; then
        printf 'Shell 文件不得包含注释：%s\n' "$source_file" >&2
        exit 1
      fi
      ;;
    *)
      printf '目录或文件命名不符合规则：%s\n' "$source_file" >&2
      exit 1
      ;;
  esac
done
export XCODE_DEFAULT_TOOLCHAIN_OVERRIDE="${XCODE_DEFAULT_TOOLCHAIN_OVERRIDE:-$(xcode-select -p)}"
"$SWIFT_LINTER" lint --strict --config .swiftlint.yml --no-cache
