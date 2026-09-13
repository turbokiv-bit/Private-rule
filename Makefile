# Theos Makefile — IDIRingReadout
# 给 iPhoneDuoIcon(iya.banana.iphoneduoicon) 加"主卡/副卡圆环", 主卡环显示实时电量
#
# 编译:
#   make clean package ARCHS="arm64e" FINALPACKAGE=1                # 只编 arm64e(rootful)
#   make clean package ARCHS="arm64 arm64e" FINALPACKAGE=1          # fat
#   make clean package ARCHS="arm64e" THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1   # rootless
#   make clean package ARCHS="arm64 arm64e" THEOS_PACKAGE_SCHEME=roothide FINALPACKAGE=1
#
# 依赖: theos + theos/sdks(打过补丁的 SDK, 支持 arm64e)
#   git clone --depth 1 https://github.com/theos/sdks.git $THEOS/sdks

TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e

INSTALL_TARGET_PROCESSES := SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = IDIRingReadout

IDIRingReadout_FILES = Tweak.m
IDIRingReadout_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
IDIRingReadout_LDFLAGS = -lsubstrate
IDIRingReadout_FRAMEWORKS = Foundation UIKit QuartzCore CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk
