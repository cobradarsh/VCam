#import "OVCRootListController.h"
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <notify.h>

// Theos passes the package install prefix as a C string: "" for rootful,
// "/var/jb" for rootless.
#ifndef THEOS_PACKAGE_INSTALL_PREFIX
#define THEOS_PACKAGE_INSTALL_PREFIX ""
#endif

static NSString *const kDomain      = @"com.example.openvcam";
static const char *kChangedNote     = "com.example.openvcam/settingschanged";
static NSString *const kImportPrefix = @"video-";

// Imported videos are copied here. Camera apps run sandboxed, and the
// jailbreak lets them read <jbroot>/Library/Application Support, so this is a
// path the tweak can open from inside any app. The package's postinst creates
// the folder and hands it to `mobile` so Settings can write into it.
static NSString *OVCImportDirectory(void) {
    return [@THEOS_PACKAGE_INSTALL_PREFIX stringByAppendingString:
            @"/Library/Application Support/OpenVCam"];
}

@interface OVCRootListController () <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) UIAlertController *progressAlert;
@end

@implementation OVCRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

#pragma mark - Photos

- (void)pickFromPhotos:(PSSpecifier *)spec {
    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.filter = [PHPickerFilter videosFilter];
    config.selectionLimit = 1;
    // Hand over the original file instead of transcoding it first: much faster,
    // and the tweak decodes HEVC/H.264 alike.
    config.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;

    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    NSItemProvider *provider = results.firstObject.itemProvider;
    [picker dismissViewControllerAnimated:YES completion:^{
        if (!provider) return; // cancelled

        NSString *type = UTTypeMovie.identifier;
        if (![provider hasItemConformingToTypeIdentifier:type]) {
            [self showTitle:@"Not a video" message:@"Pick a video, not a photo."];
            return;
        }

        [self showProgressThen:^{
            [provider loadFileRepresentationForTypeIdentifier:type
                                            completionHandler:^(NSURL *url, NSError *loadError) {
                // `url` is deleted as soon as this block returns, so copy it now.
                NSError *copyError = nil;
                NSString *dest = url ? [self importFileAtURL:url error:&copyError] : nil;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self finishImportWithPath:dest error:loadError ?: copyError];
                });
            }];
        }];
    }];
}

#pragma mark - Files

- (void)pickFromFiles:(PSSpecifier *)spec {
    // asCopy:YES gives us our own copy of the file, so iCloud Drive and
    // third-party file providers work without security-scoped access.
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeMovie ]
                                                                    asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;

    // The document picker dismisses itself; wait for that before presenting.
    [self whenNothingPresented:^{
        [self showProgressThen:^{
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSError *error = nil;
                NSString *dest = [self importFileAtURL:url error:&error];
                // Remove the picker's temporary copy.
                [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self finishImportWithPath:dest error:error];
                });
            });
        }];
    }];
}

#pragma mark - Import

// Copies the video into the import folder under a fresh name and removes
// earlier imports. Returns the new path, or nil with *error set.
- (NSString *)importFileAtURL:(NSURL *)src error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = OVCImportDirectory();

    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:error]) {
        return nil;
    }
    if (![fm isWritableFileAtPath:dir]) {
        if (error) {
            *error = [NSError errorWithDomain:kDomain code:1 userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Can't write to %@. Reinstall OpenVCam so it "
                                               @"can set up this folder.", dir]
            }];
        }
        return nil;
    }

    NSString *ext = src.pathExtension.lowercaseString;
    if (ext.length == 0) ext = @"mov";
    NSString *name = [NSString stringWithFormat:@"%@%lld.%@", kImportPrefix,
                      (long long)([[NSDate date] timeIntervalSince1970] * 1000), ext];
    NSString *dest = [dir stringByAppendingPathComponent:name];

    if (![fm copyItemAtPath:src.path toPath:dest error:error]) return nil;
    [fm setAttributes:@{ NSFilePosixPermissions: @0644 } ofItemAtPath:dest error:NULL];

    // Keep only the newest import. An app still reading an old file keeps its
    // open handle; the change notification moves it to the new one.
    for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
        if ([f hasPrefix:kImportPrefix] && ![f isEqualToString:name]) {
            [fm removeItemAtPath:[dir stringByAppendingPathComponent:f] error:NULL];
        }
    }
    return dest;
}

- (void)finishImportWithPath:(NSString *)path error:(NSError *)error {
    void (^report)(void) = ^{
        if (path) {
            CFPreferencesSetAppValue(CFSTR("SourcePath"), (__bridge CFStringRef)path,
                                     (__bridge CFStringRef)kDomain);
            CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
            notify_post(kChangedNote);
            [self reloadSpecifiers];
            [self showTitle:@"Video selected"
                    message:@"OpenVCam will use this video. Make sure Enabled is on, then "
                            @"reopen the camera in your app."];
        } else {
            [self showTitle:@"Couldn't import video"
                    message:error.localizedDescription ?: @"Unknown error."];
        }
    };

    if (self.progressAlert) {
        UIAlertController *progress = self.progressAlert;
        self.progressAlert = nil;
        [progress dismissViewControllerAnimated:YES completion:report];
    } else {
        report();
    }
}

#pragma mark - UI helpers

- (void)showProgressThen:(void (^)(void))work {
    self.progressAlert = [UIAlertController alertControllerWithTitle:@"Importing video…"
                                                             message:@"\n"
                                                      preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spinner =
        [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [spinner startAnimating];
    [self.progressAlert.view addSubview:spinner];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:self.progressAlert.view.centerXAnchor],
        [spinner.bottomAnchor constraintEqualToAnchor:self.progressAlert.view.bottomAnchor constant:-16],
    ]];
    [self presentViewController:self.progressAlert animated:YES completion:work];
}

- (void)showTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self whenNothingPresented:^{
        [self presentViewController:alert animated:YES completion:nil];
    }];
}

// Runs `block` once no other view controller is being presented or dismissed
// (presenting during a dismissal animation is silently dropped by UIKit).
- (void)whenNothingPresented:(void (^)(void))block {
    [self whenNothingPresented:block tries:0];
}

- (void)whenNothingPresented:(void (^)(void))block tries:(int)tries {
    if (self.presentedViewController == nil || tries >= 30) { // give up after ~3 s
        block();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self whenNothingPresented:block tries:tries + 1];
    });
}

@end
