#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/notch-algorithm.XXXXXX")
trap 'rm -rf "$work"' EXIT
python3 - "$base" "$work" "${1:-}" <<'PY'
from pathlib import Path
import subprocess,sys
root,work,ref=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3]
def source(name):
    path='macos/Sources/'+name+'.swift'
    return subprocess.check_output(['git','show',ref+':'+path],cwd=root,text=True) if ref else (root/path).read_text()
edge,panel=source('EdgeDock'),source('Panel')
physics=edge[edge.index('struct EdgeDockPose:'):edge.index('@MainActor\nfinal class EdgeDockModel')]
geometry=edge[edge.index('struct EdgeDockGeometry {'):edge.index('struct EdgeDockSurface<')]
frame=panel[panel.index('struct NotchElasticFrame {'):panel.index('enum NotchMaterial')]
(work/'Core.swift').write_text('import AppKit\nimport SwiftUI\n'+frame+physics+geometry)
(work/'cached').write_text('1' if 'final class EdgeDockContourCache' in edge else '0')
PY
if [ "$(cat "$work/cached")" = 1 ]; then
  swiftc -O -parse-as-library -D CACHED_CONTOUR "$work/Core.swift" "$base/macos/Tests/EdgeAlgorithmBench.swift" -o "$work/bench"
else
  swiftc -O -parse-as-library "$work/Core.swift" "$base/macos/Tests/EdgeAlgorithmBench.swift" -o "$work/bench"
fi
"$work/bench"
