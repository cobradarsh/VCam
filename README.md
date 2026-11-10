# OpenVCam

An original, from-scratch iOS **virtual camera** tweak for jailbroken devices.
It intercepts the AVFoundation camera pipeline and feeds a video file you
choose into apps in place of the live camera feed.

This is your own code — there is no licensing or payment layer, and none is
needed. It's for personal use on your own device.

> Legitimate uses: testing camera features in apps you develop, accessibility,
> content creation, privacy. Don't use it to defeat identity/liveness checks or
> otherwise misrepresent yourself to a service — that can be illegal and is not
> what this is for.

---

## How it works

1. A MobileSubstrate filter (`OpenVCam.plist`) loads the tweak only into
   processes that use `AVCaptureSession` (i.e. apps that open the camera).
2. `Tweak.x` hooks `-[AVCaptureVideoDataOutput setSampleBufferDelegate:queue:]`
   and slips a **proxy delegate** between AVFoundation and the app. Every frame
   passes through the proxy.
3. `VCamManager` decodes your chosen clip (`AVAssetReader`) into a looping
   stream of `CVPixelBuffer`s.
4. When enabled, the proxy builds a new `CMSampleBuffer` carrying your frame but
   reusing the real frame's timing, and hands that to the app instead.
5. `VCamPreview` covers the on-screen **live preview**: it lays an
   `AVSampleBufferDisplayLayer` over each `AVCaptureVideoPreviewLayer` and feeds
   it the same `VCamManager` frames, so what you see matches what the app
   captures. When the tweak is off, the overlay hides and the real preview
   shows through.
6. For **still photos**, hooks on `AVCapturePhoto` answer the app's image
   accessors (`fileDataRepresentation`, `CGImageRepresentation`, `pixelBuffer`,
   `previewCGImageRepresentation`, `previewPixelBuffer`) with the current source
   frame — rendered to JPEG/CGImage via `VCamManager`. So a captured photo is
   your frame too, not the real camera.
7. For **audio** (optional, off by default), `VCamAudio` decodes the clip's
   audio track and a hook on `AVCaptureAudioDataOutput` swaps the microphone's
   sample buffers for it, matching the app's PCM format and timing.

Video frames are also **auto-scaled** to the app's real camera resolution
(aspect-fill) so dimensions never mismatch.

Together these cover what apps *capture* (video + audio data output), *show*
(preview layer), and *photograph* (AVCapturePhoto).

---

## Prerequisites

- A jailbroken iOS device (rootful or rootless).
- **Theos** installed on macOS or Linux/WSL: https://theos.dev
  (Windows itself can't build this — use WSL, a Linux box, or a Mac. The files
  here are ready to copy over.)
- `THEOS` env var pointing at your Theos install.

## Build without a Mac (recommended on Windows)

You can't build an iOS tweak on Windows directly — there's no iOS SDK or
cross-compiler. Let GitHub build it for you:

1. Create a new GitHub repo and push these files to it (this folder = repo root,
   so `Makefile` sits at the top level).
2. The included workflow (`.github/workflows/build.yml`) runs automatically on a
   macOS runner and builds both a **rootful** and a **rootless** `.deb`.

> **Why macOS?** On A12+ devices, Settings, Camera and SpringBoard are arm64e
> processes, and on iOS 14+ they only load arm64e code built with the *new*
> arm64e ABI. Only Xcode's toolchain produces that; Linux/WSL toolchains emit the
> old ABI, which dyld rejects (the symptom is "The bundle “OpenVCamPrefs”
> couldn't be loaded"). The workflow fails the build if an old-ABI slice slips
> through.
3. Open the run under the repo's **Actions** tab, and download the `.deb` from
   the **Artifacts** section (`OpenVCam-rootless` is the one for modern arm64e
   devices like Dopamine / palera1n-rootless).

That artifact is a real, installable `.deb`. Then jump to **Install** below.

## Build locally (macOS / Linux / WSL)

```bash
cd OpenVCam
# For a rootless jailbreak (Dopamine, palera1n-rootless), first uncomment
# the THEOS_PACKAGE_SCHEME line in the Makefile.
make package
```

The `.deb` lands in `./packages/`.

## Install

```bash
# Option A: install straight to a device over SSH
make install THEOS_DEVICE_IP=<device-ip>

# Option B: copy the .deb to the device and install it with your package
# manager (Sileo/Zebra), or: dpkg -i com.example.openvcam_*.deb
```

Then respring (or reopen the target app).

---

## Usage

1. Open **Settings → OpenVCam** and turn **Enabled** on.

2. Tap **Choose from Photos…** or **Choose from Files…** and pick a video.
   OpenVCam copies it into its own folder,
   `<jbroot>/Library/Application Support/OpenVCam/`, which camera apps can read
   from inside their sandbox, and points **Path** at the copy. Only the newest
   import is kept. (You can still type a **Path** by hand instead.)

   Changes apply live — the bundle posts a Darwin notification the tweak listens
   for; if an app was already open, reopen its camera screen. A clip at the
   resolution the target app uses (commonly 1280x720 or 1920x1080) gives the
   cleanest result.

3. If the image looks sideways or mirrored, set **Rotation** (0/90/180/270) and
   **Mirror** on the same screen until it looks right. This applies to preview,
   video, and photos together.

Two more toggles are on that screen: **Auto-scale to camera resolution** (on by
default — resizes your clip to match the app) and **Replace microphone audio**
(off by default — swaps the mic for the clip's audio in apps that capture audio
frames).

Prefer the command line? The settings live in the `com.example.openvcam`
preferences domain:
```bash
defaults write com.example.openvcam Enabled -bool true
# (rootless path shown; on rootful drop the /var/jb prefix)
defaults write com.example.openvcam SourcePath -string "/var/jb/Library/Application Support/OpenVCam/clip.mp4"
notify_post com.example.openvcam/settingschanged
```

Turn **Enabled** off to pass the real camera through untouched.

---

## Limitations / planned next steps

Covered so far: data-output capture, live preview, still-photo capture
(`AVCapturePhoto`), manual rotation/mirror, auto-scaling to the app's
resolution, importing a video from Photos or Files, and microphone-audio
replacement.
Remaining gaps / follow-ups:

- **Auto orientation.** Rotation/mirror are manual (Settings → OpenVCam).
  Reading the clip's own `preferredTransform`, or each app's capture-connection
  `videoOrientation` / `isVideoMirrored`, to preset the right default is a
  possible refinement.
- **Legacy still capture.** Very old apps using `AVCaptureStillImageOutput`, or
  the iOS 10 `didFinishProcessingPhotoSampleBuffer:` path, aren't covered yet —
  only the modern `AVCapturePhoto` API is.
- **Audio scope.** Mic replacement covers apps that read audio frames via
  `AVCaptureAudioDataOutput` using interleaved LPCM. Apps that record straight
  to a movie file (`AVCaptureMovieFileOutput`), or use non-interleaved float,
  fall back to the real mic. (It's experimental — off by default.)
- **Scaling mode.** Auto-scale is aspect-fill with a center crop (fills the
  frame, may crop edges); a letterbox/fit option could be added.

Say the word and I'll build any of these on top of what's here.

---

## File map

| File              | Role                                                      |
|-------------------|-----------------------------------------------------------|
| `control`         | Package metadata (name, version, deps).                   |
| `Makefile`        | Theos build config (archs, frameworks, rootless toggle).  |
| `OpenVCam.plist`  | Injection filter — load only into camera-using apps.      |
| `VCamManager.h/.m`| Decodes the clip; rotation/mirror/scaling; renders stills. |
| `VCamPreview.h/.m`| Overlays the live preview with the same source frames.    |
| `VCamAudio.h/.m`  | Decodes the clip's audio to PCM for mic replacement.      |
| `Tweak.x`         | Hooks for captured video, preview, and still photos.      |
| `prefs/`          | Settings: toggle, Photos/Files import, path, orientation. |
| `layout/DEBIAN/`  | postinst/postrm: create / clean up the import folder.     |

Rename `com.example.openvcam` and the `Your Name` fields in `control` to your
own before building.
