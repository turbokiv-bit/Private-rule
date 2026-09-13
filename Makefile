# Theos Makefile — DuoRingReadout (CAiPhoneDuoStatus 圆环数字读数)
#
# 编译:
#   make clean package ARCHS="arm64e" FINALPACKAGE=1              # 只编 arm64e (rootful)
#   make clean package ARCHS="arm64 arm64e" FINALPACKAGE=1        # fat
#   make clean package ARCHS="arm64e" THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
#
# arm64e 编译依赖: theos/sdks 里打过补丁的 SDK
#   git clone --depth 1 https://github.com/theos/sdks.git $THEOS/sdks
#
# 嫌编译太久可以只留一个架构: 把下面 ARCHS 改成 arm64e 或 arm64。

TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e

INSTALL_TARGET_PROCESSES := SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DuoRingReadout

DuoRingReadout_FILES = Tweak.m
DuoRingReadout_CFLAGS = -fobjc-arc -I$(THEOS)/include
DuoRingReadout_LDFLAGS = -lsubstrate
DuoRingReadout_FRAMEWORKS = Foundation UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
