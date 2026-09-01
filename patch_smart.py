import io
import re
import sys

# =========================================================
#  Complete patch for merging smart outbound into reF1nd core
# =========================================================

def read(p):
    return open(p, encoding='utf-8').read()

def write(p, s):
    open(p, 'w', encoding='utf-8').write(s)

# ---------- 1) constant/proxy.go: add TypeSmart ----------
p = 'constant/proxy.go'
s = read(p)
if 'TypeSmart' not in s:
    s = s.replace('TypeURLTest     = "urltest"',
                  'TypeURLTest     = "urltest"\n\tTypeSmart       = "smart"')
    # also add a case to the Type() switch if present
    if 'case TypeURLTest:' in s and 'case TypeSmart' not in s:
        s = s.replace('case TypeURLTest:',
                      'case TypeSmart:\n\t\treturn "Smart"\n\tcase TypeURLTest:')
write(p, s)

# ---------- 2) include/registry.go: register Smart group ----------
p = 'include/registry.go'
s = read(p)
if 'RegisterSmart' not in s:
    s = s.replace('group.RegisterLoadBalance(registry)',
                  'group.RegisterLoadBalance(registry)\n\tgroup.RegisterSmart(registry)')
write(p, s)

# ---------- 3) adapter/experimental.go: add required interfaces ----------
p = 'adapter/experimental.go'
s = read(p)

# 3a) OutboundGroup gets Hidden/Icon
s = s.replace('''type OutboundGroup interface {
	Outbound
	Now() string
	All() []string
}''', '''type OutboundGroup interface {
	Outbound
	Now() string
	All() []string

	// Hidden reports the dashboard hint set in option.GroupCommonOption.
	Hidden() bool

	// Icon returns the opaque dashboard icon string from
	// option.GroupCommonOption. Empty means no icon configured.
	Icon() string
}''')

# 3b) URLTestHistoryStorage interface
if 'URLTestHistoryStorage' not in s:
    block = '''type URLTestHistoryStorage interface {
\tAddUpdateHook(hook *observable.Subscriber[struct{}])
\tNotifyUpdated()
\tLoadURLTestHistory(tag string) *URLTestHistory
\tDeleteURLTestHistory(tag string)
\tStoreURLTestHistory(tag string, history *URLTestHistory)
\tClose() error
}

'''
    s = s.replace('type ClashServer interface {',
                  block + 'type ClashServer interface {', 1)

# 3c) SmartService & GeoXService interfaces (append at end, ensure imports exist)
if 'SmartService interface' not in s:
    s += '''

// SmartService is the singleton that owns infrastructure shared by all Smart
// outbound groups: the LightGBM model, its auto-updater, and the training
// sample collector. The concrete type lives in experimental/smart.
type SmartService interface {
	LifecycleService
	// LightGBMEnabled reports whether the shared ML model is configured.
	LightGBMEnabled() bool
	// CollectorEnabled reports whether the shared training-data collector is configured.
	CollectorEnabled() bool
}

// GeoXService is the singleton that downloads and tracks global geo data
// assets (geoip.dat / geosite.dat / country.mmdb / GeoLite2-ASN.mmdb).
type GeoXService interface {
	LifecycleService

	// Enabled reports whether experimental.geox.enabled was set.
	Enabled() bool

	// GeoIPPath returns the local path of the downloaded geoip.dat, or "" if unavailable.
	GeoIPPath() string
	// GeoSitePath returns the local path of the downloaded geosite.dat.
	GeoSitePath() string
	// MMDBPath returns the local path of the downloaded country.mmdb.
	MMDBPath() string
	// ASNPath returns the FIRST local ASN mmdb path. Empty if not configured.
	ASNPath() string
	// ASNPaths returns every configured ASN mmdb path in priority order.
	ASNPaths() []string
}
'''
write(p, s)

# ---------- 4) common/httpclient/manager.go: add LookupDetour ----------
p = 'common/httpclient/manager.go'
s = read(p)
if 'LookupDetour' not in s:
    func = '''func (m *Manager) LookupDetour(tag string) string {
\tm.access.Lock()
\tdefer m.access.Unlock()
\tif client, ok := m.defines[tag]; ok {
\t\treturn client.Detour
\t}
\treturn ""
}

'''
    s = s.replace('func (m *Manager) Initialize(',
                  func + 'func (m *Manager) Initialize(', 1)
write(p, s)

# ---------- 5) option/group.go: GroupCommonOption gets hidden/icon ----------
p = 'option/group.go'
s = read(p)
if 'Hidden          bool' not in s:
    s = s.replace('UseAllProviders bool              `json:"use_all_providers,omitempty"`',
                  'UseAllProviders bool              `json:"use_all_providers,omitempty"`\n\tHidden          bool              `json:"hidden,omitempty"`\n\tIcon            string            `json:"icon,omitempty"`')
write(p, s)

# ---------- 6) option/experimental.go: add Smart & GeoX options ----------
p = 'option/experimental.go'
s = read(p)
if 'Smart               *SmartOptions' not in s:
    s = s.replace('URLTestUnifiedDelay bool                  `json:"urltest_unified_delay,omitempty"`',
                  'URLTestUnifiedDelay bool                  `json:"urltest_unified_delay,omitempty"`\n\tSmart               *SmartOptions          `json:"smart,omitempty"`\n\tGeoX                *GeoXOptions           `json:"geox,omitempty"`')
write(p, s)

# ---------- 7) Group structs: add hidden/icon fields + methods ----------
#    selector, urltest, loadbalance must satisfy new OutboundGroup interface
def patch_group(fname, structname, anchor_field):
    s = read(fname)
    # struct fields
    s = s.replace('type %s struct {' % structname,
                  'type %s struct {\n\thidden bool\n\ticon   string' % structname, 1)
    # constructor assignment after anchor_field
    s = s.replace(anchor_field, anchor_field + '\n\t\thidden:          options.Hidden,\n\t\ticon:            options.Icon,', 1)
    # methods
    s += '\n// Hidden / Icon expose the dashboard hints from option.GroupCommonOption.\n'
    s += 'func (s *%s) Hidden() bool { return s.hidden }\n' % structname
    s += 'func (s *%s) Icon() string { return s.icon }\n' % structname
    write(fname, s)

patch_group('protocol/group/selector.go',    'Selector',  '\t\tuseAllProviders: options.UseAllProviders,')
patch_group('protocol/group/urltest.go',     'URLTest',   '\t\tuseAllProviders: options.UseAllProviders,')
patch_group('protocol/group/loadbalance.go', 'LoadBalance', '\t\tuseAllProviders: options.UseAllProviders,')

# ---------- 8) box.go: register Smart & GeoX services ----------
p = 'box.go'
s = read(p)

# 8a) imports
if 'experimental/smart' not in s:
    s = s.replace('"github.com/sagernet/sing-box/experimental/geox"',  # noqa: not present; handle below
                  '"github.com/sagernet/sing-box/experimental/geox"')
# add imports next to observability import
imp_anchor = '"github.com/sagernet/sing-box/experimental/observability"'
if 'experimental/smart' not in s:
    s = s.replace(imp_anchor,
                  'geoxservice "github.com/sagernet/sing-box/experimental/geox"\n\t"github.com/sagernet/sing-box/experimental/observability"\n\tsmartservice "github.com/sagernet/sing-box/experimental/smart"')

# 8b) registration block right after the needCacheFile block
cache_block = '''	if needCacheFile {
		cacheFile := cachefile.New(ctx, logFactory.NewLogger("cache-file"), common.PtrValueOrDefault(experimentalOptions.CacheFile))
		service.MustRegister[adapter.CacheFile](ctx, cacheFile)
		internalServices = append(internalServices, cacheFile)
	}'''
service_block = '''	// Register Smart service (shared LightGBM model + collector).
	{
		smartOpts := common.PtrValueOrDefault(experimentalOptions.Smart)
		smartSvc := smartservice.NewService(ctx, logFactory.NewLogger("smart"), smartOpts)
		service.MustRegister[adapter.SmartService](ctx, smartSvc)
		internalServices = append(internalServices, smartSvc)
	}
	// Register GeoX service (global geoip/geosite/mmdb/asn downloader).
	{
		geoxOpts := common.PtrValueOrDefault(experimentalOptions.GeoX)
		geoxSvc := geoxservice.NewService(ctx, logFactory.NewLogger("geox"), geoxOpts)
		service.MustRegister[adapter.GeoXService](ctx, geoxSvc)
		internalServices = append(internalServices, geoxSvc)
	}'''
if 'Register[adapter.GeoXService]' not in s:
    s = s.replace(cache_block, cache_block + '\n' + service_block, 1)
write(p, s)

# ---------- 9) cachefile: add SmartDB() so smart groups get persistent store ----------
p = 'experimental/cachefile/cache.go'
s = read(p)
if 'func (c *CacheFile) SmartDB' not in s:
    smartdb = '''func (c *CacheFile) SmartDB() any {
	return c.DB
}

'''
    # 插在 Dependencies 方法前
    s = s.replace('func (c *CacheFile) Dependencies() []string {',
                  smartdb + 'func (c *CacheFile) Dependencies() []string {', 1)
write(p, s)
assert 'func (c *CacheFile) SmartDB() any' in read(p)

print("PATCH COMPLETE")
