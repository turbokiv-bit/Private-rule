# StatusTrio (roothide 移植版)
# 借鉴自 https://github.com/lingyired/status-trio
# 目标: iPhone 14 Pro Max (arm64e) iOS 16.5.1 roothide

export TARGET := iphone:clang:latest:16.0
export ARCHS = arm64 arm64e
export THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = statusTrio

statusTrio_FILES = Tweak.x \
    STStatusSnapshot.m \
    STStatusIconGeometry.m \
    STStatusIconRenderer.m \
    StatusProviders/STBatteryProvider.m \
    StatusProviders/STWiFiProvider.m \
    StatusProviders/STVolumeProvider.m \
    STStatusIconView.m \
    STStatusBarHooks.x

statusTrio_CFLAGS = -fobjc-arc -std=c11
statusTrio_LDFLAGS =
statusTrio_FRAMEWORKS = UIKit QuartzCore CoreGraphics CoreText Foundation
statusTrio_IPHONEOS_DEPLOYMENT_TARGET = 15.0

# roothide：tweak 安装到 /var/jb/Library/MobileSubstrate/DynamicLibraries
statusTrio_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk