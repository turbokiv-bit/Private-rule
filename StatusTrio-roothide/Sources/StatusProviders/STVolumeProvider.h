// StatusProviders/STVolumeProvider.h
// 替代 macOS CoreAudio/VolumeMonitor 的音量采集。
// iOS 无法直接读系统音量；经 roothide 注入 SpringBoard 后，
// 可访问 AVSystemController（媒体服务器卷）。

#import "STStatusSnapshot.h"
#import <Foundation/Foundation.h>

@interface STVolumeProvider : NSObject

// 尝试读取媒体音量 0~1；不可用时返回 isAvailable=NO
+ (STVolumeStatus)currentStatus;

@end