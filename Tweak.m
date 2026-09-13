// ============================================================================
// 抖音优化交流版 · 纯 ElleKit 去授权 Hook (UID 层 + SVIP 层全解锁)
// 注入: com.ss.iphone.ugc.Aweme (抖音)
// 目标: 绕过 UID 白名单层(指纹) + SVIP 功能门(isAliasSVIPUnlocked)
// 安装: Sileo 装 (depends: ellekit)。不依赖 TrollFools 注入。
// 说明: 本 hook 试图用一个 deb 完整替代 v5.dylib 的字节补丁。
// ============================================================================
#import <substrate.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// ===== 开关 =====
#define HOOK_FP            1   // hook 指纹函数 0x19213c, 强制全局槽为内置fp(打通UID白名单)
#define HOOK_ISALIAS       1   // swizzle isAliasSVIPUnlocked -> YES(解锁SVIP)
#define HOOK_ISPEAR        1   // swizzle isPearModelPickerUnlocked -> YES
#define VERBOSE_LOG        1

// 授权包内建指纹(交流版 __sjjpkga 明文, 三包共享)
static NSString* const kBuiltinFP = @"b6d1e95f66985a848f1ae0a965c53cf697c64af309e503fdddab5330b37650d3";

// dylib base(处理 ASLR)
static uintptr_t s_base = 0;
static uintptr_t libraryBase(void) {
    if (s_base) return s_base;
    int n = _dyld_image_count();
    for (int i = 0; i < n; i++) {
        const char* name = _dyld_get_image_name(i);
        if (name && strstr(name, "siwenjiajia.dylib")) {
            s_base = (uintptr_t)_dyld_get_image_header(i);
            return s_base;
        }
    }
    return 0;
}
static void* loadAddress_of(uintptr_t off) {
    return (void*)(libraryBase() + off);
}
static void logf(NSString* fmt, ...) {
    if (!VERBOSE_LOG) return;
    va_list ap; va_start(ap, fmt);
    NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[SJJ-bypass] %@", s);
    [s release];
}

#if HOOK_FP
// ---- hook 指纹计算函数 0x19213c (void f(void*, void**)) ----
// 原函数内部把指纹 hex 字符串写进全局槽 (base+0x91de58)。我们调用原函数后覆写该槽。
typedef void (*fp_compute_t)(void*, void**);
static fp_compute_t orig_fp = NULL;
static void hook_fp(void* a0, void** out) {
    orig_fp(a0, out);
    uintptr_t base = libraryBase();
    if (base) {
        // 全局槽 base+0x91de58 存 NSString/NSData; 强制写成包内 fp 字符串
        void** slot = (void**)(base + 0x91de58);
        id prev = *slot;
        *slot = (void*)kBuiltinFP;   // 让比对读到包内 fp
        logf(@"FP slot override -> %@ (old=%p)", kBuiltinFP, (void*)prev);
    }
}
#endif

#if HOOK_ISALIAS || HOOK_ISPEAR
// ---- 运行时 swizzle: 找出实现目标 selector 的所有类, 替换为恒返回 YES ----
typedef BOOL (*BOOL_getter)(id, SEL);
static BOOL retYES(id self, SEL _cmd) { (void)self; (void)_cmd; return YES; }

static void forceBoolGetterYES(SEL sel) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class* buf = (Class*)malloc(sizeof(Class) * (size_t)count);
    objc_getClassList(buf, count);
    for (int i = 0; i < count; i++) {
        Class cls = buf[i];
        // 也要类方法? 目标 getter 一般是实例方法; 这里实例+元类都试
        for (int isMeta = 0; isMeta < 2; isMeta++) {
            Class c = (isMeta) ? objc_getMetaClass(class_getName(cls)) : cls;
            Method m = class_getInstanceMethod(c, sel);
            if (m) {
                method_setImplementation(m, (IMP)retYES);
                logf(@"swizzle %s (meta=%d) -> YES on %s",
                     sel_getName(sel), isMeta, class_getName(cls));
            }
        }
    }
    free(buf);
}
#endif

__attribute__((constructor))
static void ctor(void) {
    @autoreleasepool {
        uintptr_t base = libraryBase();
        if (!base) {
            NSLog(@"[SJJ-bypass] siwenjiajia.dylib not found, abort");
            return;
        }
        NSLog(@"[SJJ-bypass] dylib base = %p", (void*)base);

#if HOOK_FP
        void* fpFn = loadAddress_of(0x19213c);
        MSHookFunction(fpFn, (void*)hook_fp, (void**)&orig_fp);
        logf(@"hooked 0x19213c @ %p", fpFn);
#endif
#if HOOK_ISALIAS
        forceBoolGetterYES(@selector(isAliasSVIPUnlocked));
        // 兼容 arm64e 下手写 sel(无法直接取到 @selector 的越狱环境可用字符串注册)
#endif
#if HOOK_ISPEAR
        forceBoolGetterYES(@selector(isPearModelPickerUnlocked));
#endif
    }
}
