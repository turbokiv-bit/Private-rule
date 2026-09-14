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
print('== summary ==')
bad = [m for st, m in STEPS if st == 'FAIL']
for st, m in STEPS:
    if st == 'FAIL':
        print('  FAILED: ' + m)
if bad:
    sys.exit(1)
print('restart-fix applied successfully')
