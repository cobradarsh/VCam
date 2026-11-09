#import "VCamPreview.h"
#import "VCamManager.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// Associated-object key: the AVSampleBufferDisplayLayer we attach to a given
// preview layer.
static char kDisplayLayerKey;

// Wrap one of our pixel buffers in a CMSampleBuffer flagged to display right
// away, so the display layer renders it without needing a timebase schedule.
static CMSampleBufferRef CreateDisplaySampleBuffer(CVPixelBufferRef pb) {
    CMVideoFormatDescriptionRef format = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &format) != noErr) {
        return NULL;
    }

    CMSampleTimingInfo timing = { kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid };
    CMSampleBufferRef sb = NULL;
    OSStatus st = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                           pb, format, &timing, &sb);
    if (format) CFRelease(format);
    if (st != noErr || !sb) return NULL;

    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sb, YES);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef d =
            (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(d, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    }
    return sb;
}

@interface VCamPreview ()
// Weakly-held set of the display layers we've attached, so overlays for
// dismissed camera screens drop out automatically.
@property (nonatomic, strong) NSHashTable<AVSampleBufferDisplayLayer *> *displayLayers;
@property (nonatomic, strong) CADisplayLink *link;
@end

@implementation VCamPreview

+ (instancetype)shared {
    static VCamPreview *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[VCamPreview alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _displayLayers = [NSHashTable weakObjectsHashTable];
    }
    return self;
}

- (void)attachToPreviewLayer:(AVCaptureVideoPreviewLayer *)layer {
    if (!layer) return;

    AVSampleBufferDisplayLayer *disp =
        objc_getAssociatedObject(layer, &kDisplayLayerKey);

    if (!disp) {
        disp = [[AVSampleBufferDisplayLayer alloc] init];
        disp.videoGravity = AVLayerVideoGravityResizeAspectFill;
        disp.zPosition = 10000.0; // sit above the camera content
        disp.hidden = YES;
        [layer addSublayer:disp];
        objc_setAssociatedObject(layer, &kDisplayLayerKey, disp,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @synchronized (self.displayLayers) { [self.displayLayers addObject:disp]; }
        [self ensureDisplayLink];
    }

    // Keep the overlay matched to the preview's bounds, without animating.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    disp.frame = layer.bounds;
    [CATransaction commit];
}

- (void)ensureDisplayLink {
    if (self.link) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.link) return;
        self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
        if (@available(iOS 10.0, *)) self.link.preferredFramesPerSecond = 30;
        [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    });
}

- (void)tick {
    BOOL enabled = [VCamManager shared].enabled;

    CMSampleBufferRef sb = NULL;
    if (enabled) {
        CVPixelBufferRef pb = [[VCamManager shared] copyCurrentPixelBuffer];
        if (pb) {
            sb = CreateDisplaySampleBuffer(pb);
            CVPixelBufferRelease(pb);
        }
    }

    NSArray<AVSampleBufferDisplayLayer *> *layers;
    @synchronized (self.displayLayers) { layers = self.displayLayers.allObjects; }

    for (AVSampleBufferDisplayLayer *disp in layers) {
        if (!enabled || !sb) {
            // Let the real preview show through.
            if (!disp.hidden) {
                disp.hidden = YES;
                [disp flushAndRemoveImage];
            }
            continue;
        }

        disp.hidden = NO;
        if (disp.status == AVQueuedSampleBufferRenderingStatusFailed) {
            [disp flush];
        }
        if (disp.isReadyForMoreMediaData) {
            [disp enqueueSampleBuffer:sb];
        }
    }

    if (sb) CFRelease(sb);
}

@end
