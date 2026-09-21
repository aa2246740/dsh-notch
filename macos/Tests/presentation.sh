#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/notch-presentation.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/Sources"
cp -R "$base/Sources/Resources" "$work/Sources/Resources"
cp "$base/Package.swift" "$work/Package.swift"
for name in IdleRobot NotchMarkdown RootView Panel Client StatusOrbit; do
  cp "$base/Sources/$name.swift" "$work/Sources/"
done
cp "$base/Tests/PresentationProbe.swift" "$work/Sources/main.swift"
swift build --package-path "$work" -c release
"$work/.build/release/dsh-notch"
