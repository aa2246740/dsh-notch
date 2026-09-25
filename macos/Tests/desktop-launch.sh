#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/notch-desktop-launch.XXXXXX")
trap 'rm -rf "$work"' EXIT
cp "$base/Package.swift" "$work/Package.swift"
cp -R "$base/Sources" "$work/Sources"
if [ "$#" -gt 0 ]; then
  git -C "$base/.." show "$1:macos/Sources/main.swift" > "$work/Sources/main.swift"
fi
python3 - "$work/Sources/main.swift" "$base/Tests/DesktopLaunchProbe.swift" <<'PY'
from pathlib import Path
import sys
main=Path(sys.argv[1]); source=main.read_text()
delegate=source[source.index('@MainActor\nfinal class AppDelegate'):]
main.write_text('import AppKit\nimport Combine\nimport SwiftUI\n'+delegate+'\n'+Path(sys.argv[2]).read_text())
PY
swift build --package-path "$work" -c release
"$work/.build/release/dsh-notch"
