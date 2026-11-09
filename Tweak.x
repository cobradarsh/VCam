#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import "VCamManager.h"
#import "VCamPreview.h"
#import "VCamAudio.h"

// Associated-object key used to keep our proxy delegate alive for as long as
// the AVCaptureVideoDataOutput that owns it.
static char kProxyKey;

// Build a new CMSampleBuffer that carries OUR pixel buffer but reuses the
// timing of the real frame, so the app's pipeline sees a well-formed buffer
// arriving on schedule.
//
// NOTE (v1 limitation): we do not rescale. For the cleanest result, encode
// your source clip at the same resolution the app requests from the camera
// (often 1280x720 or 1920x1080). Auto-scaling is a planned enhancement.
static CMSampleBufferRef CreateReplacementBuffer(CMSampleBufferRef original,
                                                 CVPixelBufferRef replacement) {
    CMSampleTimingInfo timing;
    if (CMSampleBufferGetSampleTimingInfo(original, 0, &timing) != noErr) {
        timing.duration              = kCMTimeInvalid;
        timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(original);
        timing.decodeTimeStamp       = kCMTimeInvalid;
    }

    CMVideoFormatDescriptionRef format = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                     replacement, &format) != noErr) {
        return NULL;
    }

    CMSampleBufferRef newBuffer = NULL;
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                               replacement,
                                                               format,
                                                               &timing,
                                                               &newBuffer);
    if (format) CFRelease(format);
    return (status == noErr) ? newBuffer : NULL;
}

#pragma mark - Delegate proxy

// We insert ourselves between AVFoundation and the app's real sample-buffer
// delegate. Every frame the camera produces passes through here; when the
// tweak is enabled we swap in a frame from the user's video instead.
@interface OVCDelegateProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
// Strong ref: the proxy must outlive the app's delegate during the session.
// The proxy itself is retained by the output via an associated object, and is
// released when the output is deallocated, so this does not leak permanently.
@property (nonatomic, strong) id<AVCaptureVideoDataOutputSampleBufferDelegate> target;
@end

@implementation OVCDelegateProxy

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {

    CMSampleBufferRef deliver = sampleBuffer;
    CMSampleBufferRef replacement = NULL;

    if ([VCamManager shared].enabled) {
        CVPixelBufferRef pb = NULL;
        if ([VCamManager shared].autoScale) {
            // Match the app's real camera resolution exactly.
            CVImageBufferRef real = CMSampleBufferGetImageBuffer(sampleBuffer);
            size_t tw = real ? CVPixelBufferGetWidth(real)  : 0;
            size_t th = real ? CVPixelBufferGetHeight(real) : 0;
            pb = (tw && th)
                ? [[VCamManager shared] copyCurrentPixelBufferScaledToWidth:tw height:th]
                : [[VCamManager shared] copyCurrentPixelBuffer];
        } else {
            pb = [[VCamManager shared] copyCurrentPixelBuffer];
        }
        if (pb) {
            replacement = CreateReplacementBuffer(sampleBuffer, pb);
            CVPixelBufferRelease(pb);
            if (replacement) deliver = replacement;
        }
    }

    if ([self.target respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [self.target captureOutput:output didOutputSampleBuffer:deliver fromConnection:connection];
    }

    if (replacement) CFRelease(replacement);
}

- (void)captureOutput:(AVCaptureOutput *)output
  didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    if ([self.target respondsToSelector:_cmd]) {
        [self.target captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

// Forward anything else (KVC, introspection, etc.) to the real delegate.
- (BOOL)respondsToSelector:(SEL)aSelector {
    if ([super respondsToSelector:aSelector]) return YES;
    return [self.target respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    if ([self.target respondsToSelector:aSelector]) return self.target;
    return [super forwardingTargetForSelector:aSelector];
}

@end

#pragma mark - Hook

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (!delegate || [delegate isKindOfClass:[OVCDelegateProxy class]]) {
        %orig;
        return;
    }

    OVCDelegateProxy *proxy = [[OVCDelegateProxy alloc] init];
    proxy.target = delegate;

    // Keep the proxy alive alongside this output.
    objc_setAssociatedObject(self, &kProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    %orig(proxy, queue);
}

%end

#pragma mark - Preview hook

// The data-output hook above changes what apps *capture*. The on-screen
// preview is drawn by AVCaptureVideoPreviewLayer straight from the session, so
// we overlay our own display layer on it (driven by the same source frames).
%hook AVCaptureVideoPreviewLayer

- (void)layoutSublayers {
    %orig;
    [[VCamPreview shared] attachToPreviewLayer:self];
}

%end

#pragma mark - Still photo hook

// When an app takes a photo, the system hands its delegate an AVCapturePhoto
// and the app reads the image back from it. We can't construct an AVCapturePhoto
// ourselves, so instead we let the real object through and answer its image
// accessors with data rendered from the current source frame.
%hook AVCapturePhoto

- (NSData *)fileDataRepresentation {
    if ([VCamManager shared].enabled) {
        NSData *d = [[VCamManager shared] currentJPEGDataWithQuality:0.95];
        if (d) return d;
    }
    return %orig;
}

- (CGImageRef)CGImageRepresentation {
    if ([VCamManager shared].enabled) {
        CGImageRef img = [[VCamManager shared] copyCurrentCGImage];
        if (img) return (CGImageRef)CFAutorelease(img); // caller doesn't own it
    }
    return %orig;
}

- (CGImageRef)previewCGImageRepresentation {
    if ([VCamManager shared].enabled) {
        CGImageRef img = [[VCamManager shared] copyCurrentCGImage];
        if (img) return (CGImageRef)CFAutorelease(img);
    }
    return %orig;
}

- (CVPixelBufferRef)pixelBuffer {
    if ([VCamManager shared].enabled) {
        CVPixelBufferRef pb = [[VCamManager shared] copyCurrentPixelBuffer];
        if (pb) return (CVPixelBufferRef)CFAutorelease(pb);
    }
    return %orig;
}

- (CVPixelBufferRef)previewPixelBuffer {
    if ([VCamManager shared].enabled) {
        CVPixelBufferRef pb = [[VCamManager shared] copyCurrentPixelBuffer];
        if (pb) return (CVPixelBufferRef)CFAutorelease(pb);
    }
    return %orig;
}

%end

#pragma mark - Audio replacement

static char kAudioProxyKey;

// Build a replacement audio CMSampleBuffer: same format + timing as the real
// one, but PCM pulled from the source clip. Returns NULL (keep real audio) when
// the format isn't interleaved LPCM or the source has no usable audio.
static CMSampleBufferRef CreateReplacementAudioBuffer(CMSampleBufferRef original) {
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(original);
    if (!fmt) return NULL;
    const AudioStreamBasicDescription *asbd =
        CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
    if (!asbd || asbd->mFormatID != kAudioFormatLinearPCM) return NULL;
    if (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) return NULL;
    if (asbd->mBytesPerFrame == 0) return NULL;

    CMItemCount frameCount = CMSampleBufferGetNumSamples(original);
    if (frameCount == 0) return NULL;

    [[VCamAudio shared] prepareWithASBD:asbd];

    size_t dataLen = (size_t)frameCount * asbd->mBytesPerFrame;
    void *data = malloc(dataLen);
    if (!data) return NULL;
    if (![[VCamAudio shared] fillBuffer:data frameCount:(UInt32)frameCount]) {
        free(data);
        return NULL;
    }

    CMBlockBufferRef bb = NULL;
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, data, dataLen,
                      kCFAllocatorMalloc, NULL, 0, dataLen, 0, &bb);
    if (st != kCMBlockBufferNoErr || !bb) { free(data); return NULL; }

    CMSampleTimingInfo timing;
    if (CMSampleBufferGetSampleTimingInfo(original, 0, &timing) != noErr) {
        timing.duration              = kCMTimeInvalid;
        timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(original);
        timing.decodeTimeStamp       = kCMTimeInvalid;
    }
    size_t sampleSize = asbd->mBytesPerFrame;

    CMSampleBufferRef out = NULL;
    st = CMSampleBufferCreateReady(kCFAllocatorDefault, bb, fmt,
                                   frameCount, 1, &timing, 1, &sampleSize, &out);
    CFRelease(bb); // `out` retains it; bb frees `data` when finally released
    return (st == noErr) ? out : NULL;
}

// Proxy between AVFoundation and the app's audio delegate (same shape as the
// video proxy).
@interface OVCAudioDelegateProxy : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, strong) id<AVCaptureAudioDataOutputSampleBufferDelegate> target;
@end

@implementation OVCAudioDelegateProxy

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {

    CMSampleBufferRef deliver = sampleBuffer;
    CMSampleBufferRef replacement = NULL;

    if ([VCamAudio shared].enabled) {
        replacement = CreateReplacementAudioBuffer(sampleBuffer);
        if (replacement) deliver = replacement;
    }

    if ([self.target respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [self.target captureOutput:output didOutputSampleBuffer:deliver fromConnection:connection];
    }

    if (replacement) CFRelease(replacement);
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    if ([super respondsToSelector:aSelector]) return YES;
    return [self.target respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    if ([self.target respondsToSelector:aSelector]) return self.target;
    return [super forwardingTargetForSelector:aSelector];
}

@end

%hook AVCaptureAudioDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (!delegate || [delegate isKindOfClass:[OVCAudioDelegateProxy class]]) {
        %orig;
        return;
    }
    OVCAudioDelegateProxy *proxy = [[OVCAudioDelegateProxy alloc] init];
    proxy.target = delegate;
    objc_setAssociatedObject(self, &kAudioProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(proxy, queue);
}

%end

#pragma mark - Init

%ctor {
    // Touch the managers early so they load settings and register for the
    // "settings changed" Darwin notification in each camera-using process.
    [VCamManager shared];
    [VCamAudio shared];
}
