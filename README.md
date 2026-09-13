# DuoRingReadout — 给 CAiPhoneDuoStatus 的圆环加上数字读数

给插件 **CAiPhoneDuoStatus 1.5.10**（iPad/灵动岛风格圆环状态栏）在**圆环 12 点方向的缺口**里加一个数字。

![预览](preview_readout.png)

---

## 1. 数字显示什么（按"角色"配置）

主卡 / 副卡分开：每个信号环各取自己的值，互不影响。每个环显示什么在偏好设置里可选
`off` / `signal`（该环信号%）/ `battery`（系统**实时电量**%）：

| 圆环（角色） | 判定方式 | 默认显示 |
|---|---|---|
| 主卡环 `numberPrimary` | 双卡容器里 `topSignalView` 那个 | **battery（实时电量）** |
| 副卡环 `numberSecondary` | 双卡容器里另一个 | signal（该卡信号%） |
| 单卡环 `numberSingle` | 蜂窝环不在双卡容器里（单卡机型） | battery（实时电量） |
| 双卡合成环 `numberDual` | `*DualCellularSignalView` 容器本身 | off（不显示） |
| 电量环 `numberBattery` | `*BatteryView` | `auto` = 别处已经显示电量时不显示 |

* **电量数字 = 系统实时电量**：`IOPSCopyPowerSourcesInfo()`（IOKit 电源信息，iOS 状态栏电量用的就是它），
  取不到时依次回退 `UIDevice.batteryLevel` → 视图 `chargePercent` → 我们链式 hook `setChargePercent:` 抓到的值。
  三条刷新触发：setter 链 + IOPS 电源变化通知（事件驱动）+ 30s 兜底轮询。**边充边掉都会实时变。**
* **信号数字 = 格数 / 总格数**：`numberOfActiveBars / numberOfBars`（总格数取不到时按 4 格算）。
* 视频里的 `50` / `16` 只是示意图的占位数字，本补丁不写死任何值。

## 2. 动画

| 时机 | 效果 | 时长 |
|---|---|---|
| 数字出现 / 消失（开关切换、信号丢失） | 缺口 + 数字淡入淡出 | 0.28s |
| 数值变化（比如 88 → 87） | 旧数字上滚淡出、新数字从下淡入 | 0.20s |

动画由 view 自己在动画期间 `setNeedsDisplay` 驱动重绘，只在状态变化的那 0.2~0.3 秒发生，其余时间零开销。

## 3. 逆向结论（CAiPhoneDuoStatus 1.5.10，arm64/arm64e）

插件用 `MSHookMessageEx` 挂了 **49 个方法**，其中 **7 个类** 的 `drawRect:` 被换成它自己的圆环绘制：

```
STUIStatusBarCellularSignalView        drawRect:  -> 0x4e8c   (信号环, 走 0x83b4)
_UIStatusBarCellularSignalView         drawRect:  -> 0x50c0
STUIStatusBarDualCellularSignalView    drawRect:  -> 0x52f4   (双卡合成环)
_UIStatusBarDualCellularSignalView     drawRect:  -> 0x5434
_UIBatteryView                         drawRect:  -> 0x59d4   (电量环, 走 0x88e4)
STUIStatusBarStaticBatteryView         drawRect:  -> 0x5d4c
_UIStaticBatteryView                   drawRect:  -> 0x60c4
```

* 信号环的进度：`[关联对象 numberOfActiveBars]`（关联 key = 插件镜像 base+0x10660）
* 电量环的进度：`[view chargePercent]`
* 每个 view 还有 `base+0x10648` 上的一个 `NSNumber` 决定"要不要画环"（插件内部 `0x835c` 判定）

圆环几何（从 `0x88e4` / `0x83b4` 逐条指令还原，常量表在 `__TEXT,__const`）：

```
lineWidth = max(0.105 * min(w, h), 1.0)        // 0.105
radius    = min(w, h)/2 - 0.7 * lineWidth      // -0.7
startAngle = 163.8°,  sweep = 212.4°           // 角度体系 y 向下, 90° = 正下方
=> 弧线从"8 点钟"顺时针经 12 点到"3 点半", 缺口在正下方(4 个圆点 = 信号格)
=> 12 点方向 = 1.5π, 本补丁就在这个角度开口
```

* WiFi 视图只挂了 `layoutSubviews` / `setNumberOfActiveBars:` / `setHidden:`，**没有 `drawRect:`，所以 WiFi 图标没有圆环**，也就没有数字。
* 数字颜色取插件自己的 `bodyColor` → `tintColor` → 圆环描边色，亮/暗色状态栏自动跟随。

## 4. 实现方式（不改插件本体）

```
SpringBoard 调 [view drawRect:]
        └─> [我们的实现]  ← 延迟 1.5s 安装, 保证"原实现"= 插件的圆环绘制
                 ├─ 调用原实现                      → 圆环 + 4 点 照旧
                 └─ 再在同一个 CGContext 上:
                      · kCGBlendModeClear 描一段 2×线宽的弧  → 12 点挖透明缺口
                      · 用 bodyColor 画数字(圆心落在圆环走线上)
```

额外保护：`drlPluginLoaded()` 检测 `CAiPhoneDuoStatus` 是否已加载，没加载就完全不画
（避免插件没生效时去动系统原生电量图标）。

## 5. 编译（arm64e / fat / rootless 三种都给了）

**GitHub Actions**（推荐，无需本地环境）：把工程目录推到一个仓库 → Actions 跑完 → 下载 artifact `DuoRingReadout-debs`，里面有：

| 产物 | 说明 |
|---|---|
| `DuoRingReadout_arm64e.deb` | **只编 arm64e**（普通越狱 rootful，A12+ 设备） |
| `DuoRingReadout_fat_arm64_arm64e.deb` | fat：arm64 + arm64e，两种设备都能装 |
| `DuoRingReadout_arm64e_rootless.deb` | arm64e + rootless 目录结构（Dopamine / palera1n 新版等） |

工作流里做了三件关键事（之前漏了第 2 条，所以 arm64e 容易编不出来）：
1. `git clone --recursive theos`
2. **`git clone https://github.com/theos/sdks.git $THEOS/sdks`** —— arm64e 编译必须用 theos/sdks 里打过补丁的 SDK
3. 每次 `make package ARCHS="..."` 显式指定架构，并在最后用 `lipo -info` 打印每个包里 dylib 的架构（Actions 日志里可核对）

**本机编译**（越狱设备装了 Theos）：

```bash
make clean package ARCHS="arm64e" FINALPACKAGE=1
# fat:
make clean package ARCHS="arm64 arm64e" FINALPACKAGE=1
# rootless:
make clean package ARCHS="arm64e" THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
```

嫌慢就只编一个架构（Makefile 里 `ARCHS` 改成 `arm64e`）。产出的 deb 在 `packages/`。

## 6. 安装 / 验证

1. Sileo 安装 deb（依赖 `ellekit`），respring。
2. 日志过滤 `[DuoReadout]` 应看到 7 个类的 hook 结果 + `live battery = xx%`。
3. 配置：`/var/mobile/Library/Preferences/com.callassist.duoringreadout.plist`（首次运行自动生成，Filza 改完 respring）。
   常用：`sizeFactor` 调字号、`numberPrimary` 改成 `signal` 就让主卡环显示信号而不是电量。

## 7. 已知边界

* 数字只出现在**插件画了圆环的项**上（蜂窝/双卡信号、电量）；WiFi、运营商文字没有环。
* 主卡/副卡的判定依赖双卡容器的 `topSignalView`；万一某机型没有，会退化成"同一层里最靠上那个当主卡"。
* 若插件只给"双卡合成环"画了环、没给主/副卡分别画，本补丁会把主卡那份数字自动放到合成环上（3 秒后生效），
  免得电量数字完全不出现。
* 主卡环显示电量时，**环的填充仍然表示该卡信号**（填充是插件画的），只有数字是电量。
  想让填充和数字同源，就把 `numberPrimary` 设成 `signal`。

---
解析脚本与中间产物：`/var/minis/workspace/duo/`（帧差分析、圆环拟合、stub 解码、hook 表还原）。
