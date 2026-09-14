// STStatusIconView.h — 挂在状态栏的宿主 UIView
// 借鉴 StatusTrio 的 StatusBarController + StatusIconRenderer。
// 用 CAShapeLayer 周期性重绘合成图标，承载于注入的状态栏容器。

#import <UIKit/UIKit.h>
#import "STStatusSnapshot.h"
#import "STStatusIconRenderer.h"

@interface STStatusIconView : UIImageView

- (void)refreshWithSnapshot:(STStatusSnapshot)snapshot foreground:(UIColor *)fg;
- (void)startTicking;

@end