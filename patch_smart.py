import io

# ---------- 1) constant/proxy.go: 加 TypeSmart ----------
p = 'constant/proxy.go'
s = open(p, encoding='utf-8').read()
if 'TypeSmart' not in s:
    s = s.replace('TypeURLTest     = "urltest"',
                  'TypeURLTest     = "urltest"\n\tTypeSmart       = "smart"')
open(p, 'w', encoding='utf-8').write(s)

# ---------- 2) include/registry.go: 注册 Smart ----------
p = 'include/registry.go'
s = open(p, encoding='utf-8').read()
if 'RegisterSmart' not in s:
    s = s.replace('group.RegisterLoadBalance(registry)',
                  'group.RegisterLoadBalance(registry)\n\tgroup.RegisterSmart(registry)')
open(p, 'w', encoding='utf-8').write(s)

# ---------- 3) adapter/experimental.go: 补 URLTestHistoryStorage 接口 ----------
p = 'adapter/experimental.go'
s = open(p, encoding='utf-8').read()
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
open(p, 'w', encoding='utf-8').write(s)

# ---------- 4) common/httpclient/manager.go: 补 LookupDetour ----------
p = 'common/httpclient/manager.go'
s = open(p, encoding='utf-8').read()
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
open(p, 'w', encoding='utf-8').write(s)

# ---------- 5) 校验 ----------
assert 'RegisterSmart' in open('include/registry.go', encoding='utf-8').read()
assert 'TypeSmart' in open('constant/proxy.go', encoding='utf-8').read()
print("PATCH OK")
