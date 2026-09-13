#import <UIKit/UIKit.h>

// 1. 定义全局静态变量存储双卡和电量状态（绝对内存安全，避免遍历视图树导致崩溃）
static NSInteger g_batteryLevel = 100;
static NSInteger g_primarySignal = 0;
static NSInteger g_secondarySignal = -1;

// 2. 劫持系统状态栏数据流（仅抓取数据，不执行任何 UI 刷新操作）
%hook _UIStatusBar
- (void)updateWithData:(id)data {
    %orig;
    @try {
        // 使用 KVC 动态读取属性，防止跨 iOS 版本的头文件不兼容问题引发崩溃
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
        
        // 发送异步通知，让 UI 在主线程安全自行刷新
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"DuoSimSafeUpdateUI" object:nil];
        });
    } @catch (NSException *e) {
        // 捕获所有潜在异常，死守安全底线
    }
}
%end

// 3. 安全独立的 UI 绘制模块
@interface _UIStatusBarCellularSignalView : UIView
@property (nonatomic, retain) CAShapeLayer *primaryRingLayer;
@property (nonatomic, retain) CAShapeLayer *secondaryRingLayer;
@property (nonatomic, retain) UILabel *primaryTextLabel;
@property (nonatomic, retain) UILabel *secondaryTextLabel;
- (void)duoSim_renderUI;
@end

%hook _UIStatusBarCellularSignalView

%property (nonatomic, retain) CAShapeLayer *primaryRingLayer;
%property (nonatomic, retain) CAShapeLayer *secondaryRingLayer;
%property (nonatomic, retain) UILabel *primaryTextLabel;
%property (nonatomic, retain) UILabel *secondaryTextLabel;

// 监听系统初始化，注册更新通知
- (instancetype)initWithFrame:(CGRect)frame {
    self = %orig;
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(duoSim_renderUI) name:@"DuoSimSafeUpdateUI" object:nil];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = %orig;
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(duoSim_renderUI) name:@"DuoSimSafeUpdateUI" object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    %orig;
}

- (void)layoutSubviews {
    %orig;
    [self duoSim_renderUI];
}

// 核心渲染器
%new
- (void)duoSim_renderUI {
    // 强制 UI 绘制主线程执行
    if (![NSThread isMainThread]) return;

    @try {
        // 拷贝子图层数组再遍历，防止原插件或系统动画正在修改时引发越界崩溃
        NSArray *sublayers = [self.layer.sublayers copy];
        for (CALayer *layer in sublayers) {
            if (layer != self.primaryRingLayer && layer != self.secondaryRingLayer && 
                layer != self.primaryTextLabel.layer && layer != self.secondaryTextLabel.layer) {
                // 使用透明度屏蔽而非彻底 hidden，降低与单卡原插件的渲染冲突
                layer.opacity = 0.0; 
            }
        }
        
        CGFloat viewWidth = self.bounds.size.width;
        CGFloat viewHeight = self.bounds.size.height;
        // 防御性判断：如果视图未完全加载，跳过绘制
        if (viewWidth <= 0 || viewHeight <= 0) return;
        
        CGFloat ringRadius = viewHeight * 0.4; 
        CGPoint primaryCenter = CGPointMake(viewWidth * 0.3, viewHeight / 2);
        CGPoint secondaryCenter = CGPointMake(viewWidth * 0.7, viewHeight / 2);
        
        // --- 绘制主卡 (左) ---
        if (!self.primaryRingLayer) {
            self.primaryRingLayer = [CAShapeLayer layer];
            self.primaryRingLayer.fillColor = [UIColor clearColor].CGColor;
            self.primaryRingLayer.lineCap = kCALineCapRound;
            self.primaryRingLayer.lineWidth = 2.5;
            [self.layer addSublayer:self.primaryRingLayer];
        }
        
        if (!self.primaryTextLabel) {
            self.primaryTextLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, ringRadius * 2, ringRadius * 2)];
            self.primaryTextLabel.center = CGPointMake(primaryCenter.x, primaryCenter.y - 2);
            self.primaryTextLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
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

        // --- 绘制副卡 (右) ---
        if (g_secondarySignal >= 0) {
            if (!self.secondaryRingLayer) {
                self.secondaryRingLayer = [CAShapeLayer layer];
                self.secondaryRingLayer.fillColor = [UIColor clearColor].CGColor;
                self.secondaryRingLayer.lineCap = kCALineCapRound;
                self.secondaryRingLayer.lineWidth = 2.5;
                [self.layer addSublayer:self.secondaryRingLayer];
            }
            
            if (!self.secondaryTextLabel) {
                self.secondaryTextLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, ringRadius * 2, ringRadius * 2)];
                self.secondaryTextLabel.center = CGPointMake(secondaryCenter.x, secondaryCenter.y - 2);
                self.secondaryTextLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
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
