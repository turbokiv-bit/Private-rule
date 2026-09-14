// STStatusIconRenderer.h — 借鉴自 StatusTrio StatusIconRenderer.swift
// 把合成图标画成一张 UIImage，挂到状态栏视图上。

#import <UIKit/UIKit.h>
#import "STStatusSnapshot.h"
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, STBatteryColorRole) {
    STBatteryColorRoleForeground = 0,
    STBatteryColorRoleCritical,
    STBatteryColorRoleLowPower,
    STBatteryColorRoleCharging,
};

@interface STStatusIconRenderer : NSObject

// 渲染一张合成图标（借鉴 StatusTrio 的 render(image)）
// snapshot: 数据; size: 逻辑点尺寸; scale: 屏幕 scale; foreground: 前景色
+ (UIImage *)renderSnapshot:(STStatusSnapshot)snapshot
                       size:(CGFloat)size
                      scale:(CGFloat)scale
                  foreground:(UIColor *)foreground
                       showVolume:(BOOL)showVolume;

// 状态映射（借鉴 StatusMappings）
+ (NSInteger)wifiBarsForRSSI:(NSInteger)rssi;
+ (NSInteger)volumeStepsScalar:(CGFloat)scalar isMuted:(BOOL)isMuted;
+ (STBatteryColorRole)batteryColorRoleForStatus:(STBatteryStatus)battery
                               criticalThreshold:(NSInteger)threshold;
+ (CGFloat)batteryProgress:(STBatteryStatus)battery;
+ (UIColor *)colorForRole:(STBatteryColorRole)role foreground:(UIColor *)foreground darkPalette:(BOOL)dark;

@end

NS_ASSUME_NONNULL_END