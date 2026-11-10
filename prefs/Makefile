include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = OpenVCamPrefs

OpenVCamPrefs_FILES = OVCRootListController.m OVCFilePickerController.m
OpenVCamPrefs_INSTALL_PATH = /Library/PreferenceBundles
OpenVCamPrefs_FRAMEWORKS = UIKit
OpenVCamPrefs_PRIVATE_FRAMEWORKS = Preferences
OpenVCamPrefs_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/bundle.mk

# Install the PreferenceLoader entry so the bundle shows up in the Settings
# root list. THEOS_STAGING_DIR already points at the scheme's install root
# (it includes /var/jb under the rootless scheme), so do NOT add the prefix
# again here or the path ends up doubled (var/jb/var/jb/...).
internal-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/OpenVCam.plist"$(ECHO_END)
