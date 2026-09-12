// 抖音优化交流版 去授权 Hook (ellekit)
// 注入 com.ss.iphone.ugc.Aweme
// 运行时遍历所有 ObjC 类，找到 SVIP/解锁 getter，hook 返回 YES
// 结果落盘 /var/mobile/Documents/sjjunlock.log，Filza 直接打开看
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

static IMP s_origIMP[64] = {0};
static BOOL returnYES(id self, SEL _cmd) { return YES; }

__attribute__((constructor))
static void ctor(void) {
    @autoreleasepool {
        // 清空日志
        fclose(fopen(LOGFILE, "w"));
        wlog("[SJJ-unlock] start");

        int nc = objc_getClassList(NULL, 0);
        wlogf("[SJJ-unlock] total classes: %d", nc);
        if (nc <= 0) return;
        Class* cls = (Class*)malloc(sizeof(Class) * (unsigned)nc);
        int got = objc_getClassList(cls, nc);

        int slot = 0;
        for (int selIdx = 0; unlockSelectors[selIdx] != NULL; selIdx++) {
            const char* sname = unlockSelectors[selIdx];
            SEL sel = sel_registerName(sname);
            // 先记录所有匹配的类名
            for (int i = 0; i < got; i++) {
                Method m = class_getInstanceMethod(cls[i], sel);
                if (!m) m = class_getClassMethod(cls[i], sel);
                if (m && slot < 64) {
                    s_origIMP[slot] = method_getImplementation(m);
                    MSHookMessageEx(cls[i], sel, (IMP)returnYES, &s_origIMP[slot]);
                    wlogf("[SJJ-unlock] hooked %s on %s (slot %d)", sname, class_getName(cls[i]), slot);
                    slot++;
                }
            }
            wlogf("[SJJ-unlock] selector %s scan done", sname);
        }
        free(cls);
        wlogf("[SJJ-unlock] DONE, total hooked = %d", slot);
    }
}
