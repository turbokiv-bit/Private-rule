#!/usr/bin/env python3
"""
SFI jailbreak app build fix: raise ONLY the SFI app target's deployment target to iOS 16.0.

WHY
===
The SFI dev branch (1.15.0-alpha.8) declares IPHONEOS_DEPLOYMENT_TARGET = 15.0 for the
SFI app target, but SFI/MainView.swift uses a SwiftUI .toolbar result-builder conditional
that requires ToolbarContentBuilder.buildIf (iOS 16+). Under Xcode 26.6 that is a hard
compile error (`'buildIf' is only available in iOS 16.0 or newer`).

A GLOBAL IPHONEOS_DEPLOYMENT_TARGET=16.0 override would break other targets that need
a HIGHER minimum (e.g. WidgetExtension needs iOS 18.0 for its Control Widget APIs).
So we must raise ONLY the SFI app target, leaving every other target at its own value.

HOW
===
Edit sing-box.xcodeproj/project.pbxproj: within the SFI target's Debug and Release build
configuration blocks only, change IPHONEOS_DEPLOYMENT_TARGET = 15.0 -> 16.0.

The SFI target's config ids are stable and unique (3AEC20FF Debug, 3AEC2100 Release),
looked up from the target's buildConfigurationList (3AEC20FE).

Run from the cloned repo root (the `sfi` directory):
    python3 <this-script>.py
Idempotent (no-op if 15.0 already replaced, or if already 16.0 for the SFI target).
"""

import io
import os
import re
import sys

PBX = "sing-box.xcodeproj/project.pbxproj"

# SFI target buildConfigurationList (from project.pbxproj).
SFI_CONFIG_LIST = "3AEC20FE2A459AB500A63465"
# Expected config ids under that list (Debug, Release) -> ids of their build config blocks.
# Resolved from the XCConfigurationList block.
CONFIG_NAME_TO_VERIFY = ("Debug", "Release")


def step_ok(label):
    print(f"  [ok] {label}")


def fail(label, detail):
    print(f"  FAIL {label}: {detail}")
    sys.exit(1)


def main():
    if not os.path.exists(PBX):
        fail("find project", f"{PBX} not found (run from repo root?)")

    lines = io.open(PBX, encoding="utf-8").read().splitlines()

    # 1) find the build config IDs for the SFI target's Debug/Release
    config_ids = {}
    for i, l in enumerate(lines):
        if SFI_CONFIG_LIST in l and "= {" in l:
            blk = lines[i:i + 12]
            for m in re.finditer(r"([0-9A-F]{24}) /\* (Debug|Release) \*/", "\n".join(blk)):
                config_ids.setdefault(m.group(2), []).append(m.group(1))
            break
    dbg = config_ids.get("Debug", [])[:1]
    rel = config_ids.get("Release", [])[:1]
    ids = (dbg + rel)
    if not ids:
        fail("resolve config ids", f"could not find Debug/Release configs under {SFI_CONFIG_LIST}")
    step_ok(f"SFI target config ids: Debug={dbg[0] if dbg else '-'}, Release={rel[0] if rel else '-'}")

    # 2) Within each of those config blocks only, bump 15.0 -> 16.0
    target_lines = []
    for cid in ids:
        start = next((j for j, l in enumerate(lines) if l.strip().startswith(cid)), None)
        if start is None:
            continue
        depth = 0
        for j in range(start, len(lines)):
            depth += lines[j].count("{") - lines[j].count("}")
            if depth <= 0 and lines[j].strip().startswith("};"):
                end = j + 1
                break
        target_lines.append((start, end, cid))

    changed = 0
    for start, end, cid in target_lines:
        for j in range(start, end):
            stripped = lines[j].lstrip()
            if stripped.startswith("IPHONEOS_DEPLOYMENT_TARGET") and "15.0" in stripped:
                lines[j] = lines[j].replace("15.0", "16.0")
                changed += 1
                step_ok(f"config {cid}: IPHONEOS_DEPLOYMENT_TARGET 15.0 -> 16.0")

    if changed == 0:
        # Could be already fixed, or targets not exactly 15.0. Report either way.
        step_ok("no SFI 15.0 deployment targets to change (already 16+ or not found)")

    io.open(PBX, "w", encoding="utf-8").write("\n".join(lines))
    step_ok(f"pbxproj written ({changed} change(s))")


if __name__ == "__main__":
    main()