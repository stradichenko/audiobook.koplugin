--[[--
Piper TTS Queue & Server Management
Extracted from ttsengine.lua — owns all Piper-related state:
  • Persistent server lifecycle (start / stop / FIFO I/O)
  • Async prefetch queue (enqueue → batch dispatch → poll → finalize)
  • Model configuration (resolve path, read sample rate, list voices)
  • Command building (base command, JSON lines, per-process fallback)

The module takes an `engine` (TTSEngine) reference at construction time
and accesses engine fields/methods as needed (rate, piper_model, etc.).

@module piperqueue
--]]

local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local logger = require("logger")
local time = require("ui/time")

local _utils_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local WavUtils = dofile(_utils_dir .. "wavutils.lua")

-- ── Constants ────────────────────────────────────────────────────────

local SERVER_COUNT  = 2                       -- persistent Piper servers
local SERVER_PREFIX = "/tmp/piper_server_"
local BATCH_SIZE    = 1                       -- sentences per server call
-- Maximum requests queued per server via FIFO pipelining.
-- Depth=2 ensures zero idle time between sentences on each server
-- (the next request is already waiting in the FIFO when the current
-- one finishes).  Higher depth just increases queue latency without
-- improving throughput since Piper processes requests sequentially.
local MAX_PIPELINE_DEPTH = 2

-- ── PiperQueue class ─────────────────────────────────────────────────

local PiperQueue = {}

function PiperQueue:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self

    -- Required: reference to the owning TTSEngine
    assert(o.engine, "PiperQueue requires an engine reference")

    -- Queue state
    o._queue       = {}    -- keyed by sentence text → entry table
    o._queue_order = {}    -- ordered list of queued texts

    -- Server state
    o._servers              = {}
    o._servers_running      = false
    o._servers_starting     = false
    o._server_rr            = 0
    o._slots_busy           = 0
    o._server_start_attempts = 0

    return o
end

-- ── Model configuration ─────────────────────────────────────────────

--[[--
Read the sample rate from a Piper model's companion JSON config.
@param model_path string  Path to the .onnx file
@return number  Sample rate (defaults to 22050 if unreadable)
--]]
function PiperQueue:_readModelSampleRate(model_path)
    if not model_path then return 22050 end
    local json_path = model_path .. ".json"
    local f = io.open(json_path, "r")
    if not f then
        logger.dbg("PiperQueue: No .onnx.json sidecar for", model_path)
        return 22050
    end
    local content = f:read("*a")
    f:close()
    local sr = tonumber(content:match('"sample_rate"%s*:%s*(%d+)'))
    if sr and sr > 0 then
        logger.warn("PiperQueue: Model sample rate =", sr, "Hz")
        return sr
    end
    return 22050
end

--[[--
Resolve the Piper voice model path.
@return string|nil  Absolute path to .onnx file, or nil
--]]
function PiperQueue:_resolvePiperModel()
    local engine = self.engine
    -- Explicit model path set by user or config
    if engine.piper_model then
        if engine.piper_model:sub(1, 1) == "/" then
            local f = io.open(engine.piper_model, "r")
            if f then f:close(); return engine.piper_model end
        end
        local f = io.open(engine.piper_model, "r")
        if f then
            f:close()
            logger.dbg("PiperQueue: Resolved model relative to CWD:", engine.piper_model)
            return engine.piper_model
        end
        if engine.piper_model_dir then
            local basename = engine.piper_model:match("([^/]+)$")
            if basename then
                local try = engine.piper_model_dir .. "/" .. basename
                f = io.open(try, "r")
                if f then
                    f:close()
                    logger.dbg("PiperQueue: Resolved model via basename:", try)
                    return try
                end
                if not basename:match("%.onnx$") then
                    try = engine.piper_model_dir .. "/" .. basename .. ".onnx"
                    f = io.open(try, "r")
                    if f then f:close(); return try end
                end
            end
            local try = engine.piper_model_dir .. "/" .. engine.piper_model
            f = io.open(try, "r")
            if f then f:close(); return try end
        end
    end
    -- Auto-detect: first .onnx in the model dir
    logger.warn("PiperQueue: _resolvePiperModel – explicit path failed, falling back.",
        "piper_model=", engine.piper_model or "(nil)",
        "piper_model_dir=", engine.piper_model_dir or "(nil)")
    if engine.piper_model_dir then
        local handle = io.popen('find "' .. engine.piper_model_dir
            .. '" -name "*.onnx" -type f 2>/dev/null | head -1')
        if handle then
            local result = handle:read("*a"):gsub("%s+$", "")
            handle:close()
            if result and result ~= "" then
                logger.dbg("PiperQueue: Auto-detected model:", result)
                engine._piper_sample_rate = self:_readModelSampleRate(result)
                return result
            end
        end
    end
    return nil
end

--[[--
Set the Piper voice model.
@param model string  Model name or path
--]]
function PiperQueue:setModel(model)
    local engine = self.engine
    local old_model = engine.piper_model
    engine.piper_model = model
    local resolved = self:_resolvePiperModel()
    if resolved then
        engine._piper_sample_rate = self:_readModelSampleRate(resolved)
    end
    logger.dbg("PiperQueue: Model set to", engine.piper_model,
        "sample_rate=", engine._piper_sample_rate or 22050)
    if old_model and old_model ~= model then
        logger.warn("PiperQueue: Model changed, stopping servers + pipeline")
        self:stopServers()
        engine:_stopPersistentPipeline()
        self:cleanQueue()
    end
end

--[[--
Set the Piper speaker id (multi-speaker models).
@param id number  Speaker id (0-based)
--]]
function PiperQueue:setSpeaker(id)
    self.engine.piper_speaker = id or 0
    logger.dbg("PiperQueue: Speaker set to", self.engine.piper_speaker)
end

--[[--
Get the active model's sample rate.
@return number
--]]
function PiperQueue:getSampleRate()
    return self.engine._piper_sample_rate or 22050
end

--[[--
List available Piper voice models in the model directory.
@return table  Array of {name=, path=, size=, quality=, sample_rate=}
--]]
function PiperQueue:listVoices()
    local engine = self.engine
    local voices = {}
    if not engine.piper_model_dir then return voices end
    local handle = io.popen('find "' .. engine.piper_model_dir
        .. '" -name "*.onnx" -type f 2>/dev/null')
    if handle then
        for line in handle:lines() do
            local path = line:gsub("%s+$", "")
            if path ~= "" then
                local name = path:match("([^/]+)%.onnx$") or path
                local size = engine:getFileSize(path)
                local quality, voice_sr = nil, 22050
                local jf = io.open(path .. ".json", "r")
                if jf then
                    local content = jf:read("*a")
                    jf:close()
                    quality = content:match('"quality"%s*:%s*"([^"]+)"')
                    voice_sr = tonumber(content:match('"sample_rate"%s*:%s*(%d+)')) or 22050
                end
                table.insert(voices, {
                    name = name,
                    path = path,
                    size = size,
                    quality = quality,
                    sample_rate = voice_sr,
                })
            end
        end
        handle:close()
    end
    return voices
end

-- ── Command building ─────────────────────────────────────────────────

--[[--
Clean text for Piper synthesis.
@param text string
@return string
--]]
function PiperQueue:_cleanText(text)
    local clean = text:gsub("\n", " "):gsub("\r", "")
    clean = clean:gsub("\xe2\x80\xa6", ", ")       -- U+2026 ellipsis
    clean = clean:gsub("%.[%.%s]+%.", ", ")          -- 3+ dots
    clean = clean:gsub("%.%.+", ", ")                -- 2+ dots
    return clean
end

--[[--
Build the base Piper command (no I/O flags).
@return string
--]]
function PiperQueue:buildBaseCommand()
    local engine = self.engine
    local piper_bin = engine.piper_cmd or engine.backend_cmd or "piper"
    local model_flag = ""
    local model_path = self:_resolvePiperModel()
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
            local espeak_data_dir = engine.piper_model_dir .. "/espeak-ng-data"
            local ed_f = io.open(espeak_data_dir .. "/phontab", "r")
            if ed_f then
                ed_f:close()
                model_flag = model_flag
                    .. string.format(' --espeak_data "%s"', espeak_data_dir)
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
Build a JSON line for Piper's --json-input mode.
@param text string
@param output_file string
@return string  JSON line ending with \n
--]]
function PiperQueue:_buildJsonLine(text, output_file)
    local clean = self:_cleanText(text)
    clean = clean:gsub("\\", "\\\\")
    clean = clean:gsub('"', '\\"')
    clean = clean:gsub("\t", "\\t")
    return string.format('{"text":"%s","output_file":"%s"}\n', clean, output_file)
end

--[[--
Build the shell command for per-process Piper synthesis.
@param text string
@param audio_file string
@return string cmd, string text_file
--]]
function PiperQueue:buildCommand(text, audio_file)
    local base = self:buildBaseCommand()
    local engine = self.engine
    engine.file_counter = (engine.file_counter or 0) + 1
    local text_file = "/tmp/audiobook_piper_in_"
        .. os.time() .. "_" .. engine.file_counter .. ".txt"
    local tf = io.open(text_file, "w")
    if tf then
        tf:write(self:_cleanText(text) .. "\n")
        tf:close()
    end
    local cmd = string.format('%s --output_file "%s" < "%s" 2>&1',
        base, audio_file, text_file)
    return cmd, text_file
end

-- ── Server lifecycle ─────────────────────────────────────────────────

--[[--
Pick the next server (round-robin).
@return number  1-based server id
--]]
function PiperQueue:_pickServer()
    self._server_rr = (self._server_rr or 0) % SERVER_COUNT + 1
    return self._server_rr
end

--[[--
Write a JSON line to a server's FIFO via FFI (non-blocking).
@param server_id number
@param json_line string
@return boolean
--]]
function PiperQueue:_writeToPiperFifo(server_id, json_line)
    local server = self._servers[server_id]
    if not server then return false end

    local O_WRONLY   = 1
    local O_NONBLOCK = 2048
    local fd = ffi.C.open(server.fifo, bit.bor(O_WRONLY, O_NONBLOCK))
    if fd < 0 then
        logger.err("PiperQueue: Server", server_id,
            "FIFO open failed, errno:", ffi.errno())
        return false
    end
    local len = #json_line
    local written = tonumber(ffi.C.write(fd, json_line, len))
    ffi.C.close(fd)
    if written ~= len then
        logger.err("PiperQueue: Server", server_id,
            "FIFO write incomplete:", written, "/", len)
        return false
    end
    return true
end

--[[--
Start persistent Piper servers (--json-input).
Model loads once; sentences are sent as JSON lines via FIFO.
--]]
function PiperQueue:startServers()
    if self._servers_running or self._servers_starting then return end

    self._server_start_attempts = (self._server_start_attempts or 0) + 1
    if self._server_start_attempts > 2 then
        logger.warn("PiperQueue: Server start attempts exhausted, per-process mode")
        return
    end

    self._servers_starting = true
    self._servers = {}
    self._server_rr = 0

    -- Kill ALL existing piper processes before launching
    os.execute("killall -9 piper 2>/dev/null")
    os.execute("usleep 200000")

    local base_cmd = self:buildBaseCommand()

    for i = 1, SERVER_COUNT do
        local fifo = SERVER_PREFIX .. i
        local script_path = fifo .. ".sh"
        local pid_file = fifo .. ".pid"
        local log_file = fifo .. ".log"

        os.execute(string.format('rm -f "%s" "%s" "%s" "%s"',
            fifo, pid_file, script_path, log_file))

        local script = string.format([=[#!/bin/sh
FIFO="%s"
LOG="%s"
rm -f "$FIFO" "${FIFO}.pid"
mkfifo "$FIFO"
exec 3<>"$FIFO"
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
        logger.warn("PiperQueue: Server", i, "launching...")
    end

    -- Poll for all servers to be ready
    local pq = self
    local start_time = UIManager:getTime()
    local function checkServersReady()
        local all_ready = true
        for i = 1, SERVER_COUNT do
            if not pq._servers[i] then
                local pid_file = SERVER_PREFIX .. i .. ".pid"
                local pf = io.open(pid_file, "r")
                if pf then
                    local pid = pf:read("*a"):gsub("%s+", "")
                    pf:close()
                    pq._servers[i] = {
                        fifo = SERVER_PREFIX .. i,
                        pid = tonumber(pid),
                    }
                    logger.warn("PiperQueue: Server", i, "ready, PID:", pid)
                else
                    all_ready = false
                end
            end
        end
        if all_ready then
            pq._servers_running = true
            pq._servers_starting = false
            logger.warn("PiperQueue: All", SERVER_COUNT,
                "servers ready in",
                time.to_ms(UIManager:getTime() - start_time), "ms")
            pq:launchNext()
        elseif time.to_ms(UIManager:getTime() - start_time) > 60000 then
            pq._servers_starting = false
            logger.err("PiperQueue: Server startup timed out (60s), per-process fallback")
            pq:launchNext()
        else
            UIManager:scheduleIn(0.3, checkServersReady)
        end
    end
    UIManager:scheduleIn(0.3, checkServersReady)
end

--[[--
Stop persistent Piper servers.
--]]
function PiperQueue:stopServers()
    if not self._servers_running and not self._servers_starting then return end
    for i = 1, SERVER_COUNT do
        local server = self._servers and self._servers[i]
        if server and server.pid then
            os.execute(string.format("kill %d 2>/dev/null", server.pid))
        end
        local fifo = SERVER_PREFIX .. i
        os.execute(string.format('rm -f "%s" "%s.pid" "%s.sh" "%s.log"',
            fifo, fifo, fifo, fifo))
    end
    os.execute("killall -9 piper 2>/dev/null")
    self._servers = {}
    self._servers_running = false
    self._servers_starting = false
    self._slots_busy = 0

    -- Rescue orphaned "pending" entries
    local rescued = 0
    for _, entry in pairs(self._queue) do
        if entry.status == "pending" then
            entry.status = "queued"
            entry.done_marker = entry.file and (entry.file .. ".done") or nil
            rescued = rescued + 1
        end
    end
    logger.warn("PiperQueue: Servers stopped, rescued", rescued, "pending entries")
end

-- ── Queue management ─────────────────────────────────────────────────

--[[--
Add a sentence to the prefetch queue.
@param text string
--]]
function PiperQueue:enqueue(text)
    if not text or text == "" then return end
    if self._queue[text] then return end  -- already queued

    local engine = self.engine
    engine.file_counter = (engine.file_counter or 0) + 1
    local audio_file = "/tmp/audiobook_piper_pf_"
        .. os.time() .. "_" .. engine.file_counter .. ".wav"

    self._queue[text] = {
        file        = audio_file,
        text_file   = nil,
        done_marker = audio_file .. ".done",
        timing      = nil,
        status      = "queued",
    }
    table.insert(self._queue_order, text)

    logger.dbg("PiperQueue: Queued:", text:sub(1, 40),
        "(size:", #self._queue_order, ")")

    if self._servers_running then
        self:launchNext()
    end
end

--[[--
Launch the next queued batch via persistent server (or per-process fallback).
--]]
function PiperQueue:launchNext()
    local engine = self.engine

    -- Start servers if needed
    if not self._servers_running then
        self:startServers()
        if self._servers_starting then return end
    end

    local max_concurrent = self._servers_running
        and (SERVER_COUNT * MAX_PIPELINE_DEPTH) or 2
    self._slots_busy = self._slots_busy or 0
    if self._slots_busy >= max_concurrent then return end

    -- Gather consecutive "queued" entries
    local batch_texts   = {}
    local batch_entries = {}
    for _, text in ipairs(self._queue_order) do
        local e = self._queue[text]
        if e and e.status == "queued" then
            table.insert(batch_texts, text)
            table.insert(batch_entries, e)
            if #batch_texts >= BATCH_SIZE then break end
        end
    end
    if #batch_texts == 0 then return end

    -- Mark batch as pending
    for _, e in ipairs(batch_entries) do e.status = "pending" end

    local primary_text  = batch_texts[1]
    local primary_entry = batch_entries[1]
    local combined_audio_file  = primary_entry.file
    local combined_done_marker = primary_entry.done_marker

    -- ── Persistent server path ──
    if self._servers_running then
        local server_id = self:_pickServer()
        local combined_text = table.concat(batch_texts, " ")
        local json_line = self:_buildJsonLine(combined_text, combined_audio_file)

        local ok = self:_writeToPiperFifo(server_id, json_line)
        if not ok then
            logger.warn("PiperQueue: Server", server_id, "FIFO dead, trying alternate")
            for alt = 1, SERVER_COUNT do
                if alt ~= server_id then
                    ok = self:_writeToPiperFifo(alt, json_line)
                    if ok then
                        server_id = alt
                        logger.warn("PiperQueue: Alternate server", alt, "accepted batch")
                        break
                    end
                end
            end
        end

        if not ok then
            logger.err("PiperQueue: All server FIFOs failed, per-process fallback")
            for _, e in ipairs(batch_entries) do e.status = "queued" end
            self._servers_running = false
            self:stopServers()
        else
            logger.warn("PiperQueue: BATCH → server", server_id, ":",
                #batch_texts, "sentences (",
                combined_text:sub(1, 60), ")")

            -- Prevent tryFinalize from racing with our poll
            for _, e in ipairs(batch_entries) do e.done_marker = nil end

            self._slots_busy = (self._slots_busy or 0) + 1

            -- Poll for .done marker, then split the combined WAV
            local pq = self
            local poll_count = 0
            local max_polls = 900  -- 180s
            local function pollDone()
                if not pq._queue[primary_text] then
                    os.remove(combined_audio_file)
                    os.remove(combined_done_marker)
                    pq._slots_busy = math.max(0, (pq._slots_busy or 0) - 1)
                    pq:launchNext()
                    return
                end
                poll_count = poll_count + 1
                local mf = io.open(combined_done_marker, "r")
                if mf then
                    mf:close()
                    os.remove(combined_done_marker)
                    local total_size = engine:getFileSize(combined_audio_file)
                    if not total_size or total_size <= 0 then
                        for _, t in ipairs(batch_texts) do
                            local e = pq._queue[t]
                            if e then e.status = "failed" end
                        end
                        logger.err("PiperQueue: Batch done but empty WAV")
                        pq._slots_busy = math.max(0, (pq._slots_busy or 0) - 1)
                        pq:launchNext()
                        return
                    end

                    local synth_ms = poll_count * 200
                    logger.warn("PiperQueue: BATCH READY in", synth_ms, "ms:",
                        #batch_texts, "sentences, size:", total_size)

                    if #batch_texts == 1 then
                        WavUtils.applyFade(combined_audio_file, 15)
                        engine:generateTimingEstimates(primary_text)
                        primary_entry.timing = engine.timing_data
                        primary_entry.status = "ready"
                    else
                        -- Estimate per-sentence duration from syllable counts
                        local durations = {}
                        local total_syllables = 0
                        for _, t in ipairs(batch_texts) do
                            local count = 0
                            for word in t:gmatch("%S+") do
                                count = count + engine:countSyllables(
                                    word:gsub("[%p]", ""))
                            end
                            count = math.max(count, 1)
                            table.insert(durations, count)
                            total_syllables = total_syllables + count
                        end

                        local total_dur_ms = WavUtils.getDurationMs(combined_audio_file)
                        local est_durations_ms = {}
                        for _, syl in ipairs(durations) do
                            table.insert(est_durations_ms,
                                math.floor(total_dur_ms * syl / total_syllables))
                        end

                        local output_paths = {}
                        local first_seg_tmp = combined_audio_file .. ".seg1"
                        for i, _ in ipairs(batch_texts) do
                            if i == 1 then
                                table.insert(output_paths, first_seg_tmp)
                            else
                                table.insert(output_paths, batch_entries[i].file)
                            end
                        end

                        local split_ok = WavUtils.splitFile(
                            combined_audio_file, est_durations_ms, output_paths)

                        if split_ok then
                            os.remove(combined_audio_file)
                            os.rename(first_seg_tmp, combined_audio_file)
                        else
                            os.remove(first_seg_tmp)
                        end

                        if split_ok then
                            for i, t in ipairs(batch_texts) do
                                local e = pq._queue[t]
                                if e then
                                    WavUtils.applyFade(e.file, 15)
                                    engine:generateTimingEstimates(t)
                                    e.timing = engine.timing_data
                                    e.status = "ready"
                                end
                            end
                            logger.warn("PiperQueue: Batch split OK,",
                                #batch_texts, "sentences ready, durations=",
                                table.concat(est_durations_ms, "+"))
                        else
                            engine:generateTimingEstimates(primary_text)
                            primary_entry.timing = engine.timing_data
                            primary_entry.status = "ready"
                            for i = 2, #batch_texts do
                                local e = pq._queue[batch_texts[i]]
                                if e then e.status = "failed" end
                            end
                            logger.err("PiperQueue: Batch split failed, only first ready")
                        end
                    end

                    pq._slots_busy = math.max(0, (pq._slots_busy or 0) - 1)
                    pq:launchNext()
                    return
                end
                if poll_count < max_polls then
                    UIManager:scheduleIn(0.2, pollDone)
                else
                    for _, t in ipairs(batch_texts) do
                        local e = pq._queue[t]
                        if e then e.status = "failed" end
                    end
                    logger.err("PiperQueue: Batch timed out")
                    os.remove(combined_done_marker)
                    pq._slots_busy = math.max(0, (pq._slots_busy or 0) - 1)
                    pq:launchNext()
                end
            end
            UIManager:scheduleIn(0.2, pollDone)

            -- Fill remaining server slots
            self:launchNext()
            return
        end
    end

    -- ── Per-process fallback ──
    local text_to_launch = batch_texts[1]
    local entry = batch_entries[1]
    for i = 2, #batch_entries do batch_entries[i].status = "queued" end

    local audio_file   = entry.file
    local done_marker  = entry.done_marker

    local cmd, text_file = self:buildCommand(text_to_launch, audio_file)
    entry.text_file = text_file

    local bg_cmd = string.format('(%s; echo $? > "%s") &', cmd, done_marker)
    logger.dbg("PiperQueue: Prefetch (per-process):", text_to_launch:sub(1, 40))
    os.execute(bg_cmd)
    self._slots_busy = (self._slots_busy or 0) + 1

    local pq = self
    local poll_count = 0
    local max_polls = 300  -- 60s
    local function pollDone()
        local e = pq._queue[text_to_launch]
        if not e then
            os.remove(audio_file)
            os.remove(done_marker)
            if text_file then os.remove(text_file) end
            pq._slots_busy = math.max(0, (pq._slots_busy or 0) - 1)
            pq:launchNext()
            return
        end
        poll_count = poll_count + 1
        local mf = io.open(done_marker, "r")
        if mf then
            local exit_code = mf:read("*a"):gsub("%s+", "")
            mf:close()
            os.remove(done_marker)
            if text_file then os.remove(text_file) end
            local af = io.open(audio_file, "r")
            if af then
                af:close()
                local size = engine:getFileSize(audio_file)
                if size and size > 0 then
                    engine:generateTimingEstimates(text_to_launch)
                    e.timing = engine.timing_data
                    e.status = "ready"
                    logger.dbg("PiperQueue: Prefetch ready:",
                        text_to_launch:sub(1, 40), "size:", size)
                    pq._slots_busy = math.max(0, (pq._slots_busy or 0) - 1)
                    pq:launchNext()
                    return
                end
            end
            e.status = "failed"
            logger.err("PiperQueue: Prefetch failed:",
                text_to_launch:sub(1, 40), "exit:", exit_code)
            pq._slots_busy = math.max(0, (pq._slots_busy or 0) - 1)
            pq:launchNext()
            return
        end
        if poll_count < max_polls then
            UIManager:scheduleIn(0.2, pollDone)
        else
            e.status = "failed"
            logger.err("PiperQueue: Prefetch timed out:", text_to_launch:sub(1, 40))
            if text_file then os.remove(text_file) end
            os.remove(done_marker)
            pq._slots_busy = math.max(0, (pq._slots_busy or 0) - 1)
            pq:launchNext()
        end
    end
    UIManager:scheduleIn(0.2, pollDone)
end

--[[--
Synchronously check a pending entry's .done marker.
Closes the race between background process completion and UIManager poll.
@param text string
--]]
function PiperQueue:tryFinalize(text)
    local entry = self._queue[text]
    if not entry or entry.status ~= "pending" then return end
    if not entry.done_marker then return end

    local mf = io.open(entry.done_marker, "r")
    if not mf then return end

    local exit_code = mf:read("*a"):gsub("%s+", "")
    mf:close()
    os.remove(entry.done_marker)
    if entry.text_file then os.remove(entry.text_file) end

    local engine = self.engine
    local af = io.open(entry.file, "r")
    if af then
        af:close()
        local size = engine:getFileSize(entry.file)
        if size and size > 0 then
            engine:generateTimingEstimates(text)
            entry.timing = engine.timing_data
            entry.status = "ready"
            logger.dbg("PiperQueue: Sync-finalized:", text:sub(1, 40), "size:", size)
            self._slots_busy = math.max(0, (self._slots_busy or 0) - 1)
            self:launchNext()
            return
        end
    end

    entry.status = "failed"
    logger.err("PiperQueue: Sync-finalize FAILED:", text:sub(1, 40), "exit:", exit_code)
    self._slots_busy = math.max(0, (self._slots_busy or 0) - 1)
    self:launchNext()
end

--[[--
Check if a prefetched entry is ready and consume it.
Tries to finalize pending entries first.
@param text string
@return string|nil file, table|nil timing
--]]
function PiperQueue:useReady(text)
    local entry = self._queue[text]
    if not entry then return nil, nil end
    if entry.status == "pending" then self:tryFinalize(text) end
    if entry.status ~= "ready" or not entry.file then return nil, nil end
    -- Remove from queue (promoted to current)
    self._queue[text] = nil
    for i, t in ipairs(self._queue_order) do
        if t == text then table.remove(self._queue_order, i); break end
    end
    logger.dbg("PiperQueue: Using queued audio")
    return entry.file, entry.timing
end

--[[--
Peek without consuming.
@param text string
@return string|nil file, table|nil timing, number dur_ms
--]]
function PiperQueue:peek(text)
    local entry = self._queue[text]
    if not entry then return nil, nil, 0 end
    if entry.status == "pending" then self:tryFinalize(text) end
    if entry.status == "ready" and entry.file then
        local dur = WavUtils.getDurationMs(entry.file)
        return entry.file, entry.timing, dur
    end
    return nil, nil, 0
end

--[[--
Check if entry is ready.
@param text string
@return boolean
--]]
function PiperQueue:isReady(text)
    local entry = self._queue[text]
    return entry and entry.status == "ready"
end

--[[--
Get entry status.
@param text string
@return string|nil  "queued"/"pending"/"ready"/"failed" or nil
--]]
function PiperQueue:getStatus(text)
    local entry = self._queue[text]
    if entry then return entry.status end
    return nil
end

--[[--
Remove entry unconditionally, return file+timing (ownership transfer).
Used by concat pipeline to take ownership of the WAV file.
@param text string
@return string|nil file, table|nil timing
--]]
function PiperQueue:consume(text)
    local entry = self._queue[text]
    if entry then
        self._queue[text] = nil
        for i, t in ipairs(self._queue_order) do
            if t == text then table.remove(self._queue_order, i); break end
        end
        return entry.file, entry.timing
    end
    return nil, nil
end

--[[--
Diagnostic snapshot string.
@return string
--]]
function PiperQueue:getSnapshot()
    local counts = { queued = 0, pending = 0, ready = 0, failed = 0 }
    for _, entry in pairs(self._queue or {}) do
        local st = entry.status or "unknown"
        counts[st] = (counts[st] or 0) + 1
    end
    return string.format("queued=%d pending=%d ready=%d failed=%d total=%d",
        counts.queued, counts.pending, counts.ready, counts.failed,
        #(self._queue_order or {}))
end

--[[--
Enqueue multiple sentences and kick the launcher.
@param texts table  Array of sentence texts
--]]
function PiperQueue:batchEnqueue(texts)
    for _, text in ipairs(texts) do
        if text and text ~= "" then
            self:enqueue(text)
        end
    end
    self:launchNext()
end

-- ── Cleanup ──────────────────────────────────────────────────────────

--[[--
Kill per-process piper instances (not persistent servers).
--]]
function PiperQueue:killOrphanProcesses()
    if self._servers_running then
        logger.dbg("PiperQueue: Servers active, skipping killall")
    else
        os.execute("killall -9 piper 2>/dev/null")
        logger.dbg("PiperQueue: Killed all piper processes")
    end
end

--[[--
Clean the queue: delete all WAV/marker files, reset state.
Does NOT stop persistent servers.
--]]
function PiperQueue:cleanQueue()
    self:killOrphanProcesses()
    for _, entry in pairs(self._queue) do
        if entry.file then os.remove(entry.file) end
        if entry.done_marker then os.remove(entry.done_marker) end
        if entry.text_file then os.remove(entry.text_file) end
    end
    self._queue = {}
    self._queue_order = {}
    self._slots_busy = 0
end

--[[--
Full shutdown: clean queue AND stop servers.
--]]
function PiperQueue:shutdown()
    self:cleanQueue()
    self:stopServers()
end

return PiperQueue
