// 抖音优化交流版 去授权 Hook (ellekit)
// 注入 com.ss.iphone.ugc.Aweme (siwenjiajia.dylib)
#import <substrate.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

#define HOOK_FP          1
#define VERBOSE_LOG      1

static NSString* const kBuiltinFPStr = @"b6d1e95f66985a848f1ae0a965c53cf697c64af309e503fdddab5330b37650d3";

static uintptr_t libraryBase(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char* name = _dyld_get_image_name(i);
        if (name && strstr(name, "siwenjiajia.dylib")) {
            return (uintptr_t)_dyld_get_image_header(i);
        }
    }
    return 0;
}

#if HOOK_FP
static void* (*orig_computeFP)(void*, void**) = NULL;
static void* hooked_computeFP(void* a0, void** a1) {
    void* r = orig_computeFP(a0, a1);
    uintptr_t base = libraryBase();
    if (base) {
        // 全局指纹槽 0x91de58，运行时 = base + 0x91de58
        uintptr_t slotAddr = base + 0x91de58;
        // 直接写内存：把 slot 处的 8 字节覆盖为 fp 字符串对象指针
        // 先转成裸 void*（POD），再用 memcpy 写槽，规避 ARC 限制
        uintptr_t target = (uintptr_t)(__bridge void*)kBuiltinFPStr;
        memcpy((void*)slotAddr, &target, sizeof(target));
        if (VERBOSE_LOG) NSLog(@"[SJJ-bypass] FP override -> %@", kBuiltinFPStr);
    }
    return r;
}
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
        MSHookFunction(f, (void*)hooked_computeFP, (void**)&orig_computeFP);
        if (VERBOSE_LOG) NSLog(@"[SJJ-bypass] hooked 0x19213c @ %p", f);
#endif
    }
}
