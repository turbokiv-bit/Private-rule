# 抖音优化交流版 · ellekit 去授权 Hook

Hook `siwenjiajia.dylib` 的指纹计算函数 `0x19213c`，把运行时算出的设备指纹强制覆盖为授权包内置 fp，使授权包被接受、解锁下载/胶囊等高阶功能。

## 文件

- `Tweak.m`                 — hook 源码（含开关）
- `Makefile`                — Theos 编译
- `control`                 — deb 元数据
- `SJJAuthBypass.plist`     — 注入过滤 (com.ss.iphone.ugc.Aweme)
- `.github/workflows/build.yml` — GitHub Actions 自动编译

## 在 GitHub Actions 编译（不用本地 Theos）

1. 把这个目录推到 GitHub 仓库（`git init && git add . && git commit && git push`）。
2. 打开仓库 → **Actions** → 手动 Run workflow。
3. 跑完后在 Artifacts 下载 `SJJAuthBypass-deb`。
4. 把 deb 传到越狱设备安装（Filza / `dpkg -i`）。

## 本地 Theos 编译

```bash
export THEOS=~/theos
make clean
make package FINALPACKAGE=1   # ARM64e
```

产物在 `packages/*.deb`。

## 开关（Tweak.m 顶部）

- `HOOK_FP` (1) — 覆盖全局指纹槽 `0x91de58` 为内置 fp（主方案）
- `VERBOSE_LOG` (1) — 打印日志，设备上 `log stream` 过滤 `[SJJ-bypass]`

## 验证

1. 装去授权 deb + 原交流版插件。
2. 打开抖音，测「下载(保存视频/图片/批量/实况)」和「胶囊按钮下功能」。
3. 日志过滤 `[SJJ-bypass]`，应看到 `dylib base` 与 `FP override`。

## 已知

- 若 hook 0x19213c 单独不够（下载/胶囊仍锁），说明卡点在更下游 `sjj-package-policy`（objc_msgSend stub 簇 `0x623bc0/0x626020`），需回传日志定位，再扩 hook。
- 指纹计算函数 `0x19213c`：内部 `CC_SHA256_Init/Update/Final` + hex 格式化，结果写全局槽 `0x91de58`。
