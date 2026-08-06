DEBUG = 0
FINALPACKAGE = 1
PACKAGE_VERSION = 1.0.0

TARGET := iphone:clang:14.5:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NeoFont
NeoFont_FILES = Tweak.x
NeoFont_CFLAGS = -fobjc-arc
NeoFont_FRAMEWORKS = UIKit CoreText CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += neofontprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
