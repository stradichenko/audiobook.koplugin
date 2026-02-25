--[[--
Piper TTS Server Manager
Manages persistent Piper TTS processes using --json-input mode.
Handles server lifecycle, FIFO communication, prefetch queue, and
per-process fallback when servers are unavailable.

@module piperserver
--]]

local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local logger = require("logger")
local time = require("ui/time")

-- Declare C functions for FIFO I/O (may already be declared by ttsengine)
pcall(function()
    ffi.cdef[[
        int open(const char *pathname, int flags);
        int close(int fd);
        long write(int fd, const void *buf, unsigned long count);
    ]]
end)

local WavUtils = nil  -- lazy-loaded to avoid circular deps

local PiperServer = {}

-- ── Constants ────────────────────────────────────────────────────────

PiperServer.SERVER_COUNT = 2
PiperServer.SERVER_PREFIX = "/tmp/piper_server_"
PiperServer.POLL_INTERVAL = 0.5     -- seconds between done-marker checks
PiperServer.SERVER_TIMEOUT = 15000  -- ms to wait for server startup
PiperServer.PREFETCH_TIMEOUT_FIRST = 180  -- polls (90s) for first sentence (includes model load)
PiperServer.PREFETCH_TIMEOUT = 120        -- polls (60s) for subsequent sentences

-- ── Constructor ──────────────────────────────────────────────────────

function PiperServer:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self

    -- Server state
    o._servers = {}
    o._servers_running = false
    o._servers_starting = false
    o._server_rr = 0

    -- Prefetch queue: keyed by sentence text
    -- Each entry: {file, text_file, done_marker, timing, status}
    o._queue = {}
    o._queue_order = {}  -- insertion order for FIFO processing

    -- Callbacks
    o.engine = nil           -- ref to TTSEngine for timing estimates
    o.file_counter = 0       -- temp file counter

    return o
end

--- Lazy-load WavUtils to avoid circular dependency at require() time.
local function wavutils()
    if not WavUtils then
        -- Try to load from the same directory
        local info = debug.getinfo(1, "S")
        local dir = info.source:match("^@(.*/)[^/]*$") or "./"
        WavUtils = dofile(dir .. "wavutils.lua")
    end
    return WavUtils
end

-- ── Temp file helpers ────────────────────────────────────────────────

function PiperServer:_nextTempPath(prefix, ext)
    self.file_counter = self.file_counter + 1
    return string.format("/tmp/%s_%d_%d.%s",
        prefix, os.time(), self.file_counter, ext)
end

-- ── Text cleaning ────────────────────────────────────────────────────

--- Clean text for Piper synthesis (shared between JSON and per-process).
-- Replaces ellipsis variants, normalises whitespace.
-- @param text string  Raw sentence text
-- @return string  Cleaned text
function PiperServer.cleanText(text)
    local clean = text:gsub("\n", " "):gsub("\r", "")
    clean = clean:gsub("\xe2\x80\xa6", ", ")     -- Unicode ellipsis U+2026
    clean = clean:gsub("%.[%.%s]+%.", ", ")        -- 3+ dots with optional spaces
    clean = clean:gsub("%.%.+", ", ")               -- 2+ consecutive dots
    return clean
end

-- ── Piper command building ───────────────────────────────────────────

--[[--
Build the base Piper command prefix (without input/output flags).
Handles ld-linux, library paths, model, speaker, length_scale.

@param engine table  TTSEngine instance (for piper_cmd, piper_model, etc.)
@return string  Full command prefix
--]]
function PiperServer.buildBaseCommand(engine)
    local piper_bin = engine.piper_cmd or engine.backend_cmd or "piper"
    local model_flag = ""
    local model_path = engine:_resolvePiperModel()
    if model_path then
        model_flag = string.format(' --model "%s"', model_path)
    end

    local speaker_flag = ""
    if engine.piper_speaker and engine.piper_speaker > 0 then
        speaker_flag = string.format(' --speaker %d', engine.piper_speaker)
    end

    local length_scale = 1.0 / math.max(0.25, engine.rate)
    local length_flag = ""
    if math.abs(length_scale - 1.0) > 0.01 then
        length_flag = string.format(' --length_scale %.2f', length_scale)
    end

    -- Resolve exec prefix (ld-linux + library paths)
    local exec_prefix = ""
    if engine.piper_model_dir then
        local piper_lib = engine.piper_model_dir .. "/lib"
        local probe = io.open(piper_lib .. "/libonnxruntime.so.1.14.1", "r")
        if not probe then
            probe = io.open(engine.piper_model_dir .. "/libonnxruntime.so.1.14.1", "r")
            if probe then piper_lib = engine.piper_model_dir end
        end
        if probe then probe:close() end

        local plugin_dir = engine.plugin_dir
            or "/mnt/onboard/.adds/koreader/plugins/audiobook.koplugin"
        local espeak_lib = plugin_dir .. "/espeak-ng/lib"
        local ld_linux = espeak_lib .. "/ld-linux-armhf.so.3"
        local ld_f = io.open(ld_linux, "r")
        if ld_f then
            ld_f:close()
            local lib_path = piper_lib .. ":" .. espeak_lib
            exec_prefix = string.format('"%s" --library-path "%s" ',
                ld_linux, lib_path)
            -- Check for bundled espeak-ng data next to the Piper model
            local espeak_data_dir = engine.piper_model_dir .. "/espeak-ng-data"
            local ed_f = io.open(espeak_data_dir .. "/phontab", "r")
            if ed_f then
                ed_f:close()
                model_flag = model_flag .. string.format(
                    ' --espeak_data "%s"', espeak_data_dir)
            end
        else
            exec_prefix = string.format(
                'LD_LIBRARY_PATH="%s" ESPEAK_DATA_PATH="%s" ',
                piper_lib, engine.piper_model_dir)
        end
    end

    return string.format('nice -n 19 %s%s%s%s%s',
        exec_prefix, piper_bin, model_flag, speaker_flag, length_flag)
end

--[[--
Build a complete Piper shell command for per-process synthesis.
Uses buildBaseCommand() and adds input/output file flags.

@param engine table  TTSEngine instance
@param text string  Text to synthesize
@param audio_file string  Output WAV path
@return string cmd  Shell command
@return string text_file  Path to temp text input file
--]]
function PiperServer.buildCommand(engine, text, audio_file)
    local base = PiperServer.buildBaseCommand(engine)
    local text_file = string.format("/tmp/audiobook_piper_in_%d_%d.txt",
        os.time(), (engine.file_counter or 0) + 1)
    engine.file_counter = (engine.file_counter or 0) + 1

    local tf = io.open(text_file, "w")
    if tf then
        tf:write(PiperServer.cleanText(text) .. "\n")
        tf:close()
    end

    local cmd = string.format('%s --output_file "%s" < "%s" 2>&1',
        base, audio_file, text_file)
    return cmd, text_file
end

--[[--
Build a JSON line for Piper's --json-input mode.
@param text string  Sentence text
@param output_file string  WAV output path
@return string  JSON line ending with \n
--]]
function PiperServer.buildJsonLine(text, output_file)
    local clean = PiperServer.cleanText(text)
    -- Escape for JSON string
    clean = clean:gsub("\\", "\\\\")    -- backslash first
    clean = clean:gsub('"', '\\"')      -- double quote
    clean = clean:gsub("\t", "\\t")     -- tab
    return string.format('{"text":"%s","output_file":"%s"}\n', clean, output_file)
end

-- ── Server lifecycle ─────────────────────────────────────────────────

--[[--
Start persistent Piper servers (--json-input mode).
Each server loads the model ONCE, then reads JSON lines from a FIFO.
Server stdout creates .done markers for the polling code.

@param engine table  TTSEngine instance (for command building)
--]]
function PiperServer:startServers(engine)
    if self._servers_running or self._servers_starting then return end
    self._servers_starting = true
    self._servers = {}
    self._server_rr = 0

    local base_cmd = PiperServer.buildBaseCommand(engine)

    for i = 1, self.SERVER_COUNT do
        local fifo = self.SERVER_PREFIX .. i
        local script_path = fifo .. ".sh"
        local pid_file = fifo .. ".pid"
        local log_file = fifo .. ".log"

        -- Clean previous state
        os.execute(string.format('rm -f "%s" "%s" "%s" "%s"',
            fifo, pid_file, script_path, log_file))

        -- Write server script
        local script = string.format([=[#!/bin/sh
FIFO="%s"
LOG="%s"
rm -f "$FIFO" "${FIFO}.pid"
mkfifo "$FIFO"

# Open FIFO read-write on fd 3 (never blocks on FIFOs).
# Keeps the write side open so Piper doesn't get EOF between writes.
exec 3<>"$FIFO"

# Piper reads JSON lines from fd 3, prints output paths to stdout.
# The while-read loop creates .done markers for Lua's polling code.
%s --json-input --sentence_silence 0 <&3 2>>"$LOG" | while IFS= read -r wav_path; do
  wav_path=$(echo "$wav_path" | tr -d '\r\n')
  if [ -n "$wav_path" ]; then
    echo "0" > "${wav_path}.done"
  fi
done &
PIPE_PID=$!

echo "$PIPE_PID" > "${FIFO}.pid"
wait $PIPE_PID 2>/dev/null
exec 3>&-
rm -f "$FIFO" "${FIFO}.pid"
]=], fifo, log_file, base_cmd)

        local sf = io.open(script_path, "w")
        if sf then
            sf:write(script)
            sf:close()
            os.execute('chmod +x "' .. script_path .. '"')
        end

        os.execute(string.format('/bin/sh "%s" &', script_path))
        logger.warn("PiperServer: Server", i, "launching...")
    end

    -- Poll for readiness
    local piper = self
    local start_time = UIManager:getTime()
    local function checkReady()
        local all_ready = true
        for i = 1, piper.SERVER_COUNT do
            if not piper._servers[i] then
                local pid_file = piper.SERVER_PREFIX .. i .. ".pid"
                local pf = io.open(pid_file, "r")
                if pf then
                    local pid = pf:read("*a"):gsub("%s+", "")
                    pf:close()
                    piper._servers[i] = {
                        fifo = piper.SERVER_PREFIX .. i,
                        pid = tonumber(pid),
                    }
                    logger.warn("PiperServer: Server", i, "ready, PID:", pid)
                else
                    all_ready = false
                end
            end
        end
        if all_ready then
            piper._servers_running = true
            piper._servers_starting = false
            logger.warn("PiperServer: All", piper.SERVER_COUNT,
                "servers ready in",
                time.to_ms(UIManager:getTime() - start_time), "ms")
            piper:_launchNext()
        elseif time.to_ms(UIManager:getTime() - start_time) > piper.SERVER_TIMEOUT then
            piper._servers_starting = false
            logger.err("PiperServer: Server startup timed out, using per-process fallback")
            piper:_launchNext()
        else
            UIManager:scheduleIn(0.3, checkReady)
        end
    end
    UIManager:scheduleIn(0.3, checkReady)
end

--[[--
Stop persistent Piper servers and clean up.
--]]
function PiperServer:stopServers()
    if not self._servers_running and not self._servers_starting then return end
    for i = 1, self.SERVER_COUNT do
        local server = self._servers[i]
        if server and server.pid then
            os.execute(string.format("kill %d 2>/dev/null", server.pid))
        end
        local fifo = self.SERVER_PREFIX .. i
        os.execute(string.format('rm -f "%s" "%s.pid" "%s.sh" "%s.log"',
            fifo, fifo, fifo, fifo))
    end
    os.execute("killall -9 piper 2>/dev/null")
    self._servers = {}
    self._servers_running = false
    self._servers_starting = false
    logger.warn("PiperServer: Servers stopped")
end

--- Check if servers are running.
-- @return boolean
function PiperServer:isRunning()
    return self._servers_running
end

--- Check if servers are starting up.
-- @return boolean
function PiperServer:isStarting()
    return self._servers_starting
end

-- ── FIFO communication ───────────────────────────────────────────────

--- Pick the next server (round-robin).
-- @return number  Server ID (1-based)
function PiperServer:_pickServer()
    self._server_rr = (self._server_rr or 0) % self.SERVER_COUNT + 1
    return self._server_rr
end

--[[--
Write a JSON line to a server's FIFO.
Uses FFI open(O_WRONLY|O_NONBLOCK) + write() to avoid blocking Lua.

@param server_id number  Server index (1-based)
@param json_line string  JSON line (must end with \n)
@return boolean  true if write succeeded
--]]
function PiperServer:_writeToFifo(server_id, json_line)
    local server = self._servers[server_id]
    if not server then return false end

    local O_WRONLY   = 1
    local O_NONBLOCK = 2048  -- 0x800
    local fd = ffi.C.open(server.fifo, bit.bor(O_WRONLY, O_NONBLOCK))
    if fd < 0 then
        logger.err("PiperServer: FIFO open failed for server", server_id,
            "errno:", ffi.errno())
        return false
    end

    local len = #json_line
    local written = tonumber(ffi.C.write(fd, json_line, len))
    ffi.C.close(fd)

    if written ~= len then
        logger.err("PiperServer: FIFO write incomplete for server", server_id,
            written, "/", len)
        return false
    end
    return true
end

-- ── Prefetch queue ───────────────────────────────────────────────────

--[[--
Add a sentence to the prefetch queue.
If already queued/pending/ready, this is a no-op.

@param text string  Sentence text
--]]
function PiperServer:enqueue(text)
    if not text or text == "" then return end
    if self._queue[text] then return end  -- already in queue

    local audio_file = self:_nextTempPath("audiobook_piper_pf", "wav")
    local done_marker = audio_file .. ".done"

    self._queue[text] = {
        file = audio_file,
        text_file = nil,
        done_marker = done_marker,
        timing = nil,
        status = "queued",
    }
    table.insert(self._queue_order, text)

    logger.dbg("PiperServer: Queued:", text:sub(1, 40),
        "(queue size:", #self._queue_order, ")")

    self:_launchNext()
end

--[[--
Launch the next queued prefetch entry.
Uses persistent servers when available, falls back to per-process.
--]]
function PiperServer:_launchNext()
    -- Start servers if needed
    if not self._servers_running and self.engine then
        self:startServers(self.engine)
        if self._servers_starting then return end  -- will be called again when ready
    end

    local max_concurrent = self._servers_running and self.SERVER_COUNT or 2

    -- Count pending
    local pending_count = 0
    for _, entry in pairs(self._queue) do
        if entry.status == "pending" then
            pending_count = pending_count + 1
        end
    end
    if pending_count >= max_concurrent then return end

    -- Find first queued entry
    local text_to_launch = nil
    for _, txt in ipairs(self._queue_order) do
        local entry = self._queue[txt]
        if entry and entry.status == "queued" then
            text_to_launch = txt
            break
        end
    end
    if not text_to_launch then return end

    local entry = self._queue[text_to_launch]
    entry.status = "pending"

    -- ── Server path ──
    if self._servers_running then
        local server_id = self:_pickServer()
        local json_line = PiperServer.buildJsonLine(text_to_launch, entry.file)

        if self:_writeToFifo(server_id, json_line) then
            logger.dbg("PiperServer: Sent to server", server_id, ":",
                text_to_launch:sub(1, 40))
            self:_pollDone(text_to_launch, self.PREFETCH_TIMEOUT_FIRST)
            -- Fill other server slots
            if pending_count + 1 < max_concurrent then
                self:_launchNext()
            end
            return
        else
            -- FIFO write failed — fall back to per-process
            logger.err("PiperServer: FIFO write failed, disabling servers")
            self._servers_running = false
            self:stopServers()
        end
    end

    -- ── Per-process fallback ──
    if not self.engine then
        entry.status = "failed"
        logger.err("PiperServer: No engine reference for per-process fallback")
        return
    end

    local cmd, text_file = PiperServer.buildCommand(
        self.engine, text_to_launch, entry.file)
    entry.text_file = text_file

    local bg_cmd = string.format('(%s; echo $? > "%s") &',
        cmd, entry.done_marker)
    logger.dbg("PiperServer: Per-process launch:", text_to_launch:sub(1, 40))
    os.execute(bg_cmd)

    self:_pollDone(text_to_launch, self.PREFETCH_TIMEOUT)
end

--[[--
Poll for a prefetch entry's .done marker.
When found, finalizes the entry to "ready" and launches the next queued item.

@param text string  Queue key (sentence text)
@param max_polls number  Maximum poll iterations before timeout
--]]
function PiperServer:_pollDone(text, max_polls)
    local piper = self
    local poll_count = 0

    local function poll()
        local entry = piper._queue[text]
        if not entry then
            -- Entry was removed (stopped/cleaned)
            return
        end
        poll_count = poll_count + 1

        local mf = io.open(entry.done_marker, "r")
        if mf then
            local content = mf:read("*a"):gsub("%s+", "")
            mf:close()
            os.remove(entry.done_marker)
            if entry.text_file then os.remove(entry.text_file) end

            local size = wavutils().getFileSize(entry.file)
            if size and size > 0 then
                -- Generate timing estimates
                if piper.engine then
                    piper.engine:generateTimingEstimates(text)
                    entry.timing = piper.engine.timing_data
                end
                entry.status = "ready"
                logger.dbg("PiperServer: Ready:", text:sub(1, 40),
                    "size:", size)
            else
                entry.status = "failed"
                logger.err("PiperServer: Done but empty WAV:", text:sub(1, 40))
            end
            piper:_launchNext()
            return
        end

        if poll_count < max_polls then
            UIManager:scheduleIn(piper.POLL_INTERVAL, poll)
        else
            entry.status = "failed"
            logger.err("PiperServer: Timed out:", text:sub(1, 40))
            os.remove(entry.done_marker)
            piper:_launchNext()
        end
    end

    UIManager:scheduleIn(self.POLL_INTERVAL, poll)
end

--[[--
Synchronously check a pending entry's .done marker.
Catches entries that finished between UIManager poll intervals.

@param text string  Queue key
--]]
function PiperServer:tryFinalize(text)
    local entry = self._queue[text]
    if not entry or entry.status ~= "pending" then return end
    if not entry.done_marker then return end

    local mf = io.open(entry.done_marker, "r")
    if not mf then return end

    mf:close()
    os.remove(entry.done_marker)
    if entry.text_file then os.remove(entry.text_file) end

    local size = wavutils().getFileSize(entry.file)
    if size and size > 0 then
        if self.engine then
            self.engine:generateTimingEstimates(text)
            entry.timing = self.engine.timing_data
        end
        entry.status = "ready"
        logger.dbg("PiperServer: Sync-finalized:", text:sub(1, 40))
        self:_launchNext()
        return
    end

    entry.status = "failed"
    logger.err("PiperServer: Sync-finalize FAILED:", text:sub(1, 40))
    self:_launchNext()
end

-- ── Queue queries ────────────────────────────────────────────────────

--- Get the status of a queue entry.
-- @param text string
-- @return string|nil  "ready", "pending", "queued", "failed", or nil
function PiperServer:getStatus(text)
    local entry = self._queue[text]
    return entry and entry.status or nil
end

--- Check if an entry is ready and swap it into the engine's current state.
-- @param text string
-- @param engine table  TTSEngine to update (current_audio_file, timing_data)
-- @return boolean  true if prefetch was consumed
function PiperServer:consume(text, engine)
    local entry = self._queue[text]
    if not entry then return false end

    if entry.status == "pending" then
        self:tryFinalize(text)
    end

    if entry.status == "ready" and entry.file then
        if engine.current_audio_file then
            os.remove(engine.current_audio_file)
        end
        engine.current_audio_file = entry.file
        engine.timing_data = entry.timing
        self:_removeEntry(text)
        logger.dbg("PiperServer: Consumed:", text:sub(1, 40))
        return true
    end
    return false
end

--- Peek at a ready entry without consuming it.
-- @param text string
-- @return string|nil file, table|nil timing, number duration_ms
function PiperServer:peek(text)
    local entry = self._queue[text]
    if not entry then return nil, nil, 0 end

    if entry.status == "pending" then
        self:tryFinalize(text)
    end

    if entry.status == "ready" and entry.file then
        local dur = wavutils().getDurationMs(entry.file)
        return entry.file, entry.timing, dur
    end
    return nil, nil, 0
end

--- Remove an entry without deleting its files (transfer ownership).
-- @param text string
-- @return string|nil file, table|nil timing
function PiperServer:transferOwnership(text)
    local entry = self._queue[text]
    if not entry then return nil, nil end
    local file, tmg = entry.file, entry.timing
    self:_removeEntry(text)
    return file, tmg
end

--- Remove an entry from the queue (internal).
function PiperServer:_removeEntry(text)
    self._queue[text] = nil
    for i, t in ipairs(self._queue_order) do
        if t == text then
            table.remove(self._queue_order, i)
            break
        end
    end
end

-- ── Cleanup ──────────────────────────────────────────────────────────

--- Clean up the prefetch queue (delete WAV/marker/text files).
-- Does NOT stop servers.
function PiperServer:cleanQueue()
    self:killOrphanProcesses()
    for _, entry in pairs(self._queue) do
        if entry.file then os.remove(entry.file) end
        if entry.done_marker then os.remove(entry.done_marker) end
        if entry.text_file then os.remove(entry.text_file) end
    end
    self._queue = {}
    self._queue_order = {}
end

--- Kill orphaned per-process piper instances (not persistent servers).
function PiperServer:killOrphanProcesses()
    if self._servers_running then
        logger.dbg("PiperServer: Servers active, skipping killall")
    else
        os.execute("killall -9 piper 2>/dev/null")
    end
end

--- Full shutdown: clean queue + stop servers.
function PiperServer:shutdown()
    self:cleanQueue()
    self:stopServers()
end

return PiperServer
