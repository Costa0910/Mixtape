#!/usr/bin/env bash
# Downloads the CLI tools Mixtape bundles and makes them self-contained.
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

echo "→ ffmpeg / ffprobe (relocated from your Homebrew install)"
if ! command -v dylibbundler >/dev/null; then brew install dylibbundler; fi
# Bundle dylibs alongside the binaries (same folder) so @loader_path/ resolves
# uniformly for both the executables and inter-dylib references.
for tool in ffmpeg ffprobe; do
  src="$(command -v "$tool")"
  cp "$src" "$BIN/$tool"
  dylibbundler -of -b -x "$BIN/$tool" -d "$BIN" -p "@loader_path/" >/dev/null
done

# install_name_tool invalidates signatures; Apple Silicon refuses to load
# modified Mach-O without a valid one. Re-sign everything ad-hoc.
echo "→ re-signing (ad-hoc)"
codesign --force --sign - "$BIN"/*.dylib >/dev/null 2>&1 || true
codesign --force --sign - "$BIN/ffmpeg" "$BIN/ffprobe" "$BIN/yt-dlp" "$BIN/adb" >/dev/null 2>&1 || true

echo "✓ Tools ready in $BIN"
ls -lh "$BIN"
