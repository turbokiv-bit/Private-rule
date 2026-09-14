// StatusProviders/STWiFiProvider.h
// 通过 SpringBoard 私有 WiFiManager 获取信号强度（替代 macOS CoreWLAN）

#import "STStatusSnapshot.h"
#import <Foundation/Foundation.h>

@interface STWiFiProvider : NSObject

// 返回当前 WiFi 状态；rssi 为 dBm（近似，可为 0）
// 内部优先走 SpringBoard 的 WiFiManager 私有 API；不可用时回落到 0。
+ (STWiFiStatus)currentStatus;

@end