// STStatusBarHooks.x — 状态栏注入钩子（Theos Logos 语法）
// 借鉴 StatusTrio 的 StatusBarController：把合成图标挂到状态栏。
//
// 注入目标进程：SpringBoard
// 挂载点：_UIStatusBar / UIStatusBar_Modern（iOS 13+ 状态栏根视图，二者择一存在）

#import <UIKit/UIKit.h>
#import "STStatusIconView.h"

#define ST_LOG(fmt, ...) NSLog(@"[StatusTrio] " fmt, ##__VA_ARGS__)

// 关键：显式声明私有类继承 UIView。
// 否则编译器只看到前向声明，拿不到 window 属性，也无法把 self 当 UIView* 用。
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

// 手动摆位（不使用 Auto Layout，避免与状态栏内部布局产生约束冲突）
static void STLayoutIconInBar(UIView *bar) {
    if (!_iconView || _iconView.superview != bar) return;
    CGRect b = bar.bounds;
    if (b.size.width <= 1 || b.size.height <= 1) return;

    CGFloat side = 20.0;
    // 相对状态栏中心左移 78pt：iPhone 14 Pro 上正好落在灵动岛左侧、时间右侧
    CGFloat x = CGRectGetMidX(b) - 78.0 - side / 2.0;
    if (x < 2.0) x = 2.0;
    CGFloat y = (b.size.height - side) / 2.0;
    _iconView.frame = CGRectMake(x, y, side, side);
}

static void STInstallIconIfNeeded(UIView *bar) {
    if (!STIsSpringBoard()) return;
    if (_iconView && _iconView.superview == bar) return;

    if (!_iconView) {
        _iconView = [[STStatusIconView alloc] initWithFrame:CGRectMake(0, 0, 20, 20)];
        // 不参与父视图的 Auto Layout：这样父视图不会重置我们的 frame
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    }
    if (_iconView.superview) {
        [_iconView removeFromSuperview];
    }
    [bar addSubview:_iconView];
    _iconView.layer.zPosition = 1000;

    STLayoutIconInBar(bar);
    [_iconView startTicking];

    ST_LOG(@"installed icon into %@ (frame=%@)", NSStringFromClass([bar class]),
           NSStringFromCGRect(_iconView.frame));
}

%hook _UIStatusBar

- (void)didMoveToWindow {
    %orig;
    if (self.window) STInstallIconIfNeeded(self);
}

- (void)layoutSubviews {
    %orig;
    STInstallIconIfNeeded(self);
    STLayoutIconInBar(self);
}

%end

%hook UIStatusBar_Modern

- (void)didMoveToWindow {
    %orig;
    if (self.window) STInstallIconIfNeeded(self);
}

- (void)layoutSubviews {
    %orig;
    STInstallIconIfNeeded(self);
    STLayoutIconInBar(self);
}

%end
