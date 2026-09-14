# StatusTrio (roothide 移植版)
# 借鉴自 https://github.com/lingyired/status-trio
# 目标: iPhone 14 Pro Max (arm64e) iOS 16.5.1 roothide

export TARGET := iphone:clang:latest:16.0
export ARCHS = arm64 arm64e
export THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = statusTrio

# 注意：Theos 的 _FILES 路径相对 Makefile 所在目录，源文件在 Sources/ 下
statusTrio_FILES = Sources/Tweak.x \
    Sources/STStatusBarHooks.x \
    Sources/STStatusSnapshot.m \
    Sources/STStatusIconGeometry.m \
    Sources/STStatusIconRenderer.m \
    Sources/STStatusIconView.m \
    Sources/StatusProviders/STBatteryProvider.m \
    Sources/StatusProviders/STWiFiProvider.m \
    Sources/StatusProviders/STVolumeProvider.m

statusTrio_CFLAGS = -fobjc-arc -ISources
statusTrio_FRAMEWORKS = UIKit QuartzCore CoreGraphics CoreText Foundation
statusTrio_IPHONEOS_DEPLOYMENT_TARGET = 15.0

include $(THEOS_MAKE_PATH)/tweak.mk
