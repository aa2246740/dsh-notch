#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
swift build --package-path "$repo/macos" -c release
python3 - "$repo" <<'PY'
from pathlib import Path
import plistlib,shutil,sys
repo=Path(sys.argv[1]);app=repo/'dist/DSH Notch Elastic Preview.app/Contents'
(app/'MacOS').mkdir(parents=True,exist_ok=True);(app/'Resources').mkdir(exist_ok=True)
binary=app/'MacOS/NotchElasticPreview'
staged=binary.with_suffix('.next')
shutil.copy2(repo/'macos/.build/release/dsh-notch',staged)
staged.replace(binary)
for bundle in (repo/'macos/.build/release').glob('*.bundle'):
    shutil.copytree(bundle,app/'Resources'/bundle.name,dirs_exist_ok=True)
(app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.dsh.notch.elastic-preview','CFBundleName':'Notch Elastic Preview','CFBundleExecutable':'NotchElasticPreview','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.3.0','CFBundleVersion':'1','NSHighResolutionCapable':True,'LSMinimumSystemVersion':'14.0'}))
print(app.parent)
PY
