#import <Preferences/PSListController.h>

// A minimal in-Settings file browser. Lists folders and video files under
// basePath; tapping a video writes its path to the SourcePath preference,
// tapping a folder descends into it.
@interface OVCFilePickerController : PSListController
@property (nonatomic, copy) NSString *basePath; // defaults to /var/mobile/Documents
@end
