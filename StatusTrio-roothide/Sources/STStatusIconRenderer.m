// STStatusIconRenderer.m — 从 StatusTrio StatusIconRenderer.swift 移植
// 用 CGContext + CoreText 绘制合成图标，输出 UIImage。绘制逻辑 1:1 借鉴。

#import "STStatusIconRenderer.h"
#import "STStatusIconGeometry.h"
#import <CoreText/CoreText.h>
#include <math.h>

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
        case STBatteryColorRoleCritical:
            return [UIColor colorWithRed:1.0 green:59.0/255.0 blue:48.0/255.0 alpha:1.0];
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
    CGFloat brightness = 0.299*r + 0.587*g + 0.114*b;
    return brightness < 0.5;
}

#pragma mark - 基础绘制 helper

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
          foreground:(UIColor *)fg
           textScale:(CGFloat)textScale
           inContext:(CGContextRef)ctx {
    BOOL showsChargingBolt = battery.isPresent
        && (battery.isCharging || battery.isConnectedToPower);
    BOOL showsPercentage = !showsChargingBolt; // 有闪电就不画数字
    BOOL hasTopGap = showsChargingBolt || showsPercentage;
    CGFloat topGapWidth = showsChargingBolt
        ? [STStatusIconGeometry batteryChargingBoltTopGapWidth]
        : [STStatusIconGeometry batteryValueTopGapWidth];

    // 轨道（半透明前景）
    CGColorRef trackColor = [fg colorWithAlphaComponent:0.22].CGColor;
    CGPathRef track = [STStatusIconGeometry batteryTrackWithTopGap:hasTopGap topGapWidth:topGapWidth];
    [self strokePath:track lineWidth:8 color:trackColor inContext:ctx];
    CGPathRelease(track);

    // 填充弧
    STBatteryColorRole role = [self batteryColorRoleForStatus:battery criticalThreshold:20];
    UIColor *roleColor = [self colorForRole:role
                                  foreground:fg
                                 darkPalette:[self usesDarkPaletteForeground:fg]];
    CGPathRef fill = [STStatusIconGeometry batteryFillProgress:[self batteryProgress:battery]
                                                        hasTopGap:hasTopGap
                                                     topGapWidth:topGapWidth];
    [self strokePath:fill lineWidth:8 color:roleColor.CGColor inContext:ctx];
    CGPathRelease(fill);

    if (showsChargingBolt) {
        CGPathRef bolt = [STStatusIconGeometry batteryChargingBoltWithScale:1.0];
        [self fillPath:bolt color:fg.CGColor inContext:ctx];
        CGPathRelease(bolt);
    } else if (showsPercentage) {
        [self drawBatteryPercentage:battery.isPresent ? battery.rawPercentage : 100
                              color:fg
                          textScale:textScale
                          inContext:ctx];
    }
}

+ (void)drawBatteryPercentage:(NSInteger)percentage
                        color:(UIColor *)color
                    textScale:(CGFloat)textScale
                    inContext:(CGContextRef)ctx {
    CGFloat fontSize = [STStatusIconGeometry batteryValueBaseFontSize] * textScale;
    if (fontSize < 4) fontSize = 4;

    // 圆润粗体字体（iOS 上用 SF Rounded Bold，回退系统粗体）
    UIFont *uiFont = [UIFont systemFontOfSize:fontSize weight:UIFontWeightBold];
    UIFontDescriptor *desc = [uiFont.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    UIFont *rounded = desc ? [UIFont fontWithDescriptor:desc size:fontSize] : uiFont;
    CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)rounded.fontName, fontSize, NULL);

    NSDictionary *attrs = @{
        (__bridge id)kCTFontAttributeName: (__bridge id)font,
        (__bridge id)kCTForegroundColorAttributeName: (__bridge id)color.CGColor,
        (__bridge id)kCTKernAttributeName: @(-fontSize * 0.04f),
    };
    NSAttributedString *as = [[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"%ld", (long)percentage]
            attributes:attrs];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);

    CGFloat ascent = 0, descent = 0, leading = 0;
    CGFloat width = (CGFloat)CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    CGPoint baseline = [STStatusIconGeometry batteryValueBaselineFontSize:fontSize];

    // 我们的 CTM 做了 y 翻转（canvas y 向上），文字需反向 flip 才正立 —— 与原版一致
    CGContextSaveGState(ctx);
    CGContextSetTextMatrix(ctx, CGAffineTransformMakeScale(1, -1));
    CGContextSetTextPosition(ctx, baseline.x - width / 2.0f, baseline.y);
    CTLineDraw(line, ctx);
    CGContextRestoreGState(ctx);

    CFRelease(line);
    CFRelease(font);
}

+ (void)drawWiFi:(STWiFiStatus)wifi foreground:(UIColor *)fg inContext:(CGContextRef)ctx {
    NSInteger bars = wifi.bars;
    UIColor *muted = [fg colorWithAlphaComponent:0.30];
    if (wifi.state == STWiFiStateConnected) {
        CFArrayRef arcs = [STStatusIconGeometry wifiArcsLevel:bars];
        for (CFIndex i = 0; i < CFArrayGetCount(arcs); i++) {
            CGPathRef p = (CGPathRef)CFArrayGetValueAtIndex(arcs, i);
            [self strokePath:p lineWidth:7 color:fg.CGColor inContext:ctx];
        }
        CFRelease(arcs);
        CGPathRef dot = [STStatusIconGeometry wifiDot];
        [self fillPath:dot color:fg.CGColor inContext:ctx];
        CGPathRelease(dot);
        return;
    }

    // 非连接态：灰弧 + 点（可加斜杠）
    CFArrayRef arcs = [STStatusIconGeometry wifiArcsLevel:3];
    for (CFIndex i = 0; i < CFArrayGetCount(arcs); i++) {
        CGPathRef p = (CGPathRef)CFArrayGetValueAtIndex(arcs, i);
        [self strokePath:p lineWidth:7 color:muted.CGColor inContext:ctx];
    }
    CFRelease(arcs);
    CGPathRef dot = [STStatusIconGeometry wifiDot];
    [self fillPath:dot color:muted.CGColor inContext:ctx];
    CGPathRelease(dot);

    if (wifi.state == STWiFiStateOff || wifi.state == STWiFiStateUnavailable) {
        CGPathRef slash = [STStatusIconGeometry wifiOffSlash];
        [self strokePath:slash lineWidth:6 color:muted.CGColor inContext:ctx];
        CGPathRelease(slash);
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
    CGFloat pixelDim = size * scale;
    if (!isfinite(pixelDim) || pixelDim <= 0) return nil;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)pixelDim, (size_t)pixelDim,
                                             8, (size_t)pixelDim*4, cs,
                                             kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;

    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);

    // 从像素坐标缩放到逻辑点
    CGContextScaleCTM(ctx, scale, scale);

    CGRect canvas = [STStatusIconGeometry canvas];
    CGFloat canvasScale = size / canvas.size.width;

    // 与 StatusTrio 一致的翻转：canvas 坐标（y 向上）映射到 UIKit（y 向下）
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, 0, size);
    CGContextScaleCTM(ctx, canvasScale, -canvasScale);

    [self drawBattery:snapshot.battery foreground:foreground textScale:1.0 inContext:ctx];
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