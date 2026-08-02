# 📥 Snag

A native macOS app that snags audio and video from the web and turns it into organized, offline media on your Mac and phone — download, tag, and transfer, all from one clean window. Great for **music**, but it also handles **podcasts/talks** and **video**.

Built with SwiftUI. Wraps `yt-dlp` + `ffmpeg` + `adb` so you never touch the terminal. Works with YouTube, SoundCloud, Vimeo, and [many more](https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md).

## Download

Get the latest **signed & notarized** build from **[Releases](https://github.com/Costa0910/Snag/releases/latest)** — download the `.dmg`, drag **Snag** into **Applications**, and open it with a normal double-click. **Universal** — runs natively on **Apple Silicon and Intel**, macOS 14+.

## Features

- **Music, podcasts, or video** — pick a kind per download: **Music** (album folders, tags, track numbers, playlists), **Audio / Podcast** (keeps the channel as the artist, no music-specific renaming), or **Video** (MP4 up to 1080p, to watch offline in your default player).
- **Guided onboarding** — first-run flow that welcomes you, checks the engine tools, and sets your library location.
- **Sidebar app** — Download, Library, Devices, and Settings, not just one window.
- **Download queue** — paste (or **drag-and-drop**) a YouTube video/playlist URL and it **auto-previews** the track list (with auto-skip of non-music "vlogs"). Queue multiple downloads with live per-job progress, retry failed ones, and get a **macOS notification** when each finishes.
- **Automatic organization** — one album folder per playlist, clean `album` / `artist` / `track` tags, embedded cover art, and `.m3u8` playlists (including an *All Songs* list for shuffle-everything).
- **Library browser** — a grid of your albums with extracted cover artwork, search, and total size. Tap an album to open a **detail view** with the track list and **in-app playback** (preview before you send). Hover a tile to play or manage it.
- **Wireless transfer** — flip on the built-in **Wi‑Fi server** and any phone on your network can grab tracks from a **PIN‑protected web page**: album art, in‑browser streaming (play/shuffle/repeat), search, and per‑track download — no cable required. A QR code gets your phone there instantly.
- **Send to phone**
  - **Android** — fully automatic over USB (`adb push` + media rescan so players see it instantly).
  - **iPhone** — either use the wireless page above, or the **Snag iPhone app** (see below); the legacy path also imports into the Music app for a final Finder **Sync**.
  - **Selective** — choose exactly which albums to send, or send everything.
- **Customizable** — default format/bitrate, naming & track-number padding, playlist generation, genre tag, library location, auto-transfer, accent color, and a one-click **Update yt-dlp**.

## Snag for iPhone (companion app)

A native **offline music player** for iPhone (in `ios/`) that plays your Snag library like Apple Music — but everything stays on the device. It **finds your Mac on the network automatically (Bonjour)** and syncs your tracks and playlists over Wi‑Fi (PIN‑protected), so you never plug in. Highlights: a proper library (albums / artists / genres / songs), playlists, search, a smart on‑device "For You" mix and recommendations, a real 10‑band **equalizer** and **crossfade**, queue/Up‑Next, AirPlay, a Home‑Screen widget, and Siri shortcuts. It can also import the music already in your iPhone's Music app. *(Not yet on the App Store — build it from `ios/` with Xcode.)*

## Requirements

- macOS 14+ (universal — Apple Silicon or Intel)
- The bundled build is self-contained. To build it yourself you need **Xcode 15+** and **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** (`brew install xcodegen`).

## Build from source

```bash
git clone https://github.com/Costa0910/Snag.git
cd Snag
./Scripts/fetch-tools.sh     # downloads yt-dlp, adb; relocates ffmpeg (self-contained)
xcodegen generate            # creates Snag.xcodeproj
open Snag.xcodeproj           # then press ▶ in Xcode
```

Prefer no bundling? Skip `fetch-tools.sh` and just `brew install yt-dlp ffmpeg android-platform-tools` — the app falls back to those automatically.

## Notes & limitations

- **Audio quality** is capped by what YouTube serves (typically ~129 kbps AAC). Asking for a higher number can't create quality that isn't in the source, so M4A "original" is recommended.
- **iPhone** — Apple blocks third-party apps from pushing music directly, so the smooth paths are the **wireless web page** (any browser) or the **Snag iPhone app** (Wi‑Fi sync). The old assisted Finder-sync step remains as a fallback.
- Not sandboxed / not App Store — it runs bundled binaries and talks to phones over USB, which the App Store sandbox forbids. Distribute via GitHub Releases.
- For your own use, downloads are for personal, offline listening. Respect copyright and the terms of the services you download from.

## License

MIT
