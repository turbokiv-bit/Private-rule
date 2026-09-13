# Theos Makefile (ellekit/substrate tweak)
# 编译：make clean package FINALPACKAGE=1
# roothide 设备是 arm64 而非 arm64e; 默认编 arm64 更兼容 roothide. arm64e 设备改回此。

TARGET := iphone:clang:latest:14.0
# roothide 设备是 arm64 而非 arm64e. 默认编 arm64 更兼容 roothide; arm64e 设备改回此。
ARCHS := arm64

INSTALL_TARGET_PROCESSES := Aweme

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SJJAuthBypass

SJJAuthBypass_FILES = Tweak.m
SJJAuthBypass_CFLAGS = -fobjc-arc -I$(THEOS)/include
SJJAuthBypass_LDFLAGS = -lsubstrate
SJJAuthBypass_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
