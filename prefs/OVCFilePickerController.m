#import "OVCFilePickerController.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <notify.h>

static NSString *const kDomain      = @"com.example.openvcam";
static NSString *const kDefaultRoot = @"/var/mobile/Documents";
static const char *kChangedNote     = "com.example.openvcam/settingschanged";

@implementation OVCFilePickerController

- (NSString *)basePath {
    if (!_basePath) _basePath = [kDefaultRoot copy];
    return _basePath;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self.basePath isEqualToString:kDefaultRoot]
        ? @"Choose video"
        : self.basePath.lastPathComponent;
}

- (BOOL)isVideoName:(NSString *)name {
    NSString *ext = name.pathExtension.lowercaseString;
    return [@[ @"mp4", @"mov", @"m4v" ] containsObject:ext];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        NSFileManager *fm = [NSFileManager defaultManager];

        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:self.basePath];
        [group setProperty:@"Tap a video to use it as the source. Tap a folder to open it."
                    forKey:@"footerText"];
        [specs addObject:group];

        NSArray *items = [[fm contentsOfDirectoryAtPath:self.basePath error:NULL]
                          sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
        BOOL any = NO;

        for (NSString *name in items) {
            if ([name hasPrefix:@"."]) continue;
            NSString *full = [self.basePath stringByAppendingPathComponent:name];

            BOOL isDir = NO;
            [fm fileExistsAtPath:full isDirectory:&isDir];

            if (isDir) {
                PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name
                                  target:self set:NULL get:NULL detail:Nil
                                  cell:PSLinkCell edit:Nil];
                [s setProperty:full forKey:@"ovcPath"];
                [s setButtonAction:@selector(openFolder:)];
                [specs addObject:s];
                any = YES;
            } else if ([self isVideoName:name]) {
                PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name
                                  target:self set:NULL get:NULL detail:Nil
                                  cell:PSButtonCell edit:Nil];
                [s setProperty:full forKey:@"ovcPath"];
                [s setButtonAction:@selector(selectFile:)];
                [specs addObject:s];
                any = YES;
            }
        }

        if (!any) {
            PSSpecifier *empty = [PSSpecifier groupSpecifierWithName:@""];
            [empty setProperty:@"No videos or folders here. Put an .mp4/.mov in "
                                 "/var/mobile/Documents (via Filza or SSH)."
                        forKey:@"footerText"];
            [specs addObject:empty];
        }

        _specifiers = specs;
    }
    return _specifiers;
}

- (void)openFolder:(PSSpecifier *)spec {
    OVCFilePickerController *child = [[OVCFilePickerController alloc] init];
    child.basePath = [spec propertyForKey:@"ovcPath"];
    [self pushController:child];
}

- (void)selectFile:(PSSpecifier *)spec {
    NSString *path = [spec propertyForKey:@"ovcPath"];
    if (path.length == 0) return;

    CFPreferencesSetAppValue(CFSTR("SourcePath"),
                             (__bridge CFStringRef)path,
                             (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    notify_post(kChangedNote);

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Source set"
                                            message:path.lastPathComponent
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self.navigationController popToRootViewControllerAnimated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
