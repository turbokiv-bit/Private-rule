// StatusProviders/STBatteryProvider.h
// iOS 私有 API 采集电池状态（替代 macOS 的 IOKit/BatteryMonitor）

#import "STStatusSnapshot.h"
#import <Foundation/Foundation.h>

@interface STBatteryProvider : NSObject

// 采集当前电池状态（私有 IOKit 电源源）
+ (STBatteryStatus)currentStatus;

// 低电量模式（SpringBoard 的 _launchLowPowerMode / NSProcessInfo）
+ (BOOL)isLowPowerMode;

@end