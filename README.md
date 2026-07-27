# 🎵 Mixtape

A native macOS app that turns a YouTube URL into an organized music library on your phone — download, tag, and transfer, all from one clean window.

Built with SwiftUI. Wraps `yt-dlp` + `ffmpeg` + `adb` so you never touch the terminal.

## Features

- **Guided onboarding** — first-run flow that welcomes you, checks the engine tools, and sets your library location.
- **Sidebar app** — Download, Library, Devices, and Settings, not just one window.
- **Download queue** — paste a YouTube video/playlist URL, preview the track list (with auto-skip of non-music "vlogs"), and queue multiple downloads with live per-job progress.
- **Automatic organization** — one album folder per playlist, clean `album` / `artist` / `track` tags, embedded cover art, and `.m3u8` playlists (including an *All Songs* list for shuffle-everything).
- **Library browser** — a grid of your albums with extracted cover artwork; reveal or delete in a click.
- **Send to phone**
  - **Android** — fully automatic over USB (`adb push` + media rescan so players see it instantly).
  - **iPhone** — assisted: imports into the Music app for you, then you do the final **Sync** in Finder (Apple blocks apps from pushing music directly).
- **Customizable** — default format/bitrate, naming & track-number padding, playlist generation, genre tag, library location, auto-transfer, and accent color.

## Requirements

- macOS 14+
- The bundled build is self-contained. To build it yourself you need **Xcode 15+** and **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** (`brew install xcodegen`).

## Build from source

```bash
git clone https://github.com/Costa0910/Mixtape.git
cd Mixtape
./Scripts/fetch-tools.sh     # downloads yt-dlp, adb; relocates ffmpeg (self-contained)
xcodegen generate            # creates Mixtape.xcodeproj
open Mixtape.xcodeproj        # then press ▶ in Xcode
```

Prefer no bundling? Skip `fetch-tools.sh` and just `brew install yt-dlp ffmpeg android-platform-tools` — the app falls back to those automatically.

## Notes & limitations

- **Audio quality** is capped by what YouTube serves (typically ~129 kbps AAC). Asking for a higher number can't create quality that isn't in the source, so M4A "original" is recommended.
- **iPhone** transfer is intentionally "assisted" — Apple does not allow third-party apps to push music onto an iPhone or drive a sync. The app gets you to the one-click Finder step.
- Not sandboxed / not App Store — it runs bundled binaries and talks to phones over USB, which the App Store sandbox forbids. Distribute via GitHub Releases.
- For your own use, downloads are for personal, offline listening. Respect copyright and the terms of the services you download from.

## License

MIT
