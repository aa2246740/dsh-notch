#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work="$base/.build/glass-preview"
mkdir -p "$work/Sources"
cp -R "$base/Sources/Resources" "$work/Sources/"
cp "$base/Package.swift" "$work/Package.swift"
for file in IdleRobot.swift NotchMarkdown.swift RootView.swift Panel.swift Client.swift StatusOrbit.swift; do
  cp "$base/Sources/$file" "$work/Sources/$file"
done
cp "$base/Tests/GlassPreview.swift" "$work/Sources/main.swift"
swift build --package-path "$work" -c release
python3 - "$work" <<'PY'
from pathlib import Path
import plistlib,shutil,sys
work=Path(sys.argv[1]);app=work/'Notch Glass Preview.app/Contents'
(app/'MacOS').mkdir(parents=True,exist_ok=True)
(app/'Resources').mkdir(exist_ok=True)
shutil.copy2(work/'.build/release/dsh-notch',app/'MacOS/NotchGlassPreview')
for bundle in (work/'.build/release').glob('*.bundle'):
    shutil.copytree(bundle,app/'Resources'/bundle.name,dirs_exist_ok=True)
(app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.dsh.notch.glass-preview','CFBundleName':'Notch Glass Preview','CFBundleExecutable':'NotchGlassPreview','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.3.1','CFBundleVersion':'1','NSHighResolutionCapable':True,'LSMinimumSystemVersion':'14.0'}))
print(app.parent)
PY
