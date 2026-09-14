# sfajb-roothelper shim

给 **sing-box for iOS 越狱版（SFI-JB）** 的 root helper `sfajb-roothelper`
抬高 jetsam 内存限额的启动壳。编译由 `.github/workflows/build-sfajb-shim.yml` 完成。

## 问题

`sfajb-roothelper`（`io.nekohasekai.sfajb.helper`）是 Swift + libbox 进程，
但 iOS jetsam 表里没登记它，于是吃默认值：

```
/System/Library/LaunchDaemons/com.apple.jetsamproperties.<机型>.plist
  Version4 → Daemon / Extension / XPCService → Override → Global
  = { ActiveSoftMemoryLimit: 6, InactiveHardMemoryLimit: 6, JetsamPriority: 3 }
```

→ 进程 footprint 一过 6 MB 就被 jetsam 以 `per-process-limit` 杀掉
（JetsamEvent 报告里 `rpages = 384` × 16 KB = 精确 6.00 MiB）。
Swift runtime + Foundation + libbox 启动远超 6 MB，所以它一被 spawn 就死。

## 办法

helper 本身以 root 运行，而 `kern.memorystatus_control` 只要求 **uid == 0**
或 `com.apple.private.memorystatus` 权限 —— 所以它能自己抬限额。

用一个极小的 C 壳（footprint ~1 MB）代替它启动：

1. `memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT=6, getpid(), 256, NULL, 0)`
   → active + inactive 的 fatal 限额一起抬到 256 MB
2. `memorystatus_control(MEMORYSTATUS_CMD_GRP_SET_PROPERTIES=100, 0, 0, &entry, sizeof(entry))`
   → jetsam 优先级 3 → 14
3. `execv()` 真身 —— **execv 不更换 Mach task，限额与优先级保留**

## 安装（设备上，root）

找到 helper（通常在 `sing-box.app` 里）：

```sh
find /var/containers/Bundle/Application /var/jb -name 'sfajb-roothelper*' 2>/dev/null
cd <找到的目录>
cp -a sfajb-roothelper /var/mobile/sfajb-roothelper.bak     # 先备份
mv sfajb-roothelper sfajb-roothelper.real
cp <编译产物>/sfajb-roothelper-shim ./sfajb-roothelper
chmod 755 sfajb-roothelper sfajb-roothelper.real
chown 0:0 sfajb-roothelper sfajb-roothelper.real
ldid -Sentitlements.plist sfajb-roothelper                  # 必须带原 entitlements
```

若 launchd 的 plist 可编辑，更干净的做法是让 `ProgramArguments` 指向 shim，
真身留在原处（这样进程名保持 `sfajb-roothelper`）。

## 验证

重开一次隧道后：

```sh
ps -A -o pid,rss,command | grep sfajb      # 应常驻，RSS 上百 MB 也不再被杀
```

如果 `execv` 失败，shim 会往 stderr 打印 `[shim] execv ...: <errno>`。

## 回退

```sh
cd <目录> && rm -f sfajb-roothelper && mv sfajb-roothelper.real sfajb-roothelper
```

## 备注

- `entitlements.plist` 是从原 helper 用 `ldid -e` 提取的，重签必须带，否则丢 root/无沙盒身份。
- 这是权宜之计；正解是在 jetsam 表里给 `sfajb-roothelper` 登记一条
  `Active/InactiveHardMemoryLimit 128~256`（rootless 越狱写不了 `/System`，故改用此法），
  或者反馈给上游 SagerNet/sing-box-for-apple。
