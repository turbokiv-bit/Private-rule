// STStatusSnapshot.h — 借鉴自 StatusTrio (https://github.com/lingyired/status-trio)
// 统一三路系统状态的数据模型。字段与 StatusTrio 的 StatusSnapshot 对齐，
// 但采集 API 换成 iOS 私有框架（见 StatusProviders 目录）。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ---- 电池状态 ----
typedef struct {
    NSInteger rawPercentage;   // -1 表示未知
    BOOL isPresent;
    BOOL isCharging;
    BOOL isCharged;
    BOOL isLowPowerMode;
    BOOL isConnectedToPower;
} STBatteryStatus;

// ---- WiFi 状态 ----
typedef NS_ENUM(NSInteger, STWiFiState) {
    STWiFiStateConnected = 0,
    STWiFiStateNotAssociated,
    STWiFiStateOff,
    STWiFiStateNoInternet,
    STWiFiStateUnavailable,
};

typedef struct {
    STWiFiState state;
    NSInteger rssi;    // 0 表示未知
    NSInteger bars;    // 0~3，由 rssi 映射
} STWiFiStatus;

// ---- 音量状态（可选显示，默认关闭）----
typedef struct {
    BOOL isMuted;
    BOOL isAvailable;
    CGFloat scalar;    // 0.0 ~ 1.0
} STVolumeStatus;

// ---- 合成快照（借鉴 StatusSnapshot）----
typedef struct {
    STBatteryStatus battery;
    STWiFiStatus wifi;
    STVolumeStatus volume;
} STStatusSnapshot;

// 空占位快照（借鉴 StatusTrio 的 .placeholder）
extern STStatusSnapshot STStatusSnapshotPlaceholder(void);

NS_ASSUME_NONNULL_END
