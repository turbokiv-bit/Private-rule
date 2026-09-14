// STStatusBarHooks.x — 状态栏注入钩子（Theos Logos 语法）
// 借鉴 StatusTrio 的 StatusBarController：把合成图标挂到状态栏。
//
// 注入目标进程：SpringBoard。
// 挂载点：_UIStatusBar（iOS 13+ 状态栏根视图）。
// 本文件负责「找到状态栏并插入 STStatusIconView」，采集与绘制在别的文件。

#import <UIKit/UIKit.h>
#import "STStatusIconView.h"

#define ST_LOG(fmt, ...) NSLog(@"[StatusTrio] " fmt, ##__VA_ARGS__)

// 仅 SpringBoard 进程生效的守卫
static BOOL STIsSpringBoard(void) {
    NSString *name = NSBundle.mainBundle.bundleIdentifier;
    return [name isEqualToString:@"com.apple.springboard"];
}

// 把图标视图塞进状态栏（放在灵动岛左侧 / 状态栏左侧时间附近）
static STStatusIconView *_iconView = nil;

static void STInstallIconIntoView(UIView *statusBar) {
    if (!STIsSpringBoard()) return;
    if (_iconView) return;

    _iconView = [[STStatusIconView alloc] init];
    // 初始尺寸：状态栏一个图标的点宽 ~20
    _iconView.frame = CGRectMake(0, 0, 20, 20);
    [statusBar addSubview:_iconView];

    // 尝试布局到安全区内（灵动岛机型状态栏左侧）
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    NSLayoutConstraint *lead = [NSLayoutConstraint constraintWithItem:_iconView
                                                             attribute:NSLayoutAttributeLeading
                                                             relatedBy:NSLayoutRelationEqual
                                                                toItem:statusBar
                                                             attribute:NSLayoutAttributeLeading
                                                            multiplier:1.0 constant:6];
    NSLayoutConstraint *cy = [NSLayoutConstraint constraintWithItem:_iconView
                                                             attribute:NSLayoutAttributeCenterY
                                                             relatedBy:NSLayoutRelationEqual
                                                                toItem:statusBar
                                                             attribute:NSLayoutAttributeCenterY
                                                            multiplier:1.0 constant:0];
    NSLayoutConstraint *w = [NSLayoutConstraint constraintWithItem:_iconView
                                                             attribute:NSLayoutAttributeWidth
                                                             relatedBy:NSLayoutRelationEqual
                                                                toItem:nil
                                                             attribute:NSLayoutAttributeNotAnAttribute
                                                            multiplier:1.0 constant:22];
    NSLayoutConstraint *h = [NSLayoutConstraint constraintWithItem:_iconView
                                                             attribute:NSLayoutAttributeHeight
                                                             relatedBy:NSLayoutRelationEqual
                                                                toItem:nil
                                                             attribute:NSLayoutAttributeNotAnAttribute
                                                            multiplier:1.0 constant:22];
    [statusBar addConstraints:@[lead, cy, w, h]];

    [_iconView startTicking];
    ST_LOG(@"installed icon view into %@", NSStringFromClass([statusBar class]));
}

// Hook _UIStatusBar 的 didMoveToWindow / layoutSubviews，待其出现后注入
%hook _UIStatusBar

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        STInstallIconIntoView(self);
    }
}

- (void)layoutSubviews {
    %orig;
    STInstallIconIntoView(self);
}

%end
