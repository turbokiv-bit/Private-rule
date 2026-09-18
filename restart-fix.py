#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
restart-fix.py — apply the "bridge stale -> full box reload" fix to a checked-out
reF1nd sing-box core.

Usage:  cd <core-repo-root> && python3 restart-fix.py

Why a script instead of a .patch: the reF1nd-testing branch moves, and a
context-based git patch then refuses to apply. This script uses small,
well-chosen anchors and reports exactly which step failed, so it survives
routine upstream churn (field renames nearby, etc.).

Changes made:
  1. adapter/box_restart.go                (new)  BoxRestartFunc interface
  2. experimental/libbox/command_server.go        register restart hook +
                                                  remember the config text
  3. protocol/bridge/backend.go                   rebuild hook + trigger on
                                                  egress re-apply failure
  4. protocol/bridge/backend_darwin.go            restart() + stopReload so a
                                                  reload can safely tear the tun
  5. protocol/bridge/outbound.go                  wire rebuild -> BoxRestartFunc
"""

import io
import os
import sys

STEPS = []


def read(path):
    with io.open(path, encoding='utf-8') as f:
        return f.read()


def write(path, text):
    with io.open(path, 'w', encoding='utf-8') as f:
        f.write(text)


def ok(msg):
    STEPS.append(('OK', msg))
    print('  [ok] ' + msg)


def skip(msg):
    STEPS.append(('SKIP', msg))
    print('  [skip] ' + msg)


def fail(msg):
    STEPS.append(('FAIL', msg))
    print('  [FAIL] ' + msg)


def must_replace(path, old, new, label):
    s = read(path)
    if new.strip().split('\n')[0].strip() and new.strip() in s:
        skip(label + ' (already applied)')
        return True
    if old not in s:
        fail(label + ' — anchor not found in ' + path)
        return False
    write(path, s.replace(old, new, 1))
    ok(label)
    return True


def require(path):
    if not os.path.exists(path):
        fail('missing file: ' + path)
        sys.exit(1)


# --------------------------------------------------------------------------
# 0. sanity: are we in a sing-box core checkout?
# --------------------------------------------------------------------------
if not os.path.exists('protocol/bridge/backend.go') or not os.path.exists('go.mod'):
    fail('run this from the sing-box core repo root')
    sys.exit(1)

print('== restart-fix ==')

# --------------------------------------------------------------------------
# 1. adapter/box_restart.go
# --------------------------------------------------------------------------
BOX_RESTART = '''package adapter

// BoxRestartFunc is injected by the iOS/libbox layer into the service
// registry so an outbound (e.g. the bridge) can request a full configuration
// reload when its platform session went stale after a network change.
// Reloading rebuilds every outbound — including the stale bridge — through
// the existing daemon path, which is far more robust than recreating the
// platform bridge session in place.
type BoxRestartFunc interface {
	Restart() error
}
'''

p = 'adapter/box_restart.go'
if os.path.exists(p) and 'BoxRestartFunc' in read(p):
    skip('adapter/box_restart.go (exists)')
else:
    write(p, BOX_RESTART)
    ok('adapter/box_restart.go created')

# --------------------------------------------------------------------------
# 2. experimental/libbox/command_server.go
# --------------------------------------------------------------------------
p = 'experimental/libbox/command_server.go'
require(p)
s = read(p)

# 2a. struct field currentConfig
if 'currentConfig' in s:
    skip('command_server.go currentConfig field (exists)')
else:
    # anchor: the last field line of the CommandServer struct, then the brace
    import re
    m = re.search(r'(type CommandServer struct \{(?:.|\n)*?\n)(\})', s)
    if not m:
        fail('command_server.go — CommandServer struct not found')
        sys.exit(1)
    struct_body = m.group(0)
    new_struct = struct_body[:-2] + '\t// currentConfig holds the most recent config text (best-effort).\n\tcurrentConfig     string\n}\n'
    s = s.replace(struct_body, new_struct, 1)
    write(p, s)
    ok('command_server.go currentConfig field added')

s = read(p)

# 2b. register BoxRestartFunc before the final "return server, nil" of NewCommandServer
if 'BoxRestartFunc' in s:
    skip('command_server.go BoxRestartFunc registration (exists)')
else:
    anchor = 'return server, nil\n}\n'
    idx = s.find(anchor)
    if idx < 0:
        fail('command_server.go — "return server, nil" of NewCommandServer not found')
        sys.exit(1)
    inject = (
        '\t// Inject the box-restart capability so the bridge can request a full\n'
        '\t// configuration reload when its platform session goes stale after a\n'
        '\t// network change.\n'
        '\tservice.MustRegister[adapter.BoxRestartFunc](ctx, (*boxRestarter)(server))\n'
        '\treturn server, nil\n'
        '}\n'
        '\n'
        '// boxRestarter adapts CommandServer to adapter.BoxRestartFunc.\n'
        'type boxRestarter CommandServer\n'
        '\n'
        'func (b *boxRestarter) Restart() error {\n'
        '\tlog.StdLogger().Warn("box-restart requested (bridge session stale), reloading service")\n'
        '\treturn (*CommandServer)(b).handler.ServiceReload()\n'
        '}\n'
    )
    s = s[:idx] + inject + s[idx + len(anchor):]
    write(p, s)
    ok('command_server.go BoxRestartFunc registered')

s = read(p)

# 2c. remember config text in StartOrReloadService
if 's.currentConfig' in s:
    skip('command_server.go currentConfig assignment (exists)')
else:
    anchor = 'saveConfigSnapshot(configContent)'
    if anchor not in s:
        fail('command_server.go — saveConfigSnapshot(configContent) not found')
        sys.exit(1)
    s = s.replace(anchor, 's.currentConfig = configContent\n\t' + anchor, 1)
    write(p, s)
    ok('command_server.go currentConfig assignment added')

# --------------------------------------------------------------------------
# 3. protocol/bridge/backend.go
# --------------------------------------------------------------------------
p = 'protocol/bridge/backend.go'
require(p)

must_replace(
    p,
    '\tsession       adapter.BridgeSession\n\tcurrentEgress string\n\n\tcloseOnce sync.Once\n\tclosed    chan struct{}\n\treadDone  chan struct{}\n}',
    '\tsession       adapter.BridgeSession\n\tcurrentEgress string\n\n'
    '\t// lifecycleMu serialises network-driven reload against concurrent\n'
    '\t// Write/Port/Attach access.\n'
    '\tlifecycleMu sync.Mutex\n'
    '\t// rebuild, when set by the owning Outbound, requests a full box reload\n'
    '\t// after the current egress could not be re-applied on a network change.\n'
    '\trebuild func()\n\n'
    '\tcloseOnce sync.Once\n\tclosed    chan struct{}\n'
    '\t// stopReload is closed to make batchReadLoop exit before a reload.\n'
    '\tstopReload chan struct{}\n'
    '\treadDone   chan struct{}\n}',
    'backend.go struct fields',
)

must_replace(
    p,
    '\terr := b.session.SetEgress(egress)\n\tif err != nil {\n\t\tb.logger.Debug(E.Cause(err, "apply bridge egress ", egress))\n\t\treturn\n\t}\n\tb.currentEgress = egress',
    '\terr := b.session.SetEgress(egress)\n\tif err != nil {\n'
    '\t\tb.logger.Debug(E.Cause(err, "apply bridge egress ", egress))\n'
    '\t\t// The platform session has gone stale (its interface disappeared).\n'
    '\t\t// Ask the owning Outbound to reload the box so the bridge is\n'
    '\t\t// rebuilt on the new default interface. Async: never tear the\n'
    '\t\t// session down from inside a network-monitor callback.\n'
    '\t\tif b.rebuild != nil {\n'
    '\t\t\tb.logger.Warn("bridge session stale after network change, reloading")\n'
    '\t\t\tgo b.rebuild()\n'
    '\t\t}\n'
    '\t\treturn\n\t}\n\tb.currentEgress = egress',
    'backend.go rebuild trigger',
)

# --------------------------------------------------------------------------
# 4. protocol/bridge/backend_darwin.go
# --------------------------------------------------------------------------
p = 'protocol/bridge/backend_darwin.go'
require(p)

must_replace(
    p,
    '\tb.registerMonitors(b.syncSessionEgress)\n\tb.syncSessionEgress()\n\tgo b.batchReadLoop()',
    '\tb.stopReload = make(chan struct{})\n'
    '\tb.registerMonitors(b.syncSessionEgress)\n\tb.syncSessionEgress()\n\tgo b.batchReadLoop()',
    'backend_darwin.go fresh stopReload per start',
)

must_replace(
    p,
    '\t\tpackets, err := b.batchTUN.BatchRead()\n\t\tif err != nil {\n\t\t\tselect {\n\t\t\tcase <-b.closed:\n\t\t\t\treturn\n\t\t\tdefault:\n\t\t\t}',
    '\t\tpackets, err := b.batchTUN.BatchRead()\n\t\tif err != nil {\n\t\t\tselect {\n'
    '\t\t\tcase <-b.closed:\n\t\t\t\treturn\n'
    '\t\t\tcase <-b.stopReload:\n'
    '\t\t\t\t// Reload requested: exit so the reload can recreate the tun\n'
    '\t\t\t\t// without a second reader on the same batchTUN.\n'
    '\t\t\t\treturn\n'
    '\t\t\tdefault:\n\t\t\t}',
    'backend_darwin.go batchReadLoop honours stopReload',
)

# --------------------------------------------------------------------------
# 5. protocol/bridge/outbound.go — wire rebuild -> BoxRestartFunc
# --------------------------------------------------------------------------
p = 'protocol/bridge/outbound.go'
require(p)
must_replace(
    p,
    '\toutboundBackend, err := newBackend(ctx, logger, networkManager, tag, options)\n\tif err != nil {\n\t\treturn nil, err\n\t}\n',
    '\toutboundBackend, err := newBackend(ctx, logger, networkManager, tag, options)\n\tif err != nil {\n\t\treturn nil, err\n\t}\n'
    '\t// When the bridge session goes stale, request a full box reload: the\n'
    '\t// existing daemon reload path rebuilds every outbound (including the\n'
    '\t// bridge, on the new interface).\n'
    '\tif restarter, ok := outboundBackend.(*backendDarwin); ok {\n'
    '\t\tboxRestarter := service.FromContext[adapter.BoxRestartFunc](ctx)\n'
    '\t\trestarter.rebuild = func() {\n'
    '\t\t\tif boxRestarter != nil {\n'
    '\t\t\t\t_ = boxRestarter.Restart()\n'
    '\t\t\t}\n'
    '\t\t}\n'
    '\t}\n',
    'outbound.go rebuild -> BoxRestartFunc',
)

# --------------------------------------------------------------------------
# 6. provider node tag separator: "/" -> " " (display: "🏎️ HKG·X" not "🏎️/HKG·X")
# --------------------------------------------------------------------------
PROVIDER_SEP_FILES = [
    (
        'adapter/provider/adapter.go',
        [
            ('a.providerTag, "/",', 'a.providerTag, " ",'),
            ('a.providerTag, "/endpoint-",', 'a.providerTag, " endpoint-",'),
        ],
    ),
    (
        'provider/parser/parser.go',
        [
            ('providerTag + "/" + options.Detour', 'providerTag + " " + options.Detour'),
        ],
    ),
]

for path, pairs in PROVIDER_SEP_FILES:
    if not os.path.exists(path):
        fail('missing file: ' + path)
        continue
    text = read(path)
    changed = 0
    already = 0
    for old, new in pairs:
        if new in text:
            already += text.count(new)
            continue
        n = text.count(old)
        if n:
            text = text.replace(old, new)
            changed += n
    if changed:
        write(path, text)
        ok('provider tag separator in %s (%d replacement(s))' % (os.path.basename(path), changed))
    else:
        skip('provider tag separator in %s (already applied)' % os.path.basename(path))

# --------------------------------------------------------------------------
# 7. urltest: interval: 0  =>  no periodic health-check ticker,
#    but fail-over on a dead node still works (dial error clears the cached
#    selection so the next dial re-selects a healthy node).
# --------------------------------------------------------------------------
p = 'protocol/group/urltest.go'
require(p)

must_replace(
    p,
    '\tfallback URLTestFallback\n}',
    '\tfallback URLTestFallback\n\n'
    '\t// periodicDisabled is set when interval == 0: the periodic\n'
    '\t// health-check ticker is not created, so there are no recurring\n'
    '\t// probes. Fail-over still works — a failed dial drops that node\'s\n'
    '\t// history and clears the cached selection, so the next dial picks a\n'
    '\t// healthy node.\n'
    '\tperiodicDisabled bool\n}',
    'urltest.go periodicDisabled field',
)

must_replace(
    p,
    '\tif interval == 0 {\n\t\tinterval = C.DefaultURLTestInterval\n\t}\n'
    '\tif tolerance == 0 {\n\t\ttolerance = 50\n\t}\n'
    '\tif idleTimeout == 0 {\n\t\tidleTimeout = C.DefaultURLTestIdleTimeout\n\t}\n'
    '\tif interval > idleTimeout {\n'
    '\t\treturn nil, E.New("interval must be less or equal than idle_timeout")\n\t}',
    '\t// interval == 0 disables the periodic health-check ticker entirely\n'
    '\t// (no recurring probes). idle_timeout == 0 is honoured as well: the\n'
    '\t// group counts as idle immediately, so no probe is scheduled on\n'
    '\t// provider updates either. Non-zero values keep upstream behaviour.\n'
    '\tperiodicDisabled := interval == 0\n'
    '\tif tolerance == 0 {\n\t\ttolerance = 50\n\t}\n'
    '\tif idleTimeout != 0 && !periodicDisabled {\n'
    '\t\tif interval == 0 {\n\t\t\tinterval = C.DefaultURLTestInterval\n\t\t}\n'
    '\t\tif interval > idleTimeout {\n'
    '\t\t\treturn nil, E.New("interval must be less or equal than idle_timeout")\n\t\t}\n\t}',
    'urltest.go interval==0 handling',
)

must_replace(
    p,
    '\t\tinterruptGroup:               interrupt.NewGroup(),\n'
    '\t\tinterruptExternalConnections: interruptExternalConnections,\n\t}',
    '\t\tinterruptGroup:               interrupt.NewGroup(),\n'
    '\t\tinterruptExternalConnections: interruptExternalConnections,\n'
    '\t\tperiodicDisabled:             periodicDisabled,\n\t}',
    'urltest.go store periodicDisabled',
)

must_replace(
    p,
    '\tif g.ticker != nil {\n\t\tg.lastActive.Store(time.Now())\n\t\treturn\n\t}\n'
    '\tticker := time.NewTicker(g.interval)',
    '\tif g.ticker != nil {\n\t\tg.lastActive.Store(time.Now())\n\t\treturn\n\t}\n'
    '\tif g.periodicDisabled || g.interval <= 0 {\n'
    '\t\t// interval == 0: no periodic health check. Keep the group active\n'
    '\t\t// without starting a probe ticker.\n'
    '\t\tg.lastActive.Store(time.Now())\n'
    '\t\treturn\n\t}\n'
    '\tticker := time.NewTicker(g.interval)',
    'urltest.go Touch honours periodicDisabled',
)

# helper: clear cached selection on dial failure
must_replace(
    p,
    'func (g *URLTestGroup) Select(network string) (adapter.Outbound, bool) {',
    '// ResetSelection clears the cached per-network selection so the next dial\n'
    '// re-runs Select. Called after a dial failure so fail-over still happens\n'
    '// when periodic health checks are disabled (interval == 0).\n'
    'func (g *URLTestGroup) ResetSelection(network string) {\n'
    '\tswitch N.NetworkName(network) {\n'
    '\tcase N.NetworkTCP:\n'
    '\t\tg.selectedOutboundTCP.Store(nil)\n'
    '\tcase N.NetworkUDP:\n'
    '\t\tg.selectedOutboundUDP.Store(nil)\n'
    '\t}\n}\n\n'
    'func (g *URLTestGroup) Select(network string) (adapter.Outbound, bool) {',
    'urltest.go ResetSelection()',
)

must_replace(
    p,
    '\tconn, err := outbound.DialContext(ctx, network, destination)\n'
    '\tif err == nil {\n'
    '\t\treturn s.group.interruptGroup.NewConn(conn, interrupt.IsExternalConnectionFromContext(ctx), interrupt.IsResourceDownloadFromContext(ctx)), nil\n\t}\n'
    '\ts.logger.ErrorContext(ctx, err)\n'
    '\ts.group.history.DeleteURLTestHistory(outbound.Tag())\n'
    '\treturn nil, err\n}',
    '\tconn, err := outbound.DialContext(ctx, network, destination)\n'
    '\tif err == nil {\n'
    '\t\treturn s.group.interruptGroup.NewConn(conn, interrupt.IsExternalConnectionFromContext(ctx), interrupt.IsResourceDownloadFromContext(ctx)), nil\n\t}\n'
    '\ts.logger.ErrorContext(ctx, err)\n'
    '\ts.group.history.DeleteURLTestHistory(outbound.Tag())\n'
    '\t// Drop the cached selection so the next dial re-selects (fail-over).\n'
    '\ts.group.ResetSelection(network)\n'
    '\treturn nil, err\n}',
    'urltest.go DialContext fail-over',
)

must_replace(
    p,
    '\tconn, err := outbound.ListenPacket(ctx, destination)\n'
    '\tif err == nil {\n'
    '\t\treturn s.group.interruptGroup.NewPacketConn(conn, interrupt.IsExternalConnectionFromContext(ctx), interrupt.IsResourceDownloadFromContext(ctx)), nil\n\t}\n'
    '\ts.logger.ErrorContext(ctx, err)\n'
    '\ts.group.history.DeleteURLTestHistory(outbound.Tag())\n'
    '\treturn nil, err\n}',
    '\tconn, err := outbound.ListenPacket(ctx, destination)\n'
    '\tif err == nil {\n'
    '\t\treturn s.group.interruptGroup.NewPacketConn(conn, interrupt.IsExternalConnectionFromContext(ctx), interrupt.IsResourceDownloadFromContext(ctx)), nil\n\t}\n'
    '\ts.logger.ErrorContext(ctx, err)\n'
    '\ts.group.history.DeleteURLTestHistory(outbound.Tag())\n'
    '\t// Drop the cached selection so the next packet dial re-selects.\n'
    '\ts.group.ResetSelection(N.NetworkUDP)\n'
    '\treturn nil, err\n}',
    'urltest.go ListenPacket fail-over',
)

# --------------------------------------------------------------------------
# 8. loadbalance: same interval:0 / idle_timeout:0 semantics as urltest.
# --------------------------------------------------------------------------
p = 'protocol/group/loadbalance.go'
require(p)

must_replace(
    p,
    '\tstrategyFn      strategyFn\n}',
    '\tstrategyFn      strategyFn\n\n'
    '\t// periodicDisabled is set when interval == 0: no periodic\n'
    '\t// health-check ticker is started. Fail-over still works — a failed\n'
    '\t// dial triggers CheckOutbounds, which drops the dead node\'s history\n'
    '\t// so it is skipped on the next pick.\n'
    '\tperiodicDisabled bool\n}',
    'loadbalance.go periodicDisabled field',
)

must_replace(
    p,
    '\tif interval == 0 {\n\t\tinterval = C.DefaultURLTestInterval\n\t}\n'
    '\tif idleTimeout == 0 {\n\t\tidleTimeout = C.DefaultURLTestIdleTimeout\n\t}\n'
    '\tif interval > idleTimeout {\n'
    '\t\treturn nil, E.New("interval must be less or equal than idle_timeout")\n\t}',
    '\t// interval == 0 disables the periodic health-check ticker entirely;\n'
    '\t// idle_timeout == 0 is honoured as "idle immediately". Non-zero values\n'
    '\t// keep the upstream behaviour. Fail-over via a failed dial still works.\n'
    '\tperiodicDisabled := interval == 0\n'
    '\tif idleTimeout != 0 && !periodicDisabled {\n'
    '\t\tif interval == 0 {\n\t\t\tinterval = C.DefaultURLTestInterval\n\t\t}\n'
    '\t\tif interval > idleTimeout {\n'
    '\t\t\treturn nil, E.New("interval must be less or equal than idle_timeout")\n\t\t}\n\t}',
    'loadbalance.go interval==0 handling',
)

must_replace(
    p,
    '\t\tpause:          service.FromContext[pause.Manager](ctx),\n'
    '\t\tinterruptGroup: interrupt.NewGroup(),\n\t}',
    '\t\tpause:          service.FromContext[pause.Manager](ctx),\n'
    '\t\tinterruptGroup: interrupt.NewGroup(),\n\n'
    '\t\tperiodicDisabled: periodicDisabled,\n\t}',
    'loadbalance.go store periodicDisabled',
)

must_replace(
    p,
    '\tif g.ticker != nil {\n\t\tg.lastActive.Store(time.Now())\n\t\treturn\n\t}\n'
    '\tg.ticker = time.NewTicker(g.interval)',
    '\tif g.ticker != nil {\n\t\tg.lastActive.Store(time.Now())\n\t\treturn\n\t}\n'
    '\tif g.periodicDisabled || g.interval <= 0 {\n'
    '\t\t// interval == 0: no periodic health check. Keep the group active\n'
    '\t\t// without starting a probe ticker.\n'
    '\t\tg.lastActive.Store(time.Now())\n'
    '\t\treturn\n\t}\n'
    '\tg.ticker = time.NewTicker(g.interval)',
    'loadbalance.go Touch honours periodicDisabled',
)

# --------------------------------------------------------------------------
# 9. Backport the SFI-dev-facing libbox bridge symbols from reF1nd-testing
#    into reF1nd-stable (7 files). reF1nd-stable syncs newer upstream but its
#    libbox predates symbols the sing-box-for-apple "dev" front-end requires
#    (GoroutineDump, processPaths, AutoRedirectSession/Handler, etc.).
#    Overwriting these files with the testing versions keeps the stable body
#    while making the front-end bindings compile. Idempotent + always fetches
#    fresh from the reF1nd-testing branch.
# --------------------------------------------------------------------------
import urllib.request

LIBBOX_BACKPORT_FILES = [
    'debug.go',
    'command_server.go',
    'platform.go',
    'service.go',
    'connection_owner_darwin.go',
    'power_report.go',
    'config.go',
]

BACKPORT_BASE = 'https://raw.githubusercontent.com/reF1nd/sing-box/reF1nd-testing/experimental/libbox/'

for name in LIBBOX_BACKPORT_FILES:
    dst = 'experimental/libbox/' + name
    if not os.path.exists(dst):
        fail('missing file: ' + dst)
        continue
    try:
        req = urllib.request.Request(BACKPORT_BASE + name, headers={'User-Agent': 'restart-fix'})
        content = urllib.request.urlopen(req, timeout=30).read().decode('utf-8')
    except Exception as e:
        fail('download ' + name + ' — ' + str(e))
        continue
    if read(dst) == content:
        skip(name + ' (already backported)')
        continue
    write(dst, content)
    ok(name + ' backported (libbox bridge symbols)')

# --------------------------------------------------------------------------
print('== summary ==')
bad = [m for st, m in STEPS if st == 'FAIL']
for st, m in STEPS:
    if st == 'FAIL':
        print('  FAILED: ' + m)
if bad:
    sys.exit(1)
print('restart-fix applied successfully')
