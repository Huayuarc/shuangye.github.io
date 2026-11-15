#!/usr/bin/env python3
"""Compile the production policy plus its truth table; never emulate it in Python."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
compiler = shutil.which("swiftc")
if not compiler:
    print("NOT RUN: swiftc is unavailable; no Swift policy execution was performed.")
    sys.exit(2)
source = (root / "src/ios/Agent/Chat/MinisApelinTools.swift").read_text()
start = source.index("enum MinisDevelopmentPolicy {")
end = source.index("\n/// Local-only state for future native dispatch.", start)
policy = source[start:end]
# Only the error type used by the exact production policy needs a standalone shim.
shim = '''import Foundation
enum MinisApelinTools {
    enum ToolError: Error { case invalidArgument(String) }
}
'''
tests = r'''
func check(_ operation: MinisDevelopmentPolicy.Operation,
           _ expected: [MinisDevelopmentPolicy.Verdict], screen: Bool = false,
           outside: Bool = false) {
    for (index, mode) in MinisDevelopmentPolicy.Mode.allCases.enumerated() {
        precondition(MinisDevelopmentPolicy.evaluate(operation, mode: mode,
            asksBeforeScreen: screen, outsideProject: outside) == expected[index])
    }
}
check(.integrationRead, [.allow, .allow, .allow])
check(.integrationRead, [.deny, .deny, .deny], outside: true)
check(.unsupported, [.deny, .deny, .deny])
check(.forcePush, [.ask, .ask, .ask])
check(.resetToRemote, [.ask, .ask, .ask])
check(.screenRead, [.allow, .allow, .allow])
check(.screenRead, [.ask, .ask, .ask], screen: true)
check(.screenAction, [.ask, .allow, .allow])
check(.screenAction, [.ask, .ask, .ask], screen: true)
check(.nativeCommand(root: true, presetArgv: true, usesScreen: false), [.ask, .ask, .allow])
check(.nativeCommand(root: false, presetArgv: true, usesScreen: false), [.allow, .allow, .allow])
check(.nativeCommand(root: false, presetArgv: false, usesScreen: false), [.ask, .allow, .allow])
check(.nativeCommand(root: true, presetArgv: true, usesScreen: true), [.ask, .ask, .ask], screen: true)
check(.nativeCommand(root: true, presetArgv: true, usesScreen: true), [.deny, .deny, .deny], screen: true, outside: true)
for name in ["apelin_skill_list", "apelin_skill_read", "apelin_host_environment", "apelin_integration_status"] {
    try MinisDevelopmentPolicy.authorizeIntegrationRead(name: name)
}
var refused = false
do { try MinisDevelopmentPolicy.authorizeIntegrationRead(name: "apelin_shell_run") }
catch { refused = true }
precondition(refused)
print("PASS: production Swift policy truth table (42 verdicts and exact tool whitelist)")
'''
with tempfile.TemporaryDirectory(prefix="minis-policy-") as directory:
    work = Path(directory)
    main = work / "main.swift"
    binary = work / "policy-check"
    main.write_text(shim + policy + tests)
    subprocess.run([compiler, "main.swift", "-o", "policy-check"], cwd=work, check=True)
    # A prepared iOS runner must supply the reviewed Tool.entitlements template.
    # Refuse to launch rather than guessing that unsigned execution is supported.
    if sys.platform == "darwin" and Path("/System/Library/CoreServices/SystemVersion.plist").exists():
        import plistlib
        version = plistlib.loads(Path("/System/Library/CoreServices/SystemVersion.plist").read_bytes())
        if version.get("ProductName") in ("iPhone OS", "iOS", "iPadOS"):
            signer = shutil.which("ldid")
            if not signer:
                print("NOT RUN: iOS signing tool ldid is unavailable.")
                sys.exit(2)
            import os
            template = os.environ.get("MINIS_POLICY_ENTITLEMENTS")
            if not template or not Path(template).is_file():
                print("NOT RUN: set MINIS_POLICY_ENTITLEMENTS to the reviewed Tool.entitlements file.")
                sys.exit(2)
            shutil.copyfile(template, work / "Tool.entitlements")
            subprocess.run([signer, "-STool.entitlements", "policy-check"], cwd=work, check=True)
    subprocess.run(["./policy-check"], cwd=work, check=True)
