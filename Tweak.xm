#import <UIKit/UIKit.h>

static NSInteger g_batteryLevel = 100;
static NSInteger g_primarySignal = 0;
static NSInteger g_secondarySignal = -1;

// 1. 劫持系统状态栏数据流（仅抓取数据）
%hook _UIStatusBar
- (void)updateWithData:(id)data {
    %orig;
    @try {
        if ([data respondsToSelector:NSSelectorFromString(@"mainBatteryEntry")]) {
            id batteryEntry = [data valueForKey:@"mainBatteryEntry"];
            if (batteryEntry) {
                g_batteryLevel = [[batteryEntry valueForKey:@"capacity"] integerValue];
            }
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
            [[NSNotificationCenter defaultCenter] postNotificationName:@"DuoSimStandaloneUpdate" object:nil];
        });
    } @catch (NSException *e) {}
}
%end

// 2. 核心 UI 渲染：自带宽度拉伸与双环绘制
@interface _UIStatusBarCellularSignalView : UIView
@property (nonatomic, retain) CAShapeLayer *primaryRingLayer;
@property (nonatomic, retain) CAShapeLayer *secondaryRingLayer;
@property (nonatomic, retain) UILabel *primaryTextLabel;
@property (nonatomic, retain) UILabel *secondaryTextLabel;
- (void)standalone_renderUI;
@end

%hook _UIStatusBarCellularSignalView

%property (nonatomic, retain) CAShapeLayer *primaryRingLayer;
%property (nonatomic, retain) CAShapeLayer *secondaryRingLayer;
%property (nonatomic, retain) UILabel *primaryTextLabel;
%property (nonatomic, retain) UILabel *secondaryTextLabel;

// 【关键新增】强制拉宽系统原生的信号区域，腾出双圆环的空间
- (CGSize)intrinsicContentSize {
    CGSize orig = %orig;
    CGFloat minWidth = orig.height * 2.2; // 强制宽度至少为高度的 2.2 倍
    if (orig.width < minWidth) {
        return CGSizeMake(minWidth, orig.height);
    }
    return orig;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = %orig;
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(standalone_renderUI) name:@"DuoSimStandaloneUpdate" object:nil];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = %orig;
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(standalone_renderUI) name:@"DuoSimStandaloneUpdate" object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    %orig;
}

- (void)layoutSubviews {
    %orig;
    [self standalone_renderUI];
}

%new
- (void)standalone_renderUI {
    if (![NSThread isMainThread]) return;
    @try {
        // 屏蔽 iOS 原生阶梯信号柱
        NSArray *sublayers = [self.layer.sublayers copy];
        for (CALayer *layer in sublayers) {
            if (layer != self.primaryRingLayer && layer != self.secondaryRingLayer && 
                layer != self.primaryTextLabel.layer && layer != self.secondaryTextLabel.layer) {
                layer.opacity = 0.0; 
            }
        }
        
        CGFloat viewWidth = self.bounds.size.width;
        CGFloat viewHeight = self.bounds.size.height;
        if (viewWidth <= 0 || viewHeight <= 0) return;
        
        CGFloat ringRadius = viewHeight * 0.4;
        // 动态计算左右圆环的中心点
        CGPoint primaryCenter = CGPointMake(viewWidth * 0.25, viewHeight / 2);
        CGPoint secondaryCenter = CGPointMake(viewWidth * 0.75, viewHeight / 2);
        
        // --- 绘制左侧主卡（电量） ---
        if (!self.primaryRingLayer) {
            self.primaryRingLayer = [CAShapeLayer layer];
            self.primaryRingLayer.fillColor = [UIColor clearColor].CGColor;
            self.primaryRingLayer.lineCap = kCALineCapRound;
            self.primaryRingLayer.lineWidth = 2.0; // 稍微调细一点，更精致
            [self.layer addSublayer:self.primaryRingLayer];
        }
        if (!self.primaryTextLabel) {
            self.primaryTextLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, ringRadius * 2, ringRadius * 2)];
            self.primaryTextLabel.center = CGPointMake(primaryCenter.x, primaryCenter.y);
            self.primaryTextLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
            self.primaryTextLabel.textAlignment = NSTextAlignmentCenter;
            [self addSubview:self.primaryTextLabel];
        }
        
        CGFloat primaryAngle = (g_primarySignal / 4.0) * (M_PI * 2);
        UIBezierPath *primaryPath = [UIBezierPath bezierPathWithArcCenter:primaryCenter radius:ringRadius startAngle:-M_PI_2 endAngle:primaryAngle - M_PI_2 clockwise:YES];
        self.primaryRingLayer.path = primaryPath.CGPath;
        self.primaryTextLabel.text = [NSString stringWithFormat:@"%ld", (long)g_batteryLevel];
        
        BOOL isLowBattery = (g_batteryLevel <= 20);
        self.primaryRingLayer.strokeColor = isLowBattery ? [UIColor systemRedColor].CGColor : [UIColor labelColor].CGColor;
        self.primaryTextLabel.textColor = isLowBattery ? [UIColor systemRedColor] : [UIColor labelColor];

        // --- 绘制右侧副卡（信号百分比） ---
        if (g_secondarySignal >= 0) {
            if (!self.secondaryRingLayer) {
                self.secondaryRingLayer = [CAShapeLayer layer];
                self.secondaryRingLayer.fillColor = [UIColor clearColor].CGColor;
                self.secondaryRingLayer.lineCap = kCALineCapRound;
                self.secondaryRingLayer.lineWidth = 2.0;
                [self.layer addSublayer:self.secondaryRingLayer];
            }
            if (!self.secondaryTextLabel) {
                self.secondaryTextLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, ringRadius * 2, ringRadius * 2)];
                self.secondaryTextLabel.center = CGPointMake(secondaryCenter.x, secondaryCenter.y);
                self.secondaryTextLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
                self.secondaryTextLabel.textAlignment = NSTextAlignmentCenter;
                [self addSubview:self.secondaryTextLabel];
            }
            self.secondaryRingLayer.hidden = NO;
            self.secondaryTextLabel.hidden = NO;
            
            CGFloat secondaryAngle = (g_secondarySignal / 4.0) * (M_PI * 2);
            UIBezierPath *secondaryPath = [UIBezierPath bezierPathWithArcCenter:secondaryCenter radius:ringRadius startAngle:-M_PI_2 endAngle:secondaryAngle - M_PI_2 clockwise:YES];
            self.secondaryRingLayer.path = secondaryPath.CGPath;
            
            self.secondaryTextLabel.text = [NSString stringWithFormat:@"%ld", (long)(g_secondarySignal * 25)];
            
            BOOL isLowSignal = (g_secondarySignal < 2);
            self.secondaryRingLayer.strokeColor = isLowSignal ? [UIColor systemRedColor].CGColor : [UIColor systemGrayColor].CGColor;
            self.secondaryTextLabel.textColor = isLowSignal ? [UIColor systemRedColor] : [UIColor labelColor];
        } else {
            self.secondaryRingLayer.hidden = YES;
            self.secondaryTextLabel.hidden = YES;
        }
    } @catch (NSException *e) {}
}
%end
