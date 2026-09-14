// STStatusSnapshot.m — 占位快照（借鉴 StatusTrio .placeholder）

#import "STStatusSnapshot.h"

STStatusSnapshot STStatusSnapshotPlaceholder(void) {
    STStatusSnapshot s;
    s.battery.rawPercentage = 100;
    s.battery.isPresent = YES;
    s.battery.isCharging = NO;
    s.battery.isCharged = NO;
    s.battery.isLowPowerMode = NO;
    s.battery.isConnectedToPower = NO;

    s.wifi.state = STWiFiStateUnavailable;
    s.wifi.rssi = 0;
    s.wifi.bars = 0;

    s.volume.isMuted = NO;
    s.volume.isAvailable = NO;
    s.volume.scalar = 0.5;
    return s;
}