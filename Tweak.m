// ============================================================================
// 抖音优化交流版 · 纯 ElleKit 去授权 Hook (UID 层 + SVIP 层全解锁)
// 注入: com.ss.iphone.ugc.Aweme (抖音)
// 安装: Sileo 装 (depends: ellekit)。不依赖 TrollFools 注入。
// ============================================================================
#import <substrate.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>          // _dyld_image_count / _dyld_get_image_header

// ===== 开关 =====
#define HOOK_FP            1   // 指纹函数 0x19213c 覆写全局槽 -> 打通 UID 白名单
#define HOOK_ISALIAS       1   // swizzle isAliasSVIPUnlocked -> YES (SVIP)
#define HOOK_ISPEAR        1   // swizzle isPearModelPickerUnlocked -> YES
#define VERBOSE_LOG        1

// 授权包内建指纹(交流版 __sjjpkga 明文, 三包共享)
static NSString* const kBuiltinFP = @"b6d1e95f66985a848f1ae0a965c53cf697c64af309e503fdddab5330b37650d3";

// dylib base(处理 ASLR)
static uintptr_t s_base = 0;
static uintptr_t libraryBase(void) {
    if (s_base) return s_base;
    int n = (int)_dyld_image_count();
    for (int i = 0; i < n; i++) {
        const char* name = _dyld_get_image_name(i);
        if (name && strstr(name, "siwenjiajia.dylib")) {
            s_base = (uintptr_t)_dyld_get_image_header(i);
            return s_base;
        }
    }
    return 0;
}

static void sjlog(NSString* fmt, ...) {
#if VERBOSE_LOG
    va_list ap; va_start(ap, fmt);
    NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[SJJ-bypass] %@", s);
#endif
}

#if HOOK_FP
// ---- hook 指纹计算函数 0x19213c (void f(void*, void**)) ----
// 原函数把指纹 hex 字符串写进全局槽 (base+0x91de58)。调用后覆写为包内 fp。
typedef void (*fp_compute_t)(void*, void**);
static fp_compute_t orig_fp = NULL;
static void hook_fp(void* a0, void** out) {
    orig_fp(a0, out);
    uintptr_t base = libraryBase();
    if (base) {
        void** slot = (void**)(base + 0x91de58);
        *slot = (__bridge void*)kBuiltinFP;
        sjlog(@"FP slot override -> %@", kBuiltinFP);
    }
}
#endif

#if HOOK_ISALIAS || HOOK_ISPEAR
// ---- 运行时 swizzle: 找出实现目标 selector 的类, 替换实现为恒返回 YES ----
static BOOL retYES(id self, SEL _cmd) { (void)self; (void)_cmd; return YES; }

static void forceBoolGetterYES(SEL sel) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class* buf = (Class*)malloc(sizeof(Class) * (size_t)count);
    if (!buf) return;
    objc_getClassList(buf, count);
    for (int i = 0; i < count; i++) {
        Class cls = buf[i];
        if (!cls) continue;
        Class target = cls;
        // 实例方法 + 元类(类方法)
        Method m = class_getInstanceMethod(target, sel);
        if (!m) { target = object_getClass((id)cls); m = class_getInstanceMethod(target, sel); }
        if (m) {
            method_setImplementation(m, (IMP)retYES);
            sjlog(@"swizzle %s -> YES on %s", sel_getName(sel), class_getName(target));
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
        void* fpFn = (void*)(base + 0x19213c);
        MSHookFunction(fpFn, (void*)hook_fp, (void**)&orig_fp);
        sjlog(@"hooked 0x19213c @ %p", fpFn);
#endif
#if HOOK_ISALIAS
        forceBoolGetterYES(@selector(isAliasSVIPUnlocked));
#endif
#if HOOK_ISPEAR
        forceBoolGetterYES(@selector(isPearModelPickerUnlocked));
#endif
    }
}