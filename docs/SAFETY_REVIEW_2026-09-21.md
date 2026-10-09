# PhotoSlim safety review — September 21, 2026

**Decision: do not merge to main yet.** Code safeguards and automated checks have improved, but the physical-device and failure-injection gates below remain open. This is not a guarantee against every crash or data-loss scenario. Compression is lossy; preserving an encoded copy does not prove it preserves every visual detail or Photos association.

Reviewed the Swift app, project/privacy configuration, recovery store, existing checks, UI tests, and the branch's existing uncommitted safety work. Preserved that work. The branch remains `redesign-unified-compress-flow`; neither local nor remote `main` was changed. No personal photo library, App Store submission, or public website was modified. Simulator deletion tests use generated disposable media, and the test suite refuses to run on physical devices.

## Additional findings fixed

| Finding | Change |
| --- | --- |
| A readable saved asset did not establish that Photos stored the encoded file | Slim All records a streaming SHA-256 digest before saving, then reads the actual saved PhotoKit resource with networking disabled and compares its digest before deleting the original. Both asset versions are checked again after verification. Undo also verifies the copy and requires an unchanged, locally readable original. |
| Recovery could accept two originals sharing one copy, a copy pointing to another original, impossible state transitions, or negative/overflowing counters | Validate identities, byte totals, digest format, and the transition graph before persisting or replaying. Reset copy identity, digest, version, and savings together. Index identities once instead of searching the entire plan on each transition. |
| A complete JSON record with a missing newline could be replayed and then joined to another append | Reject journals missing their final delimiter. Orphan journals block a new run. Cleanup errors now surface instead of being silently ignored. |
| Old journals lacked content fingerprints | Version 2 is required. Old or corrupt runs cannot automatically resume deletion; the keep-everything exit leaves remaining media intact. |
| Unknown capacity bypassed disk checks; arithmetic could overflow | Centralize checked headroom calculations. Unknown/invalid capacity stops compression. Reserve 500 MiB and recheck capacity before importing copies, including the complete temporary batch. Bound video export file length and compressed photo input buffering. |
| Pausing could initiate a deletion, and backgrounding released ownership before a submitted PhotoKit operation finished | Pause and low-space stops retain both sides. The writer lock stays held until the running task reaches its boundary. Cancellation during copy verification does not submit a new deletion. Scan/start actions are guarded against overlapping work. |
| HDR video was not reliably identified by PhotoKit subtype flags | Inspect AVFoundation video characteristics before export. Reject HDR, alpha, multiple video/audio tracks, and extra track types rather than silently dropping them. Explicitly exclude spatial photos too. |
| ImageIO accepted a deliberately truncated JPEG | The regression initially reproduced this failure despite ImageIO reporting a complete source. Require the JPEG end-of-image marker and source completion; reject unsupported formats. This is a conservative structural check, not a proof that every possible corrupt media file will be detected. |
| Preview loaded a full original just to create a small display image | Request a bounded image from Photos directly. |
| A crash during the first save could leave an untracked copy without a recovery warning | Warn about a possible extra copy even when no copied transition was recorded. Never guess which asset to delete. |
| Low-space text encouraged emptying Recently Deleted broadly | Refer only to verified originals, preserve unfinished pairs, and expose keep-everything exits on paused/recovery screens. |

## Verification

- Production recovery/storage checks passed, including failed checkpoint writes, conflicting identities, illegal transitions, orphan journals, truncated logs, legacy version refusal, and overflow/unknown-capacity handling.
- Production encoder checks passed: JPEG → HEIC reduction, dimensions, EXIF date/lens, GPS, rotations 3/6/8, animation refusal, corrupt input refusal, and truncated JPEG refusal.
- Production streaming SHA-256 checks passed against a known test vector and a changed byte past multiple 1 MiB chunks.
- Unsigned iOS Release build and Xcode Analyze passed. The only build diagnostic was the expected skipped App Intents metadata extraction for an app without App Intents.
- All **6 simulator UI tests passed with 0 failures** on the final code (iPhone 17, iOS 26.3): Keep Both, declined single-photo deletion, privacy/tabs, simulated low space, declined Slim All deletion followed by process termination/relaunch and undo, and accepted Slim All deletion of disposable originals. Final result bundle: `/tmp/photoslim-ui-sep21-final.xcresult`.
- Project/privacy plist validation, whitespace checks, and a basic common-secret-pattern scan passed. No third-party package dependencies or app-owned media-upload/network clients were found. This is a scoped source review, not a penetration-test certification.

Reproduce the production checks with:

```sh
sh scripts/check_safety.sh
```

UI tests require an isolated simulator with a generated JPEG above 5 MB. `scripts/seed_simulator.swift 3 1 SIMULATOR_UDID` creates suitable local fixtures. The accepted-deletion test consumes eligible originals, so re-seed before repeating the suite. Do not use a simulator containing personal photos.

Build and UI commands used:

```sh
xcodebuild -scheme PhotoSlim -configuration Release \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build analyze
xcodebuild -scheme PhotoSlim -configuration Debug \
  -destination 'platform=iOS Simulator,id=F4BC4031-5CC0-4797-882C-716E9FF976C5' \
  -parallel-testing-enabled NO test
```

## Required before merge/release

1. **Physical iPhone/iPad and memory pressure:** test a disposable library on the oldest supported device/OS class as well as a current device. Measure peak memory, responsiveness, and temperature with 48 MP photos, long/large videos, large album memberships, and a large cold scan. Pixel/input caps and sequential work reduce risk but do not establish that iOS cannot terminate the process.
2. **Actual disk pressure:** the simulator override proves the low-space branch, not full-disk behavior of Photos, AVFoundation, or the filesystem. Exercise real low capacity and write failures while exporting, importing, and synchronizing recovery records. Confirm existing originals remain recoverable.
3. **In-flight interruption:** termination/relaunch after a declined deletion passed. Still inject termination during copy submission, before its returned ID is journaled, during journal synchronization, and while a deletion is awaiting acknowledgement. Verify source/copy contents and the Recently Deleted originals after each outcome.
4. **iCloud and permission changes:** test full/limited/denied/revoked access and optimized-storage eviction, plus concurrent edits/deletions from a second device. Rechecking versions reduces stale-state risk; PhotoKit does not expose an expected-version parameter for asset deletion, so a preflight check cannot guarantee that an external edit never occurs during confirmation. This is an API limitation inferred from the [documented change-request model](https://developer.apple.com/documentation/photos/phphotolibrary/performchanges(_:completionhandler:)).
5. **Video and unusual-media fidelity:** verify ordinary videos with sound, rotation, and frame rates; confirm HDR, cinematic, spatial, RAW, edited, animated, and auxiliary-resource inputs remain untouched. Current video validation checks structure/duration/track counts; it does not compare every decoded frame or audio sample.

Even after these gates pass, do not claim “100% safe,” “lossless,” or guaranteed full Photos-library fidelity. A hash verifies the saved encoded bytes, not whether lossy compression retained every detail. There remains a deliberate preference for extra copies over guessing and deleting an untracked asset. Apple's actual [PhotoKit completion result](https://developer.apple.com/documentation/photos/phphotolibrary/performchanges(_:completionhandler:)) is awaited for a submitted change; cancelling a Swift task is not treated as cancelling that transaction.
