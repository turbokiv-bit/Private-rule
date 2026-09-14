// StatusProviders/STBatteryProvider.m
// 用公开的 UIDevice API 读取电量与充电状态，稳定无私有依赖。

#import "STBatteryProvider.h"
#import <UIKit/UIDevice.h>

@implementation STBatteryProvider

+ (STBatteryStatus)currentStatus {
    STBatteryStatus s;
    s.rawPercentage = 100;
    s.isPresent = YES;
    s.isCharging = NO;
    s.isCharged = NO;
    s.isLowPowerMode = [self isLowPowerMode];
    s.isConnectedToPower = NO;

    // 用 UIDevice 快速带电量（iOS 8+ 公开）
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    float level = [UIDevice currentDevice].batteryLevel;
    UIDeviceBatteryState state = [UIDevice currentDevice].batteryState;

    if (level >= 0) {
        s.rawPercentage = (NSInteger)llround(level * 100.0f);
        s.isPresent = YES;
    }

    switch (state) {
        case UIDeviceBatteryStateCharging:
            s.isCharging = YES;
            s.isConnectedToPower = YES;
            break;
        case UIDeviceBatteryStateFull:
            s.isCharged = YES;
            s.isConnectedToPower = YES;
            break;
        case UIDeviceBatteryStateUnplugged:
            s.isCharging = NO;
            s.isConnectedToPower = NO;
            break;
        default:
            break;
    }

    return s;
}

+ (BOOL)isLowPowerMode {
    // 首选 NSProcessInfo (iOS 9+)
    if ([NSProcessInfo.processInfo respondsToSelector:@selector(isLowPowerModeEnabled)]) {
        return NSProcessInfo.processInfo.isLowPowerModeEnabled;
    }
    return NO;
}

@end