include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = OpenVCamPrefs

OpenVCamPrefs_FILES = OVCRootListController.m OVCFilePickerController.m
OpenVCamPrefs_INSTALL_PATH = $(THEOS_PACKAGE_INSTALL_PREFIX)/Library/PreferenceBundles
OpenVCamPrefs_FRAMEWORKS = UIKit
OpenVCamPrefs_PRIVATE_FRAMEWORKS = Preferences
OpenVCamPrefs_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/bundle.mk

# Install the PreferenceLoader entry so the bundle shows up in the Settings
# root list. THEOS_PACKAGE_INSTALL_PREFIX is empty for rootful and /var/jb for
# rootless, so this works for both schemes.
internal-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/PreferenceLoader/Preferences"$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/PreferenceLoader/Preferences/OpenVCam.plist"$(ECHO_END)
