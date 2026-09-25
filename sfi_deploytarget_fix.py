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

The override line is placed AFTER the
`if [[ -n "${XCODEBUILD_CLONED_SOURCE_PACKAGES_DIR_PATH:-}" ]] ... fi` guard
(just before the `echo "Building ..."` line), so it always runs last and is never
overwritten by that guard's array assignment (`XCODEBUILD_FLAGS=(...)`).

Run from the cloned repo root (the `sfi` directory):
    python3 <this-script>.py
Idempotent.
"""

import io
import os
import sys

# Content inserted right before the "Building ..." echo, i.e. AFTER the
# `if [[ -n "${XCODEBUILD_CLONED_SOURCE_PACKAGES_DIR_PATH:-}" ]] ... fi` block,
# so it always appends and is never overwritten by that block's array assignment.
SNIPPET = (
    "# >>> SFI CI build fix: iOS 16 deployment target so SwiftUI prebuilt-module\n"
    "# ... buildIfToolbarContent availability checks pass on Xcode 26.x <<<\n"
    "XCODEBUILD_FLAGS+=(IPHONEOS_DEPLOYMENT_TARGET=16.0)\n"
)

# The exact marker we anchor on (and re-emit verbatim) so the file stays untouched elsewhere.
ANCHOR = 'echo "Building $PRODUCT_NAME (JAILBREAK, $BASE_PACKAGE_IDENTIFIER)"'

# Enough of the injected content to detect a prior apply (idempotency).
DETECT = "XCODEBUILD_FLAGS+=(IPHONEOS_DEPLOYMENT_TARGET=16.0)"


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

    # Idempotency: already applied -> no-op success.
    if DETECT in s:
        step_ok("package.sh already has the IPHONEOS_DEPLOYMENT_TARGET=16.0 override")
        return

    if ANCHOR not in s:
        fail("find flag init", f"'{ANCHOR}' not found in {p}")

    # Insert the override right before the "Building ..." echo, i.e. AFTER the
    # clonedSourcePackagesDirPath if/else guard, so it always executes last and is
    # never overwritten by that block's array assignment.
    new = s.replace(ANCHOR, SNIPPET + ANCHOR, 1)
    io.open(p, "w", encoding="utf-8").write(new)
    step_ok("package.sh override added (after the XCODEBUILD_FLAGS if/else guard)")
    step_ok("package.sh written")


if __name__ == "__main__":
    main()