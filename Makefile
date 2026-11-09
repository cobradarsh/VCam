export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:14.0

# Rootless jailbreaks (Dopamine, palera1n-rootless): uncomment the next line.
# The commercial .deb you referenced was arm64e / rootless-style, so you
# probably want this ON for a modern device.
# export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = OpenVCam
OpenVCam_FILES = Tweak.x VCamManager.m VCamPreview.m VCamAudio.m
OpenVCam_CFLAGS = -fobjc-arc
OpenVCam_FRAMEWORKS = AVFoundation CoreMedia CoreVideo CoreImage ImageIO CoreGraphics AudioToolbox QuartzCore Foundation UIKit

include $(THEOS)/makefiles/tweak.mk

SUBPROJECTS += prefs
include $(THEOS)/makefiles/aggregate.mk
