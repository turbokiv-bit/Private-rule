// STStatusIconRenderer.m — 从 StatusTrio StatusIconRenderer.swift 移植
// 用 CGContext 绘制合成图标，输出 UIImage。绘制逻辑 1:1 借鉴。

#import "STStatusIconRenderer.h"
#import "STStatusIconGeometry.h"
#import <CoreText/CoreText.h>

@implementation STStatusIconRenderer

#pragma mark - 状态映射（借鉴 StatusMappings）

+ (NSInteger)wifiBarsForRSSI:(NSInteger)rssi {
    if (rssi == 0) return 0;
    if (rssi >= -55) return 3;
    if (rssi >= -70) return 2;
    if (rssi >= -85) return 1;
    return 0;
}

+ (NSInteger)volumeStepsScalar:(CGFloat)scalar isMuted:(BOOL)isMuted {
    CGFloat clamped = MIN(1, MAX(0, scalar));
    if (isMuted || clamped == 0) return 0;
    if (clamped <= 0.25) return 1;
    if (clamped <= 0.50) return 2;
    if (clamped <= 0.75) return 3;
    return 4;
}

+ (STBatteryColorRole)batteryColorRoleForStatus:(STBatteryStatus)battery
                               criticalThreshold:(NSInteger)threshold {
    NSInteger t = MIN(100, MAX(0, threshold));
    NSInteger pct = battery.isPresent ? battery.rawPercentage : 100;
    if (pct < t) return STBatteryColorRoleCritical;
    if (battery.isLowPowerMode) return STBatteryColorRoleLowPower;
    if (battery.isCharging || battery.isConnectedToPower) return STBatteryColorRoleCharging;
    return STBatteryColorRoleForeground;
}

+ (CGFloat)batteryProgress:(STBatteryStatus)battery {
    NSInteger pct = battery.isPresent ? battery.rawPercentage : 100;
    return (CGFloat)pct / 100.0f;
}

+ (UIColor *)colorForRole:(STBatteryColorRole)role foreground:(UIColor *)foreground darkPalette:(BOOL)dark {
    switch (role) {
        case STBatteryColorRoleForeground: return foreground;
        case STBatteryColorRoleCritical: return [UIColor colorWithRed:1.0 green:59.0/255.0 blue:48.0/255.0 alpha:1.0];
        case STBatteryColorRoleCharging:
            return dark ? [UIColor colorWithRed:31.0/255 green:143.0/255 blue:61.0/255 alpha:1]
                        : [UIColor colorWithRed:52.0/255 green:199.0/255 blue:89.0/255 alpha:1];
        case STBatteryColorRoleLowPower:
            return dark ? [UIColor colorWithRed:201.0/255 green:151.0/255 blue:0 alpha:1]
                        : [UIColor colorWithRed:242.0/255 green:185.0/255 blue:0 alpha:1];
    }
    return foreground;
}

+ (BOOL)usesDarkPaletteForeground:(UIColor *)fg {
    CGFloat r=0,g=0,b=0,a=0;
    if (![fg getRed:&r green:&g blue:&b alpha:&a]) return NO;
    // 亮度低 => 暗色状态栏
    CGFloat brightness = 0.299*r + 0.587*g + 0.114*b;
    return brightness < 0.5;
}

#pragma mark - 基础绘制 helper

static CGFloat STSlice(CGFloat v) { return (CGFloat)v; }

+ (void)strokePath:(CGPathRef)path lineWidth:(CGFloat)lw color:(CGColorRef)color inContext:(CGContextRef)ctx {
    CGContextSetLineWidth(ctx, lw);
    CGContextSetStrokeColorWithColor(ctx, color);
    CGContextAddPath(ctx, path);
    CGContextStrokePath(ctx);
}

+ (void)fillPath:(CGPathRef)path color:(CGColorRef)color inContext:(CGContextRef)ctx {
    CGContextSetFillColorWithColor(ctx, color);
    CGContextAddPath(ctx, path);
    CGContextFillPath(ctx);
}

#pragma mark - 绘制三个部分

+ (void)drawBattery:(STBatteryStatus)battery
            showBolt:(BOOL)showBolt showPercent:(BOOL)showPercent
          foreground:(UIColor *)fg critical:(UIColor *)critical
           fontScale:(CGFloat)fontScale inContext:(CGContextRef)ctx {
    BOOL showsChargingBolt = battery.isPresent
        && (battery.isCharging || battery.isConnectedToPower)
        && showBolt;
    BOOL hasTopGap = showsChargingBolt || showPercent;
    CGFloat topGapWidth = showsChargingBolt ? 50.0f : 64.0f;

    // 轨道（半透明前景）
    CGColorRef trackColor = [fg colorWithAlphaComponent:0.22].CGColor;
    CGPathRef track = [STStatusIconGeometry batteryTrackWithTopGap:hasTopGap topGapWidth:topGapWidth];
    [self strokePath:track lineWidth:8 color:trackColor inContext:ctx];

    // 填充弧
    STBatteryColorRole role = [self batteryColorRoleForStatus:battery criticalThreshold:20];
    UIColor *roleColor = [self colorForRole:role foreground:fg
                                darkPalette:[self usesDarkPaletteForeground:fg]];
    CGPathRef fill = [STStatusIconGeometry batteryFillProgress:[self batteryProgress:battery]
                                                        hasTopGap:hasTopGap topGapWidth:topGapWidth];
    [self strokePath:fill lineWidth:8 color:roleColor.CGColor inContext:ctx];

    if (showsChargingBolt) {
        CGPathRef bolt = [STStatusIconGeometry batteryChargingBoltWithScale:fontScale];
        [self fillPath:bolt color:fg.CGColor inContext:ctx];
    }
    CGPathRelease(track);
    CGPathRelease(fill);
}

+ (void)drawBatteryPercentage:(NSInteger)percentage
                        color:(UIColor *)color
                     fontScale:(CGFloat)fontScale
                     baseline:(CGPoint)baseline
                     inContext:(CGContextRef)ctx {
    CGFloat fontSize = [STStatusIconGeometry batteryValueBaseFontSize] * fontScale;
    UIFont *font = [UIFont boldSystemFontOfSize:fontSize];

    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter;
    NSAttributedString *str = [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%ld",(long)percentage]
                                                              attributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
    }];
    CGSize size = [str size];
    CGRect rect = CGRectMake(baseline.x - size.width/2, baseline.y - size.height/2 + [font capHeight]*0.5,
                             size.width, size.height);
    [str drawInRect:rect];
}

+ (void)drawWiFi:(STWiFiStatus)wifi foreground:(UIColor *)fg inContext:(CGContextRef)ctx {
    NSInteger bars = wifi.bars;
    UIColor *muted = [fg colorWithAlphaComponent:0.30];
    switch (wifi.state) {
        case STWiFiStateConnected: {
            CFArrayRef arcs = [STStatusIconGeometry wifiArcsLevel:bars];
            for (CFIndex i = 0; i < CFArrayGetCount(arcs); i++) {
                CGPathRef p = (CGPathRef)CFArrayGetValueAtIndex(arcs, i);
                [self strokePath:p lineWidth:7 color:fg.CGColor inContext:ctx];
            }
            CGPathRef dot = [STStatusIconGeometry wifiDot];
            [self fillPath:dot color:fg.CGColor inContext:ctx];
            CFRelease(arcs);
            break;
        }
        case STWiFiStateNotAssociated:
        case STWiFiStateOff:
        case STWiFiStateUnavailable:
        default: {
            // 灰弧
            CFArrayRef arcs = [STStatusIconGeometry wifiArcsLevel:3];
            for (CFIndex i = 0; i < CFArrayGetCount(arcs); i++) {
                CGPathRef p = (CGPathRef)CFArrayGetValueAtIndex(arcs, i);
                [self strokePath:p lineWidth:7 color:muted.CGColor inContext:ctx];
            }
            CGPathRef dot = [STStatusIconGeometry wifiDot];
            [self fillPath:dot color:muted.CGColor inContext:ctx];
            CFRelease(arcs);
            if (wifi.state == STWiFiStateOff || wifi.state == STWiFiStateUnavailable) {
                CGPathRef slash = [STStatusIconGeometry wifiOffSlash];
                [self strokePath:slash lineWidth:6 color:muted.CGColor inContext:ctx];
            }
            break;
        }
    }
}

+ (void)drawVolume:(STVolumeStatus)volume foreground:(UIColor *)fg inContext:(CGContextRef)ctx {
    NSInteger level = [self volumeStepsScalar:volume.scalar isMuted:volume.isMuted];
    UIColor *hidden = [fg colorWithAlphaComponent:0.22];
    CFArrayRef points = [STStatusIconGeometry volumeDotPoints];
    CGFloat r = [STStatusIconGeometry volumeDotRadius];
    for (CFIndex i = 0; i < CFArrayGetCount(points); i++) {
        CFDataRef d = (CFDataRef)CFArrayGetValueAtIndex(points, i);
        CGPoint pt;
        memcpy(&pt, CFDataGetBytePtr(d), sizeof(CGPoint));
        UIColor *c = (i < level) ? fg : hidden;
        CGContextSetFillColorWithColor(ctx, c.CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(pt.x - r, pt.y - r, r*2, r*2));
    }
    CFRelease(points);
}

#pragma mark - 主渲染入口

+ (UIImage *)renderSnapshot:(STStatusSnapshot)snapshot
                       size:(CGFloat)size
                      scale:(CGFloat)scale
                  foreground:(UIColor *)foreground
                       showVolume:(BOOL)showVolume {
    CGFloat pixelDim = (size * scale);
    if (!isfinite(pixelDim) || pixelDim <= 0) return nil;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)pixelDim, (size_t)pixelDim,
                                             8, (size_t)pixelDim*4, cs,
                                             kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;

    // 放大到像素
    CGContextScaleCTM(ctx, scale, scale);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);

    CGRect canvas = [STStatusIconGeometry canvas];
    CGFloat canvasScale = size / canvas.size.width;
    // 坐标翻转：UIKit 坐标系 (y 向下) => CoreGraphics 画布保持上方向
    // StatusTrio 用 translate+scaleY(-1) 做翻转；这里直接用 UIKit 坐标即可，
    // 但与 StatusTrio 对齐：保持 canvas 120x120 逻辑坐标。
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, 0, size);
    CGContextScaleCTM(ctx, canvasScale, -canvasScale);

    // 是否使用状态色（默认开，类似 Standard options）
    BOOL dark = [self usesDarkPaletteForeground:foreground];
    UIColor *critical = [UIColor colorWithRed:1.0 green:59.0/255 blue:48.0/255 alpha:1.0];

    [self drawBattery:snapshot.battery
             showBolt:YES showPercent:YES
            foreground:foreground critical:critical
             fontScale:canvasScale*0.09 inContext:ctx];
    [self drawWiFi:snapshot.wifi foreground:foreground inContext:ctx];
    if (showVolume) {
        [self drawVolume:snapshot.volume foreground:foreground inContext:ctx];
    }

    CGContextRestoreGState(ctx);

    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!img) return nil;
    UIImage *out = [UIImage imageWithCGImage:img scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(img);
    return out;
}

@end