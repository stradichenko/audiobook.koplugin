#!/bin/sh
# Tap simulator for Kobo Libra 2 (monza)
X=${1:-632}
Y=${2:-840}
DEV=/dev/input/event1

# Write a single 16-byte input_event: 8-byte zero timestamp + type(2) + code(2) + value(4) LE
ev() {
    local t=$1 c=$2 v=$3
    if [ "$v" -lt 0 ] 2>/dev/null; then
        v=$((v + 4294967296))
    fi
    printf '\0\0\0\0\0\0\0\0'
    printf "$(printf '\\%03o\\%03o' $((t%256)) $((t/256%256)))"
    printf "$(printf '\\%03o\\%03o' $((c%256)) $((c/256%256)))"
    printf "$(printf '\\%03o\\%03o\\%03o\\%03o' $((v%256)) $((v/256%256)) $((v/65536%256)) $((v/16777216%256)))"
}

# Touch down
{
ev 3 47 0       # ABS_MT_SLOT 0
ev 3 57 100     # ABS_MT_TRACKING_ID 100
ev 3 53 $X      # ABS_MT_POSITION_X
ev 3 54 $Y      # ABS_MT_POSITION_Y
ev 3 48 1       # ABS_MT_TOUCH_MAJOR 1
ev 1 330 1      # BTN_TOUCH 1
ev 0 0 0        # SYN_REPORT
} > "$DEV"

usleep 50000

# Touch up
{
ev 3 47 0       # ABS_MT_SLOT 0
ev 3 57 -1      # ABS_MT_TRACKING_ID -1
ev 1 330 0      # BTN_TOUCH 0
ev 0 0 0        # SYN_REPORT
} > "$DEV"

echo "Tap ($X,$Y) done"
