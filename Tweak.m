// 抖音优化交流版 去授权 Hook (ellekit) - rootless
// 注入 com.ss.iphone.ugc.Aweme
// 运行时遍历 ObjC 类，hook SVIP/解锁 getter 返回 YES。
// 遍历放后台线程，避免阻塞启动导致 watchdog 杀(0x8BADF00D)。
#import <substrate.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define LOGFILE "/var/mobile/Documents/sjjunlock.log"

static void wlog(const char* s) {
    FILE* f = fopen(LOGFILE, "a");
    if (f) { fprintf(f, "%s\n", s); fclose(f); }
}
static void wlogf(const char* fmt, ...) {
    char b[1024]; va_list ap;
    va_start(ap, fmt); vsnprintf(b, sizeof(b), fmt, ap); va_end(ap);
    wlog(b);
}

static const char* unlockSelectors[] = {
    "isAliasSVIPUnlocked",
    "isPearModelPickerUnlocked",
    "isSVIPUnlocked",
    "isVipUnlocked",
    "sjj_isUnlocked",
    "sjjStatusUnlocked",
    NULL
};

static BOOL returnYES(id self, SEL _cmd) { return YES; }

static void doHookScan(void) {
    int nc = objc_getClassList(NULL, 0);
    if (nc <= 0) { wlog("[SJJ-unlock] no classes"); return; }
    Class* cls = (Class*)malloc(sizeof(Class) * (unsigned)nc);
    int got = objc_getClassList(cls, nc);
    wlogf("[SJJ-unlock] scanning %d classes", got);

    // 预注册 selector，避免循环内反复 register
    SEL sels[8]; int nsel = 0;
    for (int k = 0; unlockSelectors[k] && nsel < 8; k++)
        sels[nsel++] = sel_registerName(unlockSelectors[k]);

    int hooked = 0;
    for (int i = 0; i < got; i++) {
        for (int k = 0; k < nsel; k++) {
            Method m = class_getInstanceMethod(cls[i], sels[k]);
            if (!m) m = class_getClassMethod(cls[i], sels[k]);
            if (m) {
                static IMP orig[64];
                if (hooked >= 64) { free(cls); wlogf("[SJJ-unlock] capped at %d", hooked); return; }
                orig[hooked] = method_getImplementation(m);
                MSHookMessageEx(cls[i], sels[k], (IMP)returnYES, &orig[hooked]);
                wlogf("[SJJ-unlock] hooked %s on %s", unlockSelectors[k], class_getName(cls[i]));
                hooked++;
            }
        }
    }
    free(cls);
    wlogf("[SJJ-unlock] DONE total=%d", hooked);
}

__attribute__((constructor))
static void ctor(void) {
    // 清空日志
    fclose(fopen(LOGFILE, "w"));
    wlog("[SJJ-unlock] start");
    // 后台线程扫描, 不阻塞启动
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        @autoreleasepool { doHookScan(); }
    });
}
