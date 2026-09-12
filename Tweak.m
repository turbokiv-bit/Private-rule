// 抖音优化交流版 去授权 Hook (ellekit) - rootless
// 注入 com.ss.iphone.ugc.Aweme
// 注入 com.ss.iphone.ugc.Aweme (rootless)
// hook 后台线程扫描; 日志双落盘 /tmp + /var/mobile/Documents
#import <substrate.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

#define LOG1 "/tmp/sjjunlock.log"
#define LOG2 "/var/mobile/Documents/sjjunlock.log"

static void wlog(const char* s) {
    FILE* f = fopen(LOG1, "a");
    if (f) { fprintf(f, "%s\n", s); fclose(f); }
    f = fopen(LOG2, "a");
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
    NULL
};

static BOOL returnYES(id self, SEL _cmd) { return YES; }

static void doHookScan(void) {
    int nc = objc_getClassList(NULL, 0);
    if (nc <= 0) { wlog("[SJJ-unlock] no classes"); return; }
    Class* cls = (Class*)malloc(sizeof(Class) * (unsigned)nc);
    int got = objc_getClassList(cls, nc);
    wlogf("[SJJ-unlock] scanning %d classes", got);

    SEL sels[8]; int nsel = 0;
    for (int k = 0; unlockSelectors[k] && nsel < 8; k++)
        sels[nsel++] = sel_registerName(unlockSelectors[k]);

    static IMP orig[64];
    int hooked = 0;
    for (int i = 0; i < got; i++) {
        for (int k = 0; k < nsel; k++) {
            Method m = class_getInstanceMethod(cls[i], sels[k]);
            if (!m) m = class_getClassMethod(cls[i], sels[k]);
            if (m && hooked < 64) {
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

// 标准初始化入口。MSInitialize 宏在不同 substrate 版本展开不同，这里用最朴素通用的 constructor。
// 注意：扫描已移到后台线程，不会阻塞启动(避免 0x8BADF00D 看门狗杀)。
__attribute__((constructor))
static void SjjInit(void) {
    FILE* f = fopen(LOG1, "w"); if (f) fclose(f);
    f = fopen(LOG2, "w"); if (f) fclose(f);
    wlog("[SJJ-unlock] init");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        @autoreleasepool { doHookScan(); }
    });
}
