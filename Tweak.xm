#import <UIKit/UIKit.h>

static NSInteger g_batteryLevel = 100;
static NSInteger g_primarySignal = 0;
static NSInteger g_secondarySignal = -1;

%hook _UIStatusBar

// 1. 抓取系统底层数据
- (void)updateWithData:(id)data {
    %orig;
    @try {
        if ([data respondsToSelector:NSSelectorFromString(@"mainBatteryEntry")]) {
            id batteryEntry = [data valueForKey:@"mainBatteryEntry"];
            if (batteryEntry) g_batteryLevel = [[batteryEntry valueForKey:@"capacity"] integerValue];
        }
        if ([data respondsToSelector:NSSelectorFromString(@"cellularEntry")]) {
            id cellEntry = [data valueForKey:@"cellularEntry"];
            if (cellEntry && [[cellEntry valueForKey:@"statusAvailable"] boolValue]) {
                g_primarySignal = [[cellEntry valueForKey:@"displayValue"] integerValue];
            }
        }
        if ([data respondsToSelector:NSSelectorFromString(@"secondaryCellularEntry")]) {
            id secEntry = [data valueForKey:@"secondaryCellularEntry"];
            if (secEntry && [[secEntry valueForKey:@"statusAvailable"] boolValue]) {
                g_secondarySignal = [[secEntry valueForKey:@"displayValue"] integerValue];
            } else {
                g_secondarySignal = -1;
            }
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self duoSim_scanAndHijack];
        });
    } @catch (NSException *e) {}
}

- (void)layoutSubviews {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self duoSim_scanAndHijack];
    });
}

// 2. 雷达追踪：扫描并劫持原插件的自定义视图
%new
- (void)duoSim_scanAndHijack {
    if (![NSThread isMainThread]) return;
    [self scanForCustomView:self];
}

%new
- (void)scanForCustomView:(UIView *)view {
    NSString *className = NSStringFromClass([view class]);
    
    // 模糊匹配：拦截原作者(CA / CallAssist)插入的视图，或者系统原生信号视图
    if ([className containsString:@"CAIphone"] || [className hasPrefix:@"CAStatus"] || [className isEqualToString:@"_UIStatusBarCellularSignalView"]) {
        [self renderDualRingOnView:view];
        // 如果是系统原生视图，强行解除宽度限制
        if ([className isEqualToString:@"_UIStatusBarCellularSignalView"]) {
             CGFloat minWidth = view.bounds.size.height * 2.2;
             if (view.bounds.size.width < minWidth) {
                 view.bounds = CGRectMake(0, 0, minWidth, view.bounds.size.height);
             }
        }
        return;
    }
    
    for (UIView *subview in view.subviews) {
        [self scanForCustomView:subview];
    }
}

// 3. 强行覆写 UI
%new
- (void)renderDualRingOnView:(UIView *)targetView {
    @try {
        CGFloat viewWidth = targetView.bounds.size.width;
        CGFloat viewHeight = targetView.bounds.size.height;
        if (viewWidth <= 0 || viewHeight <= 0) return;
        
        // 隐藏原视图自带的图层（比如原插件的单卡圆环）
        for (CALayer *layer in targetView.layer.sublayers) {
            if ([layer.name isEqualToString:@"DuoSimPatchLayer"]) continue;
            layer.opacity = 0.0; 
        }
        
        // 创建我们自己的独立画布
        CAShapeLayer *patchCanvas = nil;
        for (CALayer *layer in targetView.layer.sublayers) {
            if ([layer.name isEqualToString:@"DuoSimPatchLayer"]) {
                patchCanvas = (CAShapeLayer *)layer;
                break;
            }
        }
        
        if (!patchCanvas) {
            patchCanvas = [CAShapeLayer layer];
            patchCanvas.name = @"DuoSimPatchLayer";
            patchCanvas.frame = targetView.bounds;
            [targetView.layer addSublayer:patchCanvas];
        }
        
        // 清空旧画布重绘
        patchCanvas.sublayers = nil;
        
        CGFloat ringRadius = viewHeight * 0.4;
        CGPoint primaryCenter = CGPointMake(viewWidth * 0.25, viewHeight / 2);
        CGPoint secondaryCenter = CGPointMake(viewWidth * 0.75, viewHeight / 2);
        
        // 绘制主卡电量
        CAShapeLayer *pRing = [CAShapeLayer layer];
        pRing.fillColor = [UIColor clearColor].CGColor;
        pRing.lineCap = kCALineCapRound;
        pRing.lineWidth = 2.0;
        CGFloat pAngle = (g_primarySignal / 4.0) * (M_PI * 2);
        pRing.path = [UIBezierPath bezierPathWithArcCenter:primaryCenter radius:ringRadius startAngle:-M_PI_2 endAngle:pAngle - M_PI_2 clockwise:YES].CGPath;
        
        CATextLayer *pText = [CATextLayer layer];
        pText.string = [NSString stringWithFormat:@"%ld", (long)g_batteryLevel];
        pText.fontSize = 9;
        pText.alignmentMode = kCAAlignmentCenter;
        pText.frame = CGRectMake(primaryCenter.x - ringRadius, primaryCenter.y - 6, ringRadius * 2, 12);
        pText.contentsScale = [UIScreen mainScreen].scale;
        
        BOOL lowBatt = g_batteryLevel <= 20;
        pRing.strokeColor = lowBatt ? [UIColor systemRedColor].CGColor : [UIColor labelColor].CGColor;
        pText.foregroundColor = lowBatt ? [UIColor systemRedColor].CGColor : [UIColor labelColor].CGColor;
        
        [patchCanvas addSublayer:pRing];
        [patchCanvas addSublayer:pText];
        
        // 绘制副卡信号
        if (g_secondarySignal >= 0) {
            CAShapeLayer *sRing = [CAShapeLayer layer];
            sRing.fillColor = [UIColor clearColor].CGColor;
            sRing.lineCap = kCALineCapRound;
            sRing.lineWidth = 2.0;
            CGFloat sAngle = (g_secondarySignal / 4.0) * (M_PI * 2);
            sRing.path = [UIBezierPath bezierPathWithArcCenter:secondaryCenter radius:ringRadius startAngle:-M_PI_2 endAngle:sAngle - M_PI_2 clockwise:YES].CGPath;
            
            CATextLayer *sText = [CATextLayer layer];
            sText.string = [NSString stringWithFormat:@"%ld", (long)(g_secondarySignal * 25)];
            sText.fontSize = 9;
            sText.alignmentMode = kCAAlignmentCenter;
            sText.frame = CGRectMake(secondaryCenter.x - ringRadius, secondaryCenter.y - 6, ringRadius * 2, 12);
            sText.contentsScale = [UIScreen mainScreen].scale;
            
            BOOL lowSig = g_secondarySignal < 2;
            sRing.strokeColor = lowSig ? [UIColor systemRedColor].CGColor : [UIColor systemGrayColor].CGColor;
            sText.foregroundColor = lowSig ? [UIColor systemRedColor].CGColor : [UIColor labelColor].CGColor;
            
            [patchCanvas addSublayer:sRing];
            [patchCanvas addSublayer:sText];
        }
    } @catch (NSException *e) {}
}
%end
