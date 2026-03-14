#!/bin/sh
# Get touchscreen info on Kobo
echo "=== uevent ==="
cat /sys/class/input/input1/device/uevent 2>/dev/null

echo "=== abs ranges ==="
# ABS_MT_POSITION_X = 53 (0x35)
echo "ABS_MT_POSITION_X:"
cat /sys/class/input/event1/device/abs/53 2>/dev/null || echo "not found at 53"
cat /sys/class/input/event1/device/abs/35 2>/dev/null || echo "not found at 35"

# ABS_MT_POSITION_Y = 54 (0x36)  
echo "ABS_MT_POSITION_Y:"
cat /sys/class/input/event1/device/abs/54 2>/dev/null || echo "not found at 54"
cat /sys/class/input/event1/device/abs/36 2>/dev/null || echo "not found at 36"

# ABS_MT_TRACKING_ID = 57 (0x39)
echo "ABS_MT_TRACKING_ID:"
cat /sys/class/input/event1/device/abs/57 2>/dev/null || echo "not found at 57"

# ABS_MT_SLOT = 47 (0x2f)
echo "ABS_MT_SLOT:"
cat /sys/class/input/event1/device/abs/47 2>/dev/null || echo "not found at 47"

echo "=== all abs ==="
ls /sys/class/input/event1/device/abs/ 2>/dev/null
