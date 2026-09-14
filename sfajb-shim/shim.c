/*
 * sfajb-roothelper launcher shim  (for sing-box for iOS, jailbroken build)
 *
 * 背景:
 *   iOS 的 jetsam 表 (/System/Library/LaunchDaemons/com.apple.jetsamproperties.<model>.plist)
 *   给每个区段 (Daemon / Extension / XPCService) 的 "Global" 默认值只有
 *       ActiveSoftMemoryLimit = 6, InactiveHardMemoryLimit = 6, JetsamPriority = 3
 *   凡是没被单独登记的进程名都吃这 6 MB 限额。
 *   sfajb-roothelper 是 Swift + libbox(Foundation/Library.framework) 的进程,
 *   启动就要几十 MB -> 一起来就撞 6 MB 的 fatal 限额, 被 jetsam 以
 *   per-process-limit 杀掉 (报告里 rpages=384 = 6.00 MiB)。
 *
 * 这个 shim 做的事:
 *   它自己只有 ~1MB, 能在 6MB 内启动完; 启动后第一件事就是以 root 身份
 *   调用 kern.memorystatus_control 把自己的 jetsam 限额抬高(并可提优先级),
 *   然后 execv() 真正的 helper。
 *   execv 不会换掉 Mach task, 所以抬高后的限额对真身继续有效。
 *
 * 用法:
 *   A) 首选: 改启动它的 launchd plist, ProgramArguments 指向本 shim (真身原地不动)
 *   B) 或者: 把原文件改名成 sfajb-roothelper.real, 把 shim 放到它的位置上
 *            (shim 会自动 exec 同目录的 <自己>.real)
 *
 * 编译 (需要 iOS SDK; 用你现有的 GitHub Actions / Theos 链):
 *   xcrun -sdk iphoneos clang -arch arm64 -arch arm64e -O2 -fno-stack-protector \
 *     -o sfajb-roothelper-shim shim.c
 * 签名 (保留原 helper 的 entitlements, 否则 root 身份/无沙盒会丢):
 *   ldid -e sfajb-roothelper > ent.plist
 *   ldid -Sent.plist sfajb-roothelper-shim
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <mach-o/dyld.h>
#include <sys/sysctl.h>
#include <stdint.h>

/* ---- bsd/sys/kern_memorystatus.h (私有) 里的常量, 直接内联 ---- */
#define MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT   6   /* active=inactive=limit, fatal */
#define MEMORYSTATUS_CMD_GRP_SET_PROPERTIES      100 /* 设 jetsam 优先级 */

typedef struct {
    int32_t  pid;
    int32_t  priority;
    uint64_t user_data;
    int32_t  limit;   /* MB */
    uint32_t state;
} memorystatus_priority_entry_t;

extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags,
                                void *buffer, size_t buffersize);

#define NEW_LIMIT_MB   256   /* 想更保守就改 128 */
#define NEW_PRIORITY   14    /* 参考 com.apple.nesessionmanager; 3 = 默认后台 */

static void raise_jetsam_limits(void)
{
    pid_t me = getpid();

    /* 1) 把自己 active+inactive 的 fatal 限额一起抬上去 */
    if (memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT,
                             me, (uint32_t)NEW_LIMIT_MB, NULL, 0) != 0) {
        fprintf(stderr, "[shim] set task limit failed: %s\n", strerror(errno));
    }

    /* 2) 顺便把优先级从默认 3 抬到 14, 免得在低内存时第一个被挑中 */
    memorystatus_priority_entry_t e;
    memset(&e, 0, sizeof(e));
    e.pid = me;
    e.priority = NEW_PRIORITY;
    if (memorystatus_control(MEMORYSTATUS_CMD_GRP_SET_PROPERTIES, 0, 0,
                             &e, sizeof(e)) != 0) {
        fprintf(stderr, "[shim] set priority failed: %s\n", strerror(errno));
    }
}

int main(int argc, char *argv[], char *envp[])
{
    (void)argc; (void)envp;
    raise_jetsam_limits();

    /* 自己路径 + ".real" = 真正的 helper */
    char self[4096], real[4160];
    uint32_t sz = sizeof(self);
    if (_NSGetExecutablePath(self, &sz) != 0) {
        fprintf(stderr, "[shim] cannot resolve own path\n");
        return 127;
    }
    snprintf(real, sizeof(real), "%s.real", self);

    execv(real, argv);                     /* 同 task, 限额保留 */
    fprintf(stderr, "[shim] execv %s: %s\n", real, strerror(errno));
    return 127;
}
