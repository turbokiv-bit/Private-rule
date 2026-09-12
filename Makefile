# Theos Makefile (rootless ellekit/substrate tweak)
# 编译：make clean package FINALPACKAGE=1

TARGET := iphone:clang:latest:14.0
ARCHS := arm64e

INSTALL_TARGET_PROCESSES := Aweme

# rootless 打包：安装路径自动变成 /var/jb/Library/MobileSubstrate/DynamicLibraries
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SJJAuthBypass

SJJAuthBypass_FILES = Tweak.m
SJJAuthBypass_CFLAGS = -fobjc-arc -I$(THEOS)/include
SJJAuthBypass_LDFLAGS = -lsubstrate
SJJAuthBypass_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
