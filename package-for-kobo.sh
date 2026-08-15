#!/usr/bin/env bash
# Package espeak-ng + Piper TTS + plugin for Kobo deployment
# Everything lives inside audiobook.koplugin/ — just copy to your plugins dir
# Usage: bash package-for-kobo.sh [--with-piper] [--piper-voice VOICE]
# Output: kobo-tts-bundle/audiobook.koplugin/
#
# Options:
#   --with-piper         Also bundle Piper TTS neural engine (~24 MB)
#   --piper-voice VOICE  Download a specific Piper voice (default: en_US-danny-low)
#                        Use "low" quality for smaller size (~15 MB), "medium" for better quality (~60 MB)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$SCRIPT_DIR/kobo-tts-bundle"
PLUGIN_DEST="$BUNDLE_DIR/audiobook.koplugin"
ESPEAK_DEST="$PLUGIN_DEST/espeak-ng"
PIPER_DEST="$PLUGIN_DEST/piper"

# Parse arguments
WITH_PIPER=false
PIPER_VOICE="en_US-danny-low"
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
ESPEAK_OUT=$(nix-build "$SCRIPT_DIR/cross-build-espeak.nix" --no-out-link)
echo "Nix store path: $ESPEAK_OUT"

echo "=== Packaging bundle ==="
chmod -R u+w "$BUNDLE_DIR" 2>/dev/null || true
rm -rf "$BUNDLE_DIR"
mkdir -p "$ESPEAK_DEST/bin" "$ESPEAK_DEST/lib" "$ESPEAK_DEST/share/espeak-ng-data/lang/gmw" "$ESPEAK_DEST/share/espeak-ng-data/voices"

# Plugin Lua files first
for f in absbrowse.lua abscache.lua absclient.lua abssync.lua androidmediasession.lua androidtts.lua audiobookplayer.lua benchmarkrunner.lua btmanager.lua btmediacontrol.lua btui.lua bugreport.lua debuglog.lua downloader.lua epubmediaoverlay.lua highlightmanager.lua m4bparser.lua main.lua mediaaligner.lua mediaengine.lua mediasync.lua menubuilder.lua _meta.lua piperqueue.lua playbackbar.lua sessionrecorder.lua synccontroller.lua textparser.lua transcoder.lua ttsengine.lua updater.lua utils.lua wavutils.lua; do
    if [ -f "$SCRIPT_DIR/$f" ]; then
        cp "$SCRIPT_DIR/$f" "$PLUGIN_DEST/"
    fi
done

# ffmpeg binary for audio file decoding (ARMv7l, tracked in git)
if [ -f "$SCRIPT_DIR/bin/ffmpeg" ]; then
    mkdir -p "$PLUGIN_DEST/bin"
    cp "$SCRIPT_DIR/bin/ffmpeg" "$PLUGIN_DEST/bin/"
    chmod +x "$PLUGIN_DEST/bin/ffmpeg"
    echo "Bundled bin/ffmpeg"
fi

# Standalone bug report script (for users who cannot access the plugin menu)
if [ -f "$SCRIPT_DIR/generate-report.sh" ]; then
    cp "$SCRIPT_DIR/generate-report.sh" "$PLUGIN_DEST/"
    chmod +x "$PLUGIN_DEST/generate-report.sh"
fi

# Android TTS helper (Java source + build script; .dex built in CI or by user)
mkdir -p "$PLUGIN_DEST/android"
for f in TtsHelper.java MediaSessionHelper.java build-dex.sh; do
    if [ -f "$SCRIPT_DIR/android/$f" ]; then
        cp "$SCRIPT_DIR/android/$f" "$PLUGIN_DEST/android/"
    fi
done
# Include pre-built .dex if available (CI builds them)
for f in tts_helper.dex media_session_helper.dex; do
    if [ -f "$SCRIPT_DIR/android/$f" ]; then
        cp "$SCRIPT_DIR/android/$f" "$PLUGIN_DEST/android/"
    fi
done

# Kindle GStreamer WAV player (pre-compiled ARM binary for Cat 2 Kindles)
if [ -f "$SCRIPT_DIR/kindle/gst-play" ]; then
    mkdir -p "$PLUGIN_DEST/kindle"
    cp "$SCRIPT_DIR/kindle/gst-play" "$PLUGIN_DEST/kindle/"
    chmod +x "$PLUGIN_DEST/kindle/gst-play"
    echo "Bundled kindle/gst-play"
fi

# Native-glibc variant for audio-less Kindles (PW4-class) whose old-glibc
# libgstmixersink.so cannot be loaded through the bundled ld-linux.  Built with
# koxtoolchain so it runs under the system linker like KinAMP.  Only used as a
# fallback when the compat gst-play above fails its probe (see ttsengine.lua).
if [ -f "$SCRIPT_DIR/kindle/gst-play-native" ]; then
    mkdir -p "$PLUGIN_DEST/kindle"
    cp "$SCRIPT_DIR/kindle/gst-play-native" "$PLUGIN_DEST/kindle/"
    chmod +x "$PLUGIN_DEST/kindle/gst-play-native"
    echo "Bundled kindle/gst-play-native"
fi

# Soft-float native-glibc variant for PW2/PW3/PW4-class devices on firmware
# < 5.16.3, where the hard-float kindlehf binary cannot load.  Built with
# koxtoolchain kindlepw2 (arm-kindlepw2-linux-gnueabi).  Probed before the
# hard-float native variant (see ttsengine.lua/mediaengine.lua).
if [ -f "$SCRIPT_DIR/kindle/gst-play-native-pw2" ]; then
    mkdir -p "$PLUGIN_DEST/kindle"
    cp "$SCRIPT_DIR/kindle/gst-play-native-pw2" "$PLUGIN_DEST/kindle/"
    chmod +x "$PLUGIN_DEST/kindle/gst-play-native-pw2"
    echo "Bundled kindle/gst-play-native-pw2"
fi

# espeak-ng binary + library (inside plugin dir)
cp "$ESPEAK_OUT/bin/espeak-ng" "$ESPEAK_DEST/bin/"
# Find the actual versioned .so file (e.g. libespeak-ng.so.1.52.0.1) without hardcoding version
ESPEAK_SO=$(find "$ESPEAK_OUT/lib" -name 'libespeak-ng.so.*.*.*' ! -type l | head -1)
if [ -z "$ESPEAK_SO" ]; then
    echo "ERROR: Could not find libespeak-ng.so.*.*.* in $ESPEAK_OUT/lib/"
    exit 1
fi
ESPEAK_SO_NAME=$(basename "$ESPEAK_SO")
echo "Found espeak-ng library: $ESPEAK_SO_NAME"
cp "$ESPEAK_SO" "$ESPEAK_DEST/lib/"
(cd "$ESPEAK_DEST/lib" && ln -sf "$ESPEAK_SO_NAME" libespeak-ng.so.1 && ln -sf libespeak-ng.so.1 libespeak-ng.so)

# Bundle cross-compiled glibc (Kobo's system glibc 2.11 is too old)
# The bundled ld-linux-armhf.so.3 will be used as the dynamic linker
GLIBC_STORE=$(nix-shell -p binutils --run "readelf -l $ESPEAK_OUT/bin/espeak-ng" 2>/dev/null \
    | grep -oP '/nix/store/[^/]+' | head -1)
echo "Bundling glibc from: $GLIBC_STORE"
for lib in ld-linux-armhf.so.3 libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libresolv.so.2; do
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

# Copy full espeak-ng-data (all languages bundled)
if [ -d "$ESPEAK_OUT/share/espeak-ng-data" ]; then
    cp -r "$ESPEAK_OUT/share/espeak-ng-data/"* "$ESPEAK_DEST/share/espeak-ng-data/"
    # Nix store files are read-only; make them writable so subsequent
    # packaging steps (e.g. voice stub updates) don't fail with EPERM.
    chmod -R u+w "$ESPEAK_DEST/share/espeak-ng-data/"
    echo "Bundled full espeak-ng-data (all languages)"
fi

chmod +x "$ESPEAK_DEST/bin/espeak-ng"

# ── MBROLA support (bundled with espeak-ng when mbrolaSupport=true) ───
echo ""
echo "=== Bundling MBROLA binary and default voices ==="

# Build and bundle the cross-compiled mbrola binary.
# It is NOT in espeak-ng's closure, so we build it separately.
echo "Building mbrola binary for armv7l..."
MBROLA_NIX=$(cat <<'NIX'
let
  nixpkgsSrc = fetchTarball "https://github.com/NixOS/nixpkgs/archive/255a186666b6130ddddf8ad749887102a0820914.tar.gz";
  pkgs = import nixpkgsSrc {};
  crossPkgs = pkgs.pkgsCross.armv7l-hf-multiplatform;
in
  crossPkgs.mbrola
NIX
)
MBROLA_OUT=$(nix-build -E "$MBROLA_NIX" --no-out-link 2>/dev/null)
if [ -n "$MBROLA_OUT" ] && [ -f "$MBROLA_OUT/bin/mbrola" ]; then
    cp "$MBROLA_OUT/bin/mbrola" "$ESPEAK_DEST/bin/mbrola.bin"
    chmod +x "$ESPEAK_DEST/bin/mbrola.bin"
    echo "Bundled mbrola binary from $MBROLA_OUT"
else
    echo "WARNING: Could not build/find mbrola binary"
fi

# Build and bundle the compiled C wrapper (replaces shell script to avoid
# /bin/sh subprocess issues when espeak-ng calls execlp("mbrola"))
# Uses musl static linking so no glibc version or dynamic linker issues.
echo "Building mbrola-wrapper binary..."
MBROLA_WRAPPER_OUT=$(nix-build "$SCRIPT_DIR/cross-build-mbrola-wrapper-musl.nix" --no-out-link)
cp "$MBROLA_WRAPPER_OUT/bin/mbrola-wrapper" "$ESPEAK_DEST/bin/mbrola"
chmod +x "$ESPEAK_DEST/bin/mbrola"
echo "Bundled mbrola-wrapper binary (musl static)"

# Copy MBROLA voice definition files (stubs in espeak-ng-data/voices/mb/)
if [ -d "$ESPEAK_OUT/share/espeak-ng-data/voices/mb" ]; then
    mkdir -p "$ESPEAK_DEST/share/espeak-ng-data/voices/mb"
    cp -r "$ESPEAK_OUT/share/espeak-ng-data/voices/mb/"* "$ESPEAK_DEST/share/espeak-ng-data/voices/mb/"
    echo "Bundled MBROLA voice definitions"
fi

# Download default MBROLA voice databases
MBROLA_DATA_DEST="$ESPEAK_DEST/share/mbrola"
mkdir -p "$MBROLA_DATA_DEST"
MBROLA_BASE_URL="https://raw.githubusercontent.com/numediart/MBROLA-voices/master/data"

# Default bundled voices: 2 US English, 1 French, 1 German, 1 Spanish, 1 Chinese, 1 Portuguese
DEFAULT_MBROLA_VOICES="us1 us2 fr1 de1 es1 cn1 pt1"
for voice in $DEFAULT_MBROLA_VOICES; do
    voice_dir="$MBROLA_DATA_DEST/$voice"
    mkdir -p "$voice_dir"
    if [ ! -f "$voice_dir/$voice" ]; then
        echo "Downloading MBROLA voice: $voice ..."
        curl -sL --max-time 60 -o "$voice_dir/$voice" "$MBROLA_BASE_URL/$voice/$voice"
        if [ -f "$voice_dir/$voice" ] && [ -s "$voice_dir/$voice" ]; then
            echo "  + $voice ($(wc -c < "$voice_dir/$voice" | awk '{print $1}') bytes)"
        else
            echo "  ERROR: Failed to download $voice"
            rm -f "$voice_dir/$voice"
        fi
    else
        echo "  + $voice (cached)"
    fi
done


# ── BlueALSA (BT audio bridge for BlueZ Kobo) ─────────────────────────
echo ""
echo "=== Building BlueALSA for armv7l (glibc 2.19 compatible) ==="

# Use Debian Jessie sysroot build for compatibility with older Kobo devices
# (Clara 2E has glibc 2.19; the Nix cross-compilation uses a newer glibc).
# The build script downloads Jessie packages, creates a sysroot, and builds
# bluez-alsa against it. Output lands in .build-bluealsa-compat/out/.
echo "Running build-bluealsa-compat.sh..."
if ! bash "$SCRIPT_DIR/build-bluealsa-compat.sh"; then
    echo "ERROR: BlueALSA compat build failed. Falling back to Nix cross-build."
    BLUEALSA_OUT=$(nix-build "$SCRIPT_DIR/cross-build-bluealsa.nix" --no-out-link)
else
    BLUEALSA_OUT="$SCRIPT_DIR/.build-bluealsa-compat/out"
fi
echo "BlueALSA output path: $BLUEALSA_OUT"

BLUEALSA_DEST="$PLUGIN_DEST/bluealsa"
mkdir -p "$BLUEALSA_DEST/bin" "$BLUEALSA_DEST/lib/alsa-lib" \
         "$BLUEALSA_DEST/etc/alsa/conf.d" "$BLUEALSA_DEST/share/dbus-1/system.d"

# Daemon binary
cp "$BLUEALSA_OUT/bin/bluealsa" "$BLUEALSA_DEST/bin/"
chmod +x "$BLUEALSA_DEST/bin/bluealsa"

# ALSA plugins (loaded by system aplay to route audio to BT)
cp "$BLUEALSA_OUT/lib/alsa-lib/libasound_module_pcm_bluealsa.so" "$BLUEALSA_DEST/lib/alsa-lib/"
cp "$BLUEALSA_OUT/lib/alsa-lib/libasound_module_ctl_bluealsa.so" "$BLUEALSA_DEST/lib/alsa-lib/"

# ALSA config (defines "bluealsa" PCM device)
cp "$BLUEALSA_OUT/etc/alsa/conf.d/20-bluealsa.conf" "$BLUEALSA_DEST/etc/alsa/conf.d/"

# D-Bus policy (allows root to use org.bluealsa)
cp "$BLUEALSA_OUT/share/dbus-1/system.d/bluealsa.conf" "$BLUEALSA_DEST/share/dbus-1/system.d/"

# Bundle runtime dependencies (already collected by build script)
echo "Bundling BlueALSA runtime dependencies..."
for so in "$BLUEALSA_OUT/lib/"*.so*; do
    [ -e "$so" ] || continue
    soname=$(basename "$so")
    # Skip glibc libs (device already has these)
    case "$soname" in
        ld-linux*|libc.so*|libm.so*|libdl.so*|libpthread*|librt.so*|libgcc_s*)
            ;;
        *)
            cp "$so" "$BLUEALSA_DEST/lib/"
            echo "  + $soname"
            ;;
    esac
done

echo "BlueALSA bundle contents:"
du -sh "$BLUEALSA_DEST"

# ── wav-play (minimal ALSA WAV player) ────────────────────────────────
# PocketBook (and potentially other devices) have an ALSA soundcard and
# libasound but ship no aplay binary.  Bundle our own tiny player.
echo ""
echo "=== Building wav-play for armv7l via Nix cross-compilation ==="
WAV_PLAY_OUT=$(nix-build "$SCRIPT_DIR/cross-build-wav-play.nix" --no-out-link)
echo "wav-play Nix store path: $WAV_PLAY_OUT"
mkdir -p "$PLUGIN_DEST/wav-play"
cp "$WAV_PLAY_OUT/bin/wav-play" "$PLUGIN_DEST/wav-play/"
chmod +x "$PLUGIN_DEST/wav-play/wav-play"

# Bundle libasound from the cross toolchain so wav-play works even if
# the device's libasound version is too old or missing.
# wav-play only needs libasound.so.2 beyond glibc (already bundled).
# Find it via readelf RPATH from the binary's Nix closure.
WAV_PLAY_RPATH=$(nix-shell -p binutils --run "readelf -d $WAV_PLAY_OUT/bin/wav-play" 2>/dev/null \
    | grep -oP 'RUNPATH.*\[(.+)\]' | grep -oP '\[(.+)\]' | tr -d '[]')
mkdir -p "$PLUGIN_DEST/wav-play/lib"
for rdir in $(echo "$WAV_PLAY_RPATH" | tr ':' '\n'); do
    if [ -f "$rdir/libasound.so.2" ]; then
        cp -L "$rdir/libasound.so.2" "$PLUGIN_DEST/wav-play/lib/"
        echo "  + libasound.so.2 (from $rdir)"
        break
    fi
done
echo "wav-play bundle:"
du -sh "$PLUGIN_DEST/wav-play"

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

# ── Rename ELF binaries to .bin extension ──────────────────────────────
# Some Windows zip extractors / antivirus software silently quarantine or
# skip Linux ELF executables that have no file extension.  Adding .bin
# ensures they survive extraction intact.  The plugin renames them back
# on first run (see ttsengine.lua detectBackend).
echo ""
echo "=== Renaming ELF binaries to .bin (Windows extraction workaround) ==="
for elf in "$ESPEAK_DEST/bin/espeak-ng" "$PIPER_DEST/piper" "$PIPER_DEST/piper_phonemize" "$PIPER_DEST/espeak-ng" "$BLUEALSA_DEST/bin/bluealsa" "$PLUGIN_DEST/wav-play/wav-play" "$PLUGIN_DEST/bin/ffmpeg"; do
    if [ -f "$elf" ]; then
        mv "$elf" "${elf}.bin"
        echo "  $(basename "$elf") -> $(basename "$elf").bin"
    fi
done

# The actual mbrola binary is at mbrola.bin; the compiled C wrapper stays
# at mbrola so espeak-ng's execlp("mbrola") finds it in PATH.

echo ""
echo "=== Deploy to Kobo ==="
echo "One command — copy the whole plugin folder:"
echo ""
echo "  scp -P 2222 -r $PLUGIN_DEST root@kobo:/mnt/onboard/.adds/koreader/plugins/"
echo ""
echo "Then restart KOReader."
