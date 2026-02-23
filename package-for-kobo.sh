#!/usr/bin/env bash
# Package espeak-ng + Piper TTS + plugin for Kobo deployment
# Everything lives inside audiobook.koplugin/ — just copy to your plugins dir
# Usage: bash package-for-kobo.sh [--with-piper] [--piper-voice VOICE]
# Output: kobo-tts-bundle/audiobook.koplugin/
#
# Options:
#   --with-piper         Also bundle Piper TTS neural engine (~24 MB)
#   --piper-voice VOICE  Download a specific Piper voice (default: en_US-lessac-medium)
#                        Use "low" quality for smaller size (~15 MB), "medium" for better quality (~60 MB)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$SCRIPT_DIR/kobo-tts-bundle"
PLUGIN_DEST="$BUNDLE_DIR/audiobook.koplugin"
ESPEAK_DEST="$PLUGIN_DEST/espeak-ng"
PIPER_DEST="$PLUGIN_DEST/piper"

# Parse arguments
WITH_PIPER=false
PIPER_VOICE="en_US-lessac-medium"
while [[ $# -gt 0 ]]; do
    case $1 in
        --with-piper)
            WITH_PIPER=true
            shift
            ;;
        --piper-voice)
            PIPER_VOICE="$2"
            WITH_PIPER=true
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

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
for lib in ld-linux-armhf.so.3 libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1; do
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

# ── Piper TTS (optional) ──────────────────────────────────────────────
if [ "$WITH_PIPER" = true ]; then
    echo ""
    echo "=== Bundling Piper TTS (neural voice engine) ==="
    mkdir -p "$PIPER_DEST"

    PIPER_VERSION="2023.11.14-2"
    PIPER_TAR="piper_linux_armv7l.tar.gz"
    PIPER_URL="https://github.com/rhasspy/piper/releases/download/${PIPER_VERSION}/${PIPER_TAR}"
    PIPER_CACHE="$SCRIPT_DIR/.cache/piper"
    mkdir -p "$PIPER_CACHE"

    # Download Piper armv7l binary (cached)
    if [ ! -f "$PIPER_CACHE/$PIPER_TAR" ]; then
        echo "Downloading Piper armv7l binary..."
        curl -L -o "$PIPER_CACHE/$PIPER_TAR" "$PIPER_URL"
    else
        echo "Using cached Piper binary: $PIPER_CACHE/$PIPER_TAR"
    fi

    # Extract just the piper binary + libs (not the full tarball tree)
    echo "Extracting Piper binary..."
    tar xzf "$PIPER_CACHE/$PIPER_TAR" -C "$PIPER_CACHE/"
    cp "$PIPER_CACHE/piper/piper" "$PIPER_DEST/"
    chmod +x "$PIPER_DEST/piper"
    # Copy Piper's bundled shared libs (onnxruntime, espeak-ng, piper_phonemize).
    # NOTE: The Piper tarball puts .so files FLAT next to the binary (no lib/ subdir).
    # We gather them into lib/ for a clean layout and easier LD_LIBRARY_PATH.
    mkdir -p "$PIPER_DEST/lib"
    for so in "$PIPER_CACHE/piper/"*.so*; do
        [ -e "$so" ] && cp -P "$so" "$PIPER_DEST/lib/"
    done
    # Also copy the tashkeel model (Arabic diacritization) if present
    [ -f "$PIPER_CACHE/piper/libtashkeel_model.ort" ] && cp "$PIPER_CACHE/piper/libtashkeel_model.ort" "$PIPER_DEST/lib/"
    # Copy helper binaries (piper_phonemize, espeak-ng) needed at runtime
    for helper in piper_phonemize espeak-ng; do
        [ -f "$PIPER_CACHE/piper/$helper" ] && cp "$PIPER_CACHE/piper/$helper" "$PIPER_DEST/" && chmod +x "$PIPER_DEST/$helper"
    done
    echo "Piper libs:"
    ls -la "$PIPER_DEST/lib/"
    # Copy espeak-ng-data directory (phonemizer data used by Piper internally)
    if [ -d "$PIPER_CACHE/piper/espeak-ng-data" ]; then
        cp -r "$PIPER_CACHE/piper/espeak-ng-data" "$PIPER_DEST/"
    fi

    # Download a default voice model
    echo "Downloading Piper voice: $PIPER_VOICE ..."
    VOICE_BASE_URL="https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US"
    # Parse voice name parts: e.g. en_US-lessac-medium → speaker=lessac, quality=medium
    VOICE_SPEAKER=$(echo "$PIPER_VOICE" | sed 's/^en_US-//' | sed 's/-[^-]*$//')
    VOICE_QUALITY=$(echo "$PIPER_VOICE" | sed 's/.*-//')
    VOICE_DIR="$VOICE_BASE_URL/$VOICE_SPEAKER/$VOICE_QUALITY"

    ONNX_FILE="${PIPER_VOICE}.onnx"
    JSON_FILE="${PIPER_VOICE}.onnx.json"

    if [ ! -f "$PIPER_CACHE/$ONNX_FILE" ]; then
        curl -L -o "$PIPER_CACHE/$ONNX_FILE" "$VOICE_DIR/$ONNX_FILE"
    else
        echo "Using cached voice model: $ONNX_FILE"
    fi
    if [ ! -f "$PIPER_CACHE/$JSON_FILE" ]; then
        curl -L -o "$PIPER_CACHE/$JSON_FILE" "$VOICE_DIR/$JSON_FILE"
    else
        echo "Using cached voice config: $JSON_FILE"
    fi

    cp "$PIPER_CACHE/$ONNX_FILE" "$PIPER_DEST/"
    cp "$PIPER_CACHE/$JSON_FILE" "$PIPER_DEST/"

    echo ""
    echo "=== Piper TTS bundled ==="
    du -sh "$PIPER_DEST"
    echo "Voice model: $PIPER_VOICE"
fi

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
