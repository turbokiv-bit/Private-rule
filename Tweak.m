// ============================================================================
//  DuoRingReadout —— CAiPhoneDuoStatus 圆环数字读数
//  在插件画的圆环"12 点方向缺口"里显示数字:
//    * 电量环: **系统实时电量百分比** (IOKit 电源信息, 和状态栏电量同源, 实时刷新)
//    * 信号环: 该卡信号 (numberOfActiveBars / numberOfBars)
//    * 主卡/副卡分开: 每个信号环单独取自己的值, 互不影响
//    * 数字归属按"角色"配置: 主卡环/副卡环/单卡环/双卡合成环/电量环 各自可选
//        off / signal / battery   —— 默认: 主卡环=电量, 副卡环=信号, 电量环=不显示
//    * 数字出现消失 0.28s 淡入淡出; 数值变化 0.20s 上滚淡换
//  注入: com.apple.springboard  (Sileo 安装, depends: ellekit)
//  原理: 链式 hook 插件已经 hook 过的 drawRect: —— 先调用插件原实现(画圆环),
//        再在原 context 上"挖缺口 + 画数字"。不改动插件二进制。
// ============================================================================
#import <substrate.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>   // objc_msgSend (新 SDK 里 runtime.h 不再包含)
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>

// ============================== 配置 ==============================
#define DRL_LOG 1
static NSString* const kPrefDomain = @"com.callassist.duoringreadout";

// 插件圆环的几何常量 (从 CAiPhoneDuoStatus 1.5.10 反汇编得到, 勿随意改)
static const double kLineWidthRatio = 0.105;   // lineWidth = 0.105 * min(w,h)
static const double kRadiusInset    = 0.7;     // radius    = min/2 - 0.7*lineWidth
static const double kTopAngle       = M_PI * 1.5;   // 12 点方向(插件角度体系: y 向下, 90°=正下方)
#define DRL_FADE_DUR  0.28          // 出现/消失 淡入淡出时长
#define DRL_ROLL_DUR  0.20          // 数值变化 上滚淡换时长

typedef NS_ENUM(NSInteger, DRLContent) {
    DRLContentOff     = 0,
    DRLContentSignal  = 1,   // 该环自己的信号百分比
    DRLContentBattery = 2,   // 系统实时电量
    DRLContentAuto    = 3,   // 仅用于电量环: 别处没显示电量时才显示
};

typedef struct {
    BOOL       enabled;
    BOOL       fade;
    double     sizeFactor;
    DRLContent cPrimary;     // 主卡环
    DRLContent cSecondary;   // 副卡环
    DRLContent cSingle;      // 单卡/普通蜂窝环
    DRLContent cDual;        // 双卡合成环(容器)
    DRLContent cBattery;     // 电量环
} DRLPrefs;

static DRLPrefs gPrefs;
static BOOL     gSeenDual = NO;            // 见过双卡合成环吗
static BOOL     gPrimarySeen = NO, gSecondarySeen = NO;  // 见过主卡/副卡各自的环吗
static double   gStartTime = 0;            // 进程内起始时间(避免启动瞬间抖动)
static void drlLog(NSString* fmt, ...);   // forward
static double drlNow(void);               // forward
static void drlInstallExtraRings(void);    // forward (额外圆环)

static DRLContent drlContentFromString(NSString* s, DRLContent def) {
    if (![s isKindOfClass:[NSString class]]) return def;
    NSString* t = [s lowercaseString];
    if ([t isEqualToString:@"off"] || [t isEqualToString:@"none"] || [t isEqualToString:@"0"]) return DRLContentOff;
    if ([t isEqualToString:@"signal"] || [t isEqualToString:@"bars"] || [t isEqualToString:@"1"]) return DRLContentSignal;
    if ([t isEqualToString:@"battery"] || [t isEqualToString:@"power"] || [t isEqualToString:@"2"]) return DRLContentBattery;
    if ([t isEqualToString:@"auto"]) return DRLContentAuto;
    return def;
}

static BOOL drlPrefBool(NSString* key, BOOL def) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                   (__bridge CFStringRef)kPrefDomain);
    BOOL r = def;
    if (v) {
        if (CFGetTypeID(v) == CFBooleanGetTypeID())     r = CFBooleanGetValue((CFBooleanRef)v);
        else if (CFGetTypeID(v) == CFNumberGetTypeID()) r = [(__bridge NSNumber*)v boolValue];
        CFRelease(v);
    }
    return r;
}

static double drlPrefDouble(NSString* key, double def) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                   (__bridge CFStringRef)kPrefDomain);
    double r = def;
    if (v) {
        if (CFGetTypeID(v) == CFNumberGetTypeID()) r = [(__bridge NSNumber*)v doubleValue];
        CFRelease(v);
    }
    return r;
}

static NSString* drlPrefString(NSString* key) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                   (__bridge CFStringRef)kPrefDomain);
    NSString* r = nil;
    if (v) {
        if (CFGetTypeID(v) == CFStringGetTypeID()) r = [(__bridge NSString*)v copy];
        CFRelease(v);
    }
    return r;
}

// 首次运行写入默认配置(用 Filza 改这个 plist 即可)
static void drlEnsureDefaults(void) {
    NSString* path = @"/var/mobile/Library/Preferences/com.callassist.duoringreadout.plist";
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return;
    CFStringRef app = CFSTR("com.callassist.duoringreadout");
    CFPreferencesSetAppValue(CFSTR("enabled"),         kCFBooleanTrue, app);
    CFPreferencesSetAppValue(CFSTR("fade"),            kCFBooleanTrue, app);
    CFPreferencesSetAppValue(CFSTR("sizeFactor"),      (__bridge CFNumberRef)@1.9, app);
    CFPreferencesSetAppValue(CFSTR("numberPrimary"),   CFSTR("battery"), app);  // 主卡环 -> 电量
    CFPreferencesSetAppValue(CFSTR("numberSecondary"), CFSTR("off"),     app);  // 副卡环 -> 不显示数字
    CFPreferencesSetAppValue(CFSTR("numberSingle"),    CFSTR("battery"), app);  // 单卡环 -> 电量
    CFPreferencesSetAppValue(CFSTR("numberDual"),      CFSTR("off"),     app);  // 双卡合成环 -> 不显示
    CFPreferencesSetAppValue(CFSTR("numberBattery"),   CFSTR("auto"),    app);  // 电量环 -> 自动
    CFPreferencesAppSynchronize(app);
    drlLog(@"wrote default prefs -> %@", path);
}

static DRLPrefs drlPrefs(void) {
    DRLPrefs p;
    p.enabled    = drlPrefBool(@"enabled", YES);
    p.fade       = drlPrefBool(@"fade", YES);
    p.sizeFactor = drlPrefDouble(@"sizeFactor", 1.9);
    if (p.sizeFactor < 0.8) p.sizeFactor = 0.8;
    if (p.sizeFactor > 3.0) p.sizeFactor = 3.0;
    p.cPrimary   = drlContentFromString(drlPrefString(@"numberPrimary"),   DRLContentBattery);
    p.cSecondary = drlContentFromString(drlPrefString(@"numberSecondary"), DRLContentOff);   // 副卡默认"正常状态"(无数字)
    p.cSingle    = drlContentFromString(drlPrefString(@"numberSingle"),    DRLContentBattery);
    p.cDual      = drlContentFromString(drlPrefString(@"numberDual"),      DRLContentOff);
    p.cBattery   = drlContentFromString(drlPrefString(@"numberBattery"),   DRLContentAuto);
    return p;
}

static void drlLog(NSString* fmt, ...) {
#if DRL_LOG
    va_list ap; va_start(ap, fmt);
    NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[DuoReadout] %@", s);
#endif
}

// ============================== 插件是否在 ==============================
// 只在 CAiPhoneDuoStatus 真正画圆环时加数字; 万一插件没装/没生效,
// 就不去动系统原生的电量图标。
static BOOL drlPluginLoaded(void) {
    static int cached = -1;
    if (cached >= 0) return cached ? YES : NO;
    cached = 0;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char* nm = _dyld_get_image_name(i);
        if (nm && strstr(nm, "CAiPhoneDuoStatus")) { cached = 1; break; }
    }
    if (!cached) drlLog(@"CAiPhoneDuoStatus not loaded - readout disabled");
    return cached ? YES : NO;
}

// ============================== 实时电量 ==============================
// 直接读系统电源信息(和状态栏电量同源), 不依赖插件/视图是否把值写回。
// 事件驱动: IOPS 电源变化通知 + 30s 兜底, 变化时让圆环重绘 -> 数字实时刷新。
static NSHashTable* gLiveViews = nil;        // 需要刷新的视图(弱引用)
static int gLastLivePercent = -1;

static int drlLiveBatteryPercent(void) {
    int pct = -1;
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (info) {
        CFArrayRef list = IOPSCopyPowerSourcesList(info);
        if (list) {
            for (CFIndex i = 0; i < CFArrayGetCount(list) && pct < 0; i++) {
                CFTypeRef ps = CFArrayGetValueAtIndex(list, i);
                CFDictionaryRef desc = IOPSGetPowerSourceDescription(info, ps);
                if (!desc) continue;
                CFNumberRef cap = (CFNumberRef)CFDictionaryGetValue(desc, CFSTR(kIOPSCurrentCapacityKey));
                CFNumberRef mx  = (CFNumberRef)CFDictionaryGetValue(desc, CFSTR(kIOPSMaxCapacityKey));
                int c = -1, m = 100;
                if (cap) CFNumberGetValue(cap, kCFNumberIntType, &c);
                if (mx)  CFNumberGetValue(mx,  kCFNumberIntType, &m);
                if (c >= 0 && m > 0) pct = (int)lround((double)c * 100.0 / (double)m);
            }
            CFRelease(list);
        }
        CFRelease(info);
    }
    if (pct < 0) {   // 退路: UIDevice
        UIDevice* d = [UIDevice currentDevice];
        if (!d.batteryMonitoringEnabled) d.batteryMonitoringEnabled = YES;
        float lv = d.batteryLevel;                 // 0~1, -1 = 未知
        if (lv >= 0.0f) pct = (int)lround(lv * 100.0f);
    }
    if (pct < 0) return -1;
    if (pct > 100) pct = 100;
    return pct;
}

static void drlRefreshLiveViews(void) {
    int pct = drlLiveBatteryPercent();
    if (pct < 0) return;
    if (pct == gLastLivePercent) return;
    gLastLivePercent = pct;
    drlLog(@"live battery = %d%%", pct);
    for (UIView* v in gLiveViews.allObjects) [v setNeedsDisplay];
}

static void drlPowerSourceChanged(void* ctx) { drlRefreshLiveViews(); }

static void drlInstallLiveBattery(void) {
    if (!gLiveViews) gLiveViews = [NSHashTable weakObjectsHashTable];
    gLastLivePercent = drlLiveBatteryPercent();
    CFRunLoopSourceRef src = IOPSNotificationCreateRunLoopSource(drlPowerSourceChanged, NULL);
    if (src) {
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopDefaultMode);
        CFRelease(src);
    }
    [NSTimer scheduledTimerWithTimeInterval:30.0 repeats:YES block:^(NSTimer* t) {
        drlRefreshLiveViews();
    }];
    drlLog(@"live battery source installed, now %d%%", gLastLivePercent);
}

// ============================== 几何 ==============================
typedef struct { CGFloat lw, r, cx, cy; } DRLGeom;

static DRLGeom drlGeom(CGRect rect) {
    DRLGeom g;
    CGFloat minDim = MIN(rect.size.width, rect.size.height);
    g.lw = MAX(kLineWidthRatio * minDim, 1.0);
    g.r  = minDim * 0.5 - kRadiusInset * g.lw;
    g.cx = CGRectGetMidX(rect);
    g.cy = CGRectGetMidY(rect);
    return g;
}

// ============================== 角色(主卡/副卡/单卡/双卡合成/电量) ==============================
typedef NS_ENUM(NSInteger, DRLRole) {
    DRLRoleBattery = 0,
    DRLRolePrimary,      // 主卡信号环
    DRLRoleSecondary,    // 副卡信号环
    DRLRoleSingle,       // 单卡/普通蜂窝环
    DRLRoleDual,         // 双卡合成环(容器本身)
};

static DRLRole drlRoleOfView(UIView* v) {
    NSString* cn = NSStringFromClass([v class]);
    if ([cn rangeOfString:@"Battery"].location != NSNotFound) return DRLRoleBattery;
    if ([cn rangeOfString:@"DualCellular"].location != NSNotFound) {
        gSeenDual = YES;
        return DRLRoleDual;
    }
    // 是否在双卡容器里面 -> 主卡/副卡
    UIView* sup = v.superview;
    int guard = 0;
    while (sup && guard++ < 6) {
        NSString* sn = NSStringFromClass([sup class]);
        BOOL isDualHost = ([sn rangeOfString:@"DualCellular"].location != NSNotFound) ||
                          [sup respondsToSelector:NSSelectorFromString(@"topSignalView")];
        if (isDualHost) {
            gSeenDual = YES;
            UIView* top = nil;
            if ([sup respondsToSelector:NSSelectorFromString(@"topSignalView")]) {
                top = ((UIView* (*)(id, SEL))objc_msgSend)(sup, NSSelectorFromString(@"topSignalView"));
            }
            if (top) {
                if (top == v) { gPrimarySeen = YES; return DRLRolePrimary; }
                gSecondarySeen = YES;
                return DRLRoleSecondary;
            }
            // 退路: 同层里最靠上/靠左的那个当主卡
            UIView* best = nil;
            for (UIView* sib in sup.subviews) {
                if (sib.hidden || sib.alpha <= 0.01 || sib.frame.size.width <= 1.0) continue;
                if (!best) { best = sib; continue; }
                if (sib.frame.origin.y < best.frame.origin.y - 0.5) best = sib;
                else if (fabs(sib.frame.origin.y - best.frame.origin.y) < 0.5 &&
                         sib.frame.origin.x < best.frame.origin.x) best = sib;
            }
            if (best == nil || best == v) { gPrimarySeen = YES; return DRLRolePrimary; }
            gSecondarySeen = YES;
            return DRLRoleSecondary;
        }
        sup = sup.superview;
    }
    return DRLRoleSingle;
}

static DRLContent drlContentForRole(DRLRole r) {
    // 电量环的 auto: 别处(主卡环/单卡环)已经在显示电量, 它就不显示
    if (r == DRLRoleBattery && gPrefs.cBattery == DRLContentAuto) {
        BOOL shownElsewhere = (gPrefs.cPrimary == DRLContentBattery ||
                               gPrefs.cSingle  == DRLContentBattery);
        return shownElsewhere ? DRLContentOff : DRLContentBattery;
    }
    if (r == DRLRoleDual) {
        // 兜底: 万一插件只给"双卡合成环"画了环、没给主/副卡分别画,
        // 就把主卡那份数字放到这个环上, 免得电量数字彻底不出现。
        if (gPrefs.cDual == DRLContentOff && !gPrimarySeen && !gSecondarySeen &&
            gStartTime > 0 && (drlNow() - gStartTime) > 3.0) {
            return gPrefs.cPrimary;
        }
        return gPrefs.cDual;
    }
    switch (r) {
        case DRLRoleBattery:   return gPrefs.cBattery;
        case DRLRolePrimary:   return gPrefs.cPrimary;
        case DRLRoleSecondary: return gPrefs.cSecondary;
        case DRLRoleSingle:    return gPrefs.cSingle;
        case DRLRoleDual:      return gPrefs.cDual;
    }
    return DRLContentOff;
}

// ============================== 取值 ==============================
static const void* kDRLCapturedKey = &kDRLCapturedKey;   // NSNumber: 最近一次 setter 的值

@interface NSObject (DRLPrivate)
- (double)chargePercent;          // *_BatteryView / *_StaticBatteryView
- (long long)numberOfActiveBars;  // *_CellularSignalView
- (long long)numberOfBars;
- (UIColor*)bodyColor;
@end

// 算出这个环该显示的数字(0~100); 返回 NO = 这个环不显示数字
static BOOL drlPercentForView(UIView* v, int* outPercent) {
    DRLRole role = drlRoleOfView(v);
    DRLContent c = drlContentForRole(role);
    if (c == DRLContentOff) return NO;

    if (c == DRLContentBattery) {
        if (gLiveViews) [gLiveViews addObject:v];        // 电量变化时刷新它
        int live = (gLastLivePercent >= 0) ? gLastLivePercent : drlLiveBatteryPercent();
        if (live < 0) {                                   // 退路: 抓到的 setter 值 / 视图属性
            NSNumber* cap = objc_getAssociatedObject(v, &kDRLCapturedKey);
            if (cap) {
                double d = cap.doubleValue;
                live = (int)lround(d > 1.0 ? d : d * 100.0);
            } else if ([v respondsToSelector:NSSelectorFromString(@"chargePercent")]) {
                double d = [(id)v chargePercent];
                live = (int)lround(d > 1.0 ? d : d * 100.0);
            } else {
                return NO;
            }
        }
        if (live < 0) live = 0;
        if (live > 100) live = 100;
        *outPercent = live;
        return YES;
    }

    // DRLContentSignal: 该环自己的信号格
    long long bars = 0, total = 4;
    NSNumber* cap = objc_getAssociatedObject(v, &kDRLCapturedKey);
    if (cap) bars = cap.longLongValue;
    else if ([v respondsToSelector:NSSelectorFromString(@"numberOfActiveBars")]) {
        bars = [(id)v numberOfActiveBars];
    } else {
        return NO;                                        // 容器环/取不到值 -> 不显示
    }
    if ([v respondsToSelector:NSSelectorFromString(@"numberOfBars")]) {
        long long t = [(id)v numberOfBars];
        if (t > 0 && t <= 8) total = t;
    }
    if (bars < 0) bars = 0;
    if (bars > total) bars = total;
    *outPercent = (int)lround(100.0 * (double)bars / (double)total);
    return YES;
}

static UIColor* drlNumberColor(UIView* v) {
    UIColor* c = nil;
    if ([v respondsToSelector:NSSelectorFromString(@"bodyColor")]) c = [(id)v bodyColor];
    if ((!c || CGColorGetAlpha(c.CGColor) < 0.05) && v.tintColor) c = v.tintColor;
    if (!c || CGColorGetAlpha(c.CGColor) < 0.05) {
        // 退路: 按状态栏明暗取黑/白 (状态栏视图的 traitCollection 跟随前台 App 的样式)
        BOOL dark = NO;
        if (@available(iOS 12.0, *)) dark = (v.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
        c = dark ? [UIColor whiteColor] : [UIColor blackColor];
    }
    return c;
}

// ============================== 动画状态 ==============================
@interface DRLState : NSObject
@property (nonatomic, copy)   NSString* text;
@property (nonatomic, copy)   NSString* prevText;     // 数值变化时上滚的旧数字
@property (nonatomic, assign) double    alpha;        // 出现/消失
@property (nonatomic, assign) double    startAlpha;
@property (nonatomic, assign) double    targetAlpha;
@property (nonatomic, assign) double    appearStart;
@property (nonatomic, assign) double    rollStart;
@end
@implementation DRLState
@end

static const void* kDRLStateKey = &kDRLStateKey;
static double drlNow(void) { return CACurrentMediaTime(); }

static DRLState* drlStateForView(UIView* v) {
    DRLState* s = objc_getAssociatedObject(v, kDRLStateKey);
    if (!s) {
        s = [DRLState new];
        s.alpha = 0.0;
        s.targetAlpha = 0.0;
        s.appearStart = drlNow() - 10.0;
        s.rollStart   = drlNow() - 10.0;
        objc_setAssociatedObject(v, kDRLStateKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return s;
}

// ============================== 绘制 ==============================
static void drlDrawReadout(UIView* v, CGRect rect) {
    if (!gPrefs.enabled) return;
    if (!drlPluginLoaded()) return;
    if (rect.size.width < 8.0 || rect.size.height < 8.0) return;

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    int pct = 0;
    BOOL has = drlPercentForView(v, &pct);
    NSString* text = has ? [NSString stringWithFormat:@"%d", pct] : nil;

    // ---------- 状态机 ----------
    DRLState* st = drlStateForView(v);
    double now = drlNow();
    BOOL needRedraw = NO;

    if (![st.text isEqualToString:(text ?: @"")]) {
        if (st.text.length > 0 && text.length > 0) {     // 数值变了 -> 上滚淡换
            st.prevText = st.text;
            st.rollStart = now;
        } else {
            st.prevText = nil;
        }
        st.text = text;
    }
    if (st.targetAlpha != (text ? 1.0 : 0.0)) {          // 出现/消失
        st.startAlpha = st.alpha;
        st.targetAlpha = text ? 1.0 : 0.0;
        st.appearStart = now;
    }

    double ta = gPrefs.fade ? MIN((now - st.appearStart) / DRL_FADE_DUR, 1.0) : 1.0;
    if (ta < 0.0) ta = 0.0;
    double ea = 1.0 - pow(1.0 - ta, 3.0);                // ease-out
    st.alpha = st.startAlpha + (st.targetAlpha - st.startAlpha) * ea;
    if (ta < 1.0) needRedraw = YES;

    double tr = gPrefs.fade ? MIN((now - st.rollStart) / DRL_ROLL_DUR, 1.0) : 1.0;
    if (tr < 0.0) tr = 0.0;
    if (tr >= 1.0) st.prevText = nil;
    else needRedraw = YES;

    if (needRedraw) [v setNeedsDisplay];
    if (!text || st.alpha <= 0.02) return;

    // ---------- 几何/字体 ----------
    DRLGeom g = drlGeom(rect);
    if (g.r <= 2.0) return;

    UIFont* font = [UIFont systemFontOfSize:g.lw * gPrefs.sizeFactor weight:UIFontWeightBold];
    UIColor* baseColor = drlNumberColor(v);

    NSDictionary* (^attrsFor)(CGFloat) = ^NSDictionary* (CGFloat a) {
        UIColor* c = (a >= 0.999) ? baseColor
                    : [baseColor colorWithAlphaComponent:(CGFloat)(CGColorGetAlpha(baseColor.CGColor) * a)];
        return @{ NSFontAttributeName: font, NSForegroundColorAttributeName: c };
    };

    // 缺口宽度按两段文字里较宽的那个算, 避免滚动时缺口跟着抖
    CGSize sNew = [text sizeWithAttributes:attrsFor(1.0)];
    CGSize sOld = st.prevText ? [st.prevText sizeWithAttributes:attrsFor(1.0)] : CGSizeZero;
    CGFloat textW = MAX(sNew.width, sOld.width);
    CGFloat lineH = font.lineHeight;

    double halfGap = (textW / 2.0 + g.lw * 0.18) / g.r;  // 弧度
    if (halfGap > 1.2) halfGap = 1.2;
    if (!v.opaque) {
        CGContextSaveGState(ctx);
        CGContextSetBlendMode(ctx, kCGBlendModeClear);
        CGContextSetLineWidth(ctx, g.lw * 2.0);
        CGContextSetLineCap(ctx, kCGLineCapButt);
        CGContextAddArc(ctx, g.cx, g.cy, g.r, kTopAngle - halfGap, kTopAngle + halfGap, 0);
        CGContextStrokePath(ctx);
        CGContextRestoreGState(ctx);
    }

    CGFloat cx = g.cx, cyTop = g.cy - g.r;               // 数字圆心落在圆环走线上

    void (^drawOne)(NSString*, CGFloat, CGFloat) = ^(NSString* s, CGFloat dy, CGFloat a) {
        if (!s || a <= 0.02) return;
        CGSize sz = [s sizeWithAttributes:attrsFor(1.0)];
        [s drawInRect:CGRectMake(cx - sz.width / 2.0, cyTop - sz.height / 2.0 + dy, sz.width, sz.height)
       withAttributes:attrsFor(a)];
    };

    if (st.prevText && tr < 1.0) {                       // 上滚: 旧的往上走淡出, 新的从下面上来淡入
        drawOne(st.prevText, -tr * lineH * 0.85, (1.0 - tr) * st.alpha);
        drawOne(text,        (1.0 - tr) * lineH * 0.85, tr * st.alpha);
    } else {
        drawOne(text, 0.0, st.alpha);
    }
}

// ============================== Hook ==============================
static NSArray<NSString*>* drlRingClasses(void) {
    return @[ @"STUIStatusBarCellularSignalView",
              @"_UIStatusBarCellularSignalView",
              @"STUIStatusBarDualCellularSignalView",
              @"_UIStatusBarDualCellularSignalView",
              @"_UIBatteryView",
              @"STUIStatusBarStaticBatteryView",
              @"_UIStaticBatteryView" ];
}

#define DRL_MAX 16
static IMP      gOrigDrawRect[DRL_MAX];
static IMP      gOrigCharge[DRL_MAX];
static IMP      gOrigBars[DRL_MAX];
static Class    gClasses[DRL_MAX];

static IMP drlOrigFor(id self, IMP* tbl) {
    for (int i = 0; i < DRL_MAX; i++) {
        if (gClasses[i] && [self isKindOfClass:gClasses[i]]) return tbl[i];
    }
    return NULL;
}

static void drlDrawRectHook(id self, SEL _cmd, CGRect rect) {
    IMP orig = drlOrigFor(self, gOrigDrawRect);
    if (orig) ((void (*)(id, SEL, CGRect))orig)(self, _cmd, rect);
    @try {
        drlDrawReadout((UIView*)self, rect);
    } @catch (NSException* e) {
        drlLog(@"draw exception: %@", e);
    }
}

// 抓真实值(插件 hook 了同样的 setter, 我们是链在它后面)
static void drlSetChargePercentHook(id self, SEL _cmd, double v) {
    objc_setAssociatedObject(self, &kDRLCapturedKey, @(v), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    IMP orig = drlOrigFor(self, gOrigCharge);
    if (orig) ((void (*)(id, SEL, double))orig)(self, _cmd, v);
    [(UIView*)self setNeedsDisplay];
}

static void drlSetBarsHook(id self, SEL _cmd, long long v) {
    objc_setAssociatedObject(self, &kDRLCapturedKey, @(v), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    IMP orig = drlOrigFor(self, gOrigBars);
    if (orig) ((void (*)(id, SEL, long long))orig)(self, _cmd, v);
    [(UIView*)self setNeedsDisplay];
}

static void drlInstallHooks(void) {
    if (gStartTime <= 0.0) gStartTime = drlNow();
    drlEnsureDefaults();
    gPrefs = drlPrefs();
    drlInstallLiveBattery();
    drlInstallExtraRings();

    NSArray<NSString*>* names = drlRingClasses();
    int n = 0;
    for (NSUInteger i = 0; i < names.count && n < DRL_MAX; i++) {
        Class cls = NSClassFromString(names[i]);
        if (!cls) continue;
        Method m = class_getInstanceMethod(cls, @selector(drawRect:));
        if (!m) continue;
        if (method_getImplementation(m) == (IMP)drlDrawRectHook) continue;   // 已装过

        IMP old = NULL;
        MSHookMessageEx(cls, @selector(drawRect:), (IMP)drlDrawRectHook, &old);

        IMP oldC = NULL, oldB = NULL;
        SEL selC = NSSelectorFromString(@"setChargePercent:");
        SEL selB = NSSelectorFromString(@"setNumberOfActiveBars:");
        if (class_getInstanceMethod(cls, selC) &&
            method_getImplementation(class_getInstanceMethod(cls, selC)) != (IMP)drlSetChargePercentHook) {
            MSHookMessageEx(cls, selC, (IMP)drlSetChargePercentHook, &oldC);
        }
        if (class_getInstanceMethod(cls, selB) &&
            method_getImplementation(class_getInstanceMethod(cls, selB)) != (IMP)drlSetBarsHook) {
            MSHookMessageEx(cls, selB, (IMP)drlSetBarsHook, &oldB);
        }

        gClasses[n] = cls;
        gOrigDrawRect[n] = old;
        gOrigCharge[n] = oldC;
        gOrigBars[n] = oldB;
        n++;
        drlLog(@"hooked %@  drawRect:(orig=%p) setChargePercent:(orig=%p) setBars:(orig=%p)",
               names[i], old, oldC, oldB);
    }
    drlLog(@"install done, %d class(es); primary=%ld secondary=%ld single=%ld dual=%ld battery=%ld size=%.2f",
           n, (long)gPrefs.cPrimary, (long)gPrefs.cSecondary, (long)gPrefs.cSingle,
           (long)gPrefs.cDual, (long)gPrefs.cBattery, gPrefs.sizeFactor);
}

// 插件在进程启动早期就 hook 了同样的方法; 我们延迟安装以确保
// "我们的 original = 插件的实现", 顺序才正确。
__attribute__((constructor)) static void drlInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        drlInstallHooks();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSArray<NSString*>* names = drlRingClasses();
        for (NSUInteger i = 0; i < names.count; i++) {
            Class cls = NSClassFromString(names[i]);
            if (!cls) continue;
            Method m = class_getInstanceMethod(cls, @selector(drawRect:));
            if (!m) continue;
            if (method_getImplementation(m) != (IMP)drlDrawRectHook) {
                drlLog(@"re-install (plugin hooked later?)");
                drlInstallHooks();
                break;
            }
        }
    });
}

// ============================== 额外圆环(插件没画的视图) ==============================
// 插件只给"信号/双卡/电量"画环; 需要在"数据/网络类型(5G/LTE)"之类的视图上再补一个环时用这里。
// 只画"正常状态"的环: 与插件同款几何(163.8° 起, 扫 212.4°, 底部留缺口), 灰轨道, 不带数字/填充。
static const void* kDRLExtraRingKey = &kDRLExtraRingKey;

static UIColor* drlTrackColor(UIView* v) {
    UIColor* c = nil;
    if ([v respondsToSelector:NSSelectorFromString(@"bodyColor")]) c = [(id)v bodyColor];
    if ((!c || CGColorGetAlpha(c.CGColor) < 0.05) && v.tintColor) c = v.tintColor;
    if (!c) c = [UIColor blackColor];
    return [c colorWithAlphaComponent:0.28];      // 插件的轨道透明度
}

static void drlUpdateExtraRing(UIView* v) {
    CGRect b = v.bounds;
    if (b.size.width < 6.0 || b.size.height < 6.0) return;
    CGFloat minDim = MIN(b.size.width, b.size.height);
    CGFloat lw = MAX(kLineWidthRatio * minDim, 1.0);
    CGFloat r  = minDim * 0.5 - kRadiusInset * lw;
    if (r <= 1.0) return;

    CAShapeLayer* ring = objc_getAssociatedObject(v, kDRLExtraRingKey);
    if (!ring) {
        ring = [CAShapeLayer layer];
        ring.fillColor = nil;
        ring.lineCap = kCALineCapButt;
        ring.zPosition = 5;
        objc_setAssociatedObject(v, kDRLExtraRingKey, ring, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [v.layer addSublayer:ring];
    }
    ring.frame = b;
    ring.lineWidth = lw;
    ring.strokeColor = drlTrackColor(v).CGColor;

    CGPoint c = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
    UIBezierPath* path = [UIBezierPath bezierPath];
    const int steps = 64;
    for (int i = 0; i <= steps; i++) {
        double th = (163.8 + 212.4 * (double)i / (double)steps) * M_PI / 180.0;
        CGPoint pt = CGPointMake(c.x + r * cos(th), c.y + r * sin(th));
        if (i == 0) [path moveToPoint:pt]; else [path addLineToPoint:pt];
    }
    ring.path = path.CGPath;
}

// 由偏好设置 extraRings 指定(数组, 类名); 缺省 = 数据/网络类型视图
static NSArray<NSString*>* drlExtraRingClasses(void) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("extraRings"),
                                                   (__bridge CFStringRef)kPrefDomain);
    NSArray* arr = nil;
    if (v) {
        if (CFGetTypeID(v) == CFArrayGetTypeID()) arr = [(__bridge NSArray*)v copy];
        CFRelease(v);
    }
    if (arr) return arr;
    return @[ @"STUIStatusBarCellularNetworkTypeView", @"_UIStatusBarCellularNetworkTypeView" ];
}

static IMP gOrigLayout[DRL_MAX];
static NSMutableArray<NSString*>* gExtraNames = nil;

static void drlLayoutHook(id self, SEL _cmd) {
    IMP orig = drlOrigFor(self, gOrigLayout);
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
    @try { drlUpdateExtraRing((UIView*)self); } @catch (NSException* e) { }
}

static void drlInstallExtraRings(void) {
    NSArray<NSString*>* names = drlExtraRingClasses();
    if (!gExtraNames) gExtraNames = [NSMutableArray array];
    for (NSString* nm in names) {
        Class cls = NSClassFromString(nm);
        if (!cls) continue;
        SEL sel = @selector(layoutSubviews);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) continue;
        if (method_getImplementation(m) == (IMP)drlLayoutHook) continue;
        // 复用 gClasses 的槽位来记录"这是额外环的类"
        int slot = -1;
        for (int i = 0; i < DRL_MAX; i++) if (gClasses[i] == cls) { slot = i; break; }
        IMP old = NULL;
        MSHookMessageEx(cls, sel, (IMP)drlLayoutHook, &old);
        if (slot < 0) {
            for (int i = 0; i < DRL_MAX; i++) if (!gClasses[i]) { slot = i; break; }
        }
        if (slot >= 0) { gClasses[slot] = cls; gOrigLayout[slot] = old; }
        [gExtraNames addObject:nm];
        drlLog(@"extra ring on %@ layoutSubviews (orig=%p)", nm, old);
    }
}
