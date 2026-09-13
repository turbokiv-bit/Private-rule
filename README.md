# 抖音优化交流版 · 纯 ElleKit 去授权 Hook（UID 层 + SVIP 层）

一个 deb 完整替代 v5.dylib 的字节补丁。不需要 TrollFools 注入，直接用 **Sileo 安装**。

## 它做了三件事（针对你锁的 SVIP 高端功能）

1. **`HOOK_FP`** — hook 指纹函数 `0x19213c`（返回 void，最安全的锚点）。
   调用原函数后，把全局指纹槽 `base+0x91de58` 强制写成授权包内置 fp：
   `b6d1e95f66985a848f1ae0a965c53cf697c64af309e503fdddab5330b37650d3`
   → 让 UID 白名单比对通过，**绕过「把UID发给作者/前往群聊」那层**。

2. **`HOOK_ISALIAS`** — swizzle `isAliasSVIPUnlocked` 恒返回 YES。
   覆盖它被 **75 处**调用的 SVIP 扇出（AI机器人/胶囊/动态签名等）。

3. **`HOOK_ISPEAR`** — swizzle `isPearModelPickerUnlocked` 恒返回 YES。
   解锁 Pear 模型选择器（v5 字节补丁对此门控的等价覆盖）。

## 为什么用 hook 而不是字节补丁绕 UID 层

v5 的 10 处字节补丁能解锁基础授权（你已确认"功能多了变了"），
但 **UID 白名单层**是服务端/编译进代码的状态机校验，**无法靠 NOP 干净绕过**（会崩）。
只能靠 hook 在运行时把指纹/判定改成已授权。这就是本 tweak 存在的意义。

## 文件

- `Tweak.m`  — hook 源码（含 3 个开关）
- `Makefile` — Theos 编译（默认 arm64e；arm64 也可，可自行转换）
- `control`  — deb 元数据（Depends: ellekit）
- `SJJAuthBypass.plist` — 只注入抖音 com.ss.iphone.ugc.Aweme
- `.github/workflows/build.yml` — GitHub Actions 自动出 deb

## 编译（二选一）

### 方式 A：GitHub Actions（推荐，无需本地工具链）
1. 把这个目录推到 GitHub 仓库（`git init && git add . && git commit && git push`）。
2. 打开仓库 → **Actions** → Run workflow。
3. 下载 Artifacts 里的 `SJJAuthBypass-deb`。

### 方式 B：macOS + Theos
```bash
export THEOS=~/theos
make clean
make package FINALPACKAGE=1
# 产物 packages/*.deb
```

## 安装（在 iPhone 上）
```bash
# 先卸掉 TrollFools 注入的 v5.dylib（避免双重生效/符号冲突）
dpkg -i SJJAuthBypass*.deb   # 或 Filza 打开 deb
sbreload
```
依赖：必须装有 **ellekit**（Sileo 会自动带）。

## 验证
- 打开抖音，测 SVIP 胶囊样式 / AI视频机器人 / 下载 / Pear 模型选择器。
- 日志过滤 `[SJJ-bypass]`，应看到 `dylib base`、`hooked 0x19213c`、`swizzle ... -> YES`。

## 开关（Tweak.m 顶部）
- `HOOK_FP` (1) — 指纹覆写（UID 层，**核心**）
- `HOOK_ISALIAS` / `HOOK_ISPEAR` (1) — SVIP 门控

## 已知 / 待实测
- 指纹槽 `0x91de58` 覆写后若仍被更下游拒绝，说明还有独立于 fp 的 UID 判定，
  需回传日志定位 `0x3653f4`（返回对象的 UID 授权函数）。本版未 hook 它（返回值是对象，签名复杂易崩），作为备选。