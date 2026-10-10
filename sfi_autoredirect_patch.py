#!/usr/bin/env python3
"""
sfi_autoredirect_patch.py -- fix "ExtensionPlatformInterface does not conform to
LibboxPlatformInterfaceProtocol" when building the SFI app against the reF1nd
sing-box core.

WHY
===
The app is compiled against a Libbox.xcframework generated from the reF1nd
sing-box core. reF1nd's experimental/libbox/platform.go adds ONE new required
method to the Go PlatformInterface that the official SagerNet core does not have:

    CreateAutoRedirectListener(inet6 bool) (int32, error)

gomobile generates this as a required Swift member
`createAutoRedirectListener(_ inet6: Bool, ret0_: UnsafeMutablePointer<Int32>?) throws`
in the `LibboxPlatformInterfaceProtocol` (priority out-param form, matching this
same class's `openTun(_:ret0_:)`, which is also gomobile-generated from a Go
`(int32, error)` return). The SFI app's Swift implementation
(Library/Network/ExtensionPlatformInterface.swift) does not define it, so the
whole type stops conforming and the Library target fails to compile:

    type 'ExtensionPlatformInterface' does not conform to protocol
    'LibboxPlatformInterfaceProtocol'

Auto-redirect was already not supported on Apple platforms in the app
(`usePlatformAutoRedirect` returns false, `createAutoRedirect` throws), so this
patch adds the new method throwing the same "not supported" error.

RUN (from the cloned repo root), then rebuild:
    python3 sfi_autoredirect_patch.py
Idempotent (no-op if already applied). The default path is
Library/Network/ExtensionPlatformInterface.swift; pass a different file path as
the first argument if needed.
"""

import io
import os
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "Library/Network/ExtensionPlatformInterface.swift"

ANCHOR = """    public func usePlatformAutoRedirect() -> Bool {
        false
    }

    public func createAutoRedirect(_: Data?, handler _: (any LibboxAutoRedirectHandlerProtocol)?) throws -> any LibboxAutoRedirectSessionProtocol {"""

INSERT = """    public func usePlatformAutoRedirect() -> Bool {
        false
    }

    // createAutoRedirectListener is required by the reF1nd core's
    // `PlatformInterface` (golang), which added it upstream. Auto redirect is
    // not supported on Apple platforms, so return the same "not supported"
    // error as `createAutoRedirect`, simply satisfying the protocol conformance.
    public func createAutoRedirectListener(_ inet6: Bool, ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw NSError(domain: "ExtensionPlatformInterface", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "auto redirect is not supported on Apple platforms",
        ])
    }

    public func createAutoRedirect(_: Data?, handler _: (any LibboxAutoRedirectHandlerProtocol)?) throws -> any LibboxAutoRedirectSessionProtocol {"""


def main():
    if not os.path.exists(PATH):
        print(f"[FAIL] {PATH} not found (run from the cloned repo root)")
        sys.exit(1)

    src = io.open(PATH, encoding="utf-8").read()

    if "createAutoRedirectListener" in src:
        print("[skip] createAutoRedirectListener already present — nothing to do")
        return

    if ANCHOR not in src:
        print("[FAIL] anchor not found — the file layout differs from dev branch; manual fix needed")
        sys.exit(1)

    src = src.replace(ANCHOR, INSERT, 1)
    io.open(PATH, "w", encoding="utf-8").write(src)
    print("[ok] inserted createAutoRedirectListener into", PATH)


if __name__ == "__main__":
    main()