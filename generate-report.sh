#!/bin/sh
# Standalone bug report generator for audiobook.koplugin.
# Run this via SSH or KOReader's terminal emulator when the plugin
# menu is not accessible.
#
# Usage:
#   sh /path/to/audiobook.koplugin/generate-report.sh
#
# The report is saved to the device's root storage (same location as
# the in-app report) and also printed to stdout.

set +e  # Never abort on error: every variable has a fallback value and a
        # partial report is far more useful than no report at all.

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Helpers ──────────────────────────────────────────────────────────

capture() {
    # Run a command with a 3-second hard timeout, return stdout.
    # Uses background process + SIGKILL for portability: works on BusyBox
    # ash without GNU timeout, and kills commands (e.g. bluetoothctl) that
    # ignore SIGTERM.
    "$@" 2>/dev/null &
    _cpid=$!
    ( sleep 3 && kill -9 "$_cpid" ) 2>/dev/null &
    _cwdpid=$!
    wait "$_cpid" 2>/dev/null
    kill "$_cwdpid" 2>/dev/null
    wait "$_cwdpid" 2>/dev/null
    true
}

file_exists() { [ -e "$1" ]; }

bool() { if "$@" 2>/dev/null; then echo "yes"; else echo "no"; fi; }

# ── Plugin version ───────────────────────────────────────────────────

PLUGIN_VERSION="unknown"
if [ -f "$PLUGIN_DIR/_meta.lua" ]; then
    v=$(grep 'version' "$PLUGIN_DIR/_meta.lua" | head -1 | sed 's/.*"\(.*\)".*/\1/')
    [ -n "$v" ] && PLUGIN_VERSION="$v"
fi

# ── Detect platform ─────────────────────────────────────────────────

PLATFORM="unknown"
if [ -f /etc/rc.d/functions ]; then
    PLATFORM="kindle"
elif [ -f /bin/kobo_config.sh ]; then
    PLATFORM="kobo"
elif uname -n 2>/dev/null | grep -qi pocketbook || [ -d /mnt/ext1/applications ]; then
    PLATFORM="pocketbook"
elif [ -d /sys/class/android_usb ] || command -v getprop >/dev/null 2>&1; then
    PLATFORM="android"
elif [ "$(uname -s)" = "Linux" ]; then
    PLATFORM="linux"
fi

# ── Pick save location ──────────────────────────────────────────────

case "$PLATFORM" in
    kobo)        SAVE_DIR="/mnt/onboard" ;;
    kindle)      SAVE_DIR="/mnt/us" ;;
    pocketbook)  SAVE_DIR="/mnt/ext1" ;;
    android)     SAVE_DIR="/sdcard" ;;
    *)           SAVE_DIR="${HOME:-/tmp}" ;;
esac

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
FILENAME="audiobook-bug-report-$(date -u +"%Y%m%d-%H%M%S" 2>/dev/null || date +"%Y%m%d-%H%M%S").txt"

# ── Collect info ─────────────────────────────────────────────────────

UNAME=$(capture uname -a)
ARCH=$(capture uname -m)
MODEL="unknown"
case "$PLATFORM" in
    kobo)
        [ -f /bin/kobo_config.sh ] && MODEL=$(capture sh -c '. /bin/kobo_config.sh; echo "$PRODUCT"')
        ;;
    kindle)
        [ -f /proc/usid ] && MODEL=$(capture cat /proc/usid)
        ;;
    pocketbook)
        # Prefer /ebrmain/config/device.cfg (has real model: PB632, etc.)
        if [ -f /ebrmain/config/device.cfg ]; then
            _pb_desc=$(grep '^description=' /ebrmain/config/device.cfg 2>/dev/null | head -1 | cut -d= -f2-)
            _pb_model=$(grep '^model=' /ebrmain/config/device.cfg 2>/dev/null | head -1 | cut -d= -f2-)
            _pb_bt_name=$(grep '^bluetooth_device_name=' /ebrmain/config/device.cfg 2>/dev/null | head -1 | cut -d= -f2-)
            MODEL="${_pb_desc:-${_pb_model:-unknown}}"
            [ -n "$_pb_bt_name" ] && MODEL="$MODEL ($_pb_bt_name)"
        else
            MODEL=$(cat /sys/firmware/devicetree/base/model 2>/dev/null \
                || cat /proc/device-tree/model 2>/dev/null \
                || echo "PocketBook $(uname -m)")
        fi
        ;;
    android)
        MODEL="$(capture getprop ro.product.brand) $(capture getprop ro.product.model)"
        ;;
esac

# KOReader version
KOREADER_VERSION="unknown"
for d in \
    "$(dirname "$PLUGIN_DIR")/../../" \
    "$(dirname "$PLUGIN_DIR")/../" \
    "/mnt/onboard/.adds/koreader/" \
    "/mnt/us/koreader/" \
    "/mnt/ext1/applications/koreader/" \
    "/sdcard/koreader/"
do
    if [ -f "${d}git-rev" ]; then
        KOREADER_VERSION=$(head -1 "${d}git-rev")
        break
    fi
done

# Bundled binaries
HAS_BUNDLED_ESPEAK=$(bool file_exists "$PLUGIN_DIR/espeak-ng/bin/espeak-ng")
HAS_BUNDLED_PIPER=$(bool file_exists "$PLUGIN_DIR/piper/piper")
PIPER_MODELS="none"
if ls "$PLUGIN_DIR/piper/"*.onnx >/dev/null 2>&1; then
    PIPER_MODELS=$(ls "$PLUGIN_DIR/piper/"*.onnx 2>/dev/null | xargs -n1 basename | tr '\n' ', ' | sed 's/,$//' | sed 's/, $//')
fi

# TTS commands
TTS_CMDS=""
for cmd in espeak-ng espeak piper pico2wave flite festival; do
    loc=$(command -v "$cmd" 2>/dev/null || true)
    [ -n "$loc" ] && TTS_CMDS="${TTS_CMDS}    ${cmd}: ${loc}\n"
done
[ -z "$TTS_CMDS" ] && TTS_CMDS="    (none found)\n"

# Audio players
PLAYER_CMDS=""
for cmd in aplay paplay mpv mplayer play gst-launch-1.0; do
    loc=$(command -v "$cmd" 2>/dev/null || true)
    [ -n "$loc" ] && PLAYER_CMDS="${PLAYER_CMDS}    ${cmd}: ${loc}\n"
done
[ -z "$PLAYER_CMDS" ] && PLAYER_CMDS="    (none found)\n"

# ALSA
ALSA_CARDS="not available"
[ -f /proc/asound/cards ] && ALSA_CARDS=$(cat /proc/asound/cards 2>/dev/null || echo "not available")

# Bluetooth
BT_AVAILABLE=$(bool sh -c 'command -v bluetoothctl >/dev/null || command -v hcitool >/dev/null || [ -d /sys/class/bluetooth ]')

# BT adapter
BT_HCI_DEVICES=$(ls -1 /sys/class/bluetooth/ 2>/dev/null || echo "none")

# Paired / connected devices
# Older BlueZ (< 5.65) doesn't support "devices Paired" and outputs
# "Too many arguments".  Try paired-devices first (works on all versions).
BT_PAIRED="n/a"
BT_CONNECTED="n/a"
BT_ADAPTER_INFO="n/a"
BT_SLEEP_TEST="n/a"
if command -v bluetoothctl >/dev/null 2>&1; then
    BT_PAIRED=$(capture bluetoothctl paired-devices)
    # Fallback: if paired-devices isn't supported, try devices list
    if [ -z "$BT_PAIRED" ] || echo "$BT_PAIRED" | grep -qi "invalid\|error"; then
        BT_PAIRED=$(capture bluetoothctl devices | head -10)
    fi
    [ -z "$BT_PAIRED" ] && BT_PAIRED="none"
    BT_CONNECTED=$(capture bluetoothctl info 2>/dev/null | grep -E 'Device|Name|Connected|Paired')
    [ -z "$BT_CONNECTED" ] && BT_CONNECTED="none"
    BT_ADAPTER_INFO=$(capture bluetoothctl show 2>/dev/null | grep -E 'Powered|Pairable|Discoverable|Controller')
    [ -z "$BT_ADAPTER_INFO" ] && BT_ADAPTER_INFO="unavailable"
    # Test fractional sleep support
    if sleep 0.1 2>/dev/null; then BT_SLEEP_TEST="ok"; else BT_SLEEP_TEST="unsupported"; fi
fi

# hcitool fallback
BT_HCITOOL_CON="n/a"
if command -v hcitool >/dev/null 2>&1; then
    BT_HCITOOL_CON=$(capture hcitool con)
    [ -z "$BT_HCITOOL_CON" ] && BT_HCITOOL_CON="none"
fi

# Kobo BT daemon
BT_DAEMON=$(pidof mtkbtmwrpc 2>/dev/null || pidof bluetoothd 2>/dev/null || echo "not running")

# GStreamer BT sink
GST_BT_SINK="n/a"
GST_AUDIO_SINKS="n/a"
if command -v gst-inspect-1.0 >/dev/null 2>&1; then
    GST_BT_SINK=$(capture gst-inspect-1.0 mtkbtmwrpcaudiosink 2>/dev/null | head -5)
    [ -z "$GST_BT_SINK" ] && GST_BT_SINK="not found"
    GST_AUDIO_SINKS=$(capture sh -c 'gst-inspect-1.0 --list-elements 2>/dev/null | grep -i "sink\|audio" || gst-inspect-1.0 2>/dev/null | grep -i "sink\|audio"')
    [ -z "$GST_AUDIO_SINKS" ] && GST_AUDIO_SINKS="none found"
fi

# Kobo BT abstract socket
BT_SOCKET=$(cat /proc/net/unix 2>/dev/null | grep -i 'kobo\|mtk\|bluetooth' | head -5 || echo "none")

# ALSA PCM devices (may reveal BT sinks not in /proc/asound/cards)
ALSA_PCM_DEVICES="n/a"
if command -v aplay >/dev/null 2>&1; then
    ALSA_PCM_DEVICES=$(capture aplay -L 2>/dev/null | head -20)
    [ -z "$ALSA_PCM_DEVICES" ] && ALSA_PCM_DEVICES="none"
fi

# Kindle BT diagnostics via lipc
KINDLE_SECTION=""
if [ "$PLATFORM" = "kindle" ] && command -v lipc-get-prop >/dev/null 2>&1; then
    KINDLE_BT_SERVICE="none responded"
    KINDLE_BT_PROP=""
    KINDLE_BT_ENABLED=""
    KINDLE_BT_PAIRED="n/a"
    KINDLE_BT_CONNECTED="n/a"
    KINDLE_BT_PROPS=""
    # Probe service+property combinations
    for svc in com.lab126.btfd com.lab126.btService com.lab126.cmd com.lab126.acsbt; do
        for prop in btEnabled btPowerState BTstate; do
            val=$(lipc-get-prop "$svc" "$prop" 2>/dev/null)
            if [ -n "$val" ]; then
                KINDLE_BT_SERVICE="$svc"
                KINDLE_BT_PROP="$prop"
                KINDLE_BT_ENABLED="$val"
                KINDLE_BT_PAIRED=$(capture lipc-get-prop "$svc" btPairedDevicesList)
                [ -z "$KINDLE_BT_PAIRED" ] && KINDLE_BT_PAIRED="n/a"
                KINDLE_BT_CONNECTED=$(capture lipc-get-prop "$svc" btConnectedDevices)
                [ -z "$KINDLE_BT_CONNECTED" ] && KINDLE_BT_CONNECTED="n/a"
                break 2
            fi
        done
    done
    if [ "$KINDLE_BT_SERVICE" = "none responded" ]; then
        # List available BT-related lipc services
        KINDLE_LIPC_SERVICES=$(capture lipc-probe -l 2>/dev/null | grep -i 'bt\|blue' | head -5)
        [ -z "$KINDLE_LIPC_SERVICES" ] && KINDLE_LIPC_SERVICES="none"
        # List properties for each known BT service
        for svc in com.lab126.btfd com.lab126.btService com.lab126.cmd com.lab126.acsbt; do
            p=$(lipc-probe "$svc" 2>/dev/null | head -20)
            [ -n "$p" ] && KINDLE_BT_PROPS="${KINDLE_BT_PROPS}    ${svc}: ${p}\n"
        done
    fi

    # Kindle audio subsystem probing: identify what audio path Amazon
    # exposes when BT headphones are connected (speakerless models).
    KINDLE_DEV_SND=$(ls -la /dev/snd/ 2>/dev/null || echo "not found")
    KINDLE_APLAY_L=$(aplay -l 2>&1 | head -15 || echo "n/a")
    KINDLE_APLAY_LP=$(aplay -L 2>&1 | head -20 || echo "n/a")
    KINDLE_PROC_ASOUND_PCM=$(cat /proc/asound/pcm 2>/dev/null || echo "not found")
    KINDLE_AUDIO_PROCS=$(ps 2>/dev/null | grep -iE 'audio|alsa|pulse|btfd|a2dp|bluez|sound' | grep -v grep | head -10 || echo "none")
    KINDLE_PULSEAUDIO=$(capture pactl info 2>/dev/null | head -10)
    [ -z "$KINDLE_PULSEAUDIO" ] && KINDLE_PULSEAUDIO="not available"
    KINDLE_PA_SINKS=$(capture pactl list sinks short 2>/dev/null)
    [ -z "$KINDLE_PA_SINKS" ] && KINDLE_PA_SINKS="none"
    KINDLE_LIPC_AUDIO=$(capture lipc-probe com.lab126.audio 2>/dev/null | head -20)
    [ -z "$KINDLE_LIPC_AUDIO" ] && KINDLE_LIPC_AUDIO="not found"
    KINDLE_LIPC_AUDIO_SVCS=$(capture lipc-probe -l 2>/dev/null | grep -iE 'audio|sound|media|player' | head -5)
    [ -z "$KINDLE_LIPC_AUDIO_SVCS" ] && KINDLE_LIPC_AUDIO_SVCS="none"
    KINDLE_AUDIO_BINS=""
    for b in aplay paplay mpv mplayer play madplay mpg123 ffplay sox; do
        loc=$(command -v "$b" 2>/dev/null || true)
        [ -n "$loc" ] && KINDLE_AUDIO_BINS="${KINDLE_AUDIO_BINS}    ${b}: ${loc}\n"
    done
    [ -z "$KINDLE_AUDIO_BINS" ] && KINDLE_AUDIO_BINS="    (none found)\n"
    KINDLE_SND_MODULES=$(lsmod 2>/dev/null | grep -i snd | head -10 || echo "n/a")
    KINDLE_ASOUND_CONF=$(cat /etc/asound.conf 2>/dev/null | head -10 || echo "not found")

    # btfd A2DP reverse-engineering: understand how Amazon routes
    # BT audio so we can inject PCM data into the same path.
    KINDLE_BTFD_PID=$(pidof btfd 2>/dev/null || echo "not running")
    KINDLE_BTFD_CMDLINE="n/a"
    KINDLE_BTFD_FDS="n/a"
    KINDLE_BTFD_SOCKETS="n/a"
    KINDLE_BTFD_MAPS="n/a"
    if echo "$KINDLE_BTFD_PID" | grep -qE '^[0-9]+$'; then
        KINDLE_BTFD_CMDLINE=$(cat /proc/$KINDLE_BTFD_PID/cmdline 2>/dev/null | tr '\0' ' ' || echo "n/a")
        KINDLE_BTFD_FDS=$(ls -la /proc/$KINDLE_BTFD_PID/fd/ 2>/dev/null | head -30 || echo "n/a")
        KINDLE_BTFD_SOCKETS=$(cat /proc/$KINDLE_BTFD_PID/net/unix 2>/dev/null | head -20 || echo "n/a")
        KINDLE_BTFD_MAPS=$(cat /proc/$KINDLE_BTFD_PID/maps 2>/dev/null | grep -iE 'audio|alsa|pulse|blue|a2dp|sbc|socket|pipe' | head -20 || echo "n/a")
    fi
    KINDLE_HCI_DEVS=$(ls -la /dev/hci* 2>/dev/null || echo "none")
    KINDLE_SYS_BT=$(ls -la /sys/class/bluetooth/ 2>/dev/null || echo "none")
    KINDLE_HCICONFIG=$(hciconfig -a 2>/dev/null | head -20 || echo "not available")
    KINDLE_DBUS_RUNNING=$(pidof dbus-daemon 2>/dev/null || echo "not running")
    KINDLE_DBUS_BLUEZ=$(dbus-send --system --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null | grep -i blue | head -5 || echo "no bluez on dbus")
    KINDLE_BT_SOCKETS=$(cat /proc/net/unix 2>/dev/null | grep -iE 'bt|audio|a2dp|blue|sbc' | head -15 || echo "none")
    KINDLE_LIPC_TTS_PROPS=$(capture lipc-probe com.lab126.kaf.TTSService 2>/dev/null | head -15)
    [ -z "$KINDLE_LIPC_TTS_PROPS" ] && KINDLE_LIPC_TTS_PROPS="not found"
    KINDLE_LIPC_AUDIO_PLAYER=$(capture lipc-probe com.lab126.audioPlayer 2>/dev/null | head -15)
    [ -z "$KINDLE_LIPC_AUDIO_PLAYER" ] && KINDLE_LIPC_AUDIO_PLAYER="not found"

    # audiomgrd: Amazon's audio manager daemon (discovered in v0.1.5.24 report)
    KINDLE_AUDIOMGRD_PID=$(pidof audiomgrd 2>/dev/null || echo "not running")
    KINDLE_AUDIOMGRD_CMDLINE="n/a"
    KINDLE_AUDIOMGRD_FDS="n/a"
    KINDLE_AUDIOMGRD_MAPS="n/a"
    if echo "$KINDLE_AUDIOMGRD_PID" | grep -qE '^[0-9]+$'; then
        KINDLE_AUDIOMGRD_CMDLINE=$(cat /proc/$KINDLE_AUDIOMGRD_PID/cmdline 2>/dev/null | tr '\0' ' ' || echo "n/a")
        KINDLE_AUDIOMGRD_FDS=$(ls -la /proc/$KINDLE_AUDIOMGRD_PID/fd/ 2>/dev/null | head -30 || echo "n/a")
        KINDLE_AUDIOMGRD_MAPS=$(cat /proc/$KINDLE_AUDIOMGRD_PID/maps 2>/dev/null | grep -iE 'audio|alsa|snd|pcm|mixer|pipe|socket|hw' | head -20 || echo "n/a")
    fi
    # LIPC services discovered in v0.1.5.24 report
    KINDLE_LIPC_PLAYERMGR=$(capture lipc-probe com.lab126.playermgr 2>/dev/null | head -20)
    [ -z "$KINDLE_LIPC_PLAYERMGR" ] && KINDLE_LIPC_PLAYERMGR="not found"
    KINDLE_LIPC_AUDIOMGRD=$(capture lipc-probe com.lab126.audiomgrd 2>/dev/null | head -20)
    [ -z "$KINDLE_LIPC_AUDIOMGRD" ] && KINDLE_LIPC_AUDIOMGRD="not found"
    # v0.1.5.27: capture actual playermgr/audiomgrd state values
    KINDLE_PLAYERMGR_INPLAYBACK=$(lipc-get-prop com.lab126.playermgr InPlayback 2>/dev/null || echo "n/a")
    KINDLE_PLAYERMGR_TTS_STATE=$(lipc-get-prop com.lab126.playermgr TTS_State 2>/dev/null || echo "n/a")
    KINDLE_AUDIOMGRD_OUTPUT_CONNECTED=$(lipc-get-prop com.lab126.audiomgrd audioOutputConnected 2>/dev/null || echo "n/a")
    KINDLE_AUDIOMGRD_CURRENT_OUTPUT=$(lipc-get-prop com.lab126.audiomgrd audioCurrentOutput 2>/dev/null || echo "n/a")
    KINDLE_AUDIOMGRD_VOLUME=$(lipc-get-prop com.lab126.audiomgrd speakerVolume 2>/dev/null || echo "n/a")
    # Full ALSA config (v0.1.5.24 showed dmix0 on hw:0,0)
    KINDLE_ASOUND_CONF_FULL=$(cat /etc/asound.conf 2>/dev/null || echo "not found")
    KINDLE_DEV_SND_FULL=$(ls -la /dev/snd/ 2>/dev/null || echo "empty")
    # All LIPC services for discovery
    KINDLE_LIPC_ALL_SERVICES=$(capture lipc-probe -l 2>/dev/null | head -40)
    [ -z "$KINDLE_LIPC_ALL_SERVICES" ] && KINDLE_LIPC_ALL_SERVICES="n/a"

    # v0.1.5.30: LIPC playback smoke test -- multi-strategy
    # NOTE: first line of subshell MUST be a real command (dd), not a
    # variable assignment, because the Lua shellCapture() version prepends
    # 'timeout N' which wraps only line 1.  Keep the two versions in sync.
    KINDLE_LIPC_TEST=$(
        dd if=/dev/zero bs=44100 count=1 2>/dev/null | {
            printf 'RIFF'
            printf '\x24\xac\x00\x00'
            printf 'WAVE'
            printf 'fmt '
            printf '\x10\x00\x00\x00'
            printf '\x01\x00'
            printf '\x01\x00'
            printf '\x22\x56\x00\x00'
            printf '\x44\xac\x00\x00'
            printf '\x02\x00'
            printf '\x10\x00'
            printf 'data'
            printf '\x04\xac\x00\x00'
            cat
        } > /tmp/.lipc_test.wav
        echo "wav_size=$(wc -c < /tmp/.lipc_test.wav 2>/dev/null)"
        echo "setFocus=$(lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>&1)"
        echo "gstLog=$(lipc-set-prop com.lab126.playermgr gstLogLevel 2 2>&1)"
        echo "--- strategy1: Open(URI)+Play ---"
        lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
        echo "open_uri=$(lipc-set-prop com.lab126.playermgr Open 'file:///tmp/.lipc_test.wav' 2>&1)"
        echo "play1=$(lipc-set-prop com.lab126.playermgr Play '' 2>&1)"
        sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
        echo "inplayback1=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
        echo "tts_state1=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
        echo "--- strategy2: Open(path)+Play ---"
        lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
        echo "open_path=$(lipc-set-prop com.lab126.playermgr Open '/tmp/.lipc_test.wav' 2>&1)"
        echo "play2=$(lipc-set-prop com.lab126.playermgr Play '' 2>&1)"
        sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
        echo "inplayback2=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
        echo "--- strategy3: Play(URI) ---"
        lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
        echo "play_uri=$(lipc-set-prop com.lab126.playermgr Play 'file:///tmp/.lipc_test.wav' 2>&1)"
        sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
        echo "inplayback3=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
        echo "--- strategy4: Play(path) ---"
        lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
        echo "play_path=$(lipc-set-prop com.lab126.playermgr Play '/tmp/.lipc_test.wav' 2>&1)"
        sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
        echo "inplayback4=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
        echo "--- strategy5: aplay dmix0 ---"
        lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
        echo "aplay_dmix0=$(aplay -D dmix0 /tmp/.lipc_test.wav 2>&1 | head -3)"
        echo "--- strategy6: aplay default ---"
        echo "aplay_default=$(aplay -D default /tmp/.lipc_test.wav 2>&1 | head -3)"
        echo "--- audiomgrd state ---"
        echo "audioOutput=$(lipc-get-prop com.lab126.audiomgrd audioCurrentOutput 2>&1)"
        echo "outputConn=$(lipc-get-prop com.lab126.audiomgrd audioOutputConnected 2>&1)"
        rm -f /tmp/.lipc_test.wav
    )
    [ -z "$KINDLE_LIPC_TEST" ] && KINDLE_LIPC_TEST="failed"
    # audiomgrd error log
    KINDLE_AUDIOMGRD_ERR=$(tail -20 /var/tmp/audiomgrd.err 2>/dev/null || echo "n/a")
    # GStreamer plugins available on device
    KINDLE_GST_PLUGINS=$(ls /usr/lib/gstreamer-*/ 2>/dev/null | head -30 || echo "n/a")
    # v0.1.5.31: tts.orchestrator -- Amazon's native TTS service
    KINDLE_TTS_ORCHESTRATOR=$(capture lipc-probe com.lab126.tts.orchestrator 2>/dev/null | head -30)
    [ -z "$KINDLE_TTS_ORCHESTRATOR" ] && KINDLE_TTS_ORCHESTRATOR="not found"
    KINDLE_AUDIOMGRD_IS_STARTED=$(lipc-get-prop com.lab126.audiomgrd isStarted 2>/dev/null || echo "n/a")
    KINDLE_GST_TOOLS="gst_launch=$(which gst-launch-1.0 2>/dev/null || echo not_found) gst_inspect=$(which gst-inspect-1.0 2>/dev/null || echo not_found) amixer=$(which amixer 2>/dev/null || echo not_found)"
    KINDLE_SHM=$(ls -la /dev/shm/ 2>/dev/null || echo "no /dev/shm")
    KINDLE_A2DP_SOCKETS=$(cat /proc/net/unix 2>/dev/null | grep -i a2dp || echo "none")
    KINDLE_GST_INSPECT_TTSSRC=$(gst-inspect-1.0 ttssrc 2>/dev/null | head -30 || echo "n/a")
    KINDLE_GST_INSPECT_MIXERSINK=$(gst-inspect-1.0 mixersink 2>/dev/null | head -30 || echo "n/a")
    # TTS orchestrator smoke test
    KINDLE_TTS_TEST=$(
        echo "--- tts.orchestrator probe ---"
        echo "tts_orch_props=$(lipc-probe com.lab126.tts.orchestrator 2>&1 | head -30)"
        echo "--- try native TTS speak ---"
        echo "tts_speak=$(lipc-set-prop com.lab126.tts.orchestrator speak 'test' 2>&1)"
        sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
        echo "tts_state_after=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
        echo "inplayback_after=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
        echo "--- try audiomgrd direct ---"
        echo "amgrd_started=$(lipc-get-prop com.lab126.audiomgrd isStarted 2>&1)"
        echo "amgrd_focus=$(lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>&1)"
        echo "--- ALSA after setFocus ---"
        echo "aplay_l_after=$(aplay -l 2>&1 | head -5)"
        echo "dev_snd_after=$(ls /dev/snd/ 2>/dev/null | grep pcm)"
        echo "--- A2DP socket state ---"
        echo "a2dp_socks=$(cat /proc/net/unix 2>/dev/null | grep a2dp)"
    )
    [ -z "$KINDLE_TTS_TEST" ] && KINDLE_TTS_TEST="failed"

    # v0.1.17.48: LIPC headset-button watch diagnostics. Watchers alive and
    # what they logged tells us whether stem clicks reach playermgr/audiomgrd
    # (the plugin watches them in btmediacontrol.lua).
    KINDLE_LIPC_AVRCP=$(
        echo "--- lipc headset-button watch ---"
        echo "watchers=$(pgrep -a lipc-wait-event 2>/dev/null || echo none)"
        echo "pidfiles=$(ls /tmp/abk_lipc_*.pid 2>/dev/null | tr '\n' ' ' || echo none)"
        echo "log=$(ls -la /tmp/abk-kindle-avrcp.log 2>/dev/null || echo absent)"
        echo "--- log tail ---"
        tail -20 /tmp/abk-kindle-avrcp.log 2>/dev/null || echo "no log"
        echo "--- InPlayback now ---"
        echo "inplayback=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
    )
    [ -z "$KINDLE_LIPC_AVRCP" ] && KINDLE_LIPC_AVRCP="failed"

    # v0.1.5.32: Deeper TTS + audio path exploration
    KINDLE_TTS_ORCH_STARTED=$(lipc-get-prop com.lab126.tts.orchestrator orchestratorStarted 2>&1 || echo "n/a")
    KINDLE_TTS_ORCH_HASH_CMD=$(which lipc-hash-prop 2>/dev/null || echo "not_found")
    KINDLE_TTS_ORCH_LANGS=$(lipc-hash-prop -n com.lab126.tts.orchestrator supportedLanguages 2>&1 | head -20 || echo "n/a")
    # v0.1.5.33: get FULL voices list (was truncated at 20 lines)
    KINDLE_TTS_ORCH_VOICES=$(lipc-hash-prop -n com.lab126.tts.orchestrator voices 2>&1 | head -80 || echo "n/a")
    KINDLE_TTS_ORCH_INSTALLED=$(lipc-hash-prop -n com.lab126.tts.orchestrator installedVoices 2>&1 | head -20 || echo "n/a")

    # v0.1.5.34: lipc-send-event from custom source (v0.1.5.33 tried to
    # impersonate tts.orchestrator which fails with "Failed to open LIPC").
    KINDLE_TTS_EVENT_TEST=$(
        echo "--- lipc-send-event from custom source ---"
        echo "evt1=$(lipc-send-event com.lab126.audiobook speak -s 'hello world' 2>&1)"
        echo "tts1=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
        echo "--- send ttsSpeak from kaf source ---"
        echo "evt2=$(lipc-send-event com.lab126.kaf ttsSpeak -s 'hello' 2>&1)"
        sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
        echo "tts2=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
        echo "--- send readScreen from custom source ---"
        echo "evt3=$(lipc-send-event com.lab126.audiobook readScreen -s 'hello' 2>&1)"
        echo "tts3=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
    )
    [ -z "$KINDLE_TTS_EVENT_TEST" ] && KINDLE_TTS_EVENT_TEST="failed"

    # v0.1.5.34 FIX: lipc-hash-prop has no -w flag! Use stdin pipe.
    KINDLE_TTS_CHECK_VOICE=$(
        echo "--- checkVoice write via stdin pipe ---"
        cv1=$(echo '{ language_code = "en" }' | lipc-hash-prop com.lab126.tts.orchestrator checkVoice 2>&1)
        echo "cv1=$cv1"
        echo "cv1_rc=$?"
        sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
        echo "tts_cv1=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
        echo "play_cv1=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
        echo "--- checkVoice with voice name ---"
        cv2=$(echo '{ language_code = "en_us", voice = "joanna" }' | lipc-hash-prop com.lab126.tts.orchestrator checkVoice 2>&1)
        echo "cv2=$cv2"
        sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
        echo "tts_cv2=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
        echo "--- write text to voices hash ---"
        v1=$(echo '{ Voice = "joanna", LanguageCode = "en_us" }' | lipc-hash-prop com.lab126.tts.orchestrator voices 2>&1)
        echo "voices_write=$v1"
        sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
        echo "tts_v1=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
        echo "--- checkVoice read (null input) ---"
        echo "cv_read=$(lipc-hash-prop -n com.lab126.tts.orchestrator checkVoice 2>&1 | head -10)"
    )
    [ -z "$KINDLE_TTS_CHECK_VOICE" ] && KINDLE_TTS_CHECK_VOICE="failed"

    # v0.1.5.33: TTS URI schemes via playermgr
    KINDLE_TTS_URI_TEST=$(
        lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>/dev/null
        echo "--- tts:// URI ---"
        lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
        echo "open_tts=$(lipc-set-prop com.lab126.playermgr Open 'tts://hello world' 2>&1)"
        echo "play_tts=$(lipc-set-prop com.lab126.playermgr Play '' 2>&1)"
        sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
        echo "state_tts=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
        echo "play_tts_ip=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
        echo "--- ttssrc:// URI ---"
        lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
        echo "open_ttssrc=$(lipc-set-prop com.lab126.playermgr Open 'ttssrc://hello world' 2>&1)"
        echo "play_ttssrc=$(lipc-set-prop com.lab126.playermgr Play '' 2>&1)"
        sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
        echo "state_ttssrc=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
        echo "--- Play with tts: ---"
        lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
        echo "play_tts2=$(lipc-set-prop com.lab126.playermgr Play 'tts://hello' 2>&1)"
        sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
        echo "state_tts2=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
        lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
    )
    [ -z "$KINDLE_TTS_URI_TEST" ] && KINDLE_TTS_URI_TEST="failed"

    # v0.1.5.35: Test VoiceView-compatible native TTS via PlayParameter
    KINDLE_NATIVE_TTS_TEST=$(
        lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
        lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>/dev/null
        echo "--- Strategy A: PlayParameter only ---"
        lipc-set-prop com.lab126.playermgr PlayParameter '{"type":"TTS","data":{"paramName":"textsource","paramValue":"Testing native TTS."}}' 2>&1
        sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
        echo "tts_a=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
        echo "ip_a=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
        lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
        echo "--- Strategy B: Open+PlayParameter+Play ---"
        lipc-set-prop com.lab126.playermgr Open '{"type":"TTS"}' 2>&1
        lipc-set-prop com.lab126.playermgr PlayParameter '{"type":"TTS","data":{"paramName":"textsource","paramValue":"Testing native TTS."}}' 2>&1
        lipc-set-prop com.lab126.playermgr Play '' 2>&1
        sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
        echo "tts_b=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
        echo "ip_b=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
        lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
        echo "--- Strategy C: PlayParameter+Play ---"
        lipc-set-prop com.lab126.playermgr PlayParameter '{"type":"TTS","data":{"paramName":"textsource","paramValue":"Testing native TTS."}}' 2>&1
        lipc-set-prop com.lab126.playermgr Play '{"type":"TTS"}' 2>&1
        sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
        echo "tts_c=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
        echo "ip_c=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
        lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
        echo "--- Strategy D: Open+PlayParameter+Play(empty) ---"
        lipc-set-prop com.lab126.playermgr Open '' 2>&1
        lipc-set-prop com.lab126.playermgr PlayParameter '{"type":"TTS","data":{"paramName":"textsource","paramValue":"Testing native TTS."}}' 2>&1
        lipc-set-prop com.lab126.playermgr Play '' 2>&1
        sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
        echo "tts_d=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
        echo "ip_d=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
        lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
        echo "--- Strategy E: SSML with marks ---"
        lipc-set-prop com.lab126.playermgr PlayParameter '{"type":"TTS","data":{"paramName":"textsource","paramValue":"<mark name=\"1\"/>Testing <mark name=\"9\"/>native <mark name=\"16\"/>TTS."}}' 2>&1
        sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
        echo "tts_e=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
        echo "ip_e=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
        lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
    )
    [ -z "$KINDLE_NATIVE_TTS_TEST" ] && KINDLE_NATIVE_TTS_TEST="failed"

    # PlayParameter + raw PCM test
    KINDLE_RAW_PCM_TEST=$(
        dd if=/dev/zero bs=44100 count=1 2>/dev/null | {
            printf 'RIFF'
            printf '\x24\xac\x00\x00'
            printf 'WAVE'
            printf 'fmt '
            printf '\x10\x00\x00\x00'
            printf '\x01\x00'
            printf '\x01\x00'
            printf '\x22\x56\x00\x00'
            printf '\x44\xac\x00\x00'
            printf '\x02\x00'
            printf '\x10\x00'
            printf 'data'
            printf '\x04\xac\x00\x00'
            cat
        } > /tmp/.pcm_test.wav
        dd if=/tmp/.pcm_test.wav of=/tmp/.pcm_test.raw bs=1 skip=44 2>/dev/null
        echo "raw_size=$(wc -c < /tmp/.pcm_test.raw 2>/dev/null)"
        lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
        lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>/dev/null
        echo "--- PlayParameter + raw PCM (path) ---"
        echo "param=$(lipc-set-prop com.lab126.playermgr PlayParameter 'audio/x-raw,format=S16LE,rate=22050,channels=1' 2>&1)"
        echo "open=$(lipc-set-prop com.lab126.playermgr Open '/tmp/.pcm_test.raw' 2>&1)"
        echo "play=$(lipc-set-prop com.lab126.playermgr Play '' 2>&1)"
        sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
        echo "inplayback_raw=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
        echo "--- PlayParameter + raw PCM (URI) ---"
        lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
        echo "param2=$(lipc-set-prop com.lab126.playermgr PlayParameter 'audio/x-raw,format=S16LE,rate=22050,channels=1' 2>&1)"
        echo "open2=$(lipc-set-prop com.lab126.playermgr Open 'file:///tmp/.pcm_test.raw' 2>&1)"
        echo "play2=$(lipc-set-prop com.lab126.playermgr Play '' 2>&1)"
        sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
        echo "inplayback_raw_uri=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
        lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
        rm -f /tmp/.pcm_test.wav /tmp/.pcm_test.raw
    )
    [ -z "$KINDLE_RAW_PCM_TEST" ] && KINDLE_RAW_PCM_TEST="failed"

    # amixer
    KINDLE_AMIXER=$(amixer 2>&1 | head -20 || echo "n/a")
    KINDLE_AMIXER_SCONTROLS=$(amixer scontrols 2>&1 | head -10 || echo "n/a")

    # GStreamer plugin directory details
    # v0.1.5.33: separate writable test to avoid truncation
    KINDLE_GST_PLUGIN_DIR=$(
        echo "--- GStreamer libs ---"
        ls -la /usr/lib/libgstreamer* 2>/dev/null | head -5 || echo "no libgstreamer"
        echo "--- plugin dir ---"
        for d in /usr/lib/gstreamer-*/; do
            if [ -d "$d" ]; then
                echo "dir=$d"
                ls "$d" 2>/dev/null | head -15
            fi
        done
    )
    [ -z "$KINDLE_GST_PLUGIN_DIR" ] && KINDLE_GST_PLUGIN_DIR="n/a"
    KINDLE_GST_DIR_WRITABLE=$(
        for d in /usr/lib/gstreamer-*/; do
            if [ -d "$d" ]; then
                echo "dir=$d"
                if touch "${d}.__gst_test" 2>/dev/null; then
                    rm -f "${d}.__gst_test"
                    echo "writable=yes"
                else
                    echo "writable=no"
                fi
                echo "registry=$(ls -la ${d}registry.* 2>/dev/null || echo none)"
                echo "gst_ver_dir=$(basename $d)"
            fi
        done
    )
    [ -z "$KINDLE_GST_DIR_WRITABLE" ] && KINDLE_GST_DIR_WRITABLE="n/a"

    # com.lab126.kaf probe
    KINDLE_KAF_PROBE=$(capture lipc-probe com.lab126.kaf 2>/dev/null | head -30)
    [ -z "$KINDLE_KAF_PROBE" ] && KINDLE_KAF_PROBE="not found"

    # Socket / scripting tools
    KINDLE_SOCKET_TOOLS="socat=$(which socat 2>/dev/null || echo not_found) nc=$(which nc 2>/dev/null || echo not_found) python=$(which python 2>/dev/null || which python3 2>/dev/null || echo not_found) perl=$(which perl 2>/dev/null || echo not_found) busybox=$(which busybox 2>/dev/null || echo not_found) strace=$(which strace 2>/dev/null || echo not_found)"

    # v0.1.5.34 FIX: lipc-wait-event requires event-name (was missing '*').
    KINDLE_WAIT_EVENTS=$(
        echo "--- tts.orchestrator events (5s) ---"
        lipc-wait-event -s 5 -m com.lab126.tts.orchestrator '*' 2>&1 &
        WPID=$!
        sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
        echo '{ language_code = "en" }' | lipc-hash-prop com.lab126.tts.orchestrator checkVoice 2>/dev/null
        echo '{ Voice = "joanna", LanguageCode = "en_us" }' | lipc-hash-prop com.lab126.tts.orchestrator voices 2>/dev/null
        lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>/dev/null
        sleep 4 2>/dev/null || usleep 4000000 2>/dev/null
        wait $WPID 2>/dev/null
        echo "--- playermgr events (5s) ---"
        lipc-wait-event -s 5 -m com.lab126.playermgr '*' 2>&1 &
        WPID=$!
        sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
        lipc-set-prop com.lab126.playermgr Open 'tts://hello world' 2>/dev/null
        lipc-set-prop com.lab126.playermgr Play '' 2>/dev/null
        sleep 4 2>/dev/null || usleep 4000000 2>/dev/null
        wait $WPID 2>/dev/null
        echo "--- audiomgrd events (5s) ---"
        lipc-wait-event -s 5 -m com.lab126.audiomgrd '*' 2>&1 &
        WPID=$!
        sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
        lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>/dev/null
        sleep 4 2>/dev/null || usleep 4000000 2>/dev/null
        wait $WPID 2>/dev/null
    )
    [ -z "$KINDLE_WAIT_EVENTS" ] && KINDLE_WAIT_EVENTS="n/a"

    # v0.1.5.33: voice config files on device (v0.1.5.34: read full config)
    KINDLE_TTS_VOICE_CONFIGS=$(
        echo "--- /usr/lib/tts/ ---"
        find /usr/lib/tts/ -name '*.json' 2>/dev/null | head -20 || echo "not found"
        echo "--- English voice config ---"
        for f in /usr/lib/tts/english/*.json /usr/lib/tts/en_*/*.json; do
            if [ -f "$f" ]; then
                echo "file=$f"
                cat "$f" 2>/dev/null | head -30
            fi
        done
        echo "--- voice dirs ---"
        ls -d /usr/lib/tts/*/ 2>/dev/null || echo "none"
        echo "--- English liblanguage ---"
        ls -la /usr/lib/tts/english/liblanguage_english.so 2>/dev/null || echo "not found"
    )
    [ -z "$KINDLE_TTS_VOICE_CONFIGS" ] && KINDLE_TTS_VOICE_CONFIGS="n/a"

    # v0.1.5.34 FIX: lipc-hash-prop has no -w or -v flags. Use stdin pipe.
    KINDLE_TTS_HASH_WRITE=$(
        echo "--- write to supportedLanguages hash ---"
        sl=$(echo '{ language_code = "en" }' | lipc-hash-prop com.lab126.tts.orchestrator supportedLanguages 2>&1)
        echo "sl=$sl"
        echo "--- write to installedVoices hash ---"
        iv=$(echo '{ language_code = "en_us" }' | lipc-hash-prop com.lab126.tts.orchestrator installedVoices 2>&1)
        echo "iv=$iv"
        echo "--- read installedVoices ---"
        echo "iv_read=$(lipc-hash-prop -n com.lab126.tts.orchestrator installedVoices 2>&1 | head -20)"
    )
    [ -z "$KINDLE_TTS_HASH_WRITE" ] && KINDLE_TTS_HASH_WRITE="n/a"

    # v0.1.5.34: VoiceView / accessibility service probe
    KINDLE_VOICEVIEW_PROBE=$(
        echo "--- accessibility/voiceview LIPC services ---"
        lipc-probe -l 2>/dev/null | grep -iE 'voice|access|a11y|screen.?read|tts' | head -20
        echo "---"
        echo "--- com.lab126.voiceview probe ---"
        lipc-probe com.lab126.voiceview 2>&1 | head -20
        echo "--- com.lab126.accessibility probe ---"
        lipc-probe com.lab126.accessibility 2>&1 | head -20
        echo "--- com.lab126.tts probe ---"
        lipc-probe com.lab126.tts 2>&1 | head -20
        echo "--- pillow (UI framework) probe ---"
        lipc-probe com.lab126.pillow 2>&1 | head -20
        echo "--- full service list (voice/tts/a11y) ---"
        lipc-probe -l 2>/dev/null | grep -iE 'voice|tts|a11y|access|speak|screen.?read|pillow' | head -20
    )
    [ -z "$KINDLE_VOICEVIEW_PROBE" ] && KINDLE_VOICEVIEW_PROBE="n/a"

    # v0.1.5.34: user identity
    # Only report yes/no for root, not the actual username (privacy).
    KINDLE_IS_ROOT=$([ "$(id -u 2>/dev/null)" = '0' ] && echo yes || echo no)

    # v0.1.5.34: full English voice config
    KINDLE_VOICE_CONFIG_FULL=$(cat /usr/lib/tts/english/en_us_joanna24_a11y.json 2>/dev/null | head -40 || echo "n/a")

    # v0.1.5.34: probe libtts_engine.so and voice data files
    KINDLE_TTS_ENGINE_PROBE=$(
        echo "--- libtts_engine.so ---"
        ls -la /usr/lib/tts/libtts_engine.so 2>/dev/null || echo "not found"
        echo "--- strings from libtts_engine.so (speak/synth/init) ---"
        strings /usr/lib/tts/libtts_engine.so 2>/dev/null | grep -iE 'speak|synth|init|play|audio|text|voice|tts' | head -20 || echo "no strings cmd"
        echo "--- English voice data ---"
        ls -la /mnt/base-us/voice/english/ 2>/dev/null | head -10 || echo "not found"
        ls -la /usr/lib/tts/english/ 2>/dev/null | head -10 || echo "not found"
    )
    [ -z "$KINDLE_TTS_ENGINE_PROBE" ] && KINDLE_TTS_ENGINE_PROBE="n/a"

    # audiomgrd socket analysis
    KINDLE_AUDIOMGRD_NET="n/a"
    if echo "$KINDLE_AUDIOMGRD_PID" | grep -qE '^[0-9]+$'; then
        KINDLE_AUDIOMGRD_NET=$(
            echo "--- audiomgrd socket fds ---"
            ls -la /proc/$KINDLE_AUDIOMGRD_PID/fd/ 2>/dev/null | grep socket | head -10
            echo "--- socket inodes ---"
            for sock in $(ls -la /proc/$KINDLE_AUDIOMGRD_PID/fd/ 2>/dev/null | grep socket | sed 's/.*\[\(.*\)\]/\1/'); do
                grep "$sock" /proc/net/unix 2>/dev/null
                grep "$sock" /proc/net/tcp 2>/dev/null
                grep "$sock" /proc/net/udp 2>/dev/null
            done | head -20
        )
        [ -z "$KINDLE_AUDIOMGRD_NET" ] && KINDLE_AUDIOMGRD_NET="n/a"
    fi

    KINDLE_SECTION="  kindle_lipc_available: yes
  kindle_bt_service: ${KINDLE_BT_SERVICE}
  kindle_bt_prop: ${KINDLE_BT_PROP:-n/a}
  kindle_bt_enabled: ${KINDLE_BT_ENABLED:-unknown}
  kindle_bt_paired: ${KINDLE_BT_PAIRED}
  kindle_bt_connected: ${KINDLE_BT_CONNECTED}
  kindle_dev_snd: ${KINDLE_DEV_SND}
  kindle_aplay_l: ${KINDLE_APLAY_L}
  kindle_aplay_L: ${KINDLE_APLAY_LP}
  kindle_proc_asound_pcm: ${KINDLE_PROC_ASOUND_PCM}
  kindle_audio_procs: ${KINDLE_AUDIO_PROCS}
  kindle_pulseaudio: ${KINDLE_PULSEAUDIO}
  kindle_pa_sinks: ${KINDLE_PA_SINKS}
  kindle_lipc_audio: ${KINDLE_LIPC_AUDIO}
  kindle_lipc_audio_svcs: ${KINDLE_LIPC_AUDIO_SVCS}
  kindle_audio_bins:
$(printf '%b' "$KINDLE_AUDIO_BINS")  kindle_snd_modules: ${KINDLE_SND_MODULES}
  kindle_asound_conf: ${KINDLE_ASOUND_CONF}
  kindle_btfd_pid: ${KINDLE_BTFD_PID}
  kindle_btfd_cmdline: ${KINDLE_BTFD_CMDLINE}
  kindle_btfd_fds: ${KINDLE_BTFD_FDS}
  kindle_btfd_sockets: ${KINDLE_BTFD_SOCKETS}
  kindle_btfd_maps: ${KINDLE_BTFD_MAPS}
  kindle_hci_devs: ${KINDLE_HCI_DEVS}
  kindle_sys_bt: ${KINDLE_SYS_BT}
  kindle_hciconfig: ${KINDLE_HCICONFIG}
  kindle_dbus_running: ${KINDLE_DBUS_RUNNING}
  kindle_dbus_bluez: ${KINDLE_DBUS_BLUEZ}
  kindle_bt_sockets: ${KINDLE_BT_SOCKETS}
  kindle_lipc_tts_props: ${KINDLE_LIPC_TTS_PROPS}
  kindle_lipc_audio_player: ${KINDLE_LIPC_AUDIO_PLAYER}
  kindle_audiomgrd_pid: ${KINDLE_AUDIOMGRD_PID}
  kindle_audiomgrd_cmdline: ${KINDLE_AUDIOMGRD_CMDLINE}
  kindle_audiomgrd_fds: ${KINDLE_AUDIOMGRD_FDS}
  kindle_audiomgrd_maps: ${KINDLE_AUDIOMGRD_MAPS}
  kindle_lipc_playermgr: ${KINDLE_LIPC_PLAYERMGR}
  kindle_lipc_audiomgrd: ${KINDLE_LIPC_AUDIOMGRD}
  kindle_playermgr_inplayback: ${KINDLE_PLAYERMGR_INPLAYBACK}
  kindle_playermgr_tts_state: ${KINDLE_PLAYERMGR_TTS_STATE}
  kindle_audiomgrd_output_connected: ${KINDLE_AUDIOMGRD_OUTPUT_CONNECTED}
  kindle_audiomgrd_current_output: ${KINDLE_AUDIOMGRD_CURRENT_OUTPUT}
  kindle_audiomgrd_volume: ${KINDLE_AUDIOMGRD_VOLUME}
  kindle_asound_conf_full: ${KINDLE_ASOUND_CONF_FULL}
  kindle_dev_snd_full: ${KINDLE_DEV_SND_FULL}
  kindle_lipc_all_services: ${KINDLE_LIPC_ALL_SERVICES}
  kindle_lipc_test: ${KINDLE_LIPC_TEST}
  kindle_audiomgrd_err: ${KINDLE_AUDIOMGRD_ERR}
  kindle_gst_plugins: ${KINDLE_GST_PLUGINS}
  kindle_tts_orchestrator: ${KINDLE_TTS_ORCHESTRATOR}
  kindle_audiomgrd_is_started: ${KINDLE_AUDIOMGRD_IS_STARTED}
  kindle_gst_tools: ${KINDLE_GST_TOOLS}
  kindle_shm: ${KINDLE_SHM}
  kindle_a2dp_sockets: ${KINDLE_A2DP_SOCKETS}
  kindle_gst_inspect_ttssrc: ${KINDLE_GST_INSPECT_TTSSRC}
  kindle_gst_inspect_mixersink: ${KINDLE_GST_INSPECT_MIXERSINK}
  kindle_tts_test: ${KINDLE_TTS_TEST}
  kindle_lipc_avrcp: ${KINDLE_LIPC_AVRCP}
  kindle_tts_orch_started: ${KINDLE_TTS_ORCH_STARTED}
  kindle_tts_orch_hash_cmd: ${KINDLE_TTS_ORCH_HASH_CMD}
  kindle_tts_orch_langs: ${KINDLE_TTS_ORCH_LANGS}
  kindle_tts_orch_voices: ${KINDLE_TTS_ORCH_VOICES}
  kindle_tts_orch_installed: ${KINDLE_TTS_ORCH_INSTALLED}
  kindle_tts_event_test: ${KINDLE_TTS_EVENT_TEST}
  kindle_tts_check_voice: ${KINDLE_TTS_CHECK_VOICE}
  kindle_tts_uri_test: ${KINDLE_TTS_URI_TEST}
  kindle_native_tts_test: ${KINDLE_NATIVE_TTS_TEST}
  kindle_raw_pcm_test: ${KINDLE_RAW_PCM_TEST}
  kindle_amixer: ${KINDLE_AMIXER}
  kindle_amixer_scontrols: ${KINDLE_AMIXER_SCONTROLS}
  kindle_gst_plugin_dir: ${KINDLE_GST_PLUGIN_DIR}
  kindle_gst_dir_writable: ${KINDLE_GST_DIR_WRITABLE}
  kindle_kaf_probe: ${KINDLE_KAF_PROBE}
  kindle_socket_tools: ${KINDLE_SOCKET_TOOLS}
  kindle_wait_events: ${KINDLE_WAIT_EVENTS}
  kindle_tts_voice_configs: ${KINDLE_TTS_VOICE_CONFIGS}
  kindle_tts_hash_write: ${KINDLE_TTS_HASH_WRITE}
  kindle_voiceview_probe: ${KINDLE_VOICEVIEW_PROBE}
  kindle_is_root: ${KINDLE_IS_ROOT}
  kindle_voice_config_full: ${KINDLE_VOICE_CONFIG_FULL}
  kindle_tts_engine_probe: ${KINDLE_TTS_ENGINE_PROBE}
  kindle_audiomgrd_net: ${KINDLE_AUDIOMGRD_NET}"
    [ -n "$KINDLE_LIPC_SERVICES" ] && KINDLE_SECTION="${KINDLE_SECTION}
  kindle_lipc_services: ${KINDLE_LIPC_SERVICES}"
    [ -n "$KINDLE_BT_PROPS" ] && KINDLE_SECTION="${KINDLE_SECTION}
  kindle_bt_props:
$(printf '%b' "$KINDLE_BT_PROPS")"
fi

# PocketBook extras
POCKETBOOK_SECTION=""
if [ "$PLATFORM" = "pocketbook" ]; then
    # Device config (model, variant, BT name)
    PB_DEVICE_CFG="not found"
    [ -f /ebrmain/config/device.cfg ] && PB_DEVICE_CFG=$(cat /ebrmain/config/device.cfg 2>/dev/null)

    # ALSA configuration
    PB_ASOUND_CONF="not found"
    [ -f /etc/asound.conf ] && PB_ASOUND_CONF=$(cat /etc/asound.conf 2>/dev/null)

    # ALSA top-level config file existence
    PB_ALSA_CONF_PATH="not found"
    for _ac in /usr/share/alsa/alsa.conf /etc/alsa/alsa.conf; do
        if [ -f "$_ac" ]; then
            PB_ALSA_CONF_PATH="$_ac"
            break
        fi
    done

    # /proc/asound/pcm - shows all PCM subdevices
    PB_PROC_ASOUND_PCM=$(cat /proc/asound/pcm 2>/dev/null || echo "not found")

    # Audio processes running
    PB_AUDIO_PROCS=$(ps 2>/dev/null | grep -iE 'audio|alsa|mixer|player|sound|loopback|dmix' | grep -v grep | head -10 || echo "none")

    # wav-play last stderr (captured by ttsengine.lua to /tmp/.gst_status)
    PB_WAV_PLAY_LOG="none"
    [ -f /tmp/.gst_status ] && PB_WAV_PLAY_LOG=$(cat /tmp/.gst_status 2>/dev/null | tail -30)

    # Bundled wav-play and libasound presence check
    PB_WAV_PLAY_BIN=$(ls -la "$PLUGIN_DIR/wav-play/wav-play" 2>/dev/null || echo "not found")
    PB_WAV_PLAY_LIBASOUND=$(ls -la "$PLUGIN_DIR/wav-play/lib/libasound.so"* 2>/dev/null || echo "not found")
    PB_SYSTEM_LIBASOUND=$(ls -la /usr/lib/libasound.so* 2>/dev/null || echo "not found")

    # Bundled ld-linux presence
    PB_LD_LINUX=$(ls -la "$PLUGIN_DIR/espeak-ng/lib/ld-linux"* 2>/dev/null || echo "not found")

    # ALSA mixer state on hw:0 (may not have amixer, use /proc fallback)
    PB_MIXER=$(amixer -c 0 contents 2>/dev/null | head -40 || cat /proc/asound/card0/codec_reg 2>/dev/null | head -20 || echo "n/a")

    # wav-play smoke test: verify the binary loads (ld-linux + libasound)
    # WITHOUT playing audio.  Running wav-play with no arguments prints
    # usage and exits.  This avoids calling setup_mixer() which unmutes
    # hw:0 switches and corrupts PocketBook speaker state on PB700c.
    PB_SMOKE_TEST="skipped (no bundled wav-play)"
    if [ -x "$PLUGIN_DIR/wav-play/wav-play" ] || [ -f "$PLUGIN_DIR/wav-play/wav-play" ]; then
        _ld=""
        for _l in "$PLUGIN_DIR/espeak-ng/lib/ld-linux"*; do
            [ -f "$_l" ] && _ld="$_l" && break
        done
        _wav_lib="$PLUGIN_DIR/wav-play/lib"
        _esp_lib="$PLUGIN_DIR/espeak-ng/lib"
        _alsa_env=""
        for _ac in /usr/share/alsa/alsa.conf /etc/alsa/alsa.conf /etc/asound.conf; do
            if [ -f "$_ac" ]; then
                _alsa_env="ALSA_CONFIG_PATH=$_ac"
                break
            fi
        done
        for _pd in /usr/lib/alsa-lib /usr/lib/arm-linux-gnueabihf/alsa-lib /usr/lib/alsa; do
            if [ -d "$_pd" ]; then
                _alsa_env="$_alsa_env ALSA_PLUGIN_DIR=$_pd"
                break
            fi
        done
        # Invoke wav-play with no file argument: prints usage to stderr,
        # exits 1.  This exercises the ld-linux + libasound load path
        # without opening any ALSA device or touching the mixer.
        if [ -n "$_ld" ] && [ -d "$_wav_lib" ]; then
            PB_SMOKE_TEST=$(env $_alsa_env $_ld --library-path "$_wav_lib:$_esp_lib:/usr/lib:/lib" "$PLUGIN_DIR/wav-play/wav-play" 2>&1; echo "exit_code=$?")
        else
            PB_SMOKE_TEST=$("$PLUGIN_DIR/wav-play/wav-play" 2>&1; echo "exit_code=$?")
        fi
        [ -z "$PB_SMOKE_TEST" ] && PB_SMOKE_TEST="(empty output) exit_code=$?"
    fi

    # InkView audio daemon diagnostics: check if mpd.app (PocketBook media
    # player daemon) is running and if libinkview.so exports PlayFile.
    PB_MPD_PROCS=$(ps 2>/dev/null | grep -E 'mpd\.app|mpd_start|mediaplayer' | grep -v grep | head -5 || echo "none")
    PB_INKVIEW_LIB="not found"
    for _iv in /usr/lib/libinkview.so /usr/lib/libinkview.so.1 /lib/libinkview.so; do
        if [ -f "$_iv" ]; then
            PB_INKVIEW_LIB="$_iv ($(ls -la "$_iv" 2>/dev/null | awk '{print $5}') bytes)"
            # Check if PlayFile symbol is exported
            if command -v nm >/dev/null 2>&1; then
                _pf=$(nm -D "$_iv" 2>/dev/null | grep -i PlayFile | head -3)
                [ -n "$_pf" ] && PB_INKVIEW_LIB="$PB_INKVIEW_LIB playfile_sym=yes" || PB_INKVIEW_LIB="$PB_INKVIEW_LIB playfile_sym=no(nm)"
            elif command -v grep >/dev/null 2>&1; then
                grep -q PlayFile "$_iv" 2>/dev/null && PB_INKVIEW_LIB="$PB_INKVIEW_LIB playfile_str=yes" || PB_INKVIEW_LIB="$PB_INKVIEW_LIB playfile_str=no"
            fi
            break
        fi
    done

    POCKETBOOK_SECTION="
── PocketBook ──
  device_cfg:
$(echo "$PB_DEVICE_CFG" | sed 's/^/    /')
  asound_conf:
$(echo "$PB_ASOUND_CONF" | sed 's/^/    /')
  alsa_conf_path: ${PB_ALSA_CONF_PATH}
  proc_asound_pcm: ${PB_PROC_ASOUND_PCM}
  audio_processes: ${PB_AUDIO_PROCS}
  wav_play_last_log:
$(echo "$PB_WAV_PLAY_LOG" | sed 's/^/    /')
  wav_play_bin: ${PB_WAV_PLAY_BIN}
  wav_play_libasound: ${PB_WAV_PLAY_LIBASOUND}
  system_libasound: ${PB_SYSTEM_LIBASOUND}
  ld_linux: ${PB_LD_LINUX}
  mixer_state:
$(echo "$PB_MIXER" | sed 's/^/    /')
  wav_play_smoke_test:
$(echo "$PB_SMOKE_TEST" | sed 's/^/    /')
  mpd_daemon: ${PB_MPD_PROCS}
  inkview_lib: ${PB_INKVIEW_LIB}"
fi

# Android extras
ANDROID_SECTION=""
if [ "$PLATFORM" = "android" ]; then
    ANDROID_SECTION="  android_version: $(capture getprop ro.build.version.release)
  android_sdk: $(capture getprop ro.build.version.sdk)
  android_brand: $(capture getprop ro.product.brand)
  android_device: $(capture getprop ro.product.model)
  has_tts_helper_dex: $(bool file_exists "$PLUGIN_DIR/android/tts_helper.dex")"
fi

# Resources
MEMINFO=$(head -5 /proc/meminfo 2>/dev/null || echo "not available")
DISK_TMP=$(df -h /tmp 2>/dev/null | tail -1 || echo "not available")
TMP_WRITABLE=$(bool sh -c 'touch /tmp/.audiobook_test && rm /tmp/.audiobook_test')

# Plugin settings (read from LuaSettings file if present)
SETTINGS_SECTION="  (not available -- requires KOReader runtime)"
for d in \
    "$(dirname "$PLUGIN_DIR")/../../settings/" \
    "$(dirname "$PLUGIN_DIR")/../settings/" \
    "/mnt/onboard/.adds/koreader/settings/" \
    "/mnt/us/koreader/settings/" \
    "/mnt/ext1/applications/koreader/settings/" \
    "/sdcard/koreader/settings/"
do
    SETTINGS_FILE="${d}audiobook.lua"
    if [ -f "$SETTINGS_FILE" ]; then
        SETTINGS_SECTION=$(grep -E '(tts_backend|speech_rate|speech_pitch|speech_volume|highlight_style|auto_advance|highlight_words|highlight_sentences|espeak_cold_start|keep_playing_on_lid_close|bt_media_control|piper_model)' "$SETTINGS_FILE" 2>/dev/null | sed 's/^/  /' || echo "  (parse error)")
        break
    fi
done

# ── Build report ─────────────────────────────────────────────────────

REPORT="=== Audiobook Read-Along Bug Report (v${PLUGIN_VERSION}) ===
Generated: ${TIMESTAMP}
Method: generate-report.sh (standalone)

── Device ──
  platform: ${PLATFORM}
  model: ${MODEL}
  arch: ${ARCH}
  uname: ${UNAME}
${ANDROID_SECTION:+${ANDROID_SECTION}
}
── KOReader ──
  koreader_version: ${KOREADER_VERSION}

── Plugin ──
  plugin_version: ${PLUGIN_VERSION}
  plugin_dir: ${PLUGIN_DIR}
  has_bundled_espeak: ${HAS_BUNDLED_ESPEAK}
  has_bundled_piper: ${HAS_BUNDLED_PIPER}
  piper_models: ${PIPER_MODELS}

── Plugin Settings ──
${SETTINGS_SECTION}

── Audio & TTS ──
  tts_in_path:
$(printf '%b' "$TTS_CMDS")  players_in_path:
$(printf '%b' "$PLAYER_CMDS")  alsa_cards: ${ALSA_CARDS}
  alsa_pcm_devices: ${ALSA_PCM_DEVICES}
  bt_available: ${BT_AVAILABLE}
  bt_hci_devices: ${BT_HCI_DEVICES}
  bt_paired_devices: ${BT_PAIRED}
  bt_connected_devices: ${BT_CONNECTED}
  bt_adapter_info: ${BT_ADAPTER_INFO}
  bt_sleep_test: ${BT_SLEEP_TEST}
  bt_hcitool_con: ${BT_HCITOOL_CON}
  bt_daemon: ${BT_DAEMON}
  gst_bt_sink: ${GST_BT_SINK}
  gst_audio_sinks: ${GST_AUDIO_SINKS}
  bt_abstract_socket: ${BT_SOCKET}
${KINDLE_SECTION:+${KINDLE_SECTION}
}${POCKETBOOK_SECTION:+${POCKETBOOK_SECTION}
}  tmp_writable: ${TMP_WRITABLE}

── Resources ──
  meminfo:
$(echo "$MEMINFO" | sed 's/^/    /')
  disk_tmp: ${DISK_TMP}

=== End of Bug Report ==="

# ── Save ─────────────────────────────────────────────────────────────

FILEPATH="${SAVE_DIR}/${FILENAME}"
if ! printf '%s\n' "$REPORT" > "$FILEPATH" 2>/dev/null; then
    # Fallback to /tmp
    FILEPATH="/tmp/${FILENAME}"
    printf '%s\n' "$REPORT" > "$FILEPATH"
fi

# Print to stdout as well
printf '%s\n' "$REPORT"
echo ""
echo "Report saved to: ${FILEPATH}"
