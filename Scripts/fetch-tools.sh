#!/usr/bin/env bash
# Downloads the CLI tools Snag bundles and makes them self-contained.
# Run once before building a distributable app:  ./Scripts/fetch-tools.sh
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="Tools/bin"
mkdir -p "$BIN"

echo "→ yt-dlp (official standalone macOS build)"
curl -fL --progress-bar -o "$BIN/yt-dlp" \
  https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos
chmod +x "$BIN/yt-dlp"

echo "→ adb (official Google platform-tools)"
tmp="$(mktemp -d)"
curl -fL --progress-bar -o "$tmp/pt.zip" \
  https://dl.google.com/android/repository/platform-tools-latest-darwin.zip
unzip -q "$tmp/pt.zip" -d "$tmp"
cp "$tmp/platform-tools/adb" "$BIN/adb"; chmod +x "$BIN/adb"
rm -rf "$tmp"

echo "→ ffmpeg / ffprobe (static universal builds)"
# Static builds (no external dylibs) fetched per-arch and lipo-merged into a
# single universal binary, so the app runs on both Apple Silicon and Intel and
# a fresh clone matches what the release ships. Source: ffmpeg.martin-riedl.de.
rm -f "$BIN"/*.dylib   # remove any dylibs left by an older relocation approach
for tool in ffmpeg ffprobe; do
  tmp="$(mktemp -d)"
  for arch in arm64 amd64; do
    curl -fL --progress-bar -o "$tmp/$arch.zip" \
      "https://ffmpeg.martin-riedl.de/redirect/latest/macos/$arch/release/$tool.zip"
    unzip -q "$tmp/$arch.zip" -d "$tmp/$arch"
  done
  lipo -create "$tmp/arm64/$tool" "$tmp/amd64/$tool" -output "$BIN/$tool"
  chmod +x "$BIN/$tool"
  rm -rf "$tmp"
  echo "  $tool: $(lipo -archs "$BIN/$tool")"
done

# Re-sign the merged/downloaded binaries ad-hoc so Apple Silicon will load them.
echo "→ re-signing (ad-hoc)"
codesign --force --sign - "$BIN/ffmpeg" "$BIN/ffprobe" "$BIN/yt-dlp" "$BIN/adb" >/dev/null 2>&1 || true

echo "✓ Tools ready in $BIN"
ls -lh "$BIN"
