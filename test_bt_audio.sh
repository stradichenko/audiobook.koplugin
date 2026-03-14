#!/bin/sh
# Quick BT audio test for Kobo — plays a 440Hz sine wave through mtkbtmwrpcaudiosink
# Usage: sh test_bt_audio.sh
# This verifies the BT speaker can produce sound independently of the plugin.

echo "=== BT Audio Test ==="

# Check if a BT device is connected
echo "Checking BT connection..."
if command -v dbus-send >/dev/null 2>&1; then
    CONNECTED=$(dbus-send --system --print-reply \
        --dest=com.kobo.mtk.bluedroid \
        /org/bluez/hci0/dev_C0_86_B3_D9_35_A9 \
        org.freedesktop.DBus.Properties.Get \
        string:"org.bluez.Device1" string:"Connected" 2>/dev/null | grep -c "true")
    if [ "$CONNECTED" -gt 0 ]; then
        echo "  BT device connected: YES"
    else
        echo "  BT device connected: NO (or different device address)"
        echo "  Trying anyway..."
    fi
fi

# Kill any existing gst-launch
echo "Killing any existing gst-launch..."
killall -9 gst-launch-1.0 2>/dev/null
sleep 0.5

# Check socket is free
if grep -q "@kobo:mtkbtmwrpc" /proc/net/unix 2>/dev/null; then
    echo "  WARNING: mtkbtmwrpc socket still held!"
    sleep 1
fi

# Generate a 3-second 440Hz sine wave (16kHz mono 16-bit PCM WAV)
echo "Generating test tone..."
TESTFILE="/tmp/bt_test_tone.wav"

# Use python3 or dd to generate a simple tone
if command -v python3 >/dev/null 2>&1; then
    python3 -c "
import struct, math, sys
sr = 16000; dur = 3; freq = 440; amp = 16000
n = sr * dur
# WAV header
data_size = n * 2
hdr = struct.pack('<4sI4s4sIHHIIHH4sI',
    b'RIFF', 36 + data_size, b'WAVE',
    b'fmt ', 16, 1, 1, sr, sr * 2, 2, 16,
    b'data', data_size)
with open('$TESTFILE', 'wb') as f:
    f.write(hdr)
    for i in range(n):
        s = int(amp * math.sin(2 * math.pi * freq * i / sr))
        f.write(struct.pack('<h', s))
print('Test tone generated: %s' % '$TESTFILE')
"
else
    # Fallback: generate 3 seconds of raw PCM silence with periodic clicks
    echo "python3 not available, using simple noise pattern"
    dd if=/dev/urandom bs=32000 count=3 2>/dev/null > /tmp/bt_test_raw.pcm
    # Create WAV header (16kHz mono 16-bit)
    printf 'RIFF' > "$TESTFILE"
    printf '\x24\x77\x00\x00' >> "$TESTFILE"  # file size - 8
    printf 'WAVE' >> "$TESTFILE"
    printf 'fmt \x10\x00\x00\x00' >> "$TESTFILE"  # chunk size 16
    printf '\x01\x00\x01\x00' >> "$TESTFILE"  # PCM, mono
    printf '\x80\x3e\x00\x00' >> "$TESTFILE"  # 16000 Hz
    printf '\x00\x7d\x00\x00' >> "$TESTFILE"  # byte rate 32000
    printf '\x02\x00\x10\x00' >> "$TESTFILE"  # block align 2, 16-bit
    printf 'data\x00\x77\x00\x00' >> "$TESTFILE"
    cat /tmp/bt_test_raw.pcm >> "$TESTFILE"
fi

echo "Playing through mtkbtmwrpcaudiosink..."
echo "(Should hear a tone for 3 seconds)"

# Play via GStreamer
gst-launch-1.0 filesrc location="$TESTFILE" \
    ! wavparse \
    ! audioconvert ! audioresample \
    ! "audio/x-raw,format=S16LE,rate=48000,channels=2" \
    ! mtkbtmwrpcaudiosink &
GST_PID=$!

echo "  gst-launch PID: $GST_PID"

# Wait for it to finish (max 10 seconds)
for i in $(seq 1 20); do
    if ! kill -0 $GST_PID 2>/dev/null; then
        echo "  gst-launch exited after ~$((i / 2))s"
        break
    fi
    usleep 500000
done

# Check if still running
if kill -0 $GST_PID 2>/dev/null; then
    echo "  gst-launch still running after 10s, killing..."
    kill -9 $GST_PID 2>/dev/null
fi

echo ""
echo "=== Test Complete ==="
echo "If you heard a tone, BT audio works."
echo "If no tone, the BT speaker may need re-pairing or volume adjustment."

# Cleanup
rm -f "$TESTFILE" /tmp/bt_test_raw.pcm
