#import <Foundation/Foundation.h>

@class AVCaptureVideoPreviewLayer;

NS_ASSUME_NONNULL_BEGIN

// VCamPreview handles the on-screen side of the virtual camera.
//
// The data-output hook in Tweak.x only changes the frames apps *capture*; the
// live preview an app shows comes from AVCaptureVideoPreviewLayer, which draws
// straight from the capture session and bypasses the sample-buffer delegate.
//
// To cover it, we lay an AVSampleBufferDisplayLayer over each preview layer and
// feed it frames from the shared VCamManager, so preview and capture stay in
// sync. When the tweak is disabled the overlay hides and the real preview shows
// through.
@interface VCamPreview : NSObject

+ (instancetype)shared;

// Ensure an overlay exists on this preview layer and is sized to it. Safe to
// call repeatedly (e.g. from the layer's -layoutSublayers).
- (void)attachToPreviewLayer:(AVCaptureVideoPreviewLayer *)layer;

@end

NS_ASSUME_NONNULL_END
