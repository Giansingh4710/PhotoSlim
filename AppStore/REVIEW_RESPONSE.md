# Guideline 2.1 — build 5 review evidence

Submitted October 9, 2026 at 11:05 AM EDT. App Store Connect confirmed **Waiting for Review** for version **1.0 (5)**, submission `2540cb91-a4a2-41c2-80cb-8ce656858af1`. The corrected reply and recording were posted in the review thread and the recording is also attached to version review information. Automatic release after approval remains selected.

Confirmation screenshot: `~/Desktop/PhotoSlim-Review-Evidence/App-Store-Waiting-for-Review.png`.

## App Review notes

PhotoSlim 1.0 (5) — updated Guideline 2.1 information, October 9, 2026.

1. RECORDING
Attached: PhotoSlim-build5-physical-recordings.mp4. It joins two native screen recordings from the same physical iPhone. Part 1 starts in TestFlight showing build 5, launches the app, demonstrates filtering/empty state, photo preview/compression, compressed preview, the iOS deletion prompt (declined), Keep Both, privacy information, unsupported-video refusal, and Slim All setup. Part 2 demonstrates a generated standard H.264/AAC test clip: preview, balanced compression (24.3 MB to 12.1 MB), compressed playback, Keep Both, both copies in the list, and Slim All space checks/cancellation. Photos Full Access was already granted before recording; the initial access prompt is not shown. The deletion permission prompt is shown. No login, purchase, account deletion, or social reporting/blocking flows exist.

2. TEST DEVICES
Physical: iPhone 16 Pro, iOS 27.2 beta (24B5099f), TestFlight 1.0 (5), October 9, 2026. Photo/video compression, previews, Keep Both, declined deletion, filtering, safe refusal and batch preflight/cancellation checked. No whole-library batch was run on this personal device. Additional simulator checks used iPhone 17 Pro / iOS 27.0 and iPad Pro 13-inch (M5) / iPadOS 27.0. No physical iPad was available. Simulator checks are not physical-device tests. Release archive, static analysis, safety/encoder/metadata/SHA checks and three targeted build-5 UI regressions passed.

3. PURPOSE AND AUDIENCE
A storage utility for people managing their own iPhone/iPad photo libraries. It identifies large supported media and creates smaller, lossy copies on-device. Savings vary; users can keep originals and review copies.

4. SETUP AND FEATURES
No account, credentials, subscription or purchase. Grant Selected Photos or Full Access for Photos/Videos; Slim All requires Full Access. Use local, unedited JPEG/HEIC photos or standard SDR videos. RAW, Live Photos, edited, HDR/depth/spatial and other unsupported formats are excluded or refused safely. Lower the size filter if needed (Photos: initially 5 MB, minimum 500 KB; Videos: initially 50 MB, minimum 5 MB). Tap an item, Compress, choose quality, then open Original/Compressed separately. Keep Both saves a copy. Delete Original saves a copy and requests deletion in a Photos transaction. Select mode performs batch replacement. Slim All processes supported local media oldest first, with space checks and pause/resume recovery. iOS confirms deletion. Use disposable media; originals remain in Recently Deleted and deletions sync via iCloud Photos. Do not permanently delete originals before checking saved copies.

5. SERVICES AND TOOLS
Native Apple frameworks: SwiftUI/UIKit, PhotoKit, ImageIO, UniformTypeIdentifiers, AVFoundation/AVKit, CryptoKit. No developer backend, account provider, ads, analytics, payment processor, AI service or third-party media upload. Compression is local. Apple Photos may retrieve iCloud originals for previews; copies/deletions follow iCloud settings. Support is user-initiated email. Privacy & Support is available in-app.

6. REGIONS
No region-specific features or content restrictions are implemented.

7. REGULATED SERVICES / LICENSED MATERIAL
Not applicable: personal media utility, no regulated service or licensed-content distribution. No public posting, messaging or social feed. Users process their own Photos media.

## Evidence provenance

- Original physical recordings: `~/Downloads/ScreenRecording_10-09-2026 10-39-05_1.MP4` and `~/Downloads/ScreenRecording_10-09-2026 10-54-28_1.MP4`.
- Upload artifact: `~/Desktop/PhotoSlim-Review-Evidence/PhotoSlim-build5-physical-recordings.mp4`. The two native recordings were resized/transcoded and concatenated; workflow footage was not removed.
- Photo Library Full Access predated recording. The iOS deletion prompt is included; the initial Photos access prompt is not.
- No physical iPad or additional physical device was available. No whole-library batch was started on the personal phone.
- Store assets were replaced with current iPhone/iPad simulator screenshots.
