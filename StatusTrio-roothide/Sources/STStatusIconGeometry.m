// STStatusIconGeometry.m — 从 StatusTrio StatusIconGeometry.swift 移植
// 几何常量与路径完全保留，仅把 Swift 换成 ObjC。

#import "STStatusIconGeometry.h"

static const CGFloat kRadius = 51.5;
static const CGPoint kCenter = {59.5, 61.48715261785473};
static const CGFloat kStart = 148.69008689281117f * M_PI / 180.0f;
static const CGFloat kSweep = 242.6198262143777f * M_PI / 180.0f;

static const CGFloat kTopGapValue = 64.0f;
static const CGFloat kTopGapBolt = 50.0f;
static const CGFloat kBaseFontSize = 20.0f;
static const CGFloat kBoltCalibration = 220.0f / 180.0f;

// WiFi
static const CGPoint kWifiOuterCenter = {59.5, 78.3};
static const CGFloat kWifiOuterRadius = 31.0f;
static const CGFloat kWifiOuterStart = 227.35f * M_PI / 180.0f;
static const CGFloat kWifiOuterEnd = 312.65f * M_PI / 180.0f;
static const CGPoint kWifiMiddleCenter = {59.5, 78.89};
static const CGFloat kWifiMiddleRadius = 18.5f;

// 音量点
static const CGPoint kVolumeDots[] = {
    {33, 104.2}, {50.5, 111.2}, {68.5, 111.7}, {86, 105.8}
};
static const CGFloat kVolumeDotRadius = 5.5f;

@implementation STStatusIconGeometry

+ (CGRect)canvas {
    return CGRectMake(0, 0, 120, 120);
}

#pragma mark - 辅助弧
+ (CGPathRef)arcWithCenter:(CGPoint)center radius:(CGFloat)radius start:(CGFloat)start end:(CGFloat)end {
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddArc(path, NULL, center.x, center.y, radius, start, end, false);
    return CGPathCreateCopy(path);
}

+ (CGPathRef)batteryArcWithProgress:(CGFloat)progress hasTopGap:(BOOL)hasTopGap topGapWidth:(CGFloat)topGapWidth {
    if (!hasTopGap) {
        CGFloat end = kStart + kSweep * progress;
        return [self arcWithCenter:kCenter radius:kRadius start:kStart end:end];
    }
    CGFloat gapFraction = fmin(1, fmax(0, (double)(topGapWidth / (kRadius * kSweep))));
    CGFloat gapStartProgress = 0.5f - gapFraction / 2.0f;
    CGFloat gapEndProgress = 0.5f + gapFraction / 2.0f;
    CGMutablePathRef path = CGPathCreateMutable();

    CGFloat firstSegmentEnd = fmin(progress, gapStartProgress);
    if (firstSegmentEnd > 0) {
        CGPathRef seg = [self arcWithCenter:kCenter radius:kRadius
                                start:kStart end:kStart + kSweep * firstSegmentEnd];
        CGPathAddPath(path, NULL, seg);
        CGPathRelease(seg);
    }
    if (progress > gapEndProgress) {
        CGPathRef seg = [self arcWithCenter:kCenter radius:kRadius
                               start:kStart + kSweep * gapEndProgress end:kStart + kSweep * progress];
        CGPathAddPath(path, NULL, seg);
        CGPathRelease(seg);
    }
    return path;
}

#pragma mark - 电池
+ (CGPathRef)batteryTrackWithTopGap:(BOOL)hasTopGap topGapWidth:(CGFloat)topGapWidth {
    return [self batteryArcWithProgress:1.0 hasTopGap:hasTopGap topGapWidth:topGapWidth];
}

+ (CGPathRef)batteryFillProgress:(CGFloat)progress hasTopGap:(BOOL)hasTopGap topGapWidth:(CGFloat)topGapWidth {
    CGFloat clamped = fmin(1, fmax(0, progress));
    if (clamped <= 0) return CGPathCreateMutable();
    return [self batteryArcWithProgress:clamped hasTopGap:hasTopGap topGapWidth:topGapWidth];
}

+ (CGPathRef)batteryChargingBoltWithScale:(CGFloat)scale {
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, 62.1, 2.2);
    CGPathAddQuadCurveToPoint(p, NULL, 62.6, 3.3, 62.8, 2.5);
    CGPathAddLineToPoint(p, NULL, 61.2, 7.8);
    CGPathAddLineToPoint(p, NULL, 65.9, 7.8);
    CGPathAddQuadCurveToPoint(p, NULL, 67.3, 8.6, 66.9, 7.8);
    CGPathAddQuadCurveToPoint(p, NULL, 67, 10, 67.6, 9.3);
    CGPathAddLineToPoint(p, NULL, 57, 21.3);
    CGPathAddQuadCurveToPoint(p, NULL, 55.6, 21.6, 56.4, 22);
    CGPathAddQuadCurveToPoint(p, NULL, 55.3, 20.5, 55, 21.3);
    CGPathAddLineToPoint(p, NULL, 57.4, 14.1);
    CGPathAddLineToPoint(p, NULL, 52.9, 14.1);
    CGPathAddQuadCurveToPoint(p, NULL, 51.6, 13.3, 52, 14.1);
    CGPathAddQuadCurveToPoint(p, NULL, 51.9, 12, 51.3, 12.6);
    CGPathAddLineToPoint(p, NULL, 61.1, 2.7);
    CGPathAddQuadCurveToPoint(p, NULL, 61.6, 2.1, 62.1, 2.2);
    CGPathCloseSubpath(p);

    if (!isfinite(scale) || scale <= 0 || scale == 1) return p;

    // 绕 pivot 缩放
    CGPoint pivot = CGPointMake(59.5, 2.1);
    CGAffineTransform t = CGAffineTransformMake(
        scale, 0, 0, scale,
        pivot.x * (1 - scale), pivot.y * (1 - scale));
    CGPathRef scaled = CGPathCreateCopyByTransformingPath(p, &t);
    CGPathRelease(p);
    return scaled;
}

#pragma mark - WiFi
+ (CFArrayRef)wifiArcsLevel:(NSInteger)level {
    NSInteger bars = MIN(3, MAX(0, level));
    const NSInteger maxArcs = 2;
    CGPathRef arcs[maxArcs];
    NSInteger count = 0;

    if (bars == 3) {
        arcs[count++] = [self arcWithCenter:kWifiOuterCenter radius:kWifiOuterRadius
                                 start:kWifiOuterStart end:kWifiOuterEnd];
        arcs[count++] = [self arcWithCenter:kWifiMiddleCenter radius:kWifiMiddleRadius
                                 start:227.5f*M_PI/180.0f end:312.5f*M_PI/180.0f];
    } else if (bars == 2) {
        arcs[count++] = [self arcWithCenter:kWifiMiddleCenter radius:kWifiMiddleRadius
                                 start:227.5f*M_PI/180.0f end:312.5f*M_PI/180.0f];
    }
    // bars == 1: 无线弧，仅点；bars == 0: 无

    CFMutableArrayRef arr = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
    for (NSInteger i = 0; i < count; i++) {
        CFArrayAppendValue(arr, arcs[i]);
    }
    for (NSInteger i = 0; i < count; i++) CGPathRelease(arcs[i]);
    return arr;
}

+ (CGPathRef)wifiDot {
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, 59.5, 69.9);
    CGPathAddCurveToPoint(p, NULL, 61.0, 69.9, 65.2, 70.8, 66.5, 73);
    CGPathAddCurveToPoint(p, NULL, 66.7, 73.8, 66.7, 74.3, 66.5, 75);
    CGPathAddCurveToPoint(p, NULL, 63.8, 78.8, 61.15, 80.95, 59.5, 80.95);
    CGPathAddCurveToPoint(p, NULL, 57.85, 80.95, 55.2, 78.8, 52.5, 75);
    CGPathAddCurveToPoint(p, NULL, 52.3, 74.3, 52.3, 73.8, 52.5, 73);
    CGPathAddCurveToPoint(p, NULL, 53.8, 70.8, 58.0, 69.9, 59.5, 69.9);
    CGPathCloseSubpath(p);
    return p;
}

+ (CGPathRef)wifiOffSlash {
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, 39, 46);
    CGPathAddLineToPoint(p, NULL, 81, 79);
    return p;
}

#pragma mark - 音量
+ (CFArrayRef)volumeDotPoints {
    CFMutableArrayRef arr = CFArrayCreateMutable(NULL, 4, &kCFTypeArrayCallBacks);
    for (int i = 0; i < 4; i++) {
        CFDataRef d = CFDataCreate(NULL, (const UInt8 *)&kVolumeDots[i], sizeof(CGPoint));
        CFArrayAppendValue(arr, d);
        CFRelease(d);
    }
    return arr;
}

+ (CGFloat)volumeDotRadius {
    return kVolumeDotRadius;
}

#pragma mark - 电池数字
+ (CGPoint)batteryValueBaselineFontSize:(CGFloat)fontSize {
    CGFloat refSize = 20;      // Reference font size
    CGFloat refBaseline = 17;  // Baseline for reference font size
    CGFloat curSize = 32;
    CGFloat curBaseline = 24;
    CGFloat slope = (curBaseline - refBaseline) / (curSize - refSize);
    return CGPointMake(59.5, refBaseline + (fontSize - refSize) * slope);
}

+ (CGFloat)batteryValueBaseFontSize {
    return kBaseFontSize;
}

@end