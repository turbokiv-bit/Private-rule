// Tweak.x — 入口。声明注入进程、构造函数、以及必要的 Objective-C 运行时注册。

#import <UIKit/UIKit.h>

// 声明构造函数（在 SpringBoard 加载 dylib 时执行）
%ctor {
    // 确保只影响 SpringBoard 进程，避免影响其他 App
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    if (![bundleID isEqualToString:@"com.apple.springboard"]) return;

    // 稍后由 STStatusBarHooks.x 注入图标视图
    NSLog(@"[StatusTrio] loaded in SpringBoard, waiting for status bar…");
}