# Guideline 2.1 response — complete evidence before submitting

The user confirmed this is Apple’s latest message. Apple requested information, rather than citing a specific observed defect. The previous response describes a comparison slider and selection-size behavior that are absent from the current app. Use the corrected information below with a recording of the exact submitted build. Do not claim simulator checks are physical-device tests.

## Reply / App Review Notes draft

Thank you. PhotoSlim helps iPhone and iPad users identify large supported photos and videos and create smaller, lossy copies locally. Users can review a single copy and keep both versions or explicitly replace the original. Batch replacement requires an upfront choice and iOS deletion confirmation.

1. Physical-device recording: [ATTACH RECORDING OF THE SUBMITTED BUILD, AND INSERT FILENAME OR ACCESSIBLE LINK]. The recording begins at app launch and shows the Photos permission request, listing/filtering, preview, quality selection, compression, Keep Both, and a separate deletion-confirmation example using disposable test photos. Include video compression and Slim All if these features are in the submitted build.

2. Physical devices tested: [INSERT ACTUAL MODEL, OS VERSION, BUILD NUMBER AND TEST DATE FOR EACH DEVICE]. An earlier submission reported iPhone 16 Pro / iOS 26.5; re-test the corrected build before listing that as current evidence. iPad is supported and needs physical-device verification too. Use Apple's latest publicly released OS for the recording as requested.

3. Purpose and audience: PhotoSlim is a storage utility for people managing their own iPhone/iPad photo libraries. It shows supported local media by size and offers smaller copies at a selected quality. Compression may lose detail. Users decide whether to keep originals; space may remain occupied while originals are in Recently Deleted.

4. Setup and features: No account, credentials, subscription, or purchase is required. Grant Selected Photos or Full Access for the Photos and Videos tabs. Use disposable, locally downloaded, unedited JPEG/HEIC photos or standard videos. RAW, Live Photos, edited, animated, depth/HDR and other unsupported media are excluded or safely refused. Photos initially show items over 5 MB (adjustable to 500 KB); Videos initially show items over 50 MB (adjustable to 5 MB). Lower the filter if needed. Tap an item to preview it, tap Compress, choose quality, then open Original and Compressed separately to compare. Keep Both saves a copy; Delete Original saves the copy and requests deletion in the same Photos change transaction. Select mode uses batch replacement; it does not open individual review sheets. Slim All requires Full Access for recovery checks, processes supported local media, and pauses/resumes using local recovery records. It skips items that cannot be safely compressed. iOS asks for confirmation before removing originals. Only use disposable media to demonstrate deletion.

5. Services and tools: Native Apple frameworks only: SwiftUI/UIKit, PhotoKit, ImageIO, UniformTypeIdentifiers, and AVFoundation/AVKit. No developer backend, authentication service, analytics, advertising, payment processor, or AI service. Compression takes place on-device. Apple Photos may retrieve previews/originals from the user's iCloud library; saved copies and deletions follow the user's iCloud Photos settings. There is no developer or third-party media upload. Support uses a user-initiated email link. No external donation/payment link remains in this build.

6. Regions: No region-specific features, content, pricing, or restrictions are implemented. Functionality is consistent across regions, subject to system Photos permissions and library availability.

7. Regulated services/material: Not applicable. PhotoSlim is a personal media utility, not a regulated service or a provider of licensed third-party media. It processes media selected from the user's own Photos library. There is no public posting, messaging, social feed, or content-sharing service.

Privacy information is accessible inside the app through Privacy & Support. Photo access is requested to read selected media, show sizes, save smaller copies, and delete originals only at the user's direction.

## Physical recording checklist

- Record the exact uploaded build on a physical device running the latest public OS. Start with launching PhotoSlim.
- Use disposable local test media. If necessary reset only PhotoSlim's photo permission so the recording includes the system permission prompt.
- Show Selected Photos access working, then Full Access if demonstrating Slim All. Show the filter and empty-state explanation.
- Preview a photo, select quality, compress it, inspect both previews, and choose Keep Both. Show the saved copy in Photos.
- With another disposable image, show replacement and the iOS delete prompt. Demonstrate declining once, then accepting if desired. Show that the original is recoverable in Recently Deleted. Do not empty unrelated deleted photos.
- Show video playback/compression and a small Slim All run, including pause/resume, if shipping those features.
- No login, purchase, account deletion, reporting/blocking, or tracking flows exist to demonstrate.
- Attach the actual video in App Store Connect and put the seven completed answers in App Review Notes. Remove all placeholders.
- Recapture store screenshots from the final UI. Existing screenshot files/claims need review; the app does not have a draggable before/after comparison or a quality slider.
