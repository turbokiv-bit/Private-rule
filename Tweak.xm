#import <UIKit/UIKit.h>

@interface _UIStatusBar : UIView
- (void)triggerDualSimAndBatteryDrawInView:(UIView *)view primary:(NSInteger)primary secondary:(NSInteger)secondary battery:(NSInteger)battery;
@end


// 1. 声明系统数据模型 (新增电池数据接口)
@interface _UIStatusBarDataCellularEntry : NSObject
@property (assign,nonatomic) NSInteger displayValue; // 信号格数 (0-4)
@property (assign,nonatomic) BOOL statusAvailable;
@end

@interface _UIStatusBarDataBatteryEntry : NSObject
@property (assign,nonatomic) NSInteger capacity; // 电池容量百分比 (0-100)
@end

@interface _UIStatusBarData : NSObject
@property (nonatomic, retain) _UIStatusBarDataCellularEntry *cellularEntry;
@property (nonatomic, retain) _UIStatusBarDataCellularEntry *secondaryCellularEntry;
@property (nonatomic, retain) _UIStatusBarDataBatteryEntry *mainBatteryEntry; // 劫持主电池数据
@end

@interface _UIStatusBarCellularSignalView : UIView
@property (nonatomic, retain) CAShapeLayer *primaryRingLayer;
@property (nonatomic, retain) CAShapeLayer *secondaryRingLayer;
@property (nonatomic, retain) UILabel *primaryTextLabel;   // 主卡文字标签
@property (nonatomic, retain) UILabel *secondaryTextLabel; // 副卡文字标签
- (void)applyDualSimAndBatteryStyleWithPrimary:(NSInteger)primary secondary:(NSInteger)secondary battery:(NSInteger)batteryLevel;
@end

// 2. 劫持原插件 UI 并重绘双圆环 + 居中数字
%hook _UIStatusBarCellularSignalView

%property (nonatomic, retain) CAShapeLayer *primaryRingLayer;
%property (nonatomic, retain) CAShapeLayer *secondaryRingLayer;
%property (nonatomic, retain) UILabel *primaryTextLabel;
%property (nonatomic, retain) UILabel *secondaryTextLabel;

- (void)layoutSubviews {
    %orig; 
    // 隐藏原插件可能生成的冗余图层
    for (CALayer *layer in self.layer.sublayers) {
        if (layer != self.primaryRingLayer && layer != self.secondaryRingLayer && 
            layer != self.primaryTextLabel.layer && layer != self.secondaryTextLabel.layer) {
            layer.hidden = YES; 
        }
    }
}

%new
- (void)applyDualSimAndBatteryStyleWithPrimary:(NSInteger)primaryValue secondary:(NSInteger)secondaryValue battery:(NSInteger)batteryLevel {
    CGFloat viewWidth = self.bounds.size.width;
    CGFloat viewHeight = self.bounds.size.height;
    CGFloat ringRadius = viewHeight * 0.4; 
    
    CGPoint primaryCenter = CGPointMake(viewWidth * 0.3, viewHeight / 2);
    CGPoint secondaryCenter = CGPointMake(viewWidth * 0.7, viewHeight / 2);
    
    // --- 绘制左侧主卡圆环 ---
    if (!self.primaryRingLayer) {
        self.primaryRingLayer = [CAShapeLayer layer];
        self.primaryRingLayer.fillColor = [UIColor clearColor].CGColor;
        self.primaryRingLayer.lineCap = kCALineCapRound;
        self.primaryRingLayer.lineWidth = 2.5;
        [self.layer addSublayer:self.primaryRingLayer];
    }
    
    // 动态添加左侧数字 Label (复刻视频中的 50 效果)
    if (!self.primaryTextLabel) {
        self.primaryTextLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, ringRadius * 2, ringRadius * 2)];
        self.primaryTextLabel.center = CGPointMake(primaryCenter.x, primaryCenter.y - 2); // 稍微偏上一点，给底部的点阵留空间
        self.primaryTextLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold]; // 视频同款加粗无衬线字体
        self.primaryTextLabel.textColor = [UIColor labelColor]; // 自适应深色/浅色模式
        self.primaryTextLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:self.primaryTextLabel];
    }
    
    CGFloat primaryAngle = (primaryValue / 4.0) * (M_PI * 2);
    UIBezierPath *primaryPath = [UIBezierPath bezierPathWithArcCenter:primaryCenter radius:ringRadius startAngle:-M_PI_2 endAngle:primaryAngle - M_PI_2 clockwise:YES];
    self.primaryRingLayer.path = primaryPath.CGPath;
    
    // 填充左侧数字为：手机当前真实电量
    self.primaryTextLabel.text = [NSString stringWithFormat:@"%ld", (long)batteryLevel];
    
    // 电量极低时文字变红
    if (batteryLevel <= 20) {
        self.primaryRingLayer.strokeColor = [UIColor systemRedColor].CGColor;
        self.primaryTextLabel.textColor = [UIColor systemRedColor];
    } else {
        self.primaryRingLayer.strokeColor = [UIColor labelColor].CGColor;
        self.primaryTextLabel.textColor = [UIColor labelColor];
    }

    // --- 绘制右侧副卡圆环 ---
    if (secondaryValue >= 0) {
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
            self.secondaryTextLabel.textColor = [UIColor labelColor];
            self.secondaryTextLabel.textAlignment = NSTextAlignmentCenter;
            [self addSubview:self.secondaryTextLabel];
        }
        
        self.secondaryRingLayer.hidden = NO;
        self.secondaryTextLabel.hidden = NO;
        
        CGFloat secondaryAngle = (secondaryValue / 4.0) * (M_PI * 2);
        UIBezierPath *secondaryPath = [UIBezierPath bezierPathWithArcCenter:secondaryCenter radius:ringRadius startAngle:-M_PI_2 endAngle:secondaryAngle - M_PI_2 clockwise:YES];
        self.secondaryRingLayer.path = secondaryPath.CGPath;
        
        // 填充右侧数字为：副卡信号的虚拟百分比 (例如 1格25, 4格100)，复刻视频中双数字效果
        NSInteger secondaryFakePercent = (secondaryValue * 25);
        self.secondaryTextLabel.text = [NSString stringWithFormat:@"%ld", (long)secondaryFakePercent];
        
        self.secondaryRingLayer.strokeColor = secondaryValue < 2 ? [UIColor systemRedColor].CGColor : [UIColor systemGrayColor].CGColor;
        self.secondaryTextLabel.textColor = secondaryValue < 2 ? [UIColor systemRedColor] : [UIColor labelColor];
        
    } else {
        self.secondaryRingLayer.hidden = YES;
        self.secondaryTextLabel.hidden = YES;
    }
}
%end

// 3. 拦截状态栏数据池，提取电量与双路信号并下发
%hook _UIStatusBar
- (void)updateWithData:(_UIStatusBarData *)data {
    %orig; 
    
    // 获取主副卡信号 (0-4格)
    NSInteger primarySignal = data.cellularEntry.statusAvailable ? data.cellularEntry.displayValue : 0;
    NSInteger secondarySignal = -1; 
    if (data.secondaryCellularEntry && data.secondaryCellularEntry.statusAvailable) {
        secondarySignal = data.secondaryCellularEntry.displayValue;
    }
    
    // 获取主电池电量 (0-100%)
    NSInteger batteryCapacity = data.mainBatteryEntry ? data.mainBatteryEntry.capacity : 100;
    
    [self triggerDualSimAndBatteryDrawInView:(UIView *)self primary:primarySignal secondary:secondarySignal battery:batteryCapacity];
}

%new
- (void)triggerDualSimAndBatteryDrawInView:(UIView *)view primary:(NSInteger)primary secondary:(NSInteger)secondary battery:(NSInteger)battery {
    if ([view isKindOfClass:NSClassFromString(@"_UIStatusBarCellularSignalView")]) {
        [(_UIStatusBarCellularSignalView *)view applyDualSimAndBatteryStyleWithPrimary:primary secondary:secondary battery:battery];
        return;
    }
    for (UIView *subview in view.subviews) {
        [self triggerDualSimAndBatteryDrawInView:subview primary:primary secondary:secondary battery:battery];
    }
}
%end
