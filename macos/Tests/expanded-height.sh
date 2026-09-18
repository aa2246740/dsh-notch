#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work="$base/.build/expanded-height-probe"
mkdir -p "$work/Sources"
cp -R "$base/Sources/Resources" "$work/Sources/"
cp "$base/Package.swift" "$work/Package.swift"
for file in IdleRobot.swift NotchMarkdown.swift RootView.swift Panel.swift Client.swift StatusOrbit.swift; do
  cp "$base/Sources/$file" "$work/Sources/$file"
done
cp "$base/Tests/ExpandedHeightProbe.swift" "$work/Sources/main.swift"
swift build --package-path "$work" -c release
"$work/.build/release/dsh-notch"
