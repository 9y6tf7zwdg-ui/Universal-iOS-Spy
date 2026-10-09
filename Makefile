ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = UniversalSpy
UniversalSpy_FILES = Tweak.x
UniversalSpy_CFLAGS = -fobjc-arc
UniversalSpy_FRAMEWORKS = UIKit Foundation AVFoundation PhotosUI
include $(THEOS_MAKE_PATH)/tweak.mk