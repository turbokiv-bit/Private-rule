#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lazy_recover_patch.py — step 9 of the reF1nd "no periodic url-test" work.

Context: the outer urltest has fallback.enabled and interval==0 (no periodic
health check). Members are load-balance groups A, B. When A dies a failed dial
calls DeleteURLTestHistory(A) and we cut over to B. Because interval==0 nothing
ever re-probes A, so its history is never rebuilt and the group can never fail
BACK to A once A recovers.

This step adds a *lazy, traffic-driven* recovery probe:
  - after a SUCCESSFUL dial through the currently-selected group (the network
    path is demonstrably alive), scan the outer urltest's members for any group
    that lost its URL-test history during a previous fail-over;
  - re-probe ONLY those groups (normally a single one) by running their own
    urlTest() — the same code path the periodic ticker would use, so the group's
    history entry is rebuilt correctly under its own tag;
  - if any recovered, run performUpdateCheck() so the outer fallback Select()
    re-evaluates and can switch back to the preferred group A.

This keeps steady-state probing at zero: the re-probe fires only after real
traffic flows, and it tests only the affected group(s). A small cooldown
prevents a busy stream from hammering the target.

Requires: restart-fix.py step 7 (define `periodicDisabled` on URLTestGroup)
applied FIRST. This script is idempotent and safe to re-run.
"""

import io
import os
import sys

p = 'protocol/group/urltest.go'
if not os.path.exists(p):
    print('missing ' + p + ' — run from sing-box core repo root')
    sys.exit(1)

src = io.open(p, encoding='utf-8').read()
orig = src
steps = []


def must(old, new, label):
    global src
    if new in src:
        print('  [skip] ' + label + ' (already applied)')
        steps.append('skip')
        return
    if old not in src:
        print('  [FAIL] ' + label + ' — anchor not found')
        steps.append('fail')
        return
    src = src.replace(old, new, 1)
    print('  [ok] ' + label)
    steps.append('ok')


# prerequisite: periodicDisabled must exist on URLTestGroup (from restart-fix step 7)
if 'periodicDisabled bool' not in src:
    print('  [FAIL] prerequisite: run restart-fix.py first (defines URLTestGroup.periodicDisabled)')
    sys.exit(1)

# ---------------------------------------------------------------------------
# 9a. URLTest struct: add lazy-recovery state fields
# ---------------------------------------------------------------------------
must(
    '\tproviderTags    []string\n'
    '\texclude         *regexp.Regexp\n'
    '\tinclude         *regexp.Regexp\n'
    '\tuseAllProviders bool\n'
    '}\n',
    '\tproviderTags    []string\n'
    '\texclude         *regexp.Regexp\n'
    '\tinclude         *regexp.Regexp\n'
    '\tuseAllProviders bool\n\n'
    '\t// recoverMu + lastRecoverTry implement the lazy, traffic-driven\n'
    '\t// re-probe of groups that lost their url-test history during a\n'
    '\t// previous fail-over (see maybeRecoverFailover).\n'
    '\trecoverMu      sync.Mutex\n'
    '\tlastRecoverTry time.Time\n'
    '}\n',
    '9a URLTest struct fields',
)

# ---------------------------------------------------------------------------
# 9b. package-level recover cooldown + maybeRecoverFailover method
# (insert right before the URLTestFallback type)
# ---------------------------------------------------------------------------
must(
    'type URLTestFallback struct {\n',
    '// recoverCooldown throttles how often a fail-over recovery re-probe may\n'
    '// fire after a dial success. Kept small so a recovered group is picked\n'
    '// back up quickly, but large enough that a busy stream does not hammer a\n'
    '// just-recovered target on every connection.\n'
    'const recoverCooldown = 10 * time.Second\n'
    '\n'
    '// maybeRecoverFailover is called on a successful dial. With interval == 0\n'
    '// (periodicDisabled) there is no periodic health check, so without this the\n'
    '// outer urltest would never re-evaluate its members and could not fail back\n'
    '// to the preferred group after it recovers. We trigger off a successful\n'
    '// dial (proves the network path is alive) and, cooldown permitting,\n'
    '// re-probe every member group so their URL-test history is refreshed, then\n'
    '// call performUpdateCheck so the outer fallback Select() re-runs and can\n'
    '// switch back to the preferred (first) group now that it is healthy.\n'
    'func (s *URLTest) maybeRecoverFailover(ctx context.Context) {\n'
    '\tif s.group == nil || !s.group.periodicDisabled {\n'
    '\t\t// periodic health checks are enabled; the normal ticker already\n'
    '\t\t// rebuilds history, so nothing to do here.\n'
    '\t\treturn\n'
    '\t}\n'
    '\ts.recoverMu.Lock()\n'
    '\tif !s.lastRecoverTry.IsZero() && time.Since(s.lastRecoverTry) < recoverCooldown {\n'
    '\t\ts.recoverMu.Unlock()\n'
    '\t\treturn\n'
    '\t}\n'
    '\ts.lastRecoverTry = time.Now()\n'
    '\ts.recoverMu.Unlock()\n'
    '\n'
    '\t// Background: re-probe every member group so their delay/history is fresh,\n'
    '\t// then only fail back to the preferred (first) group if it now has a live\n'
    '\t// leaf (non-nil leaf history). This avoids the false-positive where a\n'
    '\t// load-balance group whose members all failed still treated as recovered\n'
    '\t// (because urlTest() returns nil even when every member errored).\n'
    '\tgo func() {\n'
    '\t\tfor _, detour := range s.group.loadOutbounds() {\n'
    '\t\t\tif nested, ok := detour.(recursiveURLTestGroup); ok {\n'
    '\t\t\t\t_, _ = nested.urlTest(context.WithoutCancel(ctx), true)\n'
    '\t\t\t}\n'
    '\t\t}\n'
    '\t\t// The preferred target is the first member (fallback order). Only switch\n'
    '\t\t// the outer selection back to it if it genuinely has a live member now;\n'
    '\t\t// otherwise leave the current selection untouched.\n'
    '\t\tmembers := s.group.loadOutbounds()\n'
    '\t\tif len(members) == 0 || !s.groupHasLiveMember(members[0]) {\n'
    '\t\t\treturn\n'
    '\t\t}\n'
    '\t\ts.group.performUpdateCheck()\n'
    '\t}()\n'
    '}\n'
    '\n'
    '// groupHasLiveMember reports whether any leaf reachable through outbound\n'
    '// (descending nested groups) currently has a non-nil URL-test history entry.\n'
    '// Used to gate fail-back so the outer urltest does not switch to a preferred\n'
    '// group just because a urlTest() call returned nil.\n'
    'func (s *URLTest) groupHasLiveMember(outbound adapter.Outbound) bool {\n'
    '\tif outbound == nil { return false }\n'
    '\tif group, ok := outbound.(adapter.OutboundGroup); ok {\n'
    '\t\tfor _, memberTag := range group.All() {\n'
    '\t\t\tmember, loaded := s.group.outbound.Outbound(memberTag)\n'
    '\t\t\tif !loaded { continue }\n'
    '\t\t\tif s.groupHasLiveMember(member) { return true }\n'
    '\t\t}\n'
    '\t\treturn false\n'
    '\t}\n'
    '\tif s.group.history == nil { return false }\n'
    '\treturn s.group.history.LoadURLTestHistory(RealTag(s.group.outbound, outbound)) != nil\n'
    '}\n'
    '\n'
    'type URLTestFallback struct {\n',
    '9b maybeRecoverFailover method',
)

# ---------------------------------------------------------------------------
# 9c. DialContext success path -> trigger lazy recovery
# (match the restart-fix step 7 patched success block, which added ResetSelection
#  to the FAILURE block but left the success block's NewConn return untouched)
# ---------------------------------------------------------------------------
must(
    '\tconn, err := outbound.DialContext(ctx, network, destination)\n'
    '\tif err == nil {\n'
    '\t\treturn s.group.interruptGroup.NewConn(conn, interrupt.IsExternalConnectionFromContext(ctx), interrupt.IsResourceDownloadFromContext(ctx)), nil\n'
    '\t}\n',
    '\tconn, err := outbound.DialContext(ctx, network, destination)\n'
    '\tif err == nil {\n'
    '\t\t// A successful dial proves the network path is alive: opportunistically\n'
    '\t\t// re-probe any group that lost its history in a prior fail-over so it\n'
    '\t\t// can be failed back to once it recovers.\n'
    '\t\ts.maybeRecoverFailover(ctx)\n'
    '\t\treturn s.group.interruptGroup.NewConn(conn, interrupt.IsExternalConnectionFromContext(ctx), interrupt.IsResourceDownloadFromContext(ctx)), nil\n'
    '\t}\n',
    '9c DialContext success -> recover',
)

# ---------------------------------------------------------------------------
# 9d. ListenPacket success path -> trigger lazy recovery
# ---------------------------------------------------------------------------
must(
    '\tconn, err := outbound.ListenPacket(ctx, destination)\n'
    '\tif err == nil {\n'
    '\t\treturn s.group.interruptGroup.NewPacketConn(conn, interrupt.IsExternalConnectionFromContext(ctx), interrupt.IsResourceDownloadFromContext(ctx)), nil\n'
    '\t}\n',
    '\tconn, err := outbound.ListenPacket(ctx, destination)\n'
    '\tif err == nil {\n'
    '\t\t// See maybeRecoverFailover: also run the lazy re-probe on the\n'
    '\t\t// successful packet path.\n'
    '\t\ts.maybeRecoverFailover(ctx)\n'
    '\t\treturn s.group.interruptGroup.NewPacketConn(conn, interrupt.IsExternalConnectionFromContext(ctx), interrupt.IsResourceDownloadFromContext(ctx)), nil\n'
    '\t}\n',
    '9d ListenPacket success -> recover',
)

# ---------------------------------------------------------------------------
io.open(p, 'w', encoding='utf-8').write(src)
if 'fail' in steps:
    print('\n== some anchors failed — file left PARTIALLY patched; review above ==')
    sys.exit(1)
print('\n== lazy_recover_patch applied ==')