// 抖音优化交流版 去授权 Hook (ellekit)
// 注入 com.ss.iphone.ugc.Aweme
// 策略：运行时遍历所有 ObjC 类，找到 SVIP/解锁相关的 getter，hook 返回"已解锁"
// 无需预知类名，覆盖所有功能的 SVIP/解锁判定。
#import <substrate.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// 要 hook 并强制返回 YES 的解锁类方法名（getter，返回 BOOL）
static const char* unlockSelectors[] = {
    "isAliasSVIPUnlocked",
    "isPearModelPickerUnlocked",
    "isSVIPUnlocked",
    "isVipUnlocked",
    "sjj_isUnlocked",
    "sjjStatusUnlocked",
    NULL
};

// 记录 orig IMP (用全局 map 简单实现: 每个 selector 一份 orig)
static IMP s_origIMP[16] = {0};

// 通用"恒返回 YES"的替代实现
static BOOL returnYES(id self, SEL _cmd) {
    return YES;
}

__attribute__((constructor))
static void ctor(void) {
    @autoreleasepool {
        int nc = objc_getClassList(NULL, 0);
        if (nc <= 0) return;
        Class* cls = (Class*)malloc(sizeof(Class) * (unsigned)nc);
        int got = objc_getClassList(cls, nc);

        int slot = 0;
        for (int i = 0; i < got; i++) {
            Class c = cls[i];
            for (int k = 0; unlockSelectors[k] != NULL; k++) {
                SEL sel = sel_registerName(unlockSelectors[k]);
                Method m = class_getInstanceMethod(c, sel);
                if (!m) m = class_getClassMethod(c, sel);
                if (m && slot < 16) {
                    // 记录原 IMP 并 hook
                    s_origIMP[slot] = method_getImplementation(m);
                    MSHookMessageEx(c, sel, (IMP)returnYES, &s_origIMP[slot]);
                    NSLog(@"[SJJ-unlock] hooked %s on class %s", unlockSelectors[k], class_getName(c));
                    slot++;
                }
            }
        }
        free(cls);
        NSLog(@"[SJJ-unlock] done, hooked %d methods", slot);
    }
}
