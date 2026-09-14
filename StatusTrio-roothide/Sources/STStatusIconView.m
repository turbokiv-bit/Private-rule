// STStatusIconView.m — 图标宿主视图
// 注意：首次数据采集要延迟，避免在 SpringBoard 启动/布局过程中做重活。

#import "STStatusIconView.h"
#import "StatusProviders/STBatteryProvider.h"
#import "StatusProviders/STWiFiProvider.h"
#import "StatusProviders/STVolumeProvider.h"

#define ST_LOG(fmt, ...) NSLog(@"[StatusTrio] " fmt, ##__VA_ARGS__)

@interface STStatusIconView ()
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL showVolume;
@end

@implementation STStatusIconView

- (instancetype)init {
    self = [super init];
    if (self) {
        self.contentMode = UIViewContentModeRedraw;
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.showVolume = NO; // iOS 状态栏空间小，默认只显示电池+WiFi
    }
    return self;
}

- (void)startTicking {
    if (self.timer) return;
    __weak typeof(self) weakSelf = self;
    // 关键：延迟 2s 再启动，等 SpringBoard 启动流程走完，避免在布局调用栈里做数据采集
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) self_ = weakSelf;
        if (!self_) return;
        if (self_.timer) return;
        self_.timer = [NSTimer timerWithTimeInterval:5.0
                                              target:self_
                                            selector:@selector(refreshTick)
                                            userInfo:nil
                                             repeats:YES];
        // 用 common modes，滚动时也能刷新
        [[NSRunLoop mainRunLoop] addTimer:self_.timer forMode:NSRunLoopCommonModes];
        [self_ refreshTick];
    });
}

- (void)refreshTick {
    STStatusSnapshot snap;
    snap.battery = [STBatteryProvider currentStatus];
    snap.wifi    = [STWiFiProvider currentStatus];
    // 音量不显示时不去查（避免无谓地连接媒体服务器）
    snap.volume  = self.showVolume ? [STVolumeProvider currentStatus] : (STVolumeStatus){ NO, NO, 0 };
    [self refreshWithSnapshot:snap foreground:[UIColor whiteColor]];
}

- (void)refreshWithSnapshot:(STStatusSnapshot)snapshot foreground:(UIColor *)fg {
    CGFloat pointSize = self.frame.size.width ?: 20;
    if (pointSize < 4) pointSize = 20;
    CGFloat scale = [UIScreen mainScreen].scale;
    if (scale <= 0) scale = 2;
    UIImage *img = [STStatusIconRenderer renderSnapshot:snapshot
                                                   size:pointSize
                                                  scale:scale
                                              foreground:fg
                                               showVolume:self.showVolume];
    if (img) self.image = img;
}

- (void)dealloc {
    [self.timer invalidate];
    self.timer = nil;
}

@end
