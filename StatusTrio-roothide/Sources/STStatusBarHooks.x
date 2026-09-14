// STStatusBarHooks.x — 状态栏注入钩子（Theos Logos 语法）
// 借鉴 StatusTrio 的 StatusBarController：把合成图标挂到状态栏。
//
// 注入目标进程：SpringBoard
// 挂载点：_UIStatusBar / UIStatusBar_Modern
//
// 【崩溃教训】绝不能在 didMoveToWindow / layoutSubviews 里同步做重活：
//   SpringBoard 启动时创建状态栏窗口会走到这里，同步触发 UIKit 电量广播
//   → SBUIController/SBIconController 在 dispatch_once 内递归重入 → abort()。
//   所以：安装一律 dispatch_async + 延迟，布局只做轻量的 frame 调整。

#import <UIKit/UIKit.h>
#import "STStatusIconView.h"

#define ST_LOG(fmt, ...) NSLog(@"[StatusTrio] " fmt, ##__VA_ARGS__)

// 显式声明私有类继承 UIView，否则 Logos 只生成前向声明（拿不到 window、不能当 UIView* 用）
@interface _UIStatusBar : UIView
@end
@interface UIStatusBar_Modern : UIView
@end

static STStatusIconView *_iconView = nil;

static BOOL STIsSpringBoard(void) {
    static BOOL isSB = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        isSB = [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
    });
    return isSB;
}

// 轻量：只调整 frame（不触发任何数据采集）
static void STLayoutIconInBar(UIView *bar) {
    if (!_iconView || _iconView.superview != bar) return;
    CGRect b = bar.bounds;
    if (b.size.width <= 1 || b.size.height <= 1) return;

    CGFloat side = 20.0;
    // 相对状态栏中心左移 78pt：iPhone 14 Pro 上落在灵动岛左侧
    CGFloat x = CGRectGetMidX(b) - 78.0 - side / 2.0;
    if (x < 2.0) x = 2.0;
    CGFloat y = (b.size.height - side) / 2.0;
    _iconView.frame = CGRectMake(x, y, side, side);
}

static void STPerformInstall(UIView *bar) {
    if (!STIsSpringBoard()) return;
    if (_iconView && _iconView.superview == bar) return;

    if (!_iconView) {
        _iconView = [[STStatusIconView alloc] initWithFrame:CGRectMake(0, 0, 20, 20)];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    }
    if (_iconView.superview) {
        [_iconView removeFromSuperview];
    }
    [bar addSubview:_iconView];
    _iconView.layer.zPosition = 1000;

    STLayoutIconInBar(bar);
    [_iconView startTicking];  // 内部还会再延迟 2s 才开始采集

    ST_LOG(@"installed icon into %@ (frame=%@)", NSStringFromClass([bar class]),
           NSStringFromCGRect(_iconView.frame));
}

// 异步 + 延迟安装，绝不占用 UIKit 的布局/窗口回调栈
static void STScheduleInstall(UIView *bar) {
    if (!STIsSpringBoard()) return;
    if (_iconView && _iconView.superview == bar) return;

    __weak UIView *weakBar = bar;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *strongBar = weakBar;
        if (!strongBar) return;
        STPerformInstall(strongBar);
    });
}

%hook _UIStatusBar

- (void)didMoveToWindow {
    %orig;
    if (self.window) STScheduleInstall(self);
}

- (void)layoutSubviews {
    %orig;
    STLayoutIconInBar(self);
}

%end

%hook UIStatusBar_Modern

- (void)didMoveToWindow {
    %orig;
    if (self.window) STScheduleInstall(self);
}

- (void)layoutSubviews {
    %orig;
    STLayoutIconInBar(self);
}

%end
