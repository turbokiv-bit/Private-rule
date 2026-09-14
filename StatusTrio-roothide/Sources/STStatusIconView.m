// STStatusIconView.m — 图标宿主视图

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
    // 借鉴 StatusTrio 的频控：事件驱动 + 低频轮询兜底
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                  target:self
                                                selector:@selector(refreshTick)
                                                userInfo:nil
                                                 repeats:YES];
    [self refreshTick];
}

- (void)refreshTick {
    STStatusSnapshot snap;
    snap.battery = [STBatteryProvider currentStatus];
    snap.wifi    = [STWiFiProvider currentStatus];
    snap.volume  = [STVolumeProvider currentStatus];
    [self refreshWithSnapshot:snap foreground:[UIColor whiteColor]];
}

- (void)refreshWithSnapshot:(STStatusSnapshot)snapshot foreground:(UIColor *)fg {
    CGFloat pointSize = self.frame.size.width ?: 18;
    CGFloat scale = [UIScreen mainScreen].scale;
    UIImage *img = [STStatusIconRenderer renderSnapshot:snapshot
                                                   size:pointSize
                                                  scale:scale
                                              foreground:fg
                                               showVolume:self.showVolume];
    if (img) self.image = img;
}

- (void)dealloc {
    [self.timer invalidate];
}

@end