# Theos Makefile (ellekit/substrate tweak)
# 编译：make clean package FINALPACKAGE=1
# ARCHS 固定 arm64e

TARGET := iphone:clang:latest:14.0
ARCHS := arm64e

INSTALL_TARGET_PROCESSES := Aweme

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SJJAuthBypass

SJJAuthBypass_FILES = Tweak.m
SJJAuthBypass_CFLAGS = -fobjc-arc -I$(THEOS)/include
SJJAuthBypass_LDFLAGS = -lsubstrate
SJJAuthBypass_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
