#!/usr/bin/env python3
"""
SFI jailbreak app build fix: raise the SFI app deployment target to iOS 16.0.

WHY
===
The SFI dev branch (1.15.0-alpha.8) declares IPHONEOS_DEPLOYMENT_TARGET = 15.0 for the
SFI app target, but MainView.swift now uses a SwiftUI .toolbar result-builder conditional
(`if environments.remoteServer != nil ... { ... }` with a nested `if #available(iOS 26.0,*)`)
that requires ToolbarContentBuilder.buildIf, which is only available on iOS 16+.

Under the CI's Xcode 26.6 those availability checks are hard compile errors
(`'buildIf' is only available in iOS 16.0 or newer`), so `CompileSwift normal arm64
(target 'SFI')` fails and the job exits 65 before any .deb is produced.

FIX
===
Append the build-setting override IPHONEOS_DEPLOYMENT_TARGET=16.0 to the xcodebuild
invocation inside Jailbreak/package.sh (the `build()` function that builds scheme SFI).
This is a pure build-time override: no source files change, and the generated app is
right for jailbroken iOS 16+ devices. The daemon (JailbreakDaemon) is a plain CLI
without SwiftUI, so it is unaffected.

Run from the cloned repo root (the `sfi` directory):
    python3 <this-script>.py
Idempotent.
"""

import io
import os
import re
import sys

MARKER_START = "XCODEBUILD_FLAGS=()"
MARKER_ANCHOR = "\tXCODEBUILD_FLAGS=(-clonedSourcePackagesDirPath \"$XCODEBUILD_CLONED_SOURCE_PACKAGES_DIR_PATH\")"
OVERRIDE_LINE = "\tXCODEBUILD_FLAGS+=(IPHONEOS_DEPLOYMENT_TARGET=16.0)"

HEADER = """# >>> SFI CI build fix: iOS 16 deployment target so SwiftUI prebuilt-module
# ... buildIfToolbarContent availability checks pass on Xcode 26.x <<<
{X}""".format(X=OVERRIDE_LINE)


def step_ok(label):
    print(f"  [ok] {label}")


def fail(label, detail):
    print(f"  FAIL {label}: {detail}")
    sys.exit(1)


def main():
    p = "Jailbreak/package.sh"
    if not os.path.exists(p):
        fail("find package.sh", f"{p} not found (run from repo root?)")

    s = io.open(p, encoding="utf-8").read()

    # Idempotency: if we already injected, no-op success.
    if OVERRIDE_LINE in s:
        step_ok("package.sh already has IPHONEOS_DEPLOYMENT_TARGET=16.0 override")
        return

    # Insert the override right after the XCODEBUILD_FLAGS=() init, alongside the
    # clonedSourcePackagesDirPath mutation. Applies to every xcodebuild in this script
    # (SFI app build + JailbreakDaemon build). For the daemon it is harmless.
    if MARKER_START not in s:
        fail("find flag init", f"'{MARKER_START}' not found in {p}")
    if MARKER_ANCHOR in s:
        new = s.replace(MARKER_ANCHOR, MARKER_ANCHOR + "\n" + HEADER, 1)
        step_ok("package.sh override added (after clonedSourcePackagesDirPath init)")
    else:
        # fallback: insert right after the XCODEBUILD_FLAGS=() line itself
        new = s.replace(MARKER_START, MARKER_START + "\n" + HEADER, 1)
        step_ok("package.sh override added (after XCODEBUILD_FLAGS=() init)")

    io.open(p, "w", encoding="utf-8").write(new)
    step_ok("package.sh written")


if __name__ == "__main__":
    main()