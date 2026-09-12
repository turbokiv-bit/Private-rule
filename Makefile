# Theos Makefile (relaxin .jbroot rootless ellekit tweak)
# 关键: relaxin 越狱用 .jbroot 前缀(不是 /var/jb), substrate 依赖路径要对齐
# 编译：make clean package FINALPACKAGE=1

TARGET := iphone:clang:latest:14.0
ARCHS := arm64e

INSTALL_TARGET_PROCESSES := Aweme

# .jbroot 前缀 (relaxin)。Theos 会把 dylib ID/libsubstrate 依赖写成 @loader_path/.jbroot/...
export THEOS_PACKAGE_SCHEME = rootless
export THEOS_PACKAGE_INSTALL_PREFIX = .jbroot

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SJJAuthBypass

SJJAuthBypass_FILES = Tweak.m
SJJAuthBypass_CFLAGS = -fobjc-arc -I$(THEOS)/include
# 显式链接 libsubstrate (Theos 按 rootless+.jbroot 前缀处理成 @loader_path/.jbroot/usr/lib/libsubstrate.dylib)
SJJAuthBypass_LIBRARIES = substrate
SJJAuthBypass_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
