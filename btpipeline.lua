--[[--
Bluetooth Persistent GStreamer Pipeline Manager
Manages a long-lived GStreamer pipeline that reads WAV data from a FIFO,
streams continuous silence during idle, and handles audio sink recovery.

@module btpipeline
--]]

local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local logger = require("logger")
local time = require("ui/time")

-- Declare C functions for pipe resize (may already be declared)
pcall(function()
    ffi.cdef[[
        int open(const char *pathname, int flags);
        int close(int fd);
        long write(int fd, const void *buf, unsigned long count);
        int fcntl(int fd, int cmd, ...);
    ]]
end)

local WavUtils = nil  -- lazy-loaded

local BtPipeline = {}

-- ── Constants ────────────────────────────────────────────────────────

BtPipeline.PIPELINE_FIFO          = "/tmp/audiobook_fifo"
BtPipeline.PIPELINE_SCRIPT        = "/tmp/audiobook_pipeline.sh"
BtPipeline.PIPELINE_PID_FILE      = "/tmp/audiobook_pipeline.pid"
BtPipeline.PIPELINE_LOG           = "/tmp/audiobook_pipeline.log"
BtPipeline.SILENCE_FILE           = "/tmp/audiobook_silence.wav"
BtPipeline.SILENCE_DURATION_MS    = 500
BtPipeline.KEEPALIVE_INTERVAL     = 2.0   -- seconds between silence injections

-- Pipe-buffer delay: how long audio takes to pass through the OS pipe.
-- Smaller pipes (4KB via fcntl) give lower latency.
BtPipeline.PIPE_BUFFER_DELAY_64KB = 1500  -- ms (default pipe size)
BtPipeline.PIPE_BUFFER_DELAY_16KB = 370   -- ms (after F_SETPIPE_SZ 16384)

-- ── Constructor ──────────────────────────────────────────────────────

function BtPipeline:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self

    o._pipeline_running = false
    o._pipeline_starting = false
    o._keepalive_running = false
    o._process_watcher_running = false
    o._pipe_buffer_delay = BtPipeline.PIPE_BUFFER_DELAY_64KB
    o._fd_fifo = nil   -- cached FIFO fd for writes

    return o
end

--- Lazy-load WavUtils.
local function wavutils()
    if not WavUtils then
        local info = debug.getinfo(1, "S")
        local dir = info.source:match("^@(.*/)[^/]*$") or "./"
        WavUtils = dofile(dir .. "wavutils.lua")
    end
    return WavUtils
end

-- ── Pipeline script ──────────────────────────────────────────────────

--[[--
Write the pipeline shell script.
The script:
  1. Generates a short silence WAV as seed.
  2. Creates the FIFO.
  3. Cats silence into FIFO (keeps write side open).
  4. Spawns gst-launch-1.0 with filesrc reading from FIFO.
  5. Stores gst PID and resizes the pipe to 4KB for low latency.

@param sample_rate number  WAV sample rate (default 22050)
@param bt_sink string  GStreamer BT sink element
@return string  Path to the script
--]]
function BtPipeline:_writeScript(sample_rate, bt_sink)
    sample_rate = sample_rate or 22050
    bt_sink = bt_sink or "mtkbtmwrpcaudiosink"

    local script = string.format([=[#!/bin/sh
FIFO="%s"
PID_FILE="%s"
LOG_FILE="%s"
SILENCE_FILE="%s"

# Generate silence WAV seed
SOX=$(which sox 2>/dev/null)
if [ -n "$SOX" ]; then
    $SOX -n -r %d -c 1 -b 16 "$SILENCE_FILE" trim 0.0 0.5 2>/dev/null
fi

# Fallback: if SOX unavailable or failed, generate via dd
if [ ! -f "$SILENCE_FILE" ] || [ $(stat -c%%s "$SILENCE_FILE" 2>/dev/null || echo 0) -lt 45 ]; then
    {
        printf 'RIFF'
        printf '\\x24\\xAC\\x00\\x00'
        printf 'WAVEfmt '
        printf '\\x10\\x00\\x00\\x00'
        printf '\\x01\\x00'
        printf '\\x01\\x00'
        printf '\\x22\\x56\\x00\\x00'
        printf '\\x44\\xAC\\x00\\x00'
        printf '\\x02\\x00'
        printf '\\x10\\x00'
        printf 'data'
        printf '\\x00\\xAC\\x00\\x00'
        dd if=/dev/zero bs=44032 count=1 2>/dev/null
    } > "$SILENCE_FILE"
fi

# Clean + create FIFO
rm -f "$FIFO" "$PID_FILE"
mkfifo "$FIFO"

# Seed pipeline with silence (keep FIFO open in background)
cat "$SILENCE_FILE" > "$FIFO" &
CAT_PID=$!

# Launch gst-launch-1.0 in background
gst-launch-1.0 -q \
    filesrc location="$FIFO" \
    ! wavparse ignore-length=true \
    ! audioconvert \
    ! audioresample \
    ! %s \
    sync=true \
    > "$LOG_FILE" 2>&1 &
GST_PID=$!

echo "$GST_PID" > "$PID_FILE"

wait $CAT_PID 2>/dev/null

# Try to resize pipe buffer to 4KB for low latency
if command -v python3 >/dev/null 2>&1; then
    python3 -c "
import fcntl, os, struct
fd = os.open('$FIFO', os.O_WRONLY | os.O_NONBLOCK)
try:
    fcntl.fcntl(fd, 1031, 4096)
except: pass
os.close(fd)
" 2>/dev/null
fi

wait $GST_PID 2>/dev/null
rm -f "$FIFO" "$PID_FILE"
]=], self.PIPELINE_FIFO, self.PIPELINE_PID_FILE, self.PIPELINE_LOG,
     self.SILENCE_FILE, sample_rate, bt_sink)

    local sf = io.open(self.PIPELINE_SCRIPT, "w")
    if sf then
        sf:write(script)
        sf:close()
        os.execute('chmod +x "' .. self.PIPELINE_SCRIPT .. '"')
    end
    return self.PIPELINE_SCRIPT
end

-- ── Pipeline lifecycle ───────────────────────────────────────────────

--[[--
Start the persistent GStreamer pipeline.
Writes the script, launches it, waits for the PID file.

@param sample_rate number  WAV sample rate
@param bt_sink string  GStreamer sink element
@param callback function  Optional callback on ready (receives pipe_buffer_delay)
--]]
function BtPipeline:start(sample_rate, bt_sink, callback)
    if self._pipeline_running or self._pipeline_starting then
        if callback then callback(self._pipe_buffer_delay) end
        return
    end
    self._pipeline_starting = true

    self:_writeScript(sample_rate, bt_sink)
    os.execute(string.format('/bin/sh "%s" &', self.PIPELINE_SCRIPT))
    logger.warn("BtPipeline: Pipeline starting...")

    local pipeline = self
    local start_time = UIManager:getTime()

    local function checkReady()
        local pf = io.open(pipeline.PIPELINE_PID_FILE, "r")
        if pf then
            local pid = pf:read("*a"):gsub("%s+", "")
            pf:close()
            pipeline._pipeline_running = true
            pipeline._pipeline_starting = false
            logger.warn("BtPipeline: Pipeline ready, PID:", pid)

            -- Try to resize pipe to 4KB via fcntl
            pipeline:_resizePipeBuffer()

            if callback then callback(pipeline._pipe_buffer_delay) end
            return
        end
        if time.to_ms(UIManager:getTime() - start_time) > 10000 then
            pipeline._pipeline_starting = false
            logger.err("BtPipeline: Pipeline startup timed out")
            if callback then callback(nil) end
            return
        end
        UIManager:scheduleIn(0.3, checkReady)
    end
    UIManager:scheduleIn(0.3, checkReady)
end

--[[--
Stop the persistent GStreamer pipeline.
--]]
function BtPipeline:stop()
    self:stopKeepalive()
    self:_stopProcessWatcher()

    if self._fd_fifo then
        pcall(function() ffi.C.close(self._fd_fifo) end)
        self._fd_fifo = nil
    end

    local pf = io.open(self.PIPELINE_PID_FILE, "r")
    if pf then
        local pid = pf:read("*a"):gsub("%s+", "")
        pf:close()
        if pid ~= "" then
            os.execute(string.format("kill %s 2>/dev/null", pid))
        end
    end
    os.execute("killall -9 gst-launch-1.0 2>/dev/null")
    os.execute(string.format('rm -f "%s" "%s" "%s"',
        self.PIPELINE_FIFO, self.PIPELINE_PID_FILE, self.PIPELINE_SCRIPT))

    self._pipeline_running = false
    self._pipeline_starting = false
    logger.warn("BtPipeline: Pipeline stopped")
end

--- Check if the pipeline process is still alive.
-- @return boolean
function BtPipeline:isAlive()
    local pf = io.open(self.PIPELINE_PID_FILE, "r")
    if not pf then return false end
    local pid = pf:read("*a"):gsub("%s+", "")
    pf:close()
    if pid == "" then return false end
    local h = io.popen(string.format("kill -0 %s 2>&1; echo $?", pid))
    if not h then return false end
    local result = h:read("*a"):gsub("%s+", "")
    h:close()
    return result == "0"
end

--[[--
Ensure the pipeline is running. Restarts if dead.
@param sample_rate number
@param bt_sink string
@param callback function  Called when pipeline is ready
--]]
function BtPipeline:ensure(sample_rate, bt_sink, callback)
    if self._pipeline_running and self:isAlive() then
        if callback then callback(self._pipe_buffer_delay) end
        return
    end
    if self._pipeline_running then
        logger.warn("BtPipeline: Pipeline died, restarting")
        self:stop()
    end
    self:start(sample_rate, bt_sink, callback)
end

-- ── Pipe buffer resize ───────────────────────────────────────────────

--- Try to resize the FIFO pipe buffer to 16KB using fcntl F_SETPIPE_SZ.
-- 16KB (~370ms at 44100 B/s) balances low latency with enough headroom
-- to absorb CPU stalls when Piper is synthesising on ARM.
function BtPipeline:_resizePipeBuffer()
    local F_SETPIPE_SZ = 1031
    local O_WRONLY   = 1
    local O_NONBLOCK = 2048

    local fd = ffi.C.open(self.PIPELINE_FIFO, bit.bor(O_WRONLY, O_NONBLOCK))
    if fd >= 0 then
        local rc = ffi.C.fcntl(fd, F_SETPIPE_SZ, ffi.new("int", 16384))
        ffi.C.close(fd)
        if rc >= 0 then
            self._pipe_buffer_delay = self.PIPE_BUFFER_DELAY_16KB
            logger.warn("BtPipeline: Pipe resized to 16KB, delay:", self._pipe_buffer_delay, "ms")
        else
            logger.warn("BtPipeline: fcntl resize failed, keeping default delay")
        end
    else
        logger.warn("BtPipeline: Could not open FIFO for resize")
    end
end

--- Get the current pipe buffer delay.
-- @return number  milliseconds
function BtPipeline:getPipeDelay()
    return self._pipe_buffer_delay
end

--- Check if pipeline is running.
-- @return boolean
function BtPipeline:isRunning()
    return self._pipeline_running
end

-- ── Write to FIFO ────────────────────────────────────────────────────

--[[--
Write raw WAV data (with header) to the pipeline FIFO.
Opens the FIFO non-blocking, writes the file content.

@param wav_path string  Path to WAV file to inject
@return boolean  true if write succeeded
--]]
function BtPipeline:writeWav(wav_path)
    if not self._pipeline_running then return false end

    local wf = io.open(wav_path, "rb")
    if not wf then
        logger.err("BtPipeline: Cannot open WAV:", wav_path)
        return false
    end
    local data = wf:read("*a")
    wf:close()
    if not data or #data == 0 then return false end

    local O_WRONLY   = 1
    local O_NONBLOCK = 2048
    local fd = ffi.C.open(self.PIPELINE_FIFO, bit.bor(O_WRONLY, O_NONBLOCK))
    if fd < 0 then
        logger.err("BtPipeline: FIFO open failed, errno:", ffi.errno())
        return false
    end

    local written = tonumber(ffi.C.write(fd, data, #data))
    ffi.C.close(fd)

    if written ~= #data then
        logger.err("BtPipeline: Partial write:", written, "/", #data)
        return false
    end
    return true
end

-- ── BT Keepalive ─────────────────────────────────────────────────────

--[[--
Start injecting silence into the pipeline at regular intervals.
Keeps the BT A2DP connection alive during pauses.
--]]
function BtPipeline:startKeepalive()
    if self._keepalive_running then return end
    self._keepalive_running = true

    -- Ensure silence file exists
    if not wavutils().getFileSize(self.SILENCE_FILE) or
       wavutils().getFileSize(self.SILENCE_FILE) < 45 then
        wavutils().generateSilence(self.SILENCE_FILE, self.SILENCE_DURATION_MS)
    end

    local pipeline = self
    local function inject()
        if not pipeline._keepalive_running then return end
        if not pipeline._pipeline_running then
            pipeline._keepalive_running = false
            return
        end

        pipeline:writeWav(pipeline.SILENCE_FILE)
        UIManager:scheduleIn(pipeline.KEEPALIVE_INTERVAL, inject)
    end

    UIManager:scheduleIn(self.KEEPALIVE_INTERVAL, inject)
    logger.dbg("BtPipeline: Keepalive started")
end

--- Stop the keepalive silence injector.
function BtPipeline:stopKeepalive()
    self._keepalive_running = false
end

--- Check if keepalive is active.
-- @return boolean
function BtPipeline:isKeepaliveRunning()
    return self._keepalive_running
end

-- ── Process watcher ──────────────────────────────────────────────────

--[[--
Start a watcher that detects BT audio sink crashes and restarts pipeline.
Checks the gst process regularly; on crash, restarts and calls the callback.

@param sample_rate number
@param bt_sink string
@param on_restart function  Called after successful restart
--]]
function BtPipeline:startProcessWatcher(sample_rate, bt_sink, on_restart)
    if self._process_watcher_running then return end
    self._process_watcher_running = true

    local pipeline = self
    local function watch()
        if not pipeline._process_watcher_running then return end
        if not pipeline._pipeline_running then
            pipeline._process_watcher_running = false
            return
        end

        if not pipeline:isAlive() then
            logger.warn("BtPipeline: Pipeline crash detected, restarting")
            pipeline._pipeline_running = false
            pipeline:start(sample_rate, bt_sink, function(delay)
                if delay and on_restart then on_restart() end
            end)
        end

        UIManager:scheduleIn(5.0, watch)
    end

    UIManager:scheduleIn(5.0, watch)
    logger.dbg("BtPipeline: Process watcher started")
end

--- Stop the process watcher.
function BtPipeline:_stopProcessWatcher()
    self._process_watcher_running = false
end

-- ── Kill helpers ─────────────────────────────────────────────────────

--- Kill any existing audio processes (gst-launch, play, aplay, pacat).
function BtPipeline.killAudioProcesses()
    os.execute("killall -9 gst-launch-1.0 play aplay pacat 2>/dev/null")
end

return BtPipeline
