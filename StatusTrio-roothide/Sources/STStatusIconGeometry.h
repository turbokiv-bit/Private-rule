// STStatusIconGeometry.h — 借鉴自 StatusTrio 的 StatusIconGeometry.swift
// 全部为纯 CoreGraphics 几何路径，跨平台（macOS/iOS），原样移植。

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface STStatusIconGeometry : NSObject

// 画布
+ (CGRect)canvas;

// 电池轨道（整圈）
+ (CGPathRef)batteryTrackWithTopGap:(BOOL)hasTopGap topGapWidth:(CGFloat)topGapWidth;
// 电池填充（按 progress 0~1）
+ (CGPathRef)batteryFillProgress:(CGFloat)progress hasTopGap:(BOOL)hasTopGap topGapWidth:(CGFloat)topGapWidth;
// 充电闪电
+ (CGPathRef)batteryChargingBoltWithScale:(CGFloat)scale;

// WiFi 弧线（level 0~3），返回路径数组（CFArrayRef of CGPathRef）
+ (CFArrayRef)wifiArcsLevel:(NSInteger)level;
+ (CGPathRef)wifiDot;
+ (CGPathRef)wifiOffSlash;

// 音量点（4 个点 + 半径）
+ (CFArrayRef)volumeDotPoints;
+ (CGFloat)volumeDotRadius;

// 电池数值基线（放数字的位置）
+ (CGPoint)batteryValueBaselineFontSize:(CGFloat)fontSize;
+ (CGFloat)batteryValueBaseFontSize;

@end

NS_ASSUME_NONNULL_END