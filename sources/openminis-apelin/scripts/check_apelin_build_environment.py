#!/usr/bin/env python3
"""Read-only build prerequisite audit; never downloads, installs or packages."""
from pathlib import Path
import json
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
requirements = ['swiftc', 'xcodebuild', 'xcrun', 'make', 'ninja', 'go']
artifacts = ['deps/libs/libish.a', 'deps/libs/libish_emu.a',
             'deps/libs/libfakefs.a', 'deps/include',
             'deps/frameworks/Rclone.xcframework', 'deps/resources/alpine-rootfs.zip',
             'deps/lame-build/lib/libmp3lame.a']
report = {
    'commands': {name: shutil.which(name) is not None for name in requirements},
    'nativeArtifacts': {name: (root / name).exists() for name in artifacts},
    'ishSubmoduleInitialized': (root / 'deps/ish/.git').exists(),
    'minimumSwiftForFullApelinAgent': '6.1',
    'minimumHostDeployment': '16.0',
    'upstreamWidgetDeployment': '16.2',
    'currentIntegration': 'read-only host tools; independent native package in source, iOS launcher unsupported',
}
# Do not print environment paths: a resolved roothide root is temporary.
if report['commands']['swiftc']:
    result = subprocess.run(['swiftc', '--version'], capture_output=True, text=True)
    report['swiftVersion'] = result.stdout.splitlines()[:1]
report['readyForFullBuild'] = all(report['commands'].values()) and all(report['nativeArtifacts'].values()) and report['ishSubmoduleInitialized']
print(json.dumps(report, indent=2))
sys.exit(0 if report['readyForFullBuild'] else 2)
