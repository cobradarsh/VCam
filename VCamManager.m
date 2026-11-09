#import "VCamManager.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <notify.h>
#import <math.h>

// Preferences domain. The Settings bundle writes here through cfprefsd; you can
// also set values from the CLI, e.g.:
//   defaults write com.example.openvcam Enabled -bool true
static NSString *const kPrefsDomain = @"com.example.openvcam";

// Default source clip. Drop an .mp4/.mov here (or point SourcePath elsewhere).
static NSString *const kDefaultSource =
    @"/var/mobile/Documents/openvcam.mp4";

// Darwin notification the Settings bundle posts (PostNotification) so running
// processes reload without a respring: `notify_post` this name.
static NSString *const kSettingsChangedNote = @"com.example.openvcam/settingschanged";

@interface VCamManager ()
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, copy)   NSString *sourcePath;

@property (nonatomic, strong) AVAssetReader *reader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *trackOutput;

@property (nonatomic, assign) CVPixelBufferRef latestBuffer; // guarded by _bufLock
@property (nonatomic, strong) dispatch_queue_t decodeQueue;
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, strong) CIContext *ciContext; // lazy, for still rendering

// Orientation controls (from prefs). Applied once per frame in the decode loop
// so every consumer (data output, preview, photo) gets the corrected frame.
@property (nonatomic, assign) NSInteger rotationDegrees; // 0 / 90 / 180 / 270
@property (nonatomic, assign) BOOL mirror;               // horizontal flip
@property (nonatomic, assign) CVPixelBufferPoolRef pool; // reused output buffers
@property (nonatomic, assign) size_t poolWidth;
@property (nonatomic, assign) size_t poolHeight;

@property (nonatomic, assign) BOOL autoScale;
@property (nonatomic, assign) CVPixelBufferPoolRef scalePool; // reused scaled buffers
@property (nonatomic, assign) size_t scaleWidth;
@property (nonatomic, assign) size_t scaleHeight;
@end

@implementation VCamManager {
    NSLock *_bufLock;
}

+ (instancetype)shared {
    static VCamManager *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[VCamManager alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _bufLock = [[NSLock alloc] init];
        _decodeQueue = dispatch_queue_create("com.example.openvcam.decode",
                                              DISPATCH_QUEUE_SERIAL);
        [self registerForSettingsChanges];
        [self reloadSettings];
    }
    return self;
}

#pragma mark - Settings

- (void)registerForSettingsChanges {
    int token;
    notify_register_dispatch(kSettingsChangedNote.UTF8String, &token,
                             dispatch_get_main_queue(), ^(int t) {
        [self reloadSettings];
    });
}

- (void)reloadSettings {
    CFStringRef appID = (__bridge CFStringRef)kPrefsDomain;
    CFPreferencesAppSynchronize(appID); // pull the latest from cfprefsd

    BOOL wasEnabled = self.enabled;

    Boolean hasEnabled = false;
    Boolean enabled = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), appID, &hasEnabled);
    self.enabled = hasEnabled ? (BOOL)enabled : NO;

    // Orientation: next decoded frame picks these up; no restart needed.
    self.rotationDegrees = CFPreferencesGetAppIntegerValue(CFSTR("Rotation"), appID, NULL);
    Boolean hasMirror = false;
    Boolean mir = CFPreferencesGetAppBooleanValue(CFSTR("Mirror"), appID, &hasMirror);
    self.mirror = hasMirror ? (BOOL)mir : NO;

    // Auto-scale to the app's real camera resolution. Default ON.
    Boolean hasScale = false;
    Boolean asc = CFPreferencesGetAppBooleanValue(CFSTR("AutoScale"), appID, &hasScale);
    self.autoScale = hasScale ? (BOOL)asc : YES;

    NSString *path = (__bridge_transfer NSString *)
        CFPreferencesCopyAppValue(CFSTR("SourcePath"), appID);
    if (path.length == 0) path = kDefaultSource;

    BOOL pathChanged = ![path isEqualToString:self.sourcePath];
    self.sourcePath = path;

    if (self.enabled && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (!self.running || pathChanged) {
            [self stopDecodeLoop];
            [self startDecodeLoop];
        }
    } else if (wasEnabled && !self.enabled) {
        [self stopDecodeLoop];
    }
}

#pragma mark - Decode loop

- (void)startDecodeLoop {
    dispatch_async(self.decodeQueue, ^{
        if (self.running) return;
        if (![self setupReader]) return;
        self.running = YES;

        // Pull frames at ~30fps. We decode ahead of the app's own callback
        // rate and simply keep the newest frame around for it to grab.
        dispatch_source_t timer =
            dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.decodeQueue);
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, 0),
                                  (uint64_t)(NSEC_PER_SEC / 30),
                                  (uint64_t)(NSEC_PER_MSEC));
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(timer, ^{ [weakSelf decodeNextFrame]; });
        dispatch_resume(timer);
        self.timer = timer;
    });
}

- (void)stopDecodeLoop {
    dispatch_async(self.decodeQueue, ^{
        if (self.timer) {
            dispatch_source_cancel(self.timer);
            self.timer = nil;
        }
        [self.reader cancelReading];
        self.reader = nil;
        self.trackOutput = nil;
        self.running = NO;

        [self->_bufLock lock];
        if (self.latestBuffer) {
            CVPixelBufferRelease(self.latestBuffer);
            self.latestBuffer = NULL;
        }
        [self->_bufLock unlock];
    });
}

// Build a fresh AVAssetReader positioned at the start of the clip.
- (BOOL)setupReader {
    NSURL *url = [NSURL fileURLWithPath:self.sourcePath];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!track) return NO;

    NSError *err = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (!reader) return NO;

    NSDictionary *settings = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)
    };
    AVAssetReaderTrackOutput *out =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
                                                   outputSettings:settings];
    out.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:out]) return NO;
    [reader addOutput:out];
    if (![reader startReading]) return NO;

    self.reader = reader;
    self.trackOutput = out;
    return YES;
}

- (void)decodeNextFrame {
    if (!self.trackOutput) {
        if (![self setupReader]) return;
    }

    CMSampleBufferRef sb = [self.trackOutput copyNextSampleBuffer];
    if (!sb) {
        // End of clip reached - loop back to the beginning.
        [self.reader cancelReading];
        self.reader = nil;
        self.trackOutput = nil;
        if (![self setupReader]) return;
        sb = [self.trackOutput copyNextSampleBuffer];
        if (!sb) return;
    }

    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (pb) {
        CVPixelBufferRef oriented = [self orientedBufferFrom:pb]; // +1 retained
        [_bufLock lock];
        if (self.latestBuffer) CVPixelBufferRelease(self.latestBuffer);
        self.latestBuffer = oriented;
        [_bufLock unlock];
    }
    CFRelease(sb);
}

#pragma mark - Orientation

// Grab (or build) a pooled BGRA output buffer of the requested size.
- (CVPixelBufferRef)outputBufferWidth:(size_t)w height:(size_t)h {
    if (!self.pool || self.poolWidth != w || self.poolHeight != h) {
        if (self.pool) { CVPixelBufferPoolRelease(self.pool); self.pool = NULL; }
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey   : @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey             : @(w),
            (id)kCVPixelBufferHeightKey            : @(h),
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        };
        CVPixelBufferPoolRef pool = NULL;
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
                                (__bridge CFDictionaryRef)attrs, &pool);
        self.pool = pool;
        self.poolWidth = w;
        self.poolHeight = h;
    }
    CVPixelBufferRef out = NULL;
    if (self.pool) {
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, self.pool, &out);
    }
    return out;
}

// Apply rotation (90deg steps) and optional horizontal mirror. Returns a +1
// buffer the caller owns. On the no-op path (0deg, no mirror) just retains src.
- (CVPixelBufferRef)orientedBufferFrom:(CVPixelBufferRef)src {
    NSInteger rot = ((self.rotationDegrees % 360) + 360) % 360;
    BOOL mir = self.mirror;

    if (rot == 0 && !mir) {
        CVPixelBufferRetain(src);
        return src;
    }

    CIImage *img = [CIImage imageWithCVPixelBuffer:src];
    if (rot != 0) {
        CGFloat rad = (CGFloat)(rot * M_PI / 180.0);
        img = [img imageByApplyingTransform:CGAffineTransformMakeRotation(rad)];
    }
    if (mir) {
        img = [img imageByApplyingTransform:CGAffineTransformMakeScale(-1.0, 1.0)];
    }
    // A rotation/flip can push the extent off the origin; move it back.
    CGRect ext = img.extent;
    img = [img imageByApplyingTransform:
           CGAffineTransformMakeTranslation(-ext.origin.x, -ext.origin.y)];
    ext = img.extent;

    size_t w = (size_t)llround(ext.size.width);
    size_t h = (size_t)llround(ext.size.height);
    if (w == 0 || h == 0) { CVPixelBufferRetain(src); return src; }

    CVPixelBufferRef out = [self outputBufferWidth:w height:h];
    if (!out) { CVPixelBufferRetain(src); return src; }

    [self.ciContext render:img toCVPixelBuffer:out];
    return out; // +1
}

#pragma mark - Scaling

- (CVPixelBufferRef)scaledBufferWidth:(size_t)w height:(size_t)h {
    if (!self.scalePool || self.scaleWidth != w || self.scaleHeight != h) {
        if (self.scalePool) { CVPixelBufferPoolRelease(self.scalePool); self.scalePool = NULL; }
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey     : @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey               : @(w),
            (id)kCVPixelBufferHeightKey              : @(h),
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        };
        CVPixelBufferPoolRef pool = NULL;
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
                                (__bridge CFDictionaryRef)attrs, &pool);
        self.scalePool = pool;
        self.scaleWidth = w;
        self.scaleHeight = h;
    }
    CVPixelBufferRef out = NULL;
    if (self.scalePool) {
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, self.scalePool, &out);
    }
    return out;
}

- (CVPixelBufferRef)copyCurrentPixelBufferScaledToWidth:(size_t)w height:(size_t)h {
    CVPixelBufferRef src = [self copyCurrentPixelBuffer]; // oriented, +1
    if (!src) return NULL;

    size_t sw = CVPixelBufferGetWidth(src);
    size_t sh = CVPixelBufferGetHeight(src);
    if (w == 0 || h == 0 || (sw == w && sh == h)) return src; // already the right size

    CIImage *img = [CIImage imageWithCVPixelBuffer:src];
    CGFloat scale = MAX((CGFloat)w / sw, (CGFloat)h / sh); // aspect-fill
    img = [img imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];

    // Center-crop the scaled image to exactly w x h.
    CGRect ext = img.extent;
    CGFloat tx = (ext.size.width  - (CGFloat)w) / 2.0;
    CGFloat ty = (ext.size.height - (CGFloat)h) / 2.0;
    img = [img imageByApplyingTransform:
           CGAffineTransformMakeTranslation(-ext.origin.x - tx, -ext.origin.y - ty)];
    img = [img imageByCroppingToRect:CGRectMake(0, 0, w, h)];

    CVPixelBufferRef out = [self scaledBufferWidth:w height:h];
    if (!out) return src; // fall back to unscaled

    [self.ciContext render:img toCVPixelBuffer:out];
    CVPixelBufferRelease(src);
    return out; // +1
}

#pragma mark - Consumer API

- (CVPixelBufferRef)copyCurrentPixelBuffer {
    CVPixelBufferRef out = NULL;
    [_bufLock lock];
    if (self.latestBuffer) {
        out = self.latestBuffer;
        CVPixelBufferRetain(out);
    }
    [_bufLock unlock];
    return out;
}

#pragma mark - Still rendering

- (CIContext *)ciContext {
    if (!_ciContext) _ciContext = [CIContext contextWithOptions:nil];
    return _ciContext;
}

- (CGImageRef)copyCurrentCGImage {
    CVPixelBufferRef pb = [self copyCurrentPixelBuffer];
    if (!pb) return NULL;
    CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
    CGImageRef cg = [self.ciContext createCGImage:ci fromRect:ci.extent];
    CVPixelBufferRelease(pb);
    return cg; // caller owns
}

- (NSData *)currentJPEGDataWithQuality:(CGFloat)quality {
    CGImageRef cg = [self copyCurrentCGImage];
    if (!cg) return nil;

    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef dest =
        CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,
                                         (__bridge CFStringRef)@"public.jpeg",
                                         1, NULL);
    if (!dest) { CGImageRelease(cg); return nil; }

    NSDictionary *props = @{ (id)kCGImageDestinationLossyCompressionQuality : @(quality) };
    CGImageDestinationAddImage(dest, cg, (__bridge CFDictionaryRef)props);
    BOOL ok = CGImageDestinationFinalize(dest);

    CFRelease(dest);
    CGImageRelease(cg);
    return (ok && data.length) ? data : nil;
}

@end
