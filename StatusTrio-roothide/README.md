# StatusTrio for iOS (roothide)

借鉴自 [lingyired/status-trio](https://github.com/lingyired/status-trio) (macOS 状态栏三合一图标)，
移植为 iOS 越狱 tweak，在** iPhone 14 Pro Max 灵动岛附近的左侧状态栏 **显示一个合成图标：
**电池环形百分比 + WiFi 信号弧（+可选音量点）**。

- **设备**：iPhone 14 Pro Max
- **系统**：iOS 16.5.1
- **越狱**：roothide (arm64e)
- **注入目标**：SpringBoard
- **打包**：Theos `THEOS_PACKAGE_SCHEME=roothide`，deb 由 GitHub Actions 自动构建

---

## 目录结构

```
Sources/
  Tweak.x                     # 入口，仅 SpringBoard 生效
  STStatusBarHooks.x          # 状态栏注入钩子（挂 _UIStatusBar）
  STStatusIconView.{h,m}      # 状态栏里的图标宿主视图（UIImageView + 定时刷新）
  STStatusSnapshot.{h,m}      # 状态数据模型（借鉴 StatusTrio 的 StatusSnapshot）
  STStatusIconRenderer.{h,m}  # 合成图标绘制（移植 StatusTrio 的 StatusIconRenderer）
  STStatusIconGeometry.{h,m}  # 圆弧/路径几何（移植 StatusTrio 的 StatusIconGeometry）
  StatusProviders/            # iOS 数据采集（替代 macOS 的 CoreWLAN/IOKit/CoreAudio）
    STBatteryProvider.{h,m}
    STWiFiProvider.{h,m}
    STVolumeProvider.{h,m}
Makefile                      # Theos roothide 打包配置
control                       # deb 元数据
.github/workflows/build.yml   # CI 自动构建
```

## 与 macOS 原版的对应关系

| StatusTrio (macOS) | 本项目 (iOS roothide) |
|---|---|
| `NSStatusBar` + `StatusBarController` | 注入 `_UIStatusBar` 并 addSubview |
| `StatusSnapshot` struct | `STStatusSnapshot` struct（照搬字段） |
| `StatusIconRenderer` (CoreGraphics 绘制) | `STStatusIconRenderer`（移植同样的路径/颜色/映射） |
| `StatusIconGeometry` (CGPath) | `STStatusIconGeometry`（原样移植常量） |
| `StatusMappings` (rssi→bars, pct→progress, vol→steps) | 移植进 `STStatusIconRenderer` |
| `BatteryMonitor` (IOKit) | `STBatteryProvider` (UIDevice/NSProcessInfo) |
| `WiFiMonitor` (CoreWLAN) | `STWiFiProvider` (SpringBoard WiFiManager 私有 API) |
| `VolumeMonitor`/`CoreAudio` | `STVolumeProvider` (AVSystemController 私有 API) |

可 1:1 借鉴的三层（纯 CoreGraphics/Foundation）：`StatusIconGeometry`、`StatusIconRenderer`、
`StatusSnapshot`。这三层在 macOS 和 iOS 上 API 完全一致，直接移植。

需要重写的两层（平台绑定框架）：数据采集 + 状态栏宿主。

---

## 编译

采用 GitHub Actions 自动构建 `.deb`：

1. `.github/workflows/build.yml` 已配置（macOS runner + Theos + roothide scheme）
2. `make package THEOS_PACKAGE_SCHEME=roothide ARCHS="arm64 arm64e"`
3. 产物 `packages/statusTrio-*.deb`

### 手动本机编译（需要有 macOS + Theos）

```bash
export THEOS=/opt/theos
export THEOS_PACKAGE_SCHEME=roothide
export ARCHS="arm64 arm64e"
make package FINALPACKAGE=1 DEBUG=0
```

### roothide 兼容说明

`Makefile` 已设 `THEOS_PACKAGE_SCHEME=roothide`，Theos 会自动
- 用 **roothide 的 PathPrefix**（`/var/jb` 前缀路径）
- 可搭配 **cellekit** 注入器（roothide 官方方案）
- `control` 里 `Depends` 已列为 `mobilesubstrate | ellekit | cellekit`

---

## 安装与调试

1. 把 `.deb` 传到手机，用 Sileo/Sileo-for-roothide 安装
2. 若装了 ellekit/cellekit 依赖会自动装
3. **注销 (respring)** 生效
4. 查看日志确认注入成功：
   ```
   # 在手机终端或 ssh
   log stream --predicate 'subsystem contains "StatusTrio" OR eventMessage CONTAINS "StatusTrio"'
   ```
   或看系统日志过滤 `[StatusTrio]`：
   - `loaded in SpringBoard, waiting for status bar…` → 注入 OK
   - `installed icon view into …` → 已插入状态栏

### 可能现场调整的点
- **图标位置/大小**：`STStatusBarHooks.x` 里改 `constant` 与 frame；灵动岛机型左侧空间有限，若挤压可减小 `CGFloat pointSize`（`STStatusIconView.m` 的 18）。
- **显示什么**：`STStatusIconView.m` 的 `showVolume` 默认关闭；`STStatusIconRenderer` 的 `showBolt/showPercent` 可调。
- **刷新频率**：`STStatusIconView.m` 的 `NSTimer` 间隔 5s（事件驱动较理想，可后续加通知钩子）。

---

## 说明与风险
- 状态栏 hook 点 `_UIStatusBar` 是 iOS 13+ 的私有根视图，iOS 16 可用；随版本可能微调。
- WiFi/音量用的是 SpringBoard 进程内的私有 API（运行时动态查找，避免编译期私有头）。
- 本项目为学习借鉴，Keys/图标均来自 StatusTrio 的 Apache-2.0 或自行绘制。