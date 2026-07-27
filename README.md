# 🎵 Mixtape

A native macOS app that turns a YouTube URL into an organized music library on your phone — download, tag, and transfer, all from one clean window.

Built with SwiftUI. Wraps `yt-dlp` + `ffmpeg` + `adb` so you never touch the terminal.

## What it does

1. **Paste** a YouTube video or playlist URL
2. **Analyze** — see the track list, count, and any non-music "vlog" entries (auto-skippable)
3. **Download** — pick a format (M4A original / MP3 / Opus), with live progress
4. **Organize** — one album folder per playlist, proper `album` / `artist` / `track` tags, embedded cover art, and `.m3u8` playlists (including an *All Songs* list for shuffle-everything)
5. **Send to phone**
   - **Android** — fully automatic over USB (`adb push` + media rescan so players see it instantly)
   - **iPhone** — assisted: imports into the Music app for you, then you do the final **Sync** in Finder (Apple blocks apps from pushing music directly)

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
