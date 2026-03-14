#!/bin/sh
# Inject a tap at screen coordinates (x, y) on Kobo touchscreen
# Uses evtest --info style approach, then writes raw events
# 
# For Elan touchscreen on Kobo Libra 2 (Protocol B multitouch):
# struct input_event is 16 bytes on 32-bit ARM:
#   4 bytes: tv_sec
#   4 bytes: tv_usec  
#   2 bytes: type
#   2 bytes: code
#   4 bytes: value

TAP_X=${1:-632}   # Default: center of 1264-wide screen
TAP_Y=${2:-840}   # Default: center of 1680-tall screen
DEV=/dev/input/event1

# Helper to write one input_event (16 bytes) using printf
# Args: type code value
write_event() {
    local type=$1
    local code=$2
    local value=$3
    
    # Get current time
    local sec=$(date +%s)
    local usec=0
    
    # Pack as little-endian 32-bit integers using printf
    # sec (4 bytes LE) + usec (4 bytes LE) + type (2 bytes LE) + code (2 bytes LE) + value (4 bytes LE, signed)
    printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $((sec & 0xff)) $(((sec>>8) & 0xff)) $(((sec>>16) & 0xff)) $(((sec>>24) & 0xff)))"
    printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $((usec & 0xff)) $(((usec>>8) & 0xff)) $(((usec>>16) & 0xff)) $(((usec>>24) & 0xff)))"
    printf "$(printf '\\x%02x\\x%02x' $((type & 0xff)) $(((type>>8) & 0xff)))"
    printf "$(printf '\\x%02x\\x%02x' $((code & 0xff)) $(((code>>8) & 0xff)))"
    printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $((value & 0xff)) $(((value>>8) & 0xff)) $(((value>>16) & 0xff)) $(((value>>24) & 0xff)))"
}

# Event types and codes
EV_SYN=0
EV_ABS=3
EV_KEY=1
SYN_REPORT=0
ABS_MT_TRACKING_ID=57   # 0x39
ABS_MT_POSITION_X=53    # 0x35
ABS_MT_POSITION_Y=54    # 0x36
ABS_MT_TOUCH_MAJOR=48   # 0x30
ABS_MT_PRESSURE=58      # 0x3a
BTN_TOUCH=330           # 0x14a

echo "Tapping at ($TAP_X, $TAP_Y) on $DEV"

# Touch down
{
write_event $EV_ABS $ABS_MT_TRACKING_ID 1
write_event $EV_ABS $ABS_MT_POSITION_X $TAP_X
write_event $EV_ABS $ABS_MT_POSITION_Y $TAP_Y
write_event $EV_ABS $ABS_MT_TOUCH_MAJOR 1
write_event $EV_ABS $ABS_MT_PRESSURE 50
write_event $EV_KEY $BTN_TOUCH 1
write_event $EV_SYN $SYN_REPORT 0
} > $DEV

usleep 80000   # 80ms hold

# Touch up
{
write_event $EV_ABS $ABS_MT_TRACKING_ID -1
write_event $EV_KEY $BTN_TOUCH 0
write_event $EV_SYN $SYN_REPORT 0
} > $DEV

echo "Tap sent"
