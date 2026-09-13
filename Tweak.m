// ============================================================================
//  IDIRingReadout  —  给 iPhoneDuoIcon (iya.banana.iphoneduoicon) 加"主卡/副卡圆环"
// ----------------------------------------------------------------------------
//  效果(对齐视频):
//    · 主卡(primary)  : 圆环(底部 4 个信号点) + 环内 WiFi/天线波形 + 环顶缺口处的
//                       **实时电量百分比数字**; 环的填充 = 电量百分比(低电红/充电绿/省电黄)
//    · 副卡(secondary): 同样的圆环 + 4 个信号点 + 波形, **不显示数字**(正常圆环状态),
//                       环的填充 = 该卡的信号强度
//  单卡时默认保持插件原样(pref singleMode 可改成也画环)。
//
//  原理: 运行时 hook iPhoneDuoIcon 的 IDIStatusIconView, 接管它的 drawRect: 自绘。
//        只读取该插件的 IDIStatusState / IDICellularLine 里的状态, 不改插件本体。
//
//  作者: Minis   ·  许可: MIT
// ============================================================================

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <math.h>
#import <notify.h>

// ---------------------------------------------------------------- 日志 ------
static BOOL gVerbose = YES;

static void idiLog(NSString* fmt, ...) {
    if (!gVerbose) return;
    va_list ap; va_start(ap, fmt);
    NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[IDIRing] %@", s);
}

// ------------------------------------------------- 插件(iPhoneDuoIcon) 类 ----
// 只做声明, 不链接: 插件没装时这些类不存在, 我们就什么都不做。
@interface IDICellularLine : NSObject
@property (nonatomic, assign) BOOL present;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL emergencyOnly;
@property (nonatomic, assign) NSInteger bars;          // 0~4 格
@property (nonatomic, copy)   NSString*  label;        // 运营商
@property (nonatomic, copy)   NSString*  networkType;  // "5G" / "LTE" ...
@end

@interface IDIStatusState : NSObject
@property (nonatomic, assign) BOOL      hasBattery;
@property (nonatomic, assign) NSInteger batteryPercent;
@property (nonatomic, assign) BOOL      lowPowerMode;
@property (nonatomic, assign) BOOL      vpnConnected;
@property (nonatomic, assign) BOOL      airplaneMode;
@property (nonatomic, assign) BOOL      wifiConnected;
@property (nonatomic, assign) NSInteger wifiBars;
@property (nonatomic, strong) IDICellularLine* primary;
@property (nonatomic, strong) IDICellularLine* secondary;
@end

@interface IDIStatusIconView : UIView
@property (nonatomic, strong) IDIStatusState* state;
@property (nonatomic, assign) BOOL showsVPNColor;
@property (nonatomic, assign) BOOL reversesVPNColor;
- (BOOL)isCharging;
- (UIColor*)networkColor;
- (void)applyStyleAttributes:(id)attrs;
- (CGSize)sizeThatFits:(CGSize)size;
- (CGSize)intrinsicContentSize;
@end

// ------------------------------------------------------------- 偏好设置 -----
static NSString* const kPrefDomain = @"iya.banana.idiringreadout";

typedef struct {
    BOOL    enabled;
    BOOL    keepOriginal;     // 双卡时是否还保留插件原本的合成图标
    BOOL    widen;            // 双卡时把图标视图变宽(两颗环并排)
    BOOL    singleRing;       // 单卡时也画环(否则保持插件原样)
    NSInteger primaryFill;    // 0=battery 1=signal 2=track(不填充)
    NSInteger primaryNumber;  // 0=off 1=battery 2=signal
    NSInteger primaryDots;    // 0=neutral(静态) 1=signal
    NSInteger secondaryFill;  // 同上
    NSInteger secondaryNumber;
    NSInteger secondaryDots;
    double  numberScale;      // 数字字号 = D * numberScale
} IDIPrefs;

static IDIPrefs gPrefs;

static NSInteger idiEnumPref(NSString* key, NSArray* names, NSInteger def) {
    NSUserDefaults* d = [[NSUserDefaults alloc] initWithSuiteName:kPrefDomain];
    NSString* s = [d stringForKey:key];
    if (!s) return def;
    for (NSInteger i = 0; i < (NSInteger)names.count; i++)
        if ([s caseInsensitiveCompare:names[i]] == NSOrderedSame) return i;
    return def;
}

static void idiLoadPrefs(void) {
    NSUserDefaults* d = [[NSUserDefaults alloc] initWithSuiteName:kPrefDomain];
    gPrefs.enabled         = [d objectForKey:@"Enabled"]          ? [d boolForKey:@"Enabled"]          : YES;
    gPrefs.keepOriginal    = [d objectForKey:@"KeepOriginal"]     ? [d boolForKey:@"KeepOriginal"]     : NO;
    gPrefs.widen           = [d objectForKey:@"Widen"]            ? [d boolForKey:@"Widen"]            : YES;
    gPrefs.singleRing      = [d objectForKey:@"SingleRing"]       ? [d boolForKey:@"SingleRing"]       : NO;
    gPrefs.primaryFill     = idiEnumPref(@"PrimaryFill",   @[@"battery", @"signal", @"off"], 0);
    gPrefs.primaryNumber   = idiEnumPref(@"PrimaryNumber", @[@"off", @"battery", @"signal"], 1);
    gPrefs.primaryDots     = idiEnumPref(@"PrimaryDots",   @[@"neutral", @"signal"], 1);
    // 副卡: 默认"静态圆环" —— 不显示该卡信号(不填充进度、信号点不表示格数、无数字)
    gPrefs.secondaryFill   = idiEnumPref(@"SecondaryFill", @[@"battery", @"signal", @"off"], 2);
    gPrefs.secondaryNumber = idiEnumPref(@"SecondaryNumber", @[@"off", @"battery", @"signal"], 0);
    gPrefs.secondaryDots   = idiEnumPref(@"SecondaryDots", @[@"neutral", @"signal"], 0);
    gPrefs.numberScale     = [d objectForKey:@"NumberScale"] ? [d doubleForKey:@"NumberScale"] : 0.34;
    if (gPrefs.numberScale < 0.15) gPrefs.numberScale = 0.15;
    if (gPrefs.numberScale > 0.60) gPrefs.numberScale = 0.60;
    idiLog(@"prefs enabled=%d keepOriginal=%d widen=%d singleRing=%d fill(p=%ld,s=%ld) num(p=%ld,s=%ld) scale=%.2f",
           gPrefs.enabled, gPrefs.keepOriginal, gPrefs.widen, gPrefs.singleRing,
           (long)gPrefs.primaryFill, (long)gPrefs.secondaryFill,
           (long)gPrefs.primaryNumber, (long)gPrefs.secondaryNumber, gPrefs.numberScale);
}

// ------------------------------------------------------- 实时电量(不靠插件) ---
typedef CFTypeRef  (*idi_fn_info)(void);
typedef CFArrayRef (*idi_fn_list)(CFTypeRef);
typedef CFDictionaryRef (*idi_fn_desc)(CFTypeRef, CFTypeRef);
typedef CFRunLoopSourceRef (*idi_fn_notify)(void*, void*);

static void* idiSym(const char* name) {
    static void* h = (void*)-1;
    if (h == (void*)-1) {
        h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (!h) h = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (!h) h = NULL;
    }
    if (h) { void* p = dlsym(h, name); if (p) return p; }
    return dlsym(RTLD_DEFAULT, name);
}

static int idiLiveBatteryPercent(void) {
    int pct = -1;
    idi_fn_info infoFn = (idi_fn_info)idiSym("IOPSCopyPowerSourcesInfo");
    idi_fn_list listFn = (idi_fn_list)idiSym("IOPSCopyPowerSourcesList");
    idi_fn_desc descFn = (idi_fn_desc)idiSym("IOPSGetPowerSourceDescription");
    if (infoFn && listFn && descFn) {
        CFTypeRef info = infoFn();
        if (info) {
            CFArrayRef list = listFn(info);
            if (list) {
                for (CFIndex i = 0; i < CFArrayGetCount(list) && pct < 0; i++) {
                    CFTypeRef ps = CFArrayGetValueAtIndex(list, i);
                    CFDictionaryRef desc = descFn(info, ps);
                    if (!desc) continue;
                    CFNumberRef cap = (CFNumberRef)CFDictionaryGetValue(desc, CFSTR("Current Capacity"));
                    CFNumberRef mx  = (CFNumberRef)CFDictionaryGetValue(desc, CFSTR("Max Capacity"));
                    int c = -1, m = 100;
                    if (cap) CFNumberGetValue(cap, kCFNumberIntType, &c);
                    if (mx)  CFNumberGetValue(mx,  kCFNumberIntType, &m);
                    if (c >= 0 && m > 0) pct = (int)lround((double)c * 100.0 / (double)m);
                }
                CFRelease(list);
            }
            CFRelease(info);
        }
    }
    if (pct < 0) {
        UIDevice* dev = [UIDevice currentDevice];
        if (!dev.batteryMonitoringEnabled) dev.batteryMonitoringEnabled = YES;
        float lv = dev.batteryLevel;
        if (lv >= 0.0f) pct = (int)lround(lv * 100.0f);
    }
    if (pct < 0) return -1;
    return MIN(pct, 100);
}

static int  gLivePercent  = -1;
static BOOL gLiveCharging = NO;
static NSHashTable* gLiveViews = nil;      // weak: 需要刷新的 IDIStatusIconView

static void idiRefreshLiveViews(void) {
    int pct = idiLiveBatteryPercent();
    if (!gLiveViews) return;
    if (pct >= 0) {
        if (pct == gLivePercent) return;
        gLivePercent = pct;
        idiLog(@"live battery -> %d%%", pct);
    }
    for (UIView* v in gLiveViews.allObjects) [v setNeedsDisplay];
}

static void idiPowerChanged(void* ctx) { idiRefreshLiveViews(); }

static void idiInstallLiveBattery(void) {
    gLiveViews = [NSHashTable weakObjectsHashTable];
    gLivePercent = idiLiveBatteryPercent();
    idiLog(@"live battery source installed, now %d%%", gLivePercent);

    idi_fn_notify notifyFn = (idi_fn_notify)idiSym("IOPSNotificationCreateRunLoopSource");
    if (notifyFn) {
        CFRunLoopSourceRef src = notifyFn((void*)idiPowerChanged, NULL);
        if (src) { CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopDefaultMode); CFRelease(src); }
    }
    [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceBatteryLevelDidChangeNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification* n) { idiRefreshLiveViews(); }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceBatteryStateDidChangeNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification* n) { idiRefreshLiveViews(); }];
    // 兜底轮询(电量只在整数变化时才重绘, 基本不耗电)
    [NSTimer scheduledTimerWithTimeInterval:20.0 repeats:YES block:^(NSTimer* t) {
        idiRefreshLiveViews();
    }];
}

// ------------------------------------------------------------- 状态取值 -----
static IDIStatusState* idiState(UIView* v) {
    if ([v respondsToSelector:@selector(state)]) return [v valueForKey:@"state"];
    return nil;
}

static BOOL idiLinePresent(IDICellularLine* l) {
    if (!l) return NO;
    BOOL present = NO;
    @try { present = [l present]; } @catch (__unused NSException* e) { present = YES; }
    return present;
}

static NSInteger idiLineBars(IDICellularLine* l) {
    if (!l) return 0;
    NSInteger b = 0;
    @try { b = [l bars]; } @catch (__unused NSException* e) { b = 0; }
    if (b < 0) b = 0;
    if (b > 4) b = 4;
    return b;
}

static BOOL idiIsDual(IDIStatusState* st) {
    if (!st) return NO;
    return idiLinePresent(st.primary) && idiLinePresent(st.secondary);
}

static UIColor* gStyleTint = nil;

static UIColor* idiForeground(UIView* v) {
    if ([v respondsToSelector:@selector(networkColor)]) {
        UIColor* c = nil;
        @try {
            UIColor* (*msg)(id, SEL) = (UIColor* (*)(id, SEL))objc_msgSend;
            c = msg(v, @selector(networkColor));
        } @catch (__unused NSException* e) { c = nil; }
        if (c) return c;
    }
    if (gStyleTint) return gStyleTint;
    // 深色状态栏 / 浅色状态栏兜底
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor*(UITraitCollection* t) {
            return (t.userInterfaceStyle == UIUserInterfaceStyleDark) ? UIColor.whiteColor : UIColor.blackColor;
        }];
    }
    return UIColor.blackColor;
}

static UIColor* idiResolved(UIColor* c, UIView* v) {
    if (!c) return UIColor.blackColor;
    if (@available(iOS 13.0, *)) return [c resolvedColorWithTraitCollection:v.traitCollection];
    return c;
}

// 电量数字/环颜色(和插件一致: 低电红 / 充电绿 / 省电黄 / 其它用前景色)
static UIColor* idiBatteryColor(UIView* v, IDIStatusState* st, int pct) {
    BOOL charging = NO;
    if ([v respondsToSelector:@selector(isCharging)]) {
        @try { charging = [v isCharging]; } @catch (__unused NSException* e) { charging = NO; }
    }
    if (st.lowPowerMode) return UIColor.systemYellowColor;
    if (charging)        return UIColor.systemGreenColor;
    if (pct >= 0 && pct <= 20) return UIColor.systemRedColor;
    return idiForeground(v);
}

// ------------------------------------------------------------- 绘图工具 -----
static CGFloat idiClamp01(CGFloat v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

// 角度体系: y 向下, 0°=右(3点), 90°=下(6点), 180°=左(9点), 270°=上(12点)
// 角度增大 = 屏幕上顺时针
static const CGFloat kTop      = 270.0;   // 12 点方向
static const CGFloat kGapHalf  = 22.0;    // 顶部数字缺口半宽(度)
static const CGFloat kDotsHalf = 43.0;    // 底部信号点弧半宽(度)

static CGPoint idiPt(CGPoint c, CGFloat r, CGFloat deg) {
    CGFloat a = deg * M_PI / 180.0;
    return CGPointMake(c.x + r * cos(a), c.y + r * sin(a));
}

static void idiStrokeArc(CGContextRef ctx, CGPoint c, CGFloat r,
                         CGFloat a0, CGFloat a1, CGFloat lw, UIColor* color) {
    if (!color || r <= 0) return;
    CGMutablePathRef p = CGPathCreateMutable();
    CGFloat span = a1 - a0;
    int steps = MAX(6, (int)(fabs(span) / 3.0));
    for (int i = 0; i <= steps; i++) {
        CGPoint pt = idiPt(c, r, a0 + span * (CGFloat)i / (CGFloat)steps);
        if (i == 0) CGPathMoveToPoint(p, NULL, pt.x, pt.y);
        else        CGPathAddLineToPoint(p, NULL, pt.x, pt.y);
    }
    CGContextAddPath(ctx, p);
    CGContextSetStrokeColorWithColor(ctx, color.CGColor);
    CGContextSetLineWidth(ctx, lw);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextStrokePath(ctx);
    CGPathRelease(p);
}

// 环: 左弧 [kTop-kGapHalf .. 90+kDotsHalf]  右弧 [90-kDotsHalf .. 360+kTop+kGapHalf]
#define IDI_LEFT_A0   90.0 + kDotsHalf        // 133°
#define IDI_LEFT_A1   kTop - kGapHalf         // 248°
#define IDI_RIGHT_A0  kTop + kGapHalf         // 292°
#define IDI_RIGHT_A1  90.0 - kDotsHalf + 360.0 // 407° (== 47°)

// 进度填充(有数字 → 顶部留缺口, 分左右两弧共 230°; 无数字 → 连续圆环 274°)
static void idiStrokeProgress(CGContextRef ctx, CGPoint c, CGFloat r, CGFloat lw,
                              CGFloat frac, UIColor* color, BOOL hasGap) {
    frac = idiClamp01(frac);
    if (frac <= 0.0001) return;
    if (!hasGap) {
        idiStrokeArc(ctx, c, r, IDI_LEFT_A0, IDI_LEFT_A0 + frac * 274.0, lw, color);
        return;
    }
    CGFloat total = (IDI_LEFT_A1 - IDI_LEFT_A0) + (IDI_RIGHT_A1 - IDI_RIGHT_A0);  // 230°
    CGFloat leftMax = IDI_LEFT_A1 - IDI_LEFT_A0;                                   // 115°
    CGFloat done = frac * total;
    if (done <= leftMax) {
        idiStrokeArc(ctx, c, r, IDI_LEFT_A0, IDI_LEFT_A0 + done, lw, color);
    } else {
        idiStrokeArc(ctx, c, r, IDI_LEFT_A0, IDI_LEFT_A1, lw, color);
        CGFloat rest = done - leftMax;
        if (rest > 0.5)
            idiStrokeArc(ctx, c, r, IDI_RIGHT_A0, IDI_RIGHT_A0 + rest, lw, color);
    }
}

// 环底部 4 个信号点 (落在环的圆周上); mode: 0=neutral(全部前景色, 不表示信号) 1=signal
static void idiDrawDots(CGContextRef ctx, CGPoint c, CGFloat r, CGFloat lw,
                        NSInteger bars, NSInteger mode, UIColor* active, UIColor* inactive) {
    CGFloat span = kDotsHalf * 2.0;      // 86°
    CGFloat d = lw * 1.18;               // 点直径
    if (d < 1.4) d = 1.4;
    for (int i = 0; i < 4; i++) {
        CGFloat a = (90.0 + kDotsHalf) - span * (CGFloat)i / 3.0;   // 133° -> 47°
        CGPoint pt = idiPt(c, r, a);
        UIColor* col = (mode == 0) ? active : ((i < bars) ? active : inactive);
        CGContextSetFillColorWithColor(ctx, col.CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(pt.x - d/2, pt.y - d/2, d, d));
    }
}

// 环内波形(WiFi 三弧 + 圆点), 朝上
static void idiDrawGlyph(CGContextRef ctx, CGPoint c, CGFloat R, CGFloat lw,
                         BOOL on, UIColor* fg, UIColor* dim) {
    UIColor* col = on ? fg : dim;
    CGFloat w = MAX(1.0, lw * 0.55);
    CGFloat r3 = R * 0.54, r2 = R * 0.36, r1 = R * 0.18;
    CGPoint gc = CGPointMake(c.x, c.y - R * 0.04);
    // 三弧: y 向下时 214°~326° 是顶部(270°=正上方) → 彩虹形
    idiStrokeArc(ctx, gc, r3, 214.0, 326.0, w, col);
    idiStrokeArc(ctx, gc, r2, 214.0, 326.0, w, col);
    idiStrokeArc(ctx, gc, r1, 214.0, 326.0, w, col);
    CGFloat dd = MAX(1.4, lw * 1.0);
    CGPoint dp = CGPointMake(gc.x, gc.y + R * 0.24);
    CGContextSetFillColorWithColor(ctx, col.CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(dp.x - dd/2, dp.y - dd/2, dd, dd));
}

// ---------------------------------------------------------- 数值 -> 比例 -----
static CGFloat idiFillFraction(NSInteger mode, IDIStatusState* st, IDICellularLine* line,
                               UIView* v, int* outPct) {
    // 0=battery 1=signal 2=off
    if (mode == 0) {
        int pct = gLivePercent;
        if (pct < 0 && st.hasBattery) pct = (int)st.batteryPercent;
        if (outPct) *outPct = pct;
        if (pct < 0) return 0;
        return idiClamp01(pct / 100.0);
    }
    if (mode == 1) {
        NSInteger bars = idiLineBars(line);
        if (outPct) *outPct = (int)bars * 25;
        if (bars <= 0) return 0;
        return idiClamp01(bars / 4.0);
    }
    if (outPct) *outPct = -1;
    return 0;
}

static NSString* idiNumberText(NSInteger mode, IDIStatusState* st, IDICellularLine* line, int* outPct) {
    // 0=off 1=battery 2=signal
    if (mode == 1) {
        int pct = gLivePercent;
        if (pct < 0 && st.hasBattery) pct = (int)st.batteryPercent;
        if (outPct) *outPct = pct;
        return pct < 0 ? nil : [NSString stringWithFormat:@"%d", pct];
    }
    if (mode == 2) {
        NSInteger bars = idiLineBars(line);
        int pct = (int)bars * 25;
        if (outPct) *outPct = pct;
        return bars > 0 ? [NSString stringWithFormat:@"%d", pct] : nil;
    }
    if (outPct) *outPct = -1;
    return nil;
}

// ------------------------------------------------------------ 单颗环绘制 -----
static void idiDrawOneRing(CGContextRef ctx, UIView* v, IDIStatusState* st,
                           CGPoint c, CGFloat D, IDICellularLine* line,
                           NSInteger fillMode, NSInteger numMode, NSInteger dotsMode,
                           BOOL isPrimary) {
    CGFloat lw = MAX(1.1, D * 0.115);
    CGFloat R  = D * 0.5 - lw * 0.5;
    UIColor* fg = idiResolved(idiForeground(v), v);
    UIColor* track = [fg colorWithAlphaComponent:0.28];

    // 0. 先决定有没有数字: 有数字 → 顶部留缺口; 没数字 → 一条完整静态圆环
    int numPct = -1;
    NSString* txt = idiNumberText(numMode, st, line, &numPct);
    BOOL hasGap  = (txt.length > 0);

    // 1. 轨道
    if (hasGap) {
        idiStrokeArc(ctx, c, R, IDI_LEFT_A0,  IDI_LEFT_A1,  lw, track);
        idiStrokeArc(ctx, c, R, IDI_RIGHT_A0, IDI_RIGHT_A1, lw, track);
    } else {
        idiStrokeArc(ctx, c, R, IDI_LEFT_A0, IDI_LEFT_A0 + 274.0, lw, track);   // 连续环(跳过底部点弧)
    }

    // 2. 环内波形
    UIColor* dim = [fg colorWithAlphaComponent:0.32];
    idiDrawGlyph(ctx, c, R, lw, st.wifiConnected, fg, dim);

    // 3. 底部 4 个点 (dotsMode 0=静态同色 不表示信号; 1=按该卡格数)
    NSInteger bars = idiLineBars(line);
    idiDrawDots(ctx, c, R, lw, bars, dotsMode, fg, track);

    // 4. 进度填充 (fillMode: 0=battery 1=signal 2=off 不填充)
    if (fillMode != 2) {
        int pct = -1;
        CGFloat frac = idiFillFraction(fillMode, st, line, v, &pct);
        UIColor* fillColor = (fillMode == 0) ? idiBatteryColor(v, st, pct) : fg;
        idiStrokeProgress(ctx, c, R, lw, frac, fillColor, hasGap);
    }

    // 5. 数字(落在顶部缺口)
    if (hasGap) {
        CGFloat fs = MAX(6.0, D * gPrefs.numberScale);
        UIFont* f = [UIFont systemFontOfSize:fs weight:UIFontWeightBold];
        NSDictionary* attrs = @{ NSFontAttributeName: f,
                                 NSForegroundColorAttributeName: fg };
        CGSize ts = [txt sizeWithAttributes:attrs];
        CGPoint p = CGPointMake(c.x - ts.width * 0.5, c.y - R - ts.height * 0.5);
        [txt drawAtPoint:p withAttributes:attrs];
    }
}

// ------------------------------------------------------------ 主绘制入口 -----
static void idiDrawIcon(UIView* v, CGRect rect) {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    IDIStatusState* st = idiState(v);
    if (!st) return;

    BOOL dual = idiIsDual(st);
    CGRect b = v.bounds;
    CGFloat h = b.size.height, w = b.size.width;
    if (h < 4.0 || w < 4.0) return;

    int n = dual ? 2 : 1;
    CGFloat cellW = w / (CGFloat)n;
    CGFloat D = MIN(cellW, h) - 2.0;
    if (D < 5.0) D = MIN(cellW, h);
    D = MAX(D, 5.0);

    CGContextSaveGState(ctx);
    if (dual) {
        idiDrawOneRing(ctx, v, st, CGPointMake(cellW * 0.5, h * 0.5), D,
                       st.primary, gPrefs.primaryFill, gPrefs.primaryNumber,
                       gPrefs.primaryDots, YES);
        idiDrawOneRing(ctx, v, st, CGPointMake(cellW * 1.5, h * 0.5), D,
                       st.secondary, gPrefs.secondaryFill, gPrefs.secondaryNumber,
                       gPrefs.secondaryDots, NO);
    } else {
        IDICellularLine* line = idiLinePresent(st.primary) ? st.primary : st.secondary;
        idiDrawOneRing(ctx, v, st, CGPointMake(w * 0.5, h * 0.5), D,
                       line, gPrefs.primaryFill, gPrefs.primaryNumber,
                       gPrefs.primaryDots, YES);
    }
    CGContextRestoreGState(ctx);
}

// ----------------------------------------------------------------- hooks ----
static IMP gOrigDrawRect     = NULL;
static IMP gOrigSizeThatFits = NULL;
static IMP gOrigIntrinsic   = NULL;
static IMP gOrigSetState    = NULL;
static IMP gOrigApplyStyle  = NULL;

static void idi_drawRect(id self, SEL _cmd, CGRect rect) {
    @try {
        IDIStatusState* st = idiState(self);
        BOOL dual = idiIsDual(st);
        BOOL render = gPrefs.enabled && st && (dual ? YES : gPrefs.singleRing);
        if (render && gPrefs.keepOriginal && gOrigDrawRect)
            ((void(*)(id, SEL, CGRect))gOrigDrawRect)(self, _cmd, rect);
        if (render) {
            if (!gLiveViews) gLiveViews = [NSHashTable weakObjectsHashTable];
            [gLiveViews addObject:self];
            idiDrawIcon(self, rect);
        } else if (gOrigDrawRect) {
            ((void(*)(id, SEL, CGRect))gOrigDrawRect)(self, _cmd, rect);
        }
        return;
    } @catch (NSException* e) {
        idiLog(@"drawRect exception: %@", e);
    }
    if (gOrigDrawRect) ((void(*)(id, SEL, CGRect))gOrigDrawRect)(self, _cmd, rect);
}

// 双卡时把图标视图撑宽, 让两颗环并排有足够空间(widen=NO 时保持原样, 环会自动缩小适配)
static CGSize idiWiden(id self, CGSize orig) {
    if (!gPrefs.enabled || !gPrefs.widen) return orig;
    if (!idiIsDual(idiState(self))) return orig;
    CGFloat h = orig.height;
    if (h <= 2.0) {
        CGFloat bh = ((UIView*)self).bounds.size.height;
        if (bh <= 2.0) return orig;
        h = bh;
    }
    return CGSizeMake(h * 2.0, h);
}

static CGSize idi_sizeThatFits(id self, SEL _cmd, CGSize size) {
    CGSize orig = gOrigSizeThatFits ? ((CGSize(*)(id, SEL, CGSize))gOrigSizeThatFits)(self, _cmd, size)
                                    : CGSizeMake(24.0, 24.0);
    CGSize w = idiWiden(self, orig);
    idiLog(@"sizeThatFits %@ -> %@", NSStringFromCGSize(orig), NSStringFromCGSize(w));
    return w;
}

static CGSize idi_intrinsicContentSize(id self, SEL _cmd) {
    CGSize orig = gOrigIntrinsic ? ((CGSize(*)(id, SEL))gOrigIntrinsic)(self, _cmd) : CGSizeMake(24.0, 24.0);
    CGSize w = idiWiden(self, orig);
    if (!CGSizeEqualToSize(orig, w))
        idiLog(@"intrinsicContentSize %@ -> %@", NSStringFromCGSize(orig), NSStringFromCGSize(w));
    return w;
}

static void idi_setState(id self, SEL _cmd, id state) {
    if (gOrigSetState) ((void(*)(id, SEL, id))gOrigSetState)(self, _cmd, state);
    if (gPrefs.enabled) {
        if (!gLiveViews) gLiveViews = [NSHashTable weakObjectsHashTable];
        [gLiveViews addObject:self];
        [(UIView*)self setNeedsDisplay];
    }
}

static void idi_applyStyleAttributes(id self, SEL _cmd, id attrs) {
    @try {
        if (attrs) {
            UIColor* c = nil;
            if ([attrs respondsToSelector:@selector(imageTintColor)]) c = [attrs valueForKey:@"imageTintColor"];
            if (!c && [attrs respondsToSelector:@selector(textColor)]) c = [attrs valueForKey:@"textColor"];
            if (c) gStyleTint = c;
        }
    } @catch (__unused NSException* e) {}
    if (gOrigApplyStyle) ((void(*)(id, SEL, id))gOrigApplyStyle)(self, _cmd, attrs);
    [(UIView*)self setNeedsDisplay];
}

// --------------------------------------------------------------- 安装 hook ---
extern void MSHookMessageEx(Class _class, SEL sel, IMP imp, IMP* result);

static BOOL gInstalled = NO;

static void idiInstallHooks(void) {
    if (gInstalled) return;
    Class cls = objc_getClass("IDIStatusIconView");
    if (!cls) { idiLog(@"IDIStatusIconView not found yet"); return; }

    MSHookMessageEx(cls, @selector(drawRect:),
                    (IMP)idi_drawRect, &gOrigDrawRect);
    MSHookMessageEx(cls, @selector(intrinsicContentSize),
                    (IMP)idi_intrinsicContentSize, &gOrigIntrinsic);
    MSHookMessageEx(cls, @selector(sizeThatFits:),
                    (IMP)idi_sizeThatFits, &gOrigSizeThatFits);
    if (class_getInstanceMethod(cls, @selector(setState:)))
        MSHookMessageEx(cls, @selector(setState:), (IMP)idi_setState, &gOrigSetState);
    if (class_getInstanceMethod(cls, @selector(applyStyleAttributes:)))
        MSHookMessageEx(cls, @selector(applyStyleAttributes:), (IMP)idi_applyStyleAttributes, &gOrigApplyStyle);

    gInstalled = YES;
    idiLog(@"hooked IDIStatusIconView (drawRect:%p orig, intrinsic orig:%p)",
           gOrigDrawRect, gOrigIntrinsic);
}

static void idiRetryInstall(int attempt) {
    if (gInstalled) return;
    idiInstallHooks();
    if (gInstalled) return;
    if (attempt > 12) { idiLog(@"give up waiting for iPhoneDuoIcon"); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC * (1 + attempt / 2))),
                   dispatch_get_main_queue(), ^{ idiRetryInstall(attempt + 1); });
}

// ------------------------------------------------------------------ 入口 -----
__attribute__((constructor)) static void IDIRingReadoutInit(void) {
    @autoreleasepool {
        idiLoadPrefs();
        if (!gPrefs.enabled) { idiLog(@"disabled by prefs"); return; }
        idiInstallLiveBattery();

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            (CFNotificationCallback)(void*)idiLoadPrefs,
            CFSTR("iya.banana.idiringreadout/saved"), NULL,
            CFNotificationSuspensionBehaviorCoalesce);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ idiRetryInstall(0); });
    }
}
