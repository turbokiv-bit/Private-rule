// StatusProviders/STVolumeProvider.m
// 用 SpringBoard 的 AVSystemController 读媒体音量（私有但稳定）。
// 运行时动态调用，避免编译期私有头依赖。

#import "STVolumeProvider.h"
#import <objc/runtime.h>
#import <objc/message.h>

@implementation STVolumeProvider

+ (STVolumeStatus)currentStatus {
    STVolumeStatus s;
    s.isMuted = NO;
    s.isAvailable = NO;
    s.scalar = 0;

    Class avc = NSClassFromString(@"AVSystemController");
    if (!avc) return s;

    id ctrl = nil;
    SEL sharedSel = NSSelectorFromString(@"sharedAVSystemController");
    if ([avc respondsToSelector:sharedSel]) {
        ctrl = ((id(*)(id,SEL))objc_msgSend)(avc, sharedSel);
    }
    if (!ctrl) return s;

    // obtainCurrentVolume: warning: 该方法返回 BOOL，volume 通过 out 参数
    // 原型: - (BOOL)obtainCurrentVolume:(Float32*)volume warning:(BOOL*)warning
    SEL volSel = NSSelectorFromString(@"obtainCurrentVolume:warning:");
    if ([ctrl respondsToSelector:volSel]) {
        Float32 vol = -1;
        BOOL warning = NO;
        Method m = class_getInstanceMethod([ctrl class], volSel);
        BOOL (*fn)(id, SEL, Float32*, BOOL*) = (void *)method_getImplementation(m);
        BOOL ok = fn(ctrl, volSel, &vol, &warning);
        if (ok && vol >= 0 && vol <= 1) {
            s.scalar = vol;
            s.isAvailable = YES;
        }
    }
    return s;
}

@end