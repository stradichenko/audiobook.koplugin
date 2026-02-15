#!/usr/bin/env bash
# Package espeak-ng + plugin for Kobo deployment
# Everything lives inside audiobook.koplugin/ — just copy to your plugins dir
# Usage: bash package-for-kobo.sh
# Output: kobo-tts-bundle/audiobook.koplugin/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$SCRIPT_DIR/kobo-tts-bundle"
PLUGIN_DEST="$BUNDLE_DIR/audiobook.koplugin"
ESPEAK_DEST="$PLUGIN_DEST/espeak-ng"

echo "=== Building espeak-ng for armv7l via Nix cross-compilation ==="
ESPEAK_OUT=$(nix-build "$SCRIPT_DIR/cross-build-espeak.nix" --no-out-link 2>/dev/null)
echo "Nix store path: $ESPEAK_OUT"

echo "=== Packaging bundle ==="
chmod -R u+w "$BUNDLE_DIR" 2>/dev/null || true
rm -rf "$BUNDLE_DIR"
mkdir -p "$ESPEAK_DEST/bin" "$ESPEAK_DEST/lib" "$ESPEAK_DEST/share/espeak-ng-data/lang/gmw" "$ESPEAK_DEST/share/espeak-ng-data/voices"

# Plugin Lua files first
for f in main.lua textparser.lua ttsengine.lua highlightmanager.lua synccontroller.lua playbackbar.lua _meta.lua; do
    if [ -f "$SCRIPT_DIR/$f" ]; then
        cp "$SCRIPT_DIR/$f" "$PLUGIN_DEST/"
    fi
done

# espeak-ng binary + library (inside plugin dir)
cp "$ESPEAK_OUT/bin/espeak-ng" "$ESPEAK_DEST/bin/"
cp "$ESPEAK_OUT/lib/libespeak-ng.so.1.52.0.1" "$ESPEAK_DEST/lib/"
(cd "$ESPEAK_DEST/lib" && ln -sf libespeak-ng.so.1.52.0.1 libespeak-ng.so.1 && ln -sf libespeak-ng.so.1 libespeak-ng.so)

# Bundle cross-compiled glibc (Kobo's system glibc 2.11 is too old)
# The bundled ld-linux-armhf.so.3 will be used as the dynamic linker
GLIBC_STORE=$(nix-shell -p binutils --run "readelf -l $ESPEAK_OUT/bin/espeak-ng" 2>/dev/null \
    | grep -oP '/nix/store/[^/]+' | head -1)
echo "Bundling glibc from: $GLIBC_STORE"
for lib in ld-linux-armhf.so.3 libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0; do
    if [ -f "$GLIBC_STORE/lib/$lib" ]; then
        cp "$GLIBC_STORE/lib/$lib" "$ESPEAK_DEST/lib/"
        echo "  + $lib"
    fi
done
chmod +x "$ESPEAK_DEST/lib/ld-linux-armhf.so.3"

# Bundle GCC runtime libs (libstdc++, libgcc_s) needed by libespeak-ng
GCC_STORE=$(find /nix/store -maxdepth 1 -name "*armv7l*gcc*-lib" -type d 2>/dev/null | head -1)
if [ -n "$GCC_STORE" ]; then
    GCC_LIB="$GCC_STORE/armv7l-unknown-linux-gnueabihf/lib"
    echo "Bundling GCC runtime from: $GCC_LIB"
    for lib in libstdc++.so.6 libgcc_s.so.1; do
        src="$GCC_LIB/$lib"
        # Dereference symlinks so we copy the actual file
        if [ -L "$src" ]; then
            src=$(readlink -f "$src")
        fi
        if [ -f "$src" ]; then
            cp "$src" "$ESPEAK_DEST/lib/$lib"
            echo "  + $lib"
        fi
    done
else
    echo "WARNING: Could not find armv7l GCC lib store path"
fi

# Core phoneme data (required for all languages)
for f in phondata phonindex phontab intonations; do
    cp "$ESPEAK_OUT/share/espeak-ng-data/$f" "$ESPEAK_DEST/share/espeak-ng-data/"
done

# English dictionary
cp "$ESPEAK_OUT/share/espeak-ng-data/en_dict" "$ESPEAK_DEST/share/espeak-ng-data/"

# English voice definitions
cp -r "$ESPEAK_OUT/share/espeak-ng-data/lang/gmw/"en* "$ESPEAK_DEST/share/espeak-ng-data/lang/gmw/" 2>/dev/null || true

# Voice variants (!v directory)
if [ -d "$ESPEAK_OUT/share/espeak-ng-data/voices/!v" ]; then
    cp -r "$ESPEAK_OUT/share/espeak-ng-data/voices/!v" "$ESPEAK_DEST/share/espeak-ng-data/voices/"
fi

chmod +x "$ESPEAK_DEST/bin/espeak-ng"

echo ""
echo "=== Bundle ready ==="
du -sh "$PLUGIN_DEST"
echo ""
echo "=== Deploy to Kobo ==="
echo "One command — copy the whole plugin folder:"
echo ""
echo "  scp -P 2222 -r $PLUGIN_DEST root@kobo:/mnt/onboard/.adds/koreader/plugins/"
echo ""
echo "Then restart KOReader."
