#import "VCamAudio.h"
#import <AVFoundation/AVFoundation.h>
#import <notify.h>

static NSString *const kPrefsDomain = @"com.example.openvcam";
static NSString *const kDefaultSource = @"/var/mobile/Documents/openvcam.mp4";
static NSString *const kSettingsChangedNote = @"com.example.openvcam/settingschanged";

@interface VCamAudio () {
    NSLock *_lock;
}
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, copy)   NSString *sourcePath;

@property (nonatomic, strong) AVAssetReader *reader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *trackOutput;
@property (nonatomic, strong) NSMutableData *leftover; // decoded PCM not yet consumed

@property (nonatomic, assign) AudioStreamBasicDescription asbd;
@property (nonatomic, assign) BOOL hasASBD;
@property (nonatomic, assign) BOOL noAudioTrack;
@end

@implementation VCamAudio

+ (instancetype)shared {
    static VCamAudio *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[VCamAudio alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [[NSLock alloc] init];
        _leftover = [NSMutableData data];
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
    CFPreferencesAppSynchronize(appID);

    Boolean hasEnabled = false, hasReplace = false;
    Boolean en = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), appID, &hasEnabled);
    Boolean ra = CFPreferencesGetAppBooleanValue(CFSTR("ReplaceAudio"), appID, &hasReplace);
    self.enabled = (hasEnabled ? (BOOL)en : NO) && (hasReplace ? (BOOL)ra : NO);

    NSString *path = (__bridge_transfer NSString *)
        CFPreferencesCopyAppValue(CFSTR("SourcePath"), appID);
    if (path.length == 0) path = kDefaultSource;

    [_lock lock];
    if (![path isEqualToString:self.sourcePath]) {
        self.sourcePath = path;
        if (self.hasASBD) [self rebuildReaderLocked]; // re-decode new source
    }
    [_lock unlock];
}

#pragma mark - Decoder

- (void)prepareWithASBD:(const AudioStreamBasicDescription *)asbd {
    if (!asbd) return;
    [_lock lock];
    BOOL changed = !self.hasASBD
        || self.asbd.mSampleRate     != asbd->mSampleRate
        || self.asbd.mChannelsPerFrame != asbd->mChannelsPerFrame
        || self.asbd.mBitsPerChannel != asbd->mBitsPerChannel
        || self.asbd.mFormatFlags    != asbd->mFormatFlags;
    if (changed) {
        self.asbd = *asbd;
        self.hasASBD = YES;
        [self rebuildReaderLocked];
    }
    [_lock unlock];
}

// Caller must hold _lock.
- (void)rebuildReaderLocked {
    [self.reader cancelReading];
    self.reader = nil;
    self.trackOutput = nil;
    self.leftover.length = 0;
    self.noAudioTrack = NO;

    if (self.sourcePath.length == 0 || !self.hasASBD) return;

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:self.sourcePath]
                                           options:nil];
    AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (!track) { self.noAudioTrack = YES; return; }

    NSDictionary *settings = @{
        AVFormatIDKey               : @(kAudioFormatLinearPCM),
        AVSampleRateKey             : @(self.asbd.mSampleRate),
        AVNumberOfChannelsKey       : @(self.asbd.mChannelsPerFrame),
        AVLinearPCMBitDepthKey      : @(self.asbd.mBitsPerChannel),
        AVLinearPCMIsFloatKey       : @((self.asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0),
        AVLinearPCMIsBigEndianKey   : @((self.asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0),
        AVLinearPCMIsNonInterleaved : @NO, // we only support interleaved output
    };

    NSError *err = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (!reader) return;
    AVAssetReaderTrackOutput *out =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:settings];
    out.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:out]) return;
    [reader addOutput:out];
    if (![reader startReading]) return;

    self.reader = reader;
    self.trackOutput = out;
}

#pragma mark - Consumer

- (BOOL)fillBuffer:(void *)dst frameCount:(UInt32)frameCount {
    if (!self.enabled || dst == NULL || frameCount == 0) return NO;

    [_lock lock];

    // Only interleaved LPCM is supported.
    if (self.noAudioTrack || !self.trackOutput
        || (self.asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved)
        || self.asbd.mBytesPerFrame == 0) {
        [_lock unlock];
        return NO;
    }

    size_t need = (size_t)frameCount * self.asbd.mBytesPerFrame;

    int loops = 0;
    while (self.leftover.length < need) {
        CMSampleBufferRef sb = [self.trackOutput copyNextSampleBuffer];
        if (!sb) {
            // End of clip — loop back to the start.
            [self rebuildReaderLocked];
            if (!self.trackOutput || ++loops > 4) break;
            continue;
        }
        CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
        if (bb) {
            size_t len = CMBlockBufferGetDataLength(bb);
            if (len > 0) {
                void *tmp = malloc(len);
                if (tmp && CMBlockBufferCopyDataBytes(bb, 0, len, tmp) == kCMBlockBufferNoErr) {
                    [self.leftover appendBytes:tmp length:len];
                }
                if (tmp) free(tmp);
            }
        }
        CFRelease(sb);
    }

    if (self.leftover.length < need) { [_lock unlock]; return NO; }

    memcpy(dst, self.leftover.bytes, need);
    [self.leftover replaceBytesInRange:NSMakeRange(0, need) withBytes:NULL length:0];

    [_lock unlock];
    return YES;
}

@end
