#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work="$base/.build/host-lifetime-probe"
mkdir -p "$work"
swiftc -swift-version 6 -parse-as-library "$base/Sources/HostLifetime.swift" "$base/Tests/HostLifetimeProbe.swift" -o "$work/probe"
"$work/probe"
