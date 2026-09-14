// StatusProviders/STBatteryProvider.m
// 【重要】绝不能用 [UIDevice setBatteryMonitoringEnabled:]：
//   在 SpringBoard 里它会同步触发 UIKit 电量广播 → SpringBoard 去创建
//   SBUIController/SBIconController → 在 dispatch_once 内递归重入 → abort()。
// 改用 IOKit 的电源源接口（IOPSCopyPowerSourcesInfo），纯读取、无副作用。
// 用 dlsym 动态解析符号，避免链接期符号缺失导致 dylib 加载失败。

#import "STBatteryProvider.h"
#import <UIKit/UIKit.h>
#include <math.h>
#include <dlfcn.h>

typedef CFTypeRef (*STIOPSCopyPowerSourcesInfoFn)(void);
typedef CFArrayRef (*STIOPSCopyPowerSourcesListFn)(CFTypeRef);
typedef CFDictionaryRef (*STIOPSGetPowerSourceDescriptionFn)(CFTypeRef, CFTypeRef);

static STIOPSCopyPowerSourcesInfoFn        pCopyInfo = NULL;
static STIOPSCopyPowerSourcesListFn        pCopyList = NULL;
static STIOPSGetPowerSourceDescriptionFn   pGetDesc  = NULL;
static dispatch_once_t gLoadOnce;

static void STLoadIOPS(void) {
    dispatch_once(&gLoadOnce, ^{
        void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
        if (!h) return;
        pCopyInfo = (STIOPSCopyPowerSourcesInfoFn)dlsym(h, "IOPSCopyPowerSourcesInfo");
        pCopyList = (STIOPSCopyPowerSourcesListFn)dlsym(h, "IOPSCopyPowerSourcesList");
        pGetDesc  = (STIOPSGetPowerSourceDescriptionFn)dlsym(h, "IOPSGetPowerSourceDescription");
    });
}

// IOPSKeys.h 里的键名（字符串常量）
static CFStringRef const kKeyCurrentCapacity = CFSTR("Current Capacity");
static CFStringRef const kKeyMaxCapacity     = CFSTR("Max Capacity");
static CFStringRef const kKeyIsCharging      = CFSTR("Is Charging");
static CFStringRef const kKeyPowerSourceState= CFSTR("Power Source State");
static CFStringRef const kValueACPower       = CFSTR("AC Power");

@implementation STBatteryProvider

+ (STBatteryStatus)currentStatus {
    STBatteryStatus s;
    s.rawPercentage = 100;
    s.isPresent = YES;
    s.isCharging = NO;
    s.isCharged = NO;
    s.isConnectedToPower = NO;
    s.isLowPowerMode = [self isLowPowerMode];

    STLoadIOPS();
    if (!pCopyInfo || !pCopyList || !pGetDesc) return s;

    CFTypeRef blob = pCopyInfo();
    if (!blob) return s;

    CFArrayRef list = pCopyList(blob);
    if (list && CFArrayGetCount(list) > 0) {
        CFTypeRef ps = CFArrayGetValueAtIndex(list, 0);
        CFDictionaryRef d = pGetDesc(blob, ps);
        if (d) {
            int cur = 0, max = 100;
            CFNumberRef nCur = (CFNumberRef)CFDictionaryGetValue(d, kKeyCurrentCapacity);
            CFNumberRef nMax = (CFNumberRef)CFDictionaryGetValue(d, kKeyMaxCapacity);
            if (nCur && CFGetTypeID(nCur) == CFNumberGetTypeID()) CFNumberGetValue(nCur, kCFNumberIntType, &cur);
            if (nMax && CFGetTypeID(nMax) == CFNumberGetTypeID()) CFNumberGetValue(nMax, kCFNumberIntType, &max);

            if (max > 0) {
                s.rawPercentage = (NSInteger)llround(100.0 * (double)cur / (double)max);
                s.isPresent = YES;
            }

            CFBooleanRef bCharging = (CFBooleanRef)CFDictionaryGetValue(d, kKeyIsCharging);
            BOOL charging = (bCharging && CFGetTypeID(bCharging) == CFBooleanGetTypeID())
                            ? CFBooleanGetValue(bCharging) : NO;

            CFStringRef state = (CFStringRef)CFDictionaryGetValue(d, kKeyPowerSourceState);
            BOOL onAC = (state && CFGetTypeID(state) == CFStringGetTypeID())
                        && CFStringCompare(state, kValueACPower, 0) == kCFCompareEqualTo;

            s.isCharging = charging;
            s.isConnectedToPower = charging || onAC;
            s.isCharged = (!charging && onAC && s.rawPercentage >= 100);
        }
    }
    if (list) CFRelease(list);
    CFRelease(blob);
    return s;
}

+ (BOOL)isLowPowerMode {
    // 无副作用：NSProcessInfo 不触发任何 UI 回调
    if ([NSProcessInfo.processInfo respondsToSelector:@selector(isLowPowerModeEnabled)]) {
        return NSProcessInfo.processInfo.isLowPowerModeEnabled;
    }
    return NO;
}

@end
