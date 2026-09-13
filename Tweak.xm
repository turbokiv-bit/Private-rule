#import <UIKit/UIKit.h>

static NSInteger g_batteryLevel = 100;
static NSInteger g_primarySignal = 0;
static NSInteger g_secondarySignal = -1;

%hook _UIStatusBar
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
            [[NSNotificationCenter defaultCenter] postNotificationName:@"DuoSimForceUpdate" object:nil];
        });
    } @catch (NSException *e) {}
}
%end

@interface _UIStatusBarCellularSignalView : UIView
@property (nonatomic, retain) UIView *duoSimContainer;
- (void)forceRenderDualRings;
@end

%hook _UIStatusBarCellularSignalView
%property (nonatomic, retain) UIView *duoSimContainer;

- (CGSize)intrinsicContentSize {
    CGSize orig = %orig;
    // 仅在桌面/App内强行拉宽，放过控制中心
    if (![NSStringFromClass([self.window class]) containsString:@"ControlCenter"] &&
        ![NSStringFromClass([self.window class]) containsString:@"CCUI"]) {
        CGFloat minWidth = orig.height * 2.2;
        if (orig.width < minWidth) {
            return CGSizeMake(minWidth, orig.height);
        }
    }
    return orig;
}

- (void)layoutSubviews {
    %orig;
    [self forceRenderDualRings];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = %orig;
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(forceRenderDualRings) name:@"DuoSimForceUpdate" object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    %orig;
}

%new
- (void)forceRenderDualRings {
    if (![NSThread isMainThread]) return;
    @try {
        // 【关键隔离】如果当前处于控制中心，直接阻断代码运行，保留 iOS 原生信号
        NSString *windowName = NSStringFromClass([self.window class]);
        if ([windowName containsString:@"ControlCenter"] || [windowName containsString:@"CCUI"]) {
            return; 
        }

        CGFloat viewWidth = self.bounds.size.width;
        CGFloat viewHeight = self.bounds.size.height;
        if (viewWidth < 20 || viewHeight <= 0) return;

        // 初始化绝对置顶的独立容器
        if (!self.duoSimContainer) {
            self.duoSimContainer = [[UIView alloc] initWithFrame:self.bounds];
            self.duoSimContainer.backgroundColor = [UIColor clearColor];
            [self addSubview:self.duoSimContainer];
        }
        self.duoSimContainer.frame = self.bounds;
        [self bringSubviewToFront:self.duoSimContainer];
        [self.duoSimContainer.layer.sublayers makeObjectsPerformSelector:@selector(removeFromSuperlayer)];

        // 屏蔽该视图下除容器外的所有图层（即隐藏原插件的单卡圆环）
        for (CALayer *layer in self.layer.sublayers) {
            if (layer != self.duoSimContainer.layer) {
                layer.opacity = 0.0; 
            }
        }

        CGFloat ringRadius = viewHeight * 0.4;
        CGPoint primaryCenter = CGPointMake(viewWidth * 0.25, viewHeight / 2);
        CGPoint secondaryCenter = CGPointMake(viewWidth * 0.75, viewHeight / 2);

        // 绘制主卡 (左)
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
        
        [self.duoSimContainer.layer addSublayer:pRing];
        [self.duoSimContainer.layer addSublayer:pText];

        // 绘制副卡 (右)
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

            [self.duoSimContainer.layer addSublayer:sRing];
            [self.duoSimContainer.layer addSublayer:sText];
        }
    } @catch (NSException *e) {}
}
%end
