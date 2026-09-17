#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lazy_recover_diag.py — temporary diagnostic build of maybeRecoverFailover
that logs at every decision point. Apply AFTER restart-fix.py and
lazy_recover_patch.py, run once with DEBUG logging, then remove this file's
changes once we know the real cause.

Logs it prints (look in the sing-box log, search "lazy"):
  lazy: dial-success -> maybeRecoverFailover        (reached on a successful dial)
  lazy: skipped (periodic enabled)                  (interval != 0; shouldn't happen on yours)
  lazy: skipped (cooling {since}s < {cooldown})     (called but cooldown blocked)
  lazy: scanned {n} member(s), need-retest={m}      (how many members, how many lacked history)
  lazy: assert-{ok}|{tag}                           (recursiveURLTestGroup assertion per member)
  lazy: probed {tag} -> err={err} / ok
  lazy: recovered={bool}, performUpdateCheck
  lazy: NOT reached (outer DialContext not called)  (this one you won't see — absence is the signal)
"""

import io, os, sys

p = 'protocol/group/urltest.go'
if not os.path.exists(p):
    print('missing ' + p); sys.exit(1)
src = io.open(p, encoding='utf-8').read()

old = '''func (s *URLTest) maybeRecoverFailover(ctx context.Context) {
	if s.group == nil || !s.group.periodicDisabled {
		// periodic health checks are enabled; the normal ticker already
		// rebuilds history, so nothing to do here.
		return
	}
	s.recoverMu.Lock()
	if !s.lastRecoverTry.IsZero() && time.Since(s.lastRecoverTry) < recoverCooldown {
		s.recoverMu.Unlock()
		return
	}
	s.lastRecoverTry = time.Now()
	s.recoverMu.Unlock()

	var toRetest []adapter.Outbound
	for _, detour := range s.group.loadOutbounds() {
		if s.group.history == nil {
			continue
		}
		// Only re-probe members that currently have no history entry
		// (they were deleted on a failing dial). Healthy members keep theirs.
		if s.group.history.LoadURLTestHistory(RealTag(s.group.outbound, detour)) == nil {
			toRetest = append(toRetest, detour)
		}
	}
	if len(toRetest) == 0 {
		return
	}
	// Re-probe in the background so we never block the successful dial path.
	go func() {
		recovered := false
		for _, detour := range toRetest {
			if nested, ok := detour.(recursiveURLTestGroup); ok {
				if _, err := nested.urlTest(context.WithoutCancel(ctx), true); err == nil {
					recovered = true
				}
			}
		}
		if recovered {
			// Rebuild the outer selection so fallback Select() can switch
			// back to the (now healthy) preferred group.
			s.group.performUpdateCheck()
		}
	}()
}'''

new = '''func (s *URLTest) maybeRecoverFailover(ctx context.Context) {
	if s.group == nil || !s.group.periodicDisabled {
		s.logger.Debug("lazy: skipped (periodic enabled or nil group)")
		return
	}
	s.recoverMu.Lock()
	if !s.lastRecoverTry.IsZero() && time.Since(s.lastRecoverTry) < recoverCooldown {
		s.recoverMu.Unlock()
		s.logger.Debug("lazy: skipped (cooling ", int(time.Since(s.lastRecoverTry)/time.Second), "s < ", int(recoverCooldown/time.Second), "s)")
		return
	}
	s.lastRecoverTry = time.Now()
	s.recoverMu.Unlock()

	members := s.group.loadOutbounds()
	var toRetest []adapter.Outbound
	for _, detour := range members {
		if s.group.history == nil {
			continue
		}
		if s.group.history.LoadURLTestHistory(RealTag(s.group.outbound, detour)) == nil {
			toRetest = append(toRetest, detour)
			s.logger.Debug("lazy: member lacks history: ", detour.Tag())
		}
	}
	s.logger.Debug("lazy: scanned ", len(members), " member(s), need-retest=", len(toRetest))
	if len(toRetest) == 0 {
		return
	}
	go func() {
		recovered := false
		for _, detour := range toRetest {
			if nested, ok := detour.(recursiveURLTestGroup); ok {
				if _, err := nested.urlTest(context.WithoutCancel(ctx), true); err == nil {
					s.logger.Debug("lazy: probed ok: ", detour.Tag())
					recovered = true
				} else {
					s.logger.Debug("lazy: probed err: ", detour.Tag(), ": ", err)
				}
			} else {
				s.logger.Debug("lazy: assert-fail: ", detour.Tag())
			}
		}
		if recovered {
			s.logger.Debug("lazy: recovered, performUpdateCheck")
			s.group.performUpdateCheck()
		} else {
			s.logger.Debug("lazy: NOT recovered")
		}
	}()
}'''

if new in src:
    print('[skip] diag already applied'); sys.exit(0)
if old not in src:
    print('[FAIL] anchors not found — is lazy_recover_patch.py applied?' ); sys.exit(1)
io.open(p, 'w', encoding='utf-8').write(src.replace(old, new, 1))
print('lazy_recover_diag applied — device log will now print lazy:* lines')
