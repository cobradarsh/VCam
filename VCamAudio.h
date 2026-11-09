#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

// VCamAudio is the audio counterpart of VCamManager: it decodes the source
// clip's audio track into looping PCM and hands it out in whatever LPCM format
// the app's capture pipeline is using.
//
// It reads its own settings (Enabled && ReplaceAudio, SourcePath) from the
// shared preferences domain and reloads on the Darwin notification, so it is
// independent of VCamManager.
@interface VCamAudio : NSObject

+ (instancetype)shared;

// Active = tweak Enabled AND "Replace microphone" on.
@property (nonatomic, assign, readonly) BOOL enabled;

- (void)reloadSettings;

// Reconfigure the decoder to produce this exact (interleaved LPCM) format if it
// differs from the current one. Call before fillBuffer:.
- (void)prepareWithASBD:(const AudioStreamBasicDescription *)asbd;

// Copy frameCount frames of looping source audio into dst. Returns NO if audio
// isn't ready, the source has no audio track, or the format is unsupported
// (non-interleaved / non-PCM) — in which case the caller keeps the real audio.
- (BOOL)fillBuffer:(void *)dst frameCount:(UInt32)frameCount;

@end

NS_ASSUME_NONNULL_END
