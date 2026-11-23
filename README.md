# Photo Cleanup

An iPhone app that finds screenshots, WhatsApp downloads and near-duplicate photos, queues them for review, and learns from what you keep and delete. Everything runs on the phone. There is no server, no account and no paid API.

## How it works

- **Finding candidates.** Screenshots come from the Photos library's own screenshot flag. WhatsApp downloads are matched by their file name pattern (`IMG-…-WA0001`). Near-duplicates are found by comparing Apple Vision feature prints of photos taken within ten minutes of each other.
- **More categories.** Besides screenshots, WhatsApp downloads and duplicates, the scanner flags photos of medicine packs, selfies, documents and phone photos of a computer screen. The Review tab has a filter by category and a tick-all or untick-all action for what is shown.
- **Teach tab.** Pick photos you always want deleted or always want kept. The learner matches new photos against them.
- **Protecting what matters.** Favorites and photos you filed into your own albums are never touched. Photos with people are skipped unless they are screenshots, and WhatsApp photos with people or that look like documents score lower so they never start ticked.
- **Learning.** Each Keep or Delete you confirm is stored as a labelled example. New photos are compared with those examples using a nearest-neighbour vote, and the approval rate for each category adjusts the score. Long-press a photo and choose "Never delete photos like this" to protect a whole group.
- **You stay in control.** iOS does not let an app delete photos silently, so the app queues candidates and you approve one batch through the system prompt. Deleted photos stay in Recently Deleted for 30 days.
- **Background scans.** A background processing task asks iOS to scan a few times a day and sends a notification when there is something to review. iOS decides the exact times.

## Build

Requires Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
open PhotoCleanup.xcodeproj
```

In Xcode, choose your own signing team and bundle identifier for the `PhotoCleanup` target. Background scans, the delete prompt and the notification need a real iPhone with Developer Mode on.

## Layout

- `Sources/Scanner.swift` finds and scores candidates.
- `Sources/Learner.swift` is the on-device nearest-neighbour learner.
- `Sources/Store.swift` holds state, runs scans and performs deletions.
- `Sources/RootView.swift` is the review grid and history screens.
- `icon/` holds the icon source.
