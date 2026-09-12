// 抖音优化交流版 去授权 Hook (ellekit)
// 注入 com.ss.iphone.ugc.Aweme (siwenjiajia.dylib)
// 已确认地址(运行时 = macho基址 + 偏移)：
//   0x19213c  指纹 SHA256 计算函数 -> 结果写全局槽 0x91de58
//   0x366948  授权等级判断 cmp x26,#2 (2=完整授权)
//   0x623bc0  objc_msgSend stub 簇 (查 sjj-package-policy)

#import <substrate.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>

// ===== 开关 =====
#define HOOK_FP          1   // hook 0x19213c, 把全局指纹槽强制写成内置fp
#define HOOK_LEVELB      0   // hook 0x366948 区间强制等级=2 (字节补丁等价, 备用)
#define VERBOSE_LOG      1

// 授权包内置 fp / key (交流版 __sjjpkga 明文, 三包共享)
static NSString* const kBuiltinFPStr = @"b6d1e95f66985a848f1ae0a965c53cf697c64af309e503fdddab5330b37650d3";

static uintptr_t libraryBase(void) {
    int n = _dyld_image_count();
    for (int i = 0; i < n; i++) {
        const char* name = _dyld_get_image_name(i);
        if (name && strstr(name, "siwenjiajia.dylib")) {
            return (uintptr_t)_dyld_get_image_header(i);
        }
    }
    return 0;
}

#if HOOK_FP
// ---- hook 指纹计算 0x19213c: void* f(void* input, void** out) ----
static void* (*orig_computeFP)(void*, void**) = NULL;
static void* hook_computeFP(void* a0, void** a1) {
    void* r = orig_computeFP(a0, a1);
    // 原函数把指纹写进全局槽 0x91de58 (运行时 = base+0x91de58), 覆盖为内置fp
    uintptr_t base = libraryBase();
    if (base) {
        id* slot = (id*)(base + 0x91de58);
        id prev = *slot;
        *slot = kBuiltinFPStr;
        if (VERBOSE_LOG) NSLog(@"[SJJ-bypass] FP override slot=%@ (old=%@)", kBuiltinFPStr, prev);
    }
    return r;
}
#endif

#if HOOK_LEVELB
// ---- hook 授权等级路径使 x26=2 (字节补丁等价)。0x366948 cmp x26,#2
// 实际用 MSHookFunction 改 0x36694c b.eq->b(无条件), 但不构造完整函数,
// 直接在 offset 写一段 stub 不现实; 此开关预留, 主要靠 hook 上层。
#endif

__attribute__((constructor))
static void ctor(void) {
    @autoreleasepool {
        uintptr_t base = libraryBase();
        if (!base) {
            NSLog(@"[SJJ-bypass] siwenjiajia.dylib not found");
            return;
        }
        NSLog(@"[SJJ-bypass] dylib base = %p", (void*)base);

#if HOOK_FP
        void* f = (void*)(base + 0x19213c);
        MSHookFunction(f, (void*)hook_computeFP, (void**)&orig_computeFP);
        if (VERBOSE_LOG) NSLog(@"[SJJ-bypass] hooked 0x19213c @ %p", f);
#endif
    }
}
