// StatusProviders/STWiFiProvider.m
// iOS 状态栏的 WiFi 信号强度由 SpringBoard 的 _UIStatusBarDataNetworkItem
// 提供；这里通过状态栏服务取 signalStrengthBars，再映射回近似 RSSI。
// 稳健做法：直接用 CWInterface（公开 CoreWLAN 不存在于 iOS），
// 故本 provider 读取 SpringBoard 的 WiFi 私有管理器。

#import "STWiFiProvider.h"
#import "STStatusIconRenderer.h"

// SpringBoard 的 WiFiManager 单例（私有类，运行期动态查找，避免编译期符号依赖）
// 类名: SBWiFiManager / WiFiManager。这里用 objc runtime 动态 get。

#import <objc/runtime.h>
#import <objc/message.h>

@implementation STWiFiProvider

static id _wifiManager(void) {
    // 尝试多个已知类名，SpringBoard 进程内才存在
    NSArray *names = @[@"SBWiFiManager", @"WiFiManager", @"WFClient"];
    for (NSString *n in names) {
        Class cls = NSClassFromString(n);
        if (cls) {
            id shared = nil;
            SEL sharedSel = NSSelectorFromString(@"sharedInstance");
            if ([cls respondsToSelector:sharedSel]) {
                shared = ((id(*)(id,SEL))objc_msgSend)(cls, sharedSel);
            } else {
                shared = [cls new];
            }
            if (shared) return shared;
        }
    }
    return nil;
}

+ (STWiFiStatus)currentStatus {
    STWiFiStatus s;
    s.state = STWiFiStateUnavailable;
    s.rssi = 0;
    s.bars = 0;

    id mgr = _wifiManager();
    if (!mgr) return s;

    // 是否开启 WiFi
    if ([mgr respondsToSelector:NSSelectorFromString(@"wifiEnabled")]) {
        NSNumber *enabled = ((id(*)(id,SEL))objc_msgSend)(mgr, NSSelectorFromString(@"wifiEnabled"));
        if (enabled && ![enabled boolValue]) {
            s.state = STWiFiStateOff;
            return s;
        }
    }

    // 是否已关联网络
    if ([mgr respondsToSelector:NSSelectorFromString(@"isAssociated")]) {
        NSNumber *assoc = ((id(*)(id,SEL))objc_msgSend)(mgr, NSSelectorFromString(@"isAssociated"));
        if (assoc && ![assoc boolValue]) {
            s.state = STWiFiStateNotAssociated;
            return s;
        }
    }

    // 信号强度（不同版本返回类型不同：NSNumber dBm 或 0-3 条）
    NSInteger rssiDbm = 0;
    if ([mgr respondsToSelector:NSSelectorFromString(@"RSSI")]) {
        id r = ((id(*)(id,SEL))objc_msgSend)(mgr, NSSelectorFromString(@"RSSI"));
        if ([r isKindOfClass:[NSNumber class]]) {
            rssiDbm = [r integerValue];
        }
    } else if ([mgr respondsToSelector:NSSelectorFromString(@"signalStrength")]) {
        id r = ((id(*)(id,SEL))objc_msgSend)(mgr, NSSelectorFromString(@"signalStrength"));
        if ([r isKindOfClass:[NSNumber class]]) rssiDbm = [r integerValue];
    }

    s.state = STWiFiStateConnected;
    s.rssi = rssiDbm;
    s.bars = [STStatusIconRenderer wifiBarsForRSSI:rssiDbm];
    return s;
}

@end