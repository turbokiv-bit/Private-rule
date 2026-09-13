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
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#import <mach-o/dyld.h>

// ============================== 配置 ==============================
#define DRL_LOG  1
// 诊断: 所有日志同时写进文件(Filza 可直接看/发出来)。排查完可以设成 0。
#define DRL_DIAG 1
#define DRL_LOG_FILE   "/var/mobile/Media/DuoReadout.log"
#define DRL_LOG_FILE2  "/var/mobile/Library/Caches/DuoReadout.log"
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
    BOOL       drawMissing;   // 插件没画环的位置, 我们自己补一个环
    BOOL       splitDual;     // 双卡合成环: 擦掉合并环, 给每张卡各画一个
    BOOL       fade;
    NSString*  colorMode;    // auto(默认) / body / tint
    BOOL       outline;      // 数字加一层反色描边(任何背景都看得见)
    double     sizeFactor;
    DRLContent cPrimary;     // 主卡环
    DRLContent cSecondary;   // 副卡环
    DRLContent cSingle;      // 单卡/普通蜂窝环
    DRLContent cDual;        // 双卡合成环(容器)
    DRLContent cBattery;     // 电量环
} DRLPrefs;

static DRLPrefs gPrefs;
static BOOL     gSeenDual = NO;            // 见过双卡合成环吗
static BOOL     gPrimarySeen = NO, gSecondarySeen = NO, gSingleSeen = NO, gBatterySeen = NO;
static BOOL     gNumberShown = NO;         // 屏幕上已经有环在显示数字了吗

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
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    if (exists) {
        double v = drlPrefDouble(@"configVersion", 0.0);
        if (v >= 3.0) return;              // 已是新版配置
        drlLog(@"upgrading prefs v%.0f -> v3", v);
    }
    CFStringRef app = CFSTR("com.callassist.duoringreadout");
    CFPreferencesSetAppValue(CFSTR("configVersion"),  (__bridge CFNumberRef)@3.0, app);
    CFPreferencesSetAppValue(CFSTR("enabled"),         kCFBooleanTrue, app);
    CFPreferencesSetAppValue(CFSTR("drawMissingRings"), kCFBooleanTrue, app);
    CFPreferencesSetAppValue(CFSTR("splitDualRings"),   kCFBooleanTrue, app);
    CFPreferencesSetAppValue(CFSTR("fade"),            kCFBooleanTrue, app);
    CFPreferencesSetAppValue(CFSTR("sizeFactor"),      (__bridge CFNumberRef)@3.0, app);
    CFPreferencesSetAppValue(CFSTR("outline"),         kCFBooleanTrue, app);
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
    p.drawMissing = drlPrefBool(@"drawMissingRings", YES);
    p.splitDual  = drlPrefBool(@"splitDualRings", YES);
    p.fade       = drlPrefBool(@"fade", YES);
    p.colorMode  = drlPrefString(@"numberColor") ?: @"auto";
    p.outline    = drlPrefBool(@"outline", YES);
    p.sizeFactor = drlPrefDouble(@"sizeFactor", 3.0);
    if (p.sizeFactor < 0.8) p.sizeFactor = 0.8;
    if (p.sizeFactor > 5.0) p.sizeFactor = 5.0;
    p.cPrimary   = drlContentFromString(drlPrefString(@"numberPrimary"),   DRLContentBattery);
    p.cSecondary = drlContentFromString(drlPrefString(@"numberSecondary"), DRLContentOff);   // 副卡默认"正常状态"(无数字)
    p.cSingle    = drlContentFromString(drlPrefString(@"numberSingle"),    DRLContentBattery);
    p.cDual      = drlContentFromString(drlPrefString(@"numberDual"),      DRLContentOff);
    p.cBattery   = drlContentFromString(drlPrefString(@"numberBattery"),   DRLContentAuto);
    return p;
}

static void drlLogToFiles(NSString* line) {
#if DRL_DIAG
    const char* paths[2] = { DRL_LOG_FILE, DRL_LOG_FILE2 };
    for (int i = 0; i < 2; i++) {
        struct stat st;
        if (stat(paths[i], &st) == 0 && st.st_size > 256 * 1024) unlink(paths[i]);  // 简单轮转
        FILE* f = fopen(paths[i], "a");
        if (!f) continue;
        const char* c = line.UTF8String;
        if (c) fwrite(c, 1, strlen(c), f);
        fclose(f);
    }
#endif
}

static void drlLog(NSString* fmt, ...) {
#if DRL_LOG
    va_list ap; va_start(ap, fmt);
    NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[DuoReadout] %@", s);
    drlLogToFiles([NSString stringWithFormat:@"[DuoReadout] %@\n", s]);
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

// ---- 插件镜像 base / "插件到底给这个视图画环了吗" ----
// 插件会给"要画环"的视图关联一个 NSNumber(YES), key = base+0x10648 (反汇编 0x835c 里读的就是它)
static uintptr_t gPluginBase = 0;
static uintptr_t drlPluginBase(void) {
    if (gPluginBase) return gPluginBase;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char* nm = _dyld_get_image_name(i);
        if (nm && strstr(nm, "CAiPhoneDuoStatus")) {
            gPluginBase = (uintptr_t)_dyld_get_image_header(i);
            break;
        }
    }
    return gPluginBase;
}

static BOOL drlPluginDrewRing(UIView* v) {
    uintptr_t base = drlPluginBase();
    if (!base) return YES;                       // 拿不到 base 就保守认为它画了
    id n = objc_getAssociatedObject(v, (void*)(base + 0x10648));
    if ([n isKindOfClass:[NSNumber class]]) return [n boolValue];
    return NO;                                   // 没有标记 -> 插件没画
}

// ============================== 实时电量 ==============================
// 直接读系统电源信息(和状态栏电量同源), 不依赖插件/视图是否把值写回。
// 事件驱动: IOPS 电源变化通知 + 30s 兜底, 变化时让圆环重绘 -> 数字实时刷新。
//
// 注意: IOKit 的 ps 符号在 iOS SDK 的 tbd 里不一定导出(直接调用会链接失败),
// 所以统一用 dlsym 动态取; 取不到就退到 UIDevice.batteryLevel。
static NSHashTable* gLiveViews = nil;        // 需要刷新的视图(弱引用)
static int gLastLivePercent = -1;

typedef CFTypeRef       (*drl_fn_IOPSInfo)(void);
typedef CFArrayRef      (*drl_fn_IOPSList)(CFTypeRef);
typedef CFDictionaryRef (*drl_fn_IOPSDesc)(CFTypeRef, CFTypeRef);
typedef CFRunLoopSourceRef (*drl_fn_IOPSNotifySrc)(void (*)(void*), void*);

static void* drlSym(const char* name) {
    static void* h = (void*)-1;
    if (h == (void*)-1) {
        h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (!h) h = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (!h) h = NULL;
    }
    if (h) {
        void* p = dlsym(h, name);
        if (p) return p;
    }
    return dlsym(RTLD_DEFAULT, name);       // 进程里已加载的情况
}

static int drlLiveBatteryPercent(void) {
    int pct = -1;
    drl_fn_IOPSInfo infoFn = (drl_fn_IOPSInfo)drlSym("IOPSCopyPowerSourcesInfo");
    drl_fn_IOPSList listFn = (drl_fn_IOPSList)drlSym("IOPSCopyPowerSourcesList");
    drl_fn_IOPSDesc descFn = (drl_fn_IOPSDesc)drlSym("IOPSGetPowerSourceDescription");
    if (infoFn && listFn && descFn) {
        CFTypeRef info = infoFn();
        if (info) {
            CFArrayRef list = listFn(info);
            if (list) {
                for (CFIndex i = 0; i < CFArrayGetCount(list) && pct < 0; i++) {
                    CFTypeRef ps = CFArrayGetValueAtIndex(list, i);
                    CFDictionaryRef desc = descFn(info, ps);
                    if (!desc) continue;
                    // kIOPSCurrentCapacityKey = "Current Capacity", kIOPSMaxCapacityKey = "Max Capacity"
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
    drl_fn_IOPSNotifySrc notifyFn =
        (drl_fn_IOPSNotifySrc)drlSym("IOPSNotificationCreateRunLoopSource");
    if (notifyFn) {
        CFRunLoopSourceRef src = notifyFn(drlPowerSourceChanged, NULL);
        if (src) {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopDefaultMode);
            CFRelease(src);
        }
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

// 决定"这个环显示什么" —— 自适应:
//   1) 明确配置了的(非 off)优先;
//   2) 电量环的 auto: 主卡环/单卡环已经在显示电量 -> 它不显示; 否则它显示(等 1.5s 确认);
//   3) 兜底: 3 秒后屏幕上还没有任何数字 -> 信号环顶上显示实时电量。
static DRLContent drlEffectiveContent(DRLRole role, BOOL isBatteryView, BOOL isBarsView) {
    DRLContent c = DRLContentOff;
    switch (role) {
        case DRLRoleBattery:   c = gPrefs.cBattery;   break;
        case DRLRolePrimary:   c = gPrefs.cPrimary;   break;
        case DRLRoleSecondary: c = gPrefs.cSecondary; break;
        case DRLRoleSingle:    c = gPrefs.cSingle;    break;
        case DRLRoleDual:      c = gPrefs.cDual;      break;
    }
    double up = (gStartTime > 0.0) ? (drlNow() - gStartTime) : 0.0;

    // auto 只对"电量环"有意义
    if (c == DRLContentAuto) {
        if (role != DRLRoleBattery) {
            c = DRLContentOff;
        } else if (gPrefs.cPrimary == DRLContentBattery && gPrimarySeen) {
            c = DRLContentOff;
        } else if (gPrefs.cSingle == DRLContentBattery && gSingleSeen) {
            c = DRLContentOff;
        } else {
            c = (up > 1.5) ? DRLContentBattery : DRLContentOff;
        }
    }
    if (c != DRLContentOff) return c;
    // 兜底: 3 秒后屏幕上还没有任何数字 -> 信号环顶上显示实时电量
    if (up > 3.0 && !gNumberShown && isBarsView) return DRLContentBattery;
    return DRLContentOff;
}

// ============================== 取值 ==============================
static const void* kDRLCapturedKey = &kDRLCapturedKey;   // NSNumber: 最近一次 setter 的值
static DRLRole    gLastRole = DRLRoleSingle;             // 仅供日志
static DRLContent gLastContent = DRLContentOff;

@interface NSObject (DRLPrivate)
- (double)chargePercent;          // *_BatteryView / *_StaticBatteryView
- (long long)numberOfActiveBars;  // *_CellularSignalView
- (long long)numberOfBars;
- (UIColor*)bodyColor;
- (UIColor*)activeColor;
- (UIColor*)inactiveColor;
@end

// 算出这个环该显示的数字(0~100); 返回 NO = 这个环不显示数字
static BOOL drlPercentForView(UIView* v, int* outPercent) {
    BOOL batteryView = [v respondsToSelector:NSSelectorFromString(@"chargePercent")];
    BOOL barsView    = [v respondsToSelector:NSSelectorFromString(@"numberOfActiveBars")];
    if (!batteryView && !barsView) return NO;          // 只处理"电量/信号"这两类环
    DRLRole role = drlRoleOfView(v);
    if (batteryView)                            gBatterySeen = YES;
    else if (role == DRLRolePrimary)            gPrimarySeen = YES;
    else if (role == DRLRoleSecondary)          gSecondarySeen = YES;
    else if (role == DRLRoleSingle)             gSingleSeen  = YES;
    DRLContent c = drlEffectiveContent(role, batteryView, barsView);
    gLastRole = role; gLastContent = c;
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

static UIColor* drlSolid(UIColor* c) {          // 半透明的颜色(轨道色)当数字色会看不清, 强制不透明
    if (!c) return nil;
    CGFloat a = CGColorGetAlpha(c.CGColor);
    if (a <= 0.05) return nil;
    return (a >= 0.95) ? c : [c colorWithAlphaComponent:1.0];
}

// tintColor 没被设置时是系统默认蓝, 那不是状态栏前景色, 要跳过
static BOOL drlIsDefaultTint(UIColor* c) {
    if (!c) return YES;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return NO;
    UIColor* blue = [UIColor systemBlueColor];
    CGFloat br = 0, bg = 0, bb = 0, ba = 0;
    [blue getRed:&br green:&bg blue:&bb alpha:&ba];
    return (fabs(r - br) < 0.06 && fabs(g - bg) < 0.06 && fabs(b - bb) < 0.06);
}

static UIColor* drlStyleObjectColor(UIView* v) {   // 插件关联对象上的 activeColor/bodyColor
    uintptr_t base = drlPluginBase();
    if (!base) return nil;
    const uintptr_t keys[5] = {0x10640, 0x10648, 0x10650, 0x10658, 0x10660};
    for (int i = 0; i < 5; i++) {
        id obj = objc_getAssociatedObject(v, (void*)(base + keys[i]));
        if (!obj || ![obj isKindOfClass:[NSObject class]]) continue;
        if ([obj isKindOfClass:[NSNumber class]]) continue;
        for (NSString* sel in @[@"activeColor", @"bodyColor", @"inactiveColor"]) {
            SEL s2 = NSSelectorFromString(sel);
            if (![obj respondsToSelector:s2]) continue;
            UIColor* c = ((UIColor* (*)(id, SEL))objc_msgSend)(obj, s2);
            UIColor* r = drlSolid(c);
            if (r) return r;
        }
    }
    return nil;
}

static UIColor* drlPickColor(UIView* v) {
    NSString* mode = gPrefs.colorMode ?: @"auto";
    if ([mode isEqualToString:@"black"]) return [UIColor blackColor];
    if ([mode isEqualToString:@"white"]) return [UIColor whiteColor];

    if ([mode isEqualToString:@"body"]) {
        if ([v respondsToSelector:NSSelectorFromString(@"bodyColor")])
            { UIColor* c = drlSolid([(id)v bodyColor]); if (c) return c; }
    } else if ([mode isEqualToString:@"tint"]) {
        UIColor* c = drlSolid(v.tintColor); if (c) return c;
    } else {
        // auto: (a) 插件自己的样式对象(黑/白, 最准) -> (b) 真正设置过的 tintColor -> (c) active/body
        UIColor* c = drlStyleObjectColor(v);
        if (c) return c;
        if (!drlIsDefaultTint(v.tintColor)) {
            c = drlSolid(v.tintColor);
            if (c) return c;
        }
        if ([v respondsToSelector:NSSelectorFromString(@"activeColor")])
            { c = drlSolid([(id)v activeColor]); if (c) return c; }
        if ([v respondsToSelector:NSSelectorFromString(@"bodyColor")])
            { c = drlSolid([(id)v bodyColor]); if (c) return c; }
    }
    BOOL dark = NO;
    if (@available(iOS 12.0, *)) dark = (v.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    return dark ? [UIColor whiteColor] : [UIColor blackColor];
}

static UIColor* drlNumberColor(UIView* v) { return drlPickColor(v); }

// ============================== 自己补环 ==============================
// 插件在 iOS 26 上只给一部分项目画了环; 对"插件没画"的槽位我们自己补一个同款环
// (轨道 = bodyColor×0.28, 进度 = activeColor, 4 个点 = 信号格), 这样主卡/副卡能各有一个环。
static double drlRingProgress(UIView* v, BOOL batteryView, BOOL barsView) {
    if (batteryView) {
        NSNumber* cap = objc_getAssociatedObject(v, &kDRLCapturedKey);
        double p = cap ? cap.doubleValue : [(id)v chargePercent];
        if (p > 1.0) p /= 100.0;
        return MAX(0.0, MIN(1.0, p));
    }
    if (barsView) {
        long long bars = 0, total = 4;
        NSNumber* cap = objc_getAssociatedObject(v, &kDRLCapturedKey);
        if (cap) bars = cap.longLongValue;
        else     bars = [(id)v numberOfActiveBars];
        if ([v respondsToSelector:NSSelectorFromString(@"numberOfBars")]) {
            long long t = [(id)v numberOfBars];
            if (t > 0 && t <= 8) total = t;
        }
        if (bars < 0) bars = 0;
        return (total > 0) ? MAX(0.0, MIN(1.0, (double)bars / (double)total)) : 0.0;
    }
    return 0.0;
}

static void drlDrawOwnRing(UIView* v, CGRect rect, CGContextRef ctx, double progress, BOOL withDots) {
    DRLGeom g = drlGeom(rect);
    if (g.r <= 1.5) return;
    UIColor* body = nil;
    if ([v respondsToSelector:NSSelectorFromString(@"bodyColor")]) body = [(id)v bodyColor];
    if (!body || CGColorGetAlpha(body.CGColor) < 0.05) body = drlPickColor(v);
    UIColor* fill = drlPickColor(v);

    const double start = 163.8 * M_PI / 180.0;
    const double sweep = 212.4 * M_PI / 180.0;

    CGContextSaveGState(ctx);
    CGContextSetLineWidth(ctx, g.lw);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetStrokeColorWithColor(ctx, [body colorWithAlphaComponent:0.28].CGColor);
    CGContextAddArc(ctx, g.cx, g.cy, g.r, start, start + sweep, 0);
    CGContextStrokePath(ctx);
    if (progress > 0.001) {
        CGContextSetStrokeColorWithColor(ctx, fill.CGColor);
        CGContextAddArc(ctx, g.cx, g.cy, g.r, start, start + sweep * progress, 0);
        CGContextStrokePath(ctx);
    }
    if (withDots) {
        CGContextSetFillColorWithColor(ctx, fill.CGColor);
        double d = g.lw * 0.55;
        for (int i = 0; i < 4; i++) {
            double a = (90.0 + ((double)i - 1.5) * 26.0) * M_PI / 180.0;
            CGPoint pt = CGPointMake(g.cx + g.r * cos(a), g.cy + g.r * sin(a));
            CGContextFillEllipseInRect(ctx, CGRectMake(pt.x - d / 2, pt.y - d / 2, d, d));
        }
    }
    CGContextRestoreGState(ctx);
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
        s.alpha = -1.0;              // -1 = 还没画过
        s.targetAlpha = 0.0;
        s.appearStart = drlNow() - 10.0;
        s.rollStart   = drlNow() - 10.0;
        objc_setAssociatedObject(v, kDRLStateKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return s;
}

// ============================== 绘制 ==============================
static void drlDrawReadout(UIView* v, CGRect rect) {
#if DRL_DIAG
    static int s_enterLogs = 0;
    if (s_enterLogs < 100) {
        s_enterLogs++;
        drlLog(@"ENTER draw %@ rect=%@ enabled=%d plugin=%d",
               NSStringFromClass([v class]), NSStringFromCGRect(rect),
               gPrefs.enabled, drlPluginLoaded());
    }
#endif
    if (!gPrefs.enabled) return;
    if (!drlPluginLoaded()) return;
    if (rect.size.width < 8.0 || rect.size.height < 8.0) return;
    // 状态栏里有些是"内部小视图"(例如 9pt/4pt 的信号子视图), 环太小画了也看不见,
    // 只画真正当作圆环显示的那种(插件环直径 = min(w,h), 实际约 14~16pt)
    if (MIN(rect.size.width, rect.size.height) < 11.0) return;
    if (v.hidden || v.alpha <= 0.05) return;          // 状态栏里很多项目是隐藏的, 别浪费力气

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    int pct = 0;
    BOOL has = drlPercentForView(v, &pct);
#if DRL_DIAG
    static int s_drawLogs = 0;
    if (s_drawLogs < 100) {
        s_drawLogs++;
        drlLog(@"     -> role=%ld content=%ld has=%d pct=%d",
               (long)gLastRole, (long)gLastContent, has, pct);
    }
#endif
    NSString* text = has ? [NSString stringWithFormat:@"%d", pct] : nil;

    // ---------- 状态机 ----------
    DRLState* st = drlStateForView(v);
    double now = drlNow();
    BOOL needRedraw = NO;
    if (st.alpha < 0.0) {                    // 第一次绘制: 直接定到目标透明度
        st.alpha = text ? 1.0 : 0.0;
        st.targetAlpha = st.alpha;
        st.appearStart = now - 10.0;
    }

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

    // ---------- 容器类视图(双卡合成环): 拆成"每张卡一个环" ----------
    BOOL isBatteryV0 = [v respondsToSelector:NSSelectorFromString(@"chargePercent")];
    BOOL isBarsV0    = [v respondsToSelector:NSSelectorFromString(@"numberOfActiveBars")];
    BOOL isSignalV0  = isBatteryV0 || isBarsV0;
    if (!isSignalV0 && gPrefs.splitDual && MIN(rect.size.width, rect.size.height) >= 11.0 &&
        !v.hidden && v.alpha > 0.05) {
        NSMutableArray* subs = [NSMutableArray array];
        for (UIView* s1 in v.subviews) {
            BOOL sig = [s1 respondsToSelector:NSSelectorFromString(@"numberOfActiveBars")] ||
                       [s1 respondsToSelector:NSSelectorFromString(@"chargePercent")];
            if (sig && !s1.hidden) [subs addObject:s1];
        }
#if DRL_DIAG
        static int s_contLogs = 0;
        if (s_contLogs < 12) {
            s_contLogs++;
            drlLog(@"CONTAINER %@ rect=%@ subviews=%lu pluginDrew=%d split=%d",
                   NSStringFromClass([v class]), NSStringFromCGRect(rect),
                   (unsigned long)v.subviews.count, drlPluginDrewRing(v), gPrefs.splitDual);
        }
#endif
        if (subs.count >= 1) {
            if (drlPluginDrewRing(v)) CGContextClearRect(ctx, rect);   // 擦掉插件那个合并环
            for (NSUInteger i = 0; i < subs.count; i++) {
                UIView* sv = subs[i];
                CGRect r = [sv convertRect:sv.bounds toView:v];
                if (MIN(r.size.width, r.size.height) < 6.0) continue;
                BOOL svBat  = [sv respondsToSelector:NSSelectorFromString(@"chargePercent")];
                BOOL svBars = [sv respondsToSelector:NSSelectorFromString(@"numberOfActiveBars")];
                double rp = drlRingProgress(sv, svBat, svBars);
                drlDrawOwnRing(v, r, ctx, rp, svBars);
#if DRL_DIAG
                static int s_splitLogs = 0;
                if (s_splitLogs < 20) {
                    s_splitLogs++;
                    drlLog(@"SPLIT-RING %@ sub[%lu] %@ r=%@ prog=%.2f", NSStringFromClass([v class]),
                           (unsigned long)i, NSStringFromClass([sv class]), NSStringFromCGRect(r), rp);
                }
#endif
            }
        }
    }

    // ---------- 插件没画环的槽位: 我们补一个 ----------
    BOOL isBatteryV = [v respondsToSelector:NSSelectorFromString(@"chargePercent")];
    BOOL isBarsV    = [v respondsToSelector:NSSelectorFromString(@"numberOfActiveBars")];
    BOOL pluginDrew = drlPluginDrewRing(v);
    if (!pluginDrew && gPrefs.drawMissing && MIN(rect.size.width, rect.size.height) >= 11.0) {
        double rp = drlRingProgress(v, isBatteryV, isBarsV);
        drlDrawOwnRing(v, rect, ctx, rp, isBarsV);
#if DRL_DIAG
        static int s_selfRings = 0;
        if (s_selfRings < 40) {
            s_selfRings++;
            drlLog(@"SELF-RING %@ rect=%@ win=%@ prog=%.2f dots=%d",
                   NSStringFromClass([v class]), NSStringFromCGRect(rect),
                   NSStringFromCGRect([v convertRect:v.bounds toView:nil]), rp, isBarsV);
        }
#endif
    }

    // ---------- 几何/字体 ----------
    DRLGeom g = drlGeom(rect);
    if (g.r <= 2.0) return;

    UIFont* font = [UIFont systemFontOfSize:g.lw * gPrefs.sizeFactor weight:UIFontWeightBold];
    UIColor* baseColor = drlNumberColor(v);

    // 反色(按亮度判断) + 描边 -> 亮底暗底都能看清
    UIColor* strokeColor = nil;
    if (gPrefs.outline) {
        CGFloat r = 0.5, g = 0.5, b = 0.5, a = 1;
        [baseColor getRed:&r green:&g blue:&b alpha:&a];
        double lum = 0.299 * r + 0.587 * g + 0.114 * b;
        strokeColor = (lum > 0.5) ? [UIColor blackColor] : [UIColor whiteColor];
    }
    NSDictionary* (^attrsFor)(CGFloat) = ^NSDictionary* (CGFloat a) {
        UIColor* c = (a >= 0.999) ? baseColor
                    : [baseColor colorWithAlphaComponent:(CGFloat)(CGColorGetAlpha(baseColor.CGColor) * a)];
        if (strokeColor) {
            return @{ NSFontAttributeName: font,
                      NSForegroundColorAttributeName: c,
                      NSStrokeColorAttributeName: strokeColor,
                      NSStrokeWidthAttributeName: @(-2.5) };
        }
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

    gNumberShown = YES;                                  // 屏幕上有数字了
#if DRL_DIAG
    static int s_drawOk = 0;
    if (s_drawOk < 60) {
        s_drawOk++;
        UIColor* _c = drlPickColor(v);
        CGFloat _r = -1, _g = -1, _b = -1, _a = -1;
        [_c getRed:&_r green:&_g blue:&_b alpha:&_a];      // 公开 API
        drlLog(@"DRAW %@ text=%@ alpha=%.2f lw=%.2f r=%.2f center=(%.1f,%.1f) win=%@ color=(%.2f,%.2f,%.2f,%.2f)",
               NSStringFromClass([v class]), text, st.alpha, g.lw, g.r, g.cx, g.cy,
               NSStringFromCGRect([v convertRect:v.bounds toView:nil]),
               (double)_r, (double)_g, (double)_b, (double)_a);
    }
#endif
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

#define DRL_MAX 256
static IMP      gOrigDrawRect[DRL_MAX];
static IMP      gOrigCharge[DRL_MAX];
static IMP      gOrigBars[DRL_MAX];
static Class    gClasses[DRL_MAX];

static IMP drlOrigFor(id self, IMP* tbl) {
    Class c = object_getClass(self);
    for (int i = 0; i < DRL_MAX; i++) if (gClasses[i] == c) return tbl[i];       // 精确匹配
    for (Class sup = class_getSuperclass(c); sup; sup = class_getSuperclass(sup)) {
        for (int i = 0; i < DRL_MAX; i++) if (gClasses[i] == sup) return tbl[i]; // 最近的祖先
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

// 广覆盖: 把所有 "自己实现了 drawRect:" 的 StatusBar 类都挂上。
// 这样即使 iOS 版本改了类名(插件靠类名挂的 hook 我们能覆盖到), 也不会漏。
// 真正画不画由 drlPercentForView 里的"能力判定"决定(必须有 chargePercent 或 numberOfActiveBars),
// 所以不会误伤别的视图。
static int drlHookAllStatusBarClasses(void) {
    int hooked = 0;
    unsigned int count = 0;
    Class* classes = objc_copyClassList(&count);
    if (!classes) return 0;
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char* nm = class_getName(cls);
        if (!nm || !strstr(nm, "StatusBar")) continue;
        Method m = class_getInstanceMethod(cls, @selector(drawRect:));
        if (!m) continue;
        // 只处理"自己实现"了 drawRect: 的类, 避免把继承来的实现重复挂
        BOOL own = NO;
        unsigned int mc = 0;
        Method* ms = class_copyMethodList(cls, &mc);
        if (ms) {
            for (unsigned int j = 0; j < mc; j++) {
                if (method_getName(ms[j]) == @selector(drawRect:)) { own = YES; break; }
            }
            free(ms);
        }
        if (!own) continue;
        if (method_getImplementation(m) == (IMP)drlDrawRectHook) continue;
        int slot = -1;
        for (int k = 0; k < DRL_MAX; k++) if (gClasses[k] == cls) { slot = k; break; }
        if (slot < 0) for (int k = 0; k < DRL_MAX; k++) if (!gClasses[k]) { slot = k; break; }
        if (slot < 0) break;
        IMP old = NULL;
        MSHookMessageEx(cls, @selector(drawRect:), (IMP)drlDrawRectHook, &old);
        gClasses[slot] = cls;
        gOrigDrawRect[slot] = old;
        hooked++;
        drlLog(@"broad-hooked %s", nm);
    }
    free(classes);
    return hooked;
}

// ---- 诊断: 把状态栏里相关视图的 frame 打出来(判断主卡/副卡各在哪) ----
static void drlDumpView(UIView* v, int depth, int* budget) {
    if (!v || depth > 4 || *budget <= 0) return;
    (*budget)--;
    NSString* pad = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2) withString:@" " startingAtIndex:0];
    drlLog(@"%@%@ frame=%@ hidden=%d alpha=%.1f",
           pad, NSStringFromClass([v class]), NSStringFromCGRect(v.frame), v.hidden, v.alpha);
    for (UIView* sub in v.subviews) drlDumpView(sub, depth + 1, budget);
}

static void drlDumpStatusBar(void) {
    int budget = 70;
    for (UIWindow* w in UIApplication.sharedApplication.windows) {
        CGFloat lvl = w.windowLevel;
        if (lvl < UIWindowLevelStatusBar - 1.0 || lvl > UIWindowLevelStatusBar + 1.0) continue;
        drlLog(@"--- statusbar window %@ level=%.0f ---", NSStringFromClass([w class]), (double)lvl);
        drlDumpView(w, 0, &budget);
    }
    drlLog(@"--- dump end (budget left %d) ---", budget);
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
    int broad = drlHookAllStatusBarClasses();
    drlLog(@"broad hook: %d StatusBar classes", broad);
    drlLog(@"install done, %d class(es); primary=%ld secondary=%ld single=%ld dual=%ld battery=%ld size=%.2f",
           n, (long)gPrefs.cPrimary, (long)gPrefs.cSecondary, (long)gPrefs.cSingle,
           (long)gPrefs.cDual, (long)gPrefs.cBattery, gPrefs.sizeFactor);
}

// 插件在进程启动早期就 hook 了同样的方法; 我们延迟安装以确保
// "我们的 original = 插件的实现", 顺序才正确。
__attribute__((constructor)) static void drlInit(void) {
    // ---- 诊断: 证明补丁本身有没有被加载 ----
    drlLog(@"=== DuoRingReadout LOADED v1.6 pid=%d ===", getpid());
    uint32_t imgN = _dyld_image_count();
    drlLog(@"images=%u; 相关镜像:", imgN);
    for (uint32_t i = 0; i < imgN; i++) {
        const char* nm = _dyld_get_image_name(i);
        if (!nm) continue;
        if (strstr(nm, "Duo") || strstr(nm, "CAiPhone") || strstr(nm, "caiphoneduostatus") ||
            strstr(nm, "DynamicLibraries") || strstr(nm, "TrollFools") || strstr(nm, "DuoRing"))
            drlLog(@"   img[%u] %s", i, nm);
    }
    drlLog(@"plugin(CAiPhoneDuoStatus) loaded? %@", drlPluginLoaded() ? @"YES" : @"NO");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        drlInstallHooks();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        drlDumpStatusBar();
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
    // 只处理"状态栏窗口"里的视图, 避免控制中心/App 里同类视图也被套环
    CGFloat lvl = v.window.windowLevel;
    if (!(lvl >= UIWindowLevelStatusBar - 0.5 && lvl <= UIWindowLevelStatusBar + 0.5)) return;
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
    return @[];      // 默认关闭: 之前它连控制中心里的同类视图也会套环
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
