# PhotoSlim safety review — September 18, 2026

See the [September 21 follow-up](SAFETY_REVIEW_2026-09-21.md) for additional findings, fixes, current checks, and the decision to hold the merge. The notes below describe the earlier audit.

Existing uncommitted feature work was preserved and hardened. No real photo library was modified, no App Store reply was sent, and no build was uploaded.

## Findings and changes

| Risk found | Change |
| --- | --- |
| Limited Photos access led to a dead end | Photos/Videos accept limited access and refresh authorization after returning from Settings. Slim All retains a Full Access requirement for recovery. |
| Undocumented `fileSize` KVC could crash or fail App Review | Use public PhotoKit editing-input URLs and local file sizes, with cancellable streaming fallback. Cache by asset ID and modification date; never cache failed/unknown reads. No scan-triggered cloud downloads. |
| RAW, animation, Live Photos, edits, depth/HDR, shared/synced assets could lose information | One conservative allowlist at scan and compression time; multi-resource/edited/special media is excluded. Encoder rejects multi-frame, auxiliary depth/HDR, high-bit-depth and alpha inputs. Large images above 50 MP or 16,384 pixels on either side are refused to bound memory. |
| Chosen quality silently lowered until a file shrank | Encode at the selected quality. Leave items that do not shrink untouched. |
| Slim All recreated incompressible files merely to reorder them | Remove that path. It added disk use and replacement risk without storage savings. Ordering UI now acknowledges skipped items. |
| Source changed or disappeared after selection | Re-fetch and compare source version/eligibility before encoding and saving. |
| Saved copy removed or edited before cleanup | Persist source and copy modification dates. Before flush, require distinct, accessible, unchanged originals and copies with readable local media. Stop on uncertainty. Undo requires a surviving original and unchanged copy. |
| Low-disk checkpoint errors silently ignored | Throw on plan/log errors; synchronize records before publishing transitions. Stop processing, retain media, and expose a keep-everything recovery exit. |
| Corrupt checkpoint, duplicate IDs, or missing copy IDs could drive deletion | Fail closed. Unsupported/torn/corrupt logs cannot resume automatically or be overwritten by a new plan. |
| Timeout did not cancel a live Photos deletion | Await PhotoKit's actual completion. Permission loss or missing IDs never count as a successful deletion. Do not retry an unresolved live transaction. |
| Concurrent tabs/reviews/bulk runs | One shared operation owner; unfinished Slim All records block per-tab compression. Recovery actions and double taps are guarded. |
| Temporary files leaked when review was swiped away or app killed | Clean on sheet dismissal and clean only the app's dedicated scratch directory on next launch. |
| Work continued after cancellation | Check cancellation at safe boundaries, cancel video exports and streamed scans, add Cancel feedback, and cancel per-tab work on backgrounding. An already submitted Photos transaction must finish. |
| Large batches used unbounded scratch storage | Batch by both item count (100 maximum) and estimated bytes (256 MiB target); one larger item uses its own batch. Check headroom before each compression. |
| Whole-library loop repeatedly searched/copied the full queue | Iterate pending indices once and avoid publishing a shared full queue after every item. Keep periodic snapshots/checkpoints. |
| Encoded output trusted without structural checks | Check photo decode/dimensions/orientation; check video playability, duration and audio-track count. |
| Privacy/marketing/reviewer instructions contradicted the app | Add in-app privacy/support, required-reason manifest, corrected iCloud/deletion/lossy wording, updated support/privacy pages and accurate review notes. Remove the external donation link. |
| Instructions said Delete All in Recently Deleted | Tell users to inspect saved copies and permanently delete only verified originals. Explain cross-device iCloud deletion. |

## Verification

Final result: Release device build succeeded; all 3 UI tests passed on an iPhone 17 simulator running iOS 26.3; production recovery and encoder checks passed. These simulator results do not replace Apple’s requested physical-device evidence.

- Production recovery-log checks compile `PhotoSlim/SlimRun.swift`, rather than a duplicated implementation. Cover unresolved-plan overwrite, replay, distinct copy IDs, reset identity, failed writes, unreadable/torn logs, malformed copied states, and duplicate IDs.
- Production encoder checks compile `PhotoSlim/PhotoEncoder.swift` and `Models.swift`. Cover real JPEG-to-HEIC reduction, dimensions, EXIF date/lens/GPS, orientations 3/6/8, animation rejection and corrupt input rejection.
- Debug simulator build, Release device build (unsigned), UI-test compilation, project/manifest plist validation, and whitespace checks are run locally.
- Simulator UI checks cover the actual Full Access prompt, photo compression/Keep Both, declining the system deletion prompt and returning to the same original, and privacy/tab navigation. Early runs were blocked by simulator startup and add-only access from `simctl privacy`; tests now reset Photos permission and use the real prompt. A toolbar accessibility issue found by the tests was fixed.
- No real-device compression, accepted destructive PhotoKit transaction, iCloud synchronization, low-space device run or force-quit recovery has been tested in this audit.

Commands:

```sh
swiftc -D SAFETY_CHECKS PhotoSlim/SlimRun.swift slim_run_check.swift -o /tmp/photoslim-recovery-check
/tmp/photoslim-recovery-check
swiftc PhotoSlim/Models.swift PhotoSlim/PhotoEncoder.swift metadata_check.swift -o /tmp/photoslim-metadata-check
/tmp/photoslim-metadata-check
xcodebuild -scheme PhotoSlim -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

For UI tests, use an isolated simulator containing disposable local JPEGs above 5 MB, then run the shared PhotoSlim scheme's test action with normal simulator signing (or `CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES`). Tests reset Photos authorization and accept the real Full Access prompt. `scripts/seed_simulator.swift` accepts a third argument specifying the simulator UDID. Photo review/deletion-decline tests need a qualifying fixture; testPrivacyAndTabs needs no media. Never seed or automate deletion against a real personal library.

## Remaining release gates and limitations

1. Follow [the Guideline 2.1 evidence checklist](../AppStore/REVIEW_RESPONSE.md). Apple specifically requested a physical-device recording and actual device/OS test inventory. The prior July response is not evidence for the corrected build.
2. Exercise limited/full/denied/revoked permissions, empty library, HEIC/JPEG rotations, 48 MP images, edited/RAW/Live/HDR/animated sources, ordinary/large videos with audio, iCloud-only items, disk pressure, keep-both, delete decline/accept, backgrounding, force-quit and rollback on disposable media. Verify originals and copies in Photos, including favorites, location and writable albums. Repeat on physical iPad.
3. PhotoKit has no conditional compare-and-delete transaction. Checks reduce stale-state risk but cannot provide an absolute guarantee against simultaneous changes from other devices during a system confirmation. Keep Both is the safest choice when another device is editing the library.
4. A crash after Photos saves a copy but before its ID reaches the log can leave an extra copy. The original remains. The app never guesses which untracked asset to delete. A corrupt log requires manual review/keep-everything recovery.
5. PhotoKit completion can stall. A timeout cannot undo the operation; the app now waits rather than running a second destructive request. Real-device regression testing is required.
6. Album membership can change externally during a long run. Regular writable memberships are copied; Photos associations and exact Recently Added order are not guaranteed. Do not promise full library fidelity.
7. A cold scan may still stream media where PhotoKit cannot expose a matching local file URL. Benchmark large libraries on-device. Cloud-only items and unsupported formats intentionally remain out of scope.
8. Re-capture store screenshots, publish the corrected privacy/support pages, and verify their public URLs. Existing screenshots were not updated by this audit. Archive/upload with an unused build number; use the same build for review evidence.

Apple references: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), [required-reason API declarations](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons), [PhotoKit editing inputs](https://developer.apple.com/documentation/photos/phcontenteditinginput).
