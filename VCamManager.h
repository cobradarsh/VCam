#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// VCamManager owns the "source" side of the virtual camera:
// it decodes a user-supplied video file into a looping stream of
// CVPixelBuffers that the hook layer can hand to apps in place of the
// real camera frames.
@interface VCamManager : NSObject

+ (instancetype)shared;

// Whether frame replacement is currently active. Driven by the prefs plist.
@property (nonatomic, assign, readonly) BOOL enabled;

// Whether source frames should be scaled to the app's real camera resolution.
@property (nonatomic, assign, readonly) BOOL autoScale;

// Reload Enabled / SourcePath from the preferences plist and (re)start or
// stop decoding as needed. Safe to call repeatedly.
- (void)reloadSettings;

// Returns a retained copy reference to the most recently decoded frame,
// or NULL if nothing is ready yet. Caller must CVPixelBufferRelease() it.
- (nullable CVPixelBufferRef)copyCurrentPixelBuffer CF_RETURNS_RETAINED;

// Like copyCurrentPixelBuffer, but scaled (aspect-fill, center-crop) to the
// given size — used to match the app's real camera resolution so dimensions
// never mismatch. Caller must CVPixelBufferRelease() it.
- (nullable CVPixelBufferRef)copyCurrentPixelBufferScaledToWidth:(size_t)width
                                                          height:(size_t)height CF_RETURNS_RETAINED;

// Render the current frame for still-photo interception.
// copyCurrentCGImage returns a +1 CGImage the caller owns (CGImageRelease).
// currentJPEGDataWithQuality returns encoded JPEG bytes. Both nil/NULL if no
// frame is ready yet.
- (nullable CGImageRef)copyCurrentCGImage CF_RETURNS_RETAINED;
- (nullable NSData *)currentJPEGDataWithQuality:(CGFloat)quality;

@end

NS_ASSUME_NONNULL_END
