#!/usr/bin/env bash
#
# Build the Android helper .dex files from their Java sources using the
# Android SDK:
#   - tts_helper.dex from TtsHelper.java (Android TTS)
#   - media_session_helper.dex from MediaSessionHelper.java (AVRCP/MediaSession)
#
# Prerequisites:
#   - ANDROID_HOME (or ANDROID_SDK_ROOT) set to the Android SDK path
#   - Build tools installed (sdkmanager "build-tools;34.0.0")
#   - Platform API 21+ installed (sdkmanager "platforms;android-34")
#
# Usage:
#   ./build-dex.sh
#
# Output:
#   android/tts_helper.dex
#   android/media_session_helper.dex
#
set -euo pipefail
cd "$(dirname "$0")"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$SDK" ]]; then
    echo "Error: ANDROID_HOME or ANDROID_SDK_ROOT not set" >&2
    exit 1
fi

# Find build-tools (newest available)
BT_DIR=$(ls -d "$SDK/build-tools"/*/ 2>/dev/null | sort -V | tail -1)
if [[ -z "$BT_DIR" ]]; then
    echo "Error: No build-tools found in $SDK/build-tools/" >&2
    exit 1
fi
D8="$BT_DIR/d8"

# Find android.jar (newest platform)
PLATFORM=$(ls -d "$SDK/platforms"/android-*/ 2>/dev/null | sort -V | tail -1)
if [[ -z "$PLATFORM" ]]; then
    echo "Error: No platform found in $SDK/platforms/" >&2
    exit 1
fi
ANDROID_JAR="$PLATFORM/android.jar"

echo "SDK:         $SDK"
echo "Build tools: $BT_DIR"
echo "Platform:    $PLATFORM"
echo "d8:          $D8"

# Compile .java -> .class (both helpers share one package)
echo "Compiling TtsHelper.java and MediaSessionHelper.java..."
mkdir -p build
javac -source 8 -target 8 \
    -classpath "$ANDROID_JAR" \
    -d build \
    TtsHelper.java MediaSessionHelper.java

# Convert .class -> .dex, one dex per helper (each plugin module loads its
# own dex via DexClassLoader).  Include inner/anonymous classes like
# TtsHelper$1 / MediaSessionHelper$1.
for PAIR in "TtsHelper tts_helper" "MediaSessionHelper media_session_helper"; do
    set -- $PAIR
    JAVA_CLASS="$1"
    DEX_NAME="$2"
    echo "Dexing $JAVA_CLASS..."
    "$D8" --min-api 21 --output . "build/org/koreader/plugin/audiobook/${JAVA_CLASS}"*.class
    # d8 outputs classes.dex; rename to our expected name
    mv classes.dex "$DEX_NAME.dex"
    echo "Created $DEX_NAME.dex ($(wc -c < "$DEX_NAME.dex") bytes)"
done
rm -rf build
