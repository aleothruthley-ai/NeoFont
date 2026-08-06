TARGET := iphone:clang:14.5:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = NeoFontPrefs

NeoFontPrefs_FILES = NeoFontRootListController.m
NeoFontPrefs_FRAMEWORKS = UIKit CoreText
NeoFontPrefs_PRIVATE_FRAMEWORKS = Preferences
NeoFontPrefs_INSTALL_PATH = /Library/PreferenceBundles
NeoFontPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
