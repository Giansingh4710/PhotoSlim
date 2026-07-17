# PhotoSlim — App Store Submission Metadata

Everything below is ready to paste into App Store Connect. Character limits noted; all fields are within limit.

---

## App Name (30 max)
`PhotoSlim: Photo Compressor`
*(27 chars. Alt if taken: `PhotoSlim — Shrink Photos`)*

## Subtitle (30 max)
`Free up storage, keep photos`
*(28 chars)*

## Promotional Text (170 max — editable anytime without review)
`Running out of storage? PhotoSlim finds your biggest photos and shrinks them up to 90% — same shot, a fraction of the size. Compare before and after, then decide.`
*(163 chars)*

## Keywords (100 max, comma-separated, NO spaces after commas)
`compress,photo,shrink,storage,cleaner,space,reduce,size,HEIC,image,optimizer,free up,slim,cleanup`
*(97 chars)*

## Description (4000 max)
```
Your photos are quietly eating your storage. PhotoSlim finds the biggest ones and shrinks them — up to 90% smaller — while keeping them looking great.

No accounts. No uploads. No subscriptions. Everything happens right on your iPhone.

FIND WHAT'S TAKING UP SPACE
PhotoSlim scans your library and sorts every photo by file size, largest first. In seconds you can see exactly which photos are worth compressing — and skip the small stuff with a simple size filter.

SHRINK WITHOUT THE GUESSWORK
Before anything is saved, you get a live before/after view. Drag the slider across the photo to compare the original and the compressed copy side by side. Zoom in to inspect the detail. Adjust the quality until you're happy — the file size updates instantly.

YOU'RE ALWAYS IN CONTROL
Nothing is deleted or replaced behind your back. When you're ready, choose:
• Keep Both — save the compressed copy alongside the original
• Delete Originals — replace them and reclaim the space

Compressed copies keep the original's date, location, and album, so your library stays organized exactly as it was.

BATCH IT
Select a few photos or your entire list and compress them in one pass. Free up gigabytes in a couple of taps.

PRIVATE BY DESIGN
PhotoSlim never sends your photos anywhere. No cloud, no servers, no tracking. Your library stays yours.

WHY PHOTOSLIM
• See your largest photos instantly, sorted by size
• Compress up to 90% with visually clean results
• Live before/after compare with a quality slider
• Keep originals or delete them — your call
• Preserves date, location, and albums
• Batch compress the whole library at once
• 100% on-device. No account, no upload, no subscription

Reclaim your storage without losing your memories. Download PhotoSlim and see how much space you can save today.
```
*(~1,560 chars — well under 4000)*

---

## App Information (General)

**Category (Primary):** Utilities
**Category (Secondary):** Photo & Video

**Age Rating:** 4+ (no objectionable content)

**Bundle ID:** com.giansingh.PhotoSlim
**SKU:** photoslim-001
**Version:** 1.0

---

## App Privacy (Trust & Safety)

PhotoSlim does not collect any data. In App Store Connect → App Privacy, select:

- **Data Not Collected** — "We do not collect data from this app."

Justification: all processing is on-device; no analytics SDK, no network calls except the optional "Buy me a coffee" link (a Safari open, not data collection).

**Privacy Policy URL:** *(required even with no collection — see PRIVACY_POLICY.md; host it and paste the URL)*

---

## App Review Information

**Sign-in required:** No
**Demo account:** Not needed
**Notes for reviewer:**
```
PhotoSlim is a fully on-device photo compressor.

To test:
1. Launch the app and tap "Allow Full Access" when prompted for photo access (required — the app scans the library to find large photos to compress).
2. If the simulator/device library has no photos above the size filter, drag the size slider (bottom bar) left to lower the threshold so photos appear.
3. Select one or more photos and tap "Compress".
4. In the compare view, drag the vertical slider to see before/after, adjust quality, then tap "Keep Both" or "Delete Originals".

Nothing is uploaded. The only network use is an optional "Buy me a coffee" link that opens Safari. No account or login is required.
```

**Contact:** Gian Singh · giansingh4710@gmail.com

---

## Pricing and Availability
- **Price:** Free (Tier 0)
- **Availability:** All countries/regions
- No in-app purchases

---

## Screenshots
- **6.5" iPhone (required):** `screenshots-6.5/` — 5 images, 1290 × 2796 px.
  These same images satisfy the 6.7" slot too; App Store Connect scales them for smaller sizes.
- **13" iPad (required — the app now supports iPad):** `screenshots-ipad-13/` — 3 images, 2064 × 2752 px.
  Upload these to the iPad tab in the Previews and Screenshots section.

> The app is now Universal (iPhone + iPad). `TARGETED_DEVICE_FAMILY = "1,2"`. iPad supports all orientations; iPhone stays portrait.

---

## Pre-submission checklist
- [ ] Archive a Release build (Xcode → Product → Archive) and upload via Organizer / Transporter
- [ ] Confirm signing with your team (UXX67B9ASA) and a distribution provisioning profile
- [ ] Fill App Privacy → Data Not Collected
- [ ] Host PRIVACY_POLICY.md and paste its URL
- [ ] Upload the 5 screenshots to the 6.5" slot
- [ ] Paste name, subtitle, promo text, keywords, description
- [ ] Set category = Utilities, age rating 4+
- [ ] Add the reviewer notes above
- [ ] Add for Review → Submit

## Unresolved
- App name uniqueness — "PhotoSlim" may be taken; have the fallback ready.
- Privacy policy must be hosted somewhere (GitHub Pages / any static host) before submit.
- iPad layout is functional but not tailored to the large canvas (rows/empty space stretch full-width). Fine for approval; a future update could add a wider grid/multi-column layout.
```
