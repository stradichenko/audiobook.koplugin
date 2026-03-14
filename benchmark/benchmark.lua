--[[--
Piper TTS Benchmark Harness
Standalone benchmark that runs on Kobo (or any Linux with Piper).

Measures synthesis performance across different strategies to find
the optimal approach for gapless paragraph playback.

Usage:
    lua benchmark.lua                  -- run all strategies
    lua benchmark.lua baseline         -- run one strategy
    lua benchmark.lua --list           -- list strategies
    lua benchmark.lua --pages 1,2,3    -- test specific pages only
    lua benchmark.lua --quick          -- quick mode (2 pages only)

@module benchmark
--]]

-- ── Helpers ──────────────────────────────────────────────────────────

local function timestamp_ms()
    -- Try high-resolution clock first (Linux)
    local f = io.popen("date +%s%3N 2>/dev/null")
    if f then
        local result = f:read("*a"):gsub("%s+", "")
        f:close()
        local ms = tonumber(result)
        if ms and ms > 0 then return ms end
    end
    return os.time() * 1000
end

local function sleep_ms(ms)
    os.execute(string.format("usleep %d 2>/dev/null || sleep %.3f",
        ms * 1000, ms / 1000))
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local function file_size(path)
    local f = io.open(path, "r")
    if not f then return 0 end
    local size = f:seek("end")
    f:close()
    return size or 0
end

local function read_le32(raw)
    if not raw or #raw < 4 then return 0 end
    local b1, b2, b3, b4 = raw:byte(1, 4)
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function wav_duration_ms(path)
    local f = io.open(path, "rb")
    if not f then return 0 end
    local header = f:read(44)
    f:close()
    if not header or #header < 44 then return 0 end
    local byte_rate = read_le32(header:sub(29, 32))
    local data_size = read_le32(header:sub(41, 44))
    if byte_rate <= 0 then return 0 end
    return math.floor(data_size * 1000 / byte_rate)
end

local function get_rss_kb()
    local f = io.popen("ps aux 2>/dev/null | grep '[p]iper' | awk '{sum+=$6} END{print sum}'")
    if f then
        local result = f:read("*a"):gsub("%s+", "")
        f:close()
        return tonumber(result) or 0
    end
    return 0
end

local function clean_text(text)
    local clean = text:gsub("\n", " "):gsub("\r", "")
    clean = clean:gsub("\xe2\x80\xa6", ", ")       -- ellipsis
    clean = clean:gsub("%.[%.%s]+%.", ", ")
    clean = clean:gsub("%.%.+", ", ")
    return clean
end

local function printf(fmt, ...)
    io.write(string.format(fmt, ...))
    io.flush()
end

local function log(fmt, ...)
    local msg = string.format(fmt, ...)
    printf("[%s] %s\n", os.date("%H:%M:%S"), msg)
end

-- ── Piper command builder ────────────────────────────────────────────

local Config = {
    piper_bin = nil,        -- resolved at startup
    model_path = nil,       -- resolved at startup
    espeak_data = nil,      -- resolved at startup
    lib_path = nil,         -- resolved at startup
    ld_linux = nil,         -- resolved at startup
    sample_rate = 22050,
    output_dir = "/tmp/piper-benchmark/wav",
    results_dir = "/tmp/piper-benchmark/results",
    plugin_dir = "/mnt/onboard/.adds/koreader/plugins/audiobook.koplugin",
}

local function resolve_config()
    -- Try bundled Piper first
    local candidates = {
        Config.plugin_dir .. "/piper/piper",
        "./piper/piper",
        "/usr/local/bin/piper",
        "/usr/bin/piper",
    }
    for _, path in ipairs(candidates) do
        if file_exists(path) then
            Config.piper_bin = path
            break
        end
    end

    if not Config.piper_bin then
        -- Check PATH
        local h = io.popen("which piper 2>/dev/null")
        if h then
            local result = h:read("*a"):gsub("%s+", "")
            h:close()
            if result ~= "" then Config.piper_bin = result end
        end
    end

    if not Config.piper_bin then
        io.stderr:write("ERROR: Cannot find Piper binary\n")
        os.exit(1)
    end

    log("Piper binary: %s", Config.piper_bin)

    -- Find model
    local piper_dir = Config.piper_bin:match("^(.*/)[^/]*$") or "./"
    local model_candidates = {}
    local h = io.popen(string.format('find "%s" -name "*-low.onnx" -o -name "*-medium.onnx" 2>/dev/null | head -5', piper_dir))
    if h then
        for line in h:lines() do
            local path = line:gsub("%s+$", "")
            if path ~= "" then table.insert(model_candidates, path) end
        end
        h:close()
    end
    -- Prefer low models (faster on ARM)
    for _, path in ipairs(model_candidates) do
        if path:match("%-low%.onnx$") then
            Config.model_path = path
            break
        end
    end
    if not Config.model_path and #model_candidates > 0 then
        Config.model_path = model_candidates[1]
    end
    if not Config.model_path then
        -- Try models in the piper/ directory relative to benchmark
        h = io.popen('find "' .. piper_dir .. '/.." -name "*.onnx" -type f 2>/dev/null | head -1')
        if h then
            local result = h:read("*a"):gsub("%s+", "")
            h:close()
            if result ~= "" then Config.model_path = result end
        end
    end

    if not Config.model_path then
        io.stderr:write("ERROR: Cannot find a Piper .onnx model\n")
        os.exit(1)
    end

    log("Model: %s", Config.model_path)

    -- Read sample rate from model JSON
    local json_path = Config.model_path .. ".json"
    local jf = io.open(json_path, "r")
    if jf then
        local content = jf:read("*a")
        jf:close()
        local sr = tonumber(content:match('"sample_rate"%s*:%s*(%d+)'))
        if sr and sr > 0 then Config.sample_rate = sr end
    end
    log("Sample rate: %d Hz", Config.sample_rate)

    -- Resolve library path and espeak data
    local lib_path = piper_dir .. "lib"
    if file_exists(lib_path .. "/libonnxruntime.so.1.14.1") then
        Config.lib_path = lib_path
    elseif file_exists(piper_dir .. "libonnxruntime.so.1.14.1") then
        Config.lib_path = piper_dir
    end

    local espeak_data = piper_dir .. "espeak-ng-data"
    if file_exists(espeak_data .. "/phontab") then
        Config.espeak_data = espeak_data
    end

    -- Check for ld-linux (bundled ARM sysroot)
    local espeak_ng_dir = Config.plugin_dir .. "/espeak-ng"
    local ld_linux = espeak_ng_dir .. "/lib/ld-linux-armhf.so.3"
    if file_exists(ld_linux) then
        Config.ld_linux = ld_linux
        local espeak_lib = espeak_ng_dir .. "/lib"
        if Config.lib_path then
            Config.lib_path = Config.lib_path .. ":" .. espeak_lib
        else
            Config.lib_path = espeak_lib
        end
    end

    -- Create output directories
    os.execute(string.format('mkdir -p "%s" "%s"', Config.output_dir, Config.results_dir))
end

local function build_piper_cmd(extra_flags)
    extra_flags = extra_flags or ""
    local prefix = ""
    if Config.ld_linux then
        prefix = string.format('"%s" --library-path "%s" ',
            Config.ld_linux, Config.lib_path)
    elseif Config.lib_path then
        prefix = string.format('LD_LIBRARY_PATH="%s" ', Config.lib_path)
    end
    local espeak_flag = ""
    if Config.espeak_data then
        espeak_flag = string.format(' --espeak_data "%s"', Config.espeak_data)
    end
    return string.format('nice -n 19 %s%s --model "%s"%s --sentence_silence 0 %s',
        prefix, Config.piper_bin, Config.model_path, espeak_flag, extra_flags)
end

-- ── WAV file utils ───────────────────────────────────────────────────

local function concat_wavs(input_files, output_path)
    -- Simple WAV concatenation: copy header from first, append raw PCM from all
    if #input_files == 0 then return false end

    local out = io.open(output_path, "wb")
    if not out then return false end

    local total_data_size = 0
    local header = nil

    -- First pass: read all PCM data
    local pcm_chunks = {}
    for _, path in ipairs(input_files) do
        local f = io.open(path, "rb")
        if f then
            local h = f:read(44)
            if h and #h == 44 then
                if not header then header = h end
                local data = f:read("*a")
                if data then
                    table.insert(pcm_chunks, data)
                    total_data_size = total_data_size + #data
                end
            end
            f:close()
        end
    end

    if not header then out:close(); return false end

    -- Patch header with new sizes
    local function le32(n)
        return string.char(n % 256, math.floor(n/256) % 256,
            math.floor(n/65536) % 256, math.floor(n/16777216) % 256)
    end

    -- RIFF chunk size = 36 + data_size
    header = header:sub(1, 4) .. le32(36 + total_data_size) .. header:sub(9, 40) .. le32(total_data_size)

    out:write(header)
    for _, chunk in ipairs(pcm_chunks) do
        out:write(chunk)
    end
    out:close()
    return true
end

-- ── Strategy interface ───────────────────────────────────────────────
-- Each strategy implements:
--   strategy:init(config)          -- setup (start servers, etc.)
--   strategy:synthesize(sentences) -- synthesize array of sentences,
--                                     returns array of {file, duration_ms, synth_ms}
--   strategy:cleanup()             -- stop servers, remove temp files

local Strategies = {}

-- ── Strategy 1: Baseline (per-process, one sentence at a time) ──────

Strategies.baseline = {
    name = "baseline",
    description = "Per-process synthesis, one sentence at a time (serial)",
}

function Strategies.baseline:init(config) end
function Strategies.baseline:cleanup() end

function Strategies.baseline:synthesize(sentences)
    local results = {}
    local counter = 0

    for i, sent in ipairs(sentences) do
        counter = counter + 1
        local wav_file = string.format("%s/baseline_%d.wav", Config.output_dir, counter)
        local text_file = string.format("/tmp/piper_bench_in_%d.txt", counter)

        local tf = io.open(text_file, "w")
        if tf then
            tf:write(clean_text(sent.text) .. "\n")
            tf:close()
        end

        local cmd = string.format('%s --output_file "%s" < "%s" 2>/dev/null',
            build_piper_cmd(), wav_file, text_file)

        local t0 = timestamp_ms()
        os.execute(cmd)
        local t1 = timestamp_ms()

        os.remove(text_file)

        local dur = wav_duration_ms(wav_file)
        local synth_time = t1 - t0

        table.insert(results, {
            file = wav_file,
            duration_ms = dur,
            synth_ms = synth_time,
            text = sent.text,
            text_len = #sent.text,
            mem_kb = get_rss_kb(),
        })

        printf("  [%d/%d] %4dms synth, %4dms audio, %.2fx RT | %s\n",
            i, #sentences, synth_time, dur,
            dur > 0 and dur / synth_time or 0,
            sent.text:sub(1, 50))
    end
    return results
end

-- ── Strategy 2: Persistent server (single, pipeline depth=1) ────────

Strategies.server_1x1 = {
    name = "server_1x1",
    description = "1 persistent server, pipeline depth 1",
    _server_pid = nil,
    _fifo = "/tmp/piper_bench_server_1",
}

function Strategies.server_1x1:init(config)
    local fifo = self._fifo
    os.execute("killall -9 piper 2>/dev/null")
    sleep_ms(200)
    os.execute(string.format('rm -f "%s" "%s.pid" "%s.log"', fifo, fifo, fifo))

    local script = string.format([=[#!/bin/sh
FIFO="%s"
rm -f "$FIFO" "${FIFO}.pid"
mkfifo "$FIFO"
exec 3<>"$FIFO"
%s --json-input <&3 2>>"${FIFO}.log" | while IFS= read -r wav_path; do
  wav_path=$(echo "$wav_path" | tr -d '\r\n')
  if [ -n "$wav_path" ]; then echo "0" > "${wav_path}.done"; fi
done &
PIPE_PID=$!
echo "$PIPE_PID" > "${FIFO}.pid"
wait $PIPE_PID 2>/dev/null
exec 3>&-
rm -f "$FIFO" "${FIFO}.pid"
]=], fifo, build_piper_cmd())

    local script_path = fifo .. ".sh"
    local sf = io.open(script_path, "w")
    if sf then sf:write(script); sf:close() end
    os.execute('chmod +x "' .. script_path .. '"')
    os.execute(string.format('/bin/sh "%s" &', script_path))

    -- Wait for server to be ready
    log("Waiting for server to start...")
    local t0 = timestamp_ms()
    for _ = 1, 200 do
        sleep_ms(300)
        local pf = io.open(fifo .. ".pid", "r")
        if pf then
            local pid = pf:read("*a"):gsub("%s+", "")
            pf:close()
            self._server_pid = tonumber(pid)
            log("Server ready (PID %s) in %dms", pid, timestamp_ms() - t0)
            return
        end
    end
    log("WARNING: Server startup timed out")
end

function Strategies.server_1x1:cleanup()
    if self._server_pid then
        os.execute(string.format("kill %d 2>/dev/null", self._server_pid))
    end
    os.execute("killall -9 piper 2>/dev/null")
    local fifo = self._fifo
    os.execute(string.format('rm -f "%s" "%s.pid" "%s.sh" "%s.log"', fifo, fifo, fifo, fifo))
    self._server_pid = nil
end

function Strategies.server_1x1:synthesize(sentences)
    local results = {}
    local counter = 0

    for i, sent in ipairs(sentences) do
        counter = counter + 1
        local wav_file = string.format("%s/srv1x1_%d.wav", Config.output_dir, counter)
        local done_marker = wav_file .. ".done"
        os.execute(string.format('rm -f "%s" "%s"', wav_file, done_marker))

        -- Build JSON line
        local clean = clean_text(sent.text):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\t", "\\t")
        local json_line = string.format('{"text":"%s","output_file":"%s"}\n', clean, wav_file)

        local t0 = timestamp_ms()

        -- Write to FIFO
        local fifo_f = io.open(self._fifo, "w")
        if fifo_f then
            fifo_f:write(json_line)
            fifo_f:close()
        end

        -- Poll for done
        local poll = 0
        while poll < 900 do  -- 180s timeout
            poll = poll + 1
            sleep_ms(200)
            if file_exists(done_marker) then break end
        end

        local t1 = timestamp_ms()
        os.remove(done_marker)

        local dur = wav_duration_ms(wav_file)
        local synth_time = t1 - t0

        table.insert(results, {
            file = wav_file,
            duration_ms = dur,
            synth_ms = synth_time,
            text = sent.text,
            text_len = #sent.text,
            mem_kb = get_rss_kb(),
        })

        printf("  [%d/%d] %4dms synth, %4dms audio, %.2fx RT | %s\n",
            i, #sentences, synth_time, dur,
            dur > 0 and dur / synth_time or 0,
            sent.text:sub(1, 50))
    end
    return results
end

-- ── Strategy 3: 2 servers, pipeline depth 2 (current production) ────

Strategies.server_2x2 = {
    name = "server_2x2",
    description = "2 persistent servers, pipeline depth 2 (current production config)",
    _servers = {},
    _server_count = 2,
    _pipeline_depth = 2,
    _rr = 0,
}

function Strategies.server_2x2:init(config)
    os.execute("killall -9 piper 2>/dev/null")
    sleep_ms(200)
    self._servers = {}
    self._rr = 0

    for s = 1, self._server_count do
        local fifo = string.format("/tmp/piper_bench_server_%d_%d", self._server_count, s)
        os.execute(string.format('rm -f "%s" "%s.pid" "%s.log"', fifo, fifo, fifo))

        local script = string.format([=[#!/bin/sh
FIFO="%s"
rm -f "$FIFO" "${FIFO}.pid"
mkfifo "$FIFO"
exec 3<>"$FIFO"
%s --json-input <&3 2>>"${FIFO}.log" | while IFS= read -r wav_path; do
  wav_path=$(echo "$wav_path" | tr -d '\r\n')
  if [ -n "$wav_path" ]; then echo "0" > "${wav_path}.done"; fi
done &
PIPE_PID=$!
echo "$PIPE_PID" > "${FIFO}.pid"
wait $PIPE_PID 2>/dev/null
exec 3>&-
rm -f "$FIFO" "${FIFO}.pid"
]=], fifo, build_piper_cmd())

        local script_path = fifo .. ".sh"
        local sf = io.open(script_path, "w")
        if sf then sf:write(script); sf:close() end
        os.execute('chmod +x "' .. script_path .. '"')
        os.execute(string.format('/bin/sh "%s" &', script_path))
        self._servers[s] = { fifo = fifo, pid = nil }
    end

    -- Wait for all servers
    log("Waiting for %d servers to start...", self._server_count)
    local t0 = timestamp_ms()
    for _ = 1, 200 do
        sleep_ms(300)
        local all_ready = true
        for s = 1, self._server_count do
            if not self._servers[s].pid then
                local pf = io.open(self._servers[s].fifo .. ".pid", "r")
                if pf then
                    local pid = pf:read("*a"):gsub("%s+", "")
                    pf:close()
                    self._servers[s].pid = tonumber(pid)
                    log("  Server %d ready (PID %s)", s, pid)
                else
                    all_ready = false
                end
            end
        end
        if all_ready then break end
    end
    log("All servers ready in %dms", timestamp_ms() - t0)
end

function Strategies.server_2x2:cleanup()
    for _, srv in ipairs(self._servers) do
        if srv.pid then
            os.execute(string.format("kill %d 2>/dev/null", srv.pid))
        end
        os.execute(string.format('rm -f "%s" "%s.pid" "%s.sh" "%s.log"',
            srv.fifo, srv.fifo, srv.fifo, srv.fifo))
    end
    os.execute("killall -9 piper 2>/dev/null")
    self._servers = {}
end

function Strategies.server_2x2:synthesize(sentences)
    local results = {}
    local counter = 0

    -- With pipeline depth, we can fire multiple requests then collect
    local pending = {}  -- {idx, wav_file, done_marker, t0, sent}

    local function collect_one()
        -- Find the first pending that's done
        for pi = 1, #pending do
            local p = pending[pi]
            if file_exists(p.done_marker) then
                local t1 = timestamp_ms()
                os.remove(p.done_marker)
                local dur = wav_duration_ms(p.wav_file)
                local synth_time = t1 - p.t0
                table.insert(results, {
                    file = p.wav_file,
                    duration_ms = dur,
                    synth_ms = synth_time,
                    text = p.sent.text,
                    text_len = #p.sent.text,
                    mem_kb = get_rss_kb(),
                })
                printf("  [%d/%d] %4dms synth, %4dms audio, %.2fx RT | %s\n",
                    p.idx, #sentences, synth_time, dur,
                    dur > 0 and dur / synth_time or 0,
                    p.sent.text:sub(1, 50))
                table.remove(pending, pi)
                return true
            end
        end
        return false
    end

    local function collect_all_ready()
        while collect_one() do end
    end

    local max_inflight = self._server_count * self._pipeline_depth

    for i, sent in ipairs(sentences) do
        -- If at max capacity, wait for one to finish
        while #pending >= max_inflight do
            if not collect_one() then
                sleep_ms(200)
            end
        end

        counter = counter + 1
        local wav_file = string.format("%s/srv%dx%d_%d.wav",
            Config.output_dir, self._server_count, self._pipeline_depth, counter)
        local done_marker = wav_file .. ".done"
        os.execute(string.format('rm -f "%s" "%s"', wav_file, done_marker))

        -- Round-robin server selection
        self._rr = self._rr % self._server_count + 1
        local srv = self._servers[self._rr]

        local clean = clean_text(sent.text):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\t", "\\t")
        local json_line = string.format('{"text":"%s","output_file":"%s"}\n', clean, wav_file)

        local t0 = timestamp_ms()
        local fifo_f = io.open(srv.fifo, "w")
        if fifo_f then
            fifo_f:write(json_line)
            fifo_f:close()
        end

        table.insert(pending, {
            idx = i,
            wav_file = wav_file,
            done_marker = done_marker,
            t0 = t0,
            sent = sent,
        })

        -- Opportunistically collect any ready results
        collect_all_ready()
    end

    -- Drain remaining pending
    while #pending > 0 do
        if not collect_one() then
            sleep_ms(200)
        end
    end

    return results
end

-- ── Strategy 4: 4 servers, pipeline depth 2 (aggressive) ────────────

Strategies.server_4x2 = {
    name = "server_4x2",
    description = "4 persistent servers, pipeline depth 2 (aggressive parallelism)",
    _servers = {},
    _server_count = 4,
    _pipeline_depth = 2,
    _rr = 0,
}

-- Reuse server_2x2 methods
Strategies.server_4x2.init = Strategies.server_2x2.init
Strategies.server_4x2.cleanup = Strategies.server_2x2.cleanup
Strategies.server_4x2.synthesize = Strategies.server_2x2.synthesize

-- ── Strategy 5: Batch concatenation (N sentences per call) ──────────

Strategies.batch_5 = {
    name = "batch_5",
    description = "Batch 5 sentences per Piper call, serial synthesis",
    _batch_size = 5,
}

function Strategies.batch_5:init(config) end
function Strategies.batch_5:cleanup() end

function Strategies.batch_5:synthesize(sentences)
    local results = {}
    local counter = 0
    local batch_size = self._batch_size

    local i = 1
    while i <= #sentences do
        -- Build batch
        local batch = {}
        for j = i, math.min(i + batch_size - 1, #sentences) do
            table.insert(batch, sentences[j])
        end

        counter = counter + 1
        local wav_file = string.format("%s/batch%d_%d.wav",
            Config.output_dir, batch_size, counter)
        local text_file = string.format("/tmp/piper_bench_batch_%d.txt", counter)

        -- Concatenate all batch texts
        local combined = {}
        for _, s in ipairs(batch) do
            table.insert(combined, clean_text(s.text))
        end
        local combined_text = table.concat(combined, ". ")

        local tf = io.open(text_file, "w")
        if tf then
            tf:write(combined_text .. "\n")
            tf:close()
        end

        local cmd = string.format('%s --output_file "%s" < "%s" 2>/dev/null',
            build_piper_cmd(), wav_file, text_file)

        local t0 = timestamp_ms()
        os.execute(cmd)
        local t1 = timestamp_ms()

        os.remove(text_file)

        local total_dur = wav_duration_ms(wav_file)
        local synth_time = t1 - t0

        -- Distribute duration proportionally to text length
        local total_chars = 0
        for _, s in ipairs(batch) do total_chars = total_chars + #s.text end

        for bi, s in ipairs(batch) do
            local proportion = #s.text / math.max(1, total_chars)
            local est_dur = math.floor(total_dur * proportion)
            table.insert(results, {
                file = wav_file,
                duration_ms = est_dur,
                synth_ms = math.floor(synth_time / #batch),
                text = s.text,
                text_len = #s.text,
                mem_kb = get_rss_kb(),
                batch_id = counter,
            })
        end

        printf("  [batch %d] %d sentences, %4dms synth, %4dms audio, %.2fx RT\n",
            counter, #batch, synth_time, total_dur,
            total_dur > 0 and total_dur / synth_time or 0)

        i = i + #batch
    end
    return results
end

-- ── Strategy 6: Batch 10 sentences per call ─────────────────────────

Strategies.batch_10 = {
    name = "batch_10",
    description = "Batch 10 sentences per Piper call, serial synthesis",
    _batch_size = 10,
}
Strategies.batch_10.init = Strategies.batch_5.init
Strategies.batch_10.cleanup = Strategies.batch_5.cleanup
Strategies.batch_10.synthesize = Strategies.batch_5.synthesize

-- ── Strategy 7: Adaptive batching by sentence length ────────────────

Strategies.adaptive = {
    name = "adaptive",
    description = "Adaptive batching: group by character count target (~500 chars)",
    _target_chars = 500,
}

function Strategies.adaptive:init(config) end
function Strategies.adaptive:cleanup() end

function Strategies.adaptive:synthesize(sentences)
    local results = {}
    local counter = 0
    local target = self._target_chars

    local i = 1
    while i <= #sentences do
        -- Build batch up to target char count
        local batch = {}
        local char_count = 0
        for j = i, #sentences do
            local len = #sentences[j].text
            if char_count > 0 and char_count + len > target then break end
            table.insert(batch, sentences[j])
            char_count = char_count + len
        end

        counter = counter + 1
        local wav_file = string.format("%s/adaptive_%d.wav", Config.output_dir, counter)
        local text_file = string.format("/tmp/piper_bench_adaptive_%d.txt", counter)

        local combined = {}
        for _, s in ipairs(batch) do
            table.insert(combined, clean_text(s.text))
        end
        local combined_text = table.concat(combined, ". ")

        local tf = io.open(text_file, "w")
        if tf then
            tf:write(combined_text .. "\n")
            tf:close()
        end

        local cmd = string.format('%s --output_file "%s" < "%s" 2>/dev/null',
            build_piper_cmd(), wav_file, text_file)

        local t0 = timestamp_ms()
        os.execute(cmd)
        local t1 = timestamp_ms()

        os.remove(text_file)

        local total_dur = wav_duration_ms(wav_file)
        local synth_time = t1 - t0

        local total_chars = 0
        for _, s in ipairs(batch) do total_chars = total_chars + #s.text end

        for _, s in ipairs(batch) do
            local proportion = #s.text / math.max(1, total_chars)
            table.insert(results, {
                file = wav_file,
                duration_ms = math.floor(total_dur * proportion),
                synth_ms = math.floor(synth_time / #batch),
                text = s.text,
                text_len = #s.text,
                mem_kb = get_rss_kb(),
                batch_id = counter,
            })
        end

        printf("  [adaptive batch %d] %d sentences (%d chars), %4dms synth, %4dms audio, %.2fx RT\n",
            counter, #batch, char_count, synth_time, total_dur,
            total_dur > 0 and total_dur / synth_time or 0)

        i = i + #batch
    end
    return results
end

-- ── Strategy 8: Char-size profiling (find throughput sweet spot) ─────

Strategies.chunk_profile = {
    name = "chunk_profile",
    description = "Profile synthesis throughput vs text length (50-1000 chars)",
}

function Strategies.chunk_profile:init(config) end
function Strategies.chunk_profile:cleanup() end

function Strategies.chunk_profile:synthesize(sentences)
    local results = {}
    local counter = 0

    -- Group sentences into fixed character-count chunks
    local chunk_sizes = {50, 100, 200, 300, 500, 750, 1000}

    for _, target_size in ipairs(chunk_sizes) do
        log("  Profiling chunk size: %d chars", target_size)
        local i = 1
        local chunks_done = 0
        local total_synth = 0
        local total_dur = 0

        while i <= #sentences and chunks_done < 3 do  -- 3 samples per size
            -- Build a chunk up to target_size
            local chunk_text = ""
            local chunk_sents = {}
            for j = i, #sentences do
                local candidate = chunk_text
                if candidate ~= "" then candidate = candidate .. " " end
                candidate = candidate .. clean_text(sentences[j].text)
                if #candidate > target_size and #chunk_text > 0 then break end
                chunk_text = candidate
                table.insert(chunk_sents, sentences[j])
                i = j + 1
                if #chunk_text >= target_size then break end
            end

            if chunk_text == "" then break end

            counter = counter + 1
            local wav_file = string.format("%s/profile_%d_%d.wav",
                Config.output_dir, target_size, counter)
            local text_file = string.format("/tmp/piper_bench_profile_%d.txt", counter)

            local tf = io.open(text_file, "w")
            if tf then tf:write(chunk_text .. "\n"); tf:close() end

            local cmd = string.format('%s --output_file "%s" < "%s" 2>/dev/null',
                build_piper_cmd(), wav_file, text_file)

            local t0 = timestamp_ms()
            os.execute(cmd)
            local t1 = timestamp_ms()

            os.remove(text_file)

            local dur = wav_duration_ms(wav_file)
            local synth_time = t1 - t0
            total_synth = total_synth + synth_time
            total_dur = total_dur + dur
            chunks_done = chunks_done + 1

            for _, s in ipairs(chunk_sents) do
                table.insert(results, {
                    file = wav_file,
                    duration_ms = dur / #chunk_sents,
                    synth_ms = synth_time,
                    text = s.text,
                    text_len = #s.text,
                    mem_kb = get_rss_kb(),
                    chunk_target = target_size,
                    chunk_actual = #chunk_text,
                })
            end

            printf("    chunk=%4d actual=%4d: %4dms synth, %4dms audio, %.2fx RT, %.1f chars/s\n",
                target_size, #chunk_text, synth_time, dur,
                dur > 0 and dur / synth_time or 0,
                synth_time > 0 and #chunk_text * 1000 / synth_time or 0)
        end

        if total_synth > 0 then
            printf("  === target=%d avg: %.2fx RT, %.1f chars/s\n",
                target_size, total_dur / total_synth,
                chunks_done > 0 and total_synth > 0
                    and (total_dur > 0 and total_dur / total_synth or 0) or 0)
        end
    end

    return results
end

-- ── Strategy 9: 2 servers + batch 3 sentences ───────────────────────

Strategies.server_2x2_batch3 = {
    name = "server_2x2_batch3",
    description = "2 servers, pipeline depth 2, batch 3 sentences per request",
    _servers = {},
    _server_count = 2,
    _pipeline_depth = 2,
    _batch_size = 3,
    _rr = 0,
}

function Strategies.server_2x2_batch3:init(config)
    -- Reuse server_2x2 init
    Strategies.server_2x2.init(self, config)
end

function Strategies.server_2x2_batch3:cleanup()
    Strategies.server_2x2.cleanup(self)
end

function Strategies.server_2x2_batch3:synthesize(sentences)
    local results = {}
    local counter = 0
    local batch_size = self._batch_size
    local pending = {}
    local max_inflight = self._server_count * self._pipeline_depth

    local function collect_one()
        for pi = 1, #pending do
            local p = pending[pi]
            if file_exists(p.done_marker) then
                local t1 = timestamp_ms()
                os.remove(p.done_marker)
                local dur = wav_duration_ms(p.wav_file)
                local synth_time = t1 - p.t0
                local total_chars = 0
                for _, s in ipairs(p.batch) do total_chars = total_chars + #s.text end
                for _, s in ipairs(p.batch) do
                    local proportion = #s.text / math.max(1, total_chars)
                    table.insert(results, {
                        file = p.wav_file,
                        duration_ms = math.floor(dur * proportion),
                        synth_ms = math.floor(synth_time / #p.batch),
                        text = s.text,
                        text_len = #s.text,
                        mem_kb = get_rss_kb(),
                        batch_id = p.batch_id,
                    })
                end
                printf("  [batch %d] %d sents, %4dms synth, %4dms audio, %.2fx RT\n",
                    p.batch_id, #p.batch, synth_time, dur,
                    dur > 0 and dur / synth_time or 0)
                table.remove(pending, pi)
                return true
            end
        end
        return false
    end

    local i = 1
    while i <= #sentences do
        while #pending >= max_inflight do
            if not collect_one() then sleep_ms(200) end
        end

        -- Build batch
        local batch = {}
        for j = i, math.min(i + batch_size - 1, #sentences) do
            table.insert(batch, sentences[j])
        end

        counter = counter + 1
        local wav_file = string.format("%s/srv2b3_%d.wav", Config.output_dir, counter)
        local done_marker = wav_file .. ".done"
        os.execute(string.format('rm -f "%s" "%s"', wav_file, done_marker))

        self._rr = self._rr % self._server_count + 1
        local srv = self._servers[self._rr]

        local combined = {}
        for _, s in ipairs(batch) do
            table.insert(combined, clean_text(s.text))
        end
        local combined_text = table.concat(combined, ". ")
        local clean = combined_text:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\t", "\\t")
        local json_line = string.format('{"text":"%s","output_file":"%s"}\n', clean, wav_file)

        local t0 = timestamp_ms()
        local fifo_f = io.open(srv.fifo, "w")
        if fifo_f then fifo_f:write(json_line); fifo_f:close() end

        table.insert(pending, {
            batch_id = counter,
            wav_file = wav_file,
            done_marker = done_marker,
            t0 = t0,
            batch = batch,
        })

        -- Collect ready
        while collect_one() do end

        i = i + #batch
    end

    while #pending > 0 do
        if not collect_one() then sleep_ms(200) end
    end

    return results
end

-- ── Strategy 10: 1 server, pipeline depth 2 (recommended config) ────

Strategies.server_1x2 = {
    name = "server_1x2",
    description = "1 persistent server, pipeline depth 2 (queue next while current synthesizes)",
    _servers = {},
    _server_count = 1,
    _pipeline_depth = 2,
    _rr = 0,
}

Strategies.server_1x2.init = Strategies.server_2x2.init
Strategies.server_1x2.cleanup = Strategies.server_2x2.cleanup
Strategies.server_1x2.synthesize = Strategies.server_2x2.synthesize

-- ── Strategy 11: 1 server + batch 3 sentences (hybrid) ─────────────

Strategies.server_1x1_batch3 = {
    name = "server_1x1_batch3",
    description = "1 persistent server, pipeline depth 1, batch 3 sentences per request",
    _server_pid = nil,
    _fifo = "/tmp/piper_bench_server_1b3",
    _batch_size = 3,
}

function Strategies.server_1x1_batch3:init(config)
    -- Reuse server_1x1 init with our FIFO path
    Strategies.server_1x1.init(self, config)
end

function Strategies.server_1x1_batch3:cleanup()
    Strategies.server_1x1.cleanup(self)
end

function Strategies.server_1x1_batch3:synthesize(sentences)
    local results = {}
    local counter = 0
    local batch_size = self._batch_size

    local i = 1
    while i <= #sentences do
        -- Build batch
        local batch = {}
        for j = i, math.min(i + batch_size - 1, #sentences) do
            table.insert(batch, sentences[j])
        end

        counter = counter + 1
        local wav_file = string.format("%s/srv1b3_%d.wav", Config.output_dir, counter)
        local done_marker = wav_file .. ".done"
        os.execute(string.format('rm -f "%s" "%s"', wav_file, done_marker))

        -- Combine text
        local combined = {}
        for _, s in ipairs(batch) do
            table.insert(combined, clean_text(s.text))
        end
        local combined_text = table.concat(combined, ". ")
        local clean = combined_text:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\t", "\\t")
        local json_line = string.format('{"text":"%s","output_file":"%s"}\n', clean, wav_file)

        local t0 = timestamp_ms()
        local fifo_f = io.open(self._fifo, "w")
        if fifo_f then fifo_f:write(json_line); fifo_f:close() end

        -- Poll for done
        local poll = 0
        while poll < 900 do
            poll = poll + 1
            sleep_ms(200)
            if file_exists(done_marker) then break end
        end

        local t1 = timestamp_ms()
        os.remove(done_marker)

        local total_dur = wav_duration_ms(wav_file)
        local synth_time = t1 - t0
        local total_chars = 0
        for _, s in ipairs(batch) do total_chars = total_chars + #s.text end

        for _, s in ipairs(batch) do
            local proportion = #s.text / math.max(1, total_chars)
            table.insert(results, {
                file = wav_file,
                duration_ms = math.floor(total_dur * proportion),
                synth_ms = math.floor(synth_time / #batch),
                text = s.text,
                text_len = #s.text,
                mem_kb = get_rss_kb(),
                batch_id = counter,
            })
        end

        printf("  [batch %d] %d sents (%d chars), %4dms synth, %4dms audio, %.2fx RT\n",
            counter, #batch, total_chars, synth_time, total_dur,
            total_dur > 0 and total_dur / synth_time or 0)

        i = i + #batch
    end
    return results
end

-- ── Strategy 12: Model comparison ───────────────────────────────────

Strategies.model_compare = {
    name = "model_compare",
    description = "Compare all available .onnx models (danny, lessac, ryan)",
}

function Strategies.model_compare:init(config) end
function Strategies.model_compare:cleanup() end

function Strategies.model_compare:synthesize(sentences)
    local results = {}

    -- Find all .onnx models in the piper directory
    local piper_dir = Config.piper_dir or Config.model_path:match("^(.*/)")
    local models = {}
    local ls = io.popen(string.format('ls "%s"*.onnx 2>/dev/null', piper_dir))
    if ls then
        for line in ls:lines() do
            if not line:match("%.onnx%.json$") then
                table.insert(models, line)
            end
        end
        ls:close()
    end

    if #models == 0 then
        models = { Config.model_path }
    end

    -- Test each model with the same 8 sentences (mix of short and long)
    local test_subset = {}
    local pick_indices = {1, 4, 10, 14, 18, 20, 24, 25}
    for _, idx in ipairs(pick_indices) do
        if sentences[idx] then
            table.insert(test_subset, sentences[idx])
        end
    end
    if #test_subset == 0 then
        for j = 1, math.min(8, #sentences) do
            table.insert(test_subset, sentences[j])
        end
    end

    for _, model_path in ipairs(models) do
        local model_name = model_path:match("([^/]+)%.onnx$") or model_path
        log("  Testing model: %s", model_name)

        -- Build command for this specific model
        local prefix = ""
        if Config.ld_linux then
            prefix = string.format('"%s" --library-path "%s" ',
                Config.ld_linux, Config.lib_path)
        elseif Config.lib_path then
            prefix = string.format('LD_LIBRARY_PATH="%s" ', Config.lib_path)
        end
        local espeak_flag = ""
        if Config.espeak_data then
            espeak_flag = string.format(' --espeak_data "%s"', Config.espeak_data)
        end
        local model_cmd = string.format('nice -n 19 %s%s --model "%s"%s --sentence_silence 0',
            prefix, Config.piper_bin, model_path, espeak_flag)

        local model_total_synth = 0
        local model_total_dur = 0

        for si, sent in ipairs(test_subset) do
            local wav_file = string.format("%s/model_%s_%d.wav",
                Config.output_dir, model_name, si)
            local text_file = string.format("/tmp/piper_bench_model_%d.txt", si)

            local tf = io.open(text_file, "w")
            if tf then tf:write(clean_text(sent.text) .. "\n"); tf:close() end

            local cmd = string.format('%s --output_file "%s" < "%s" 2>/dev/null',
                model_cmd, wav_file, text_file)

            local t0 = timestamp_ms()
            os.execute(cmd)
            local t1 = timestamp_ms()
            os.remove(text_file)

            local dur = wav_duration_ms(wav_file)
            local synth_time = t1 - t0
            model_total_synth = model_total_synth + synth_time
            model_total_dur = model_total_dur + dur

            table.insert(results, {
                file = wav_file,
                duration_ms = dur,
                synth_ms = synth_time,
                text = sent.text,
                text_len = #sent.text,
                mem_kb = get_rss_kb(),
                model = model_name,
            })

            printf("    [%s #%d] %4dms synth, %4dms audio, %.2fx RT | %s\n",
                model_name, si, synth_time, dur,
                dur > 0 and dur / synth_time or 0,
                sent.text:sub(1, 40))
        end

        local model_rt = model_total_dur > 0 and model_total_dur / model_total_synth or 0
        log("  === %s: %.2fx RT, %.1f chars/s",
            model_name, model_rt,
            model_total_synth > 0 and
                (function() local c=0; for _,s in ipairs(test_subset) do c=c+#s.text end; return c*1000/model_total_synth end)()
                or 0)
    end

    return results
end

-- ── Strategy 13: Deterministic inference (noise=0) ──────────────────

Strategies.noise_zero = {
    name = "noise_zero",
    description = "Deterministic inference: --noise_scale 0 --noise_w 0",
}

function Strategies.noise_zero:init(config) end
function Strategies.noise_zero:cleanup() end

function Strategies.noise_zero:synthesize(sentences)
    local results = {}
    local counter = 0

    for i, sent in ipairs(sentences) do
        counter = counter + 1
        local wav_file = string.format("%s/nz_%d.wav", Config.output_dir, counter)
        local text_file = string.format("/tmp/piper_bench_nz_%d.txt", counter)

        local tf = io.open(text_file, "w")
        if tf then tf:write(clean_text(sent.text) .. "\n"); tf:close() end

        local cmd = string.format('%s --output_file "%s" < "%s" 2>/dev/null',
            build_piper_cmd("--noise_scale 0 --noise_w 0"), wav_file, text_file)

        local t0 = timestamp_ms()
        os.execute(cmd)
        local t1 = timestamp_ms()
        os.remove(text_file)

        local dur = wav_duration_ms(wav_file)
        local synth_time = t1 - t0

        table.insert(results, {
            file = wav_file,
            duration_ms = dur,
            synth_ms = synth_time,
            text = sent.text,
            text_len = #sent.text,
            mem_kb = get_rss_kb(),
        })

        printf("  [%d/%d] %4dms synth, %4dms audio, %.2fx RT | %s\n",
            i, #sentences, synth_time, dur,
            dur > 0 and dur / synth_time or 0,
            sent.text:sub(1, 50))
    end
    return results
end

-- ── Strategy 14: Raw PCM streaming (--output_raw) ───────────────────

Strategies.output_raw = {
    name = "output_raw",
    description = "Stream raw PCM via --output_raw, measure first-byte and total latency",
}

function Strategies.output_raw:init(config) end
function Strategies.output_raw:cleanup() end

function Strategies.output_raw:synthesize(sentences)
    local results = {}
    local counter = 0
    local sr = Config.sample_rate or 16000
    -- bytes per ms = sample_rate * 2 (16-bit) / 1000
    local bytes_per_ms = sr * 2 / 1000

    for i, sent in ipairs(sentences) do
        counter = counter + 1
        local raw_file = string.format("%s/raw_%d.pcm", Config.output_dir, counter)
        local text_file = string.format("/tmp/piper_bench_raw_%d.txt", counter)

        local tf = io.open(text_file, "w")
        if tf then tf:write(clean_text(sent.text) .. "\n"); tf:close() end

        -- Use --output_raw and redirect stdout to file, capture timing
        -- We use a wrapper script that records first-byte time
        local timing_file = string.format("/tmp/piper_bench_raw_timing_%d.txt", counter)
        local script = string.format([=[#!/bin/sh
T0=$(date +%%s%%3N)
%s --output_raw < "%s" 2>/dev/null | {
  # Read first byte to measure first-byte latency
  dd bs=1 count=1 of=/dev/null 2>/dev/null
  T1=$(date +%%s%%3N)
  cat > "%s.tail"
  T2=$(date +%%s%%3N)
  echo "$T0 $T1 $T2" > "%s"
}
# Reassemble: first byte was consumed, but we saved the rest
printf '\0' > "%s"
cat "%s.tail" >> "%s" 2>/dev/null
rm -f "%s.tail"
]=], build_piper_cmd("--output_raw"), text_file,
    raw_file, timing_file,
    raw_file, raw_file, raw_file, raw_file)

        local script_path = string.format("/tmp/piper_bench_raw_script_%d.sh", counter)
        local sf = io.open(script_path, "w")
        if sf then sf:write(script); sf:close() end

        local t0 = timestamp_ms()
        os.execute('/bin/sh "' .. script_path .. '"')
        local t1 = timestamp_ms()

        os.remove(text_file)
        os.remove(script_path)

        -- Read timing info
        local first_byte_ms = 0
        local tf2 = io.open(timing_file, "r")
        if tf2 then
            local line = tf2:read("*l") or ""
            tf2:close()
            os.remove(timing_file)
            local ts0, ts1, ts2 = line:match("(%d+)%s+(%d+)%s+(%d+)")
            if ts0 and ts1 then
                first_byte_ms = tonumber(ts1) - tonumber(ts0)
            end
        end

        -- Calculate audio duration from raw PCM size
        local raw_size = file_size(raw_file)
        local dur = raw_size > 0 and math.floor(raw_size / bytes_per_ms) or 0
        local synth_time = t1 - t0

        table.insert(results, {
            file = raw_file,
            duration_ms = dur,
            synth_ms = synth_time,
            text = sent.text,
            text_len = #sent.text,
            mem_kb = get_rss_kb(),
            first_byte_ms = first_byte_ms,
        })

        printf("  [%d/%d] %4dms synth (%4dms first-byte), %4dms audio, %.2fx RT | %s\n",
            i, #sentences, synth_time, first_byte_ms, dur,
            dur > 0 and dur / synth_time or 0,
            sent.text:sub(1, 40))

        os.remove(raw_file)
        os.remove(raw_file .. ".tail")
    end
    return results
end

-- ── Strategy 15: Faster speaking rate (length_scale 0.8) ────────────

Strategies.length_scale_08 = {
    name = "length_scale_08",
    description = "1.25x speaking speed via --length_scale 0.8",
}

function Strategies.length_scale_08:init(config) end
function Strategies.length_scale_08:cleanup() end

function Strategies.length_scale_08:synthesize(sentences)
    local results = {}
    local counter = 0

    for i, sent in ipairs(sentences) do
        counter = counter + 1
        local wav_file = string.format("%s/ls08_%d.wav", Config.output_dir, counter)
        local text_file = string.format("/tmp/piper_bench_ls08_%d.txt", counter)

        local tf = io.open(text_file, "w")
        if tf then tf:write(clean_text(sent.text) .. "\n"); tf:close() end

        local cmd = string.format('%s --output_file "%s" < "%s" 2>/dev/null',
            build_piper_cmd("--length_scale 0.8"), wav_file, text_file)

        local t0 = timestamp_ms()
        os.execute(cmd)
        local t1 = timestamp_ms()
        os.remove(text_file)

        local dur = wav_duration_ms(wav_file)
        local synth_time = t1 - t0

        table.insert(results, {
            file = wav_file,
            duration_ms = dur,
            synth_ms = synth_time,
            text = sent.text,
            text_len = #sent.text,
            mem_kb = get_rss_kb(),
        })

        printf("  [%d/%d] %4dms synth, %4dms audio, %.2fx RT | %s\n",
            i, #sentences, synth_time, dur,
            dur > 0 and dur / synth_time or 0,
            sent.text:sub(1, 50))
    end
    return results
end

-- ── Strategy 16: Quiet mode (--quiet) ───────────────────────────────

Strategies.quiet_flag = {
    name = "quiet_flag",
    description = "Per-process with --quiet flag (disable Piper logging)",
}

function Strategies.quiet_flag:init(config) end
function Strategies.quiet_flag:cleanup() end

function Strategies.quiet_flag:synthesize(sentences)
    local results = {}
    local counter = 0

    for i, sent in ipairs(sentences) do
        counter = counter + 1
        local wav_file = string.format("%s/quiet_%d.wav", Config.output_dir, counter)
        local text_file = string.format("/tmp/piper_bench_quiet_%d.txt", counter)

        local tf = io.open(text_file, "w")
        if tf then tf:write(clean_text(sent.text) .. "\n"); tf:close() end

        local cmd = string.format('%s --output_file "%s" < "%s" 2>/dev/null',
            build_piper_cmd("--quiet"), wav_file, text_file)

        local t0 = timestamp_ms()
        os.execute(cmd)
        local t1 = timestamp_ms()
        os.remove(text_file)

        local dur = wav_duration_ms(wav_file)
        local synth_time = t1 - t0

        table.insert(results, {
            file = wav_file,
            duration_ms = dur,
            synth_ms = synth_time,
            text = sent.text,
            text_len = #sent.text,
            mem_kb = get_rss_kb(),
        })

        printf("  [%d/%d] %4dms synth, %4dms audio, %.2fx RT | %s\n",
            i, #sentences, synth_time, dur,
            dur > 0 and dur / synth_time or 0,
            sent.text:sub(1, 50))
    end
    return results
end

-- ── Aggregate statistics ─────────────────────────────────────────────

local function compute_stats(results)
    if #results == 0 then
        return { error = "no results" }
    end

    local total_synth = 0
    local total_audio = 0
    local total_chars = 0
    local total_words = 0
    local total_wav_bytes = 0
    local peak_mem = 0
    local synth_times = {}
    local gaps = {}

    for i, r in ipairs(results) do
        total_synth = total_synth + r.synth_ms
        total_audio = total_audio + r.duration_ms
        total_chars = total_chars + r.text_len
        peak_mem = math.max(peak_mem, r.mem_kb or 0)
        table.insert(synth_times, r.synth_ms)

        for _ in r.text:gmatch("%S+") do
            total_words = total_words + 1
        end

        if r.file then
            total_wav_bytes = total_wav_bytes + file_size(r.file)
        end

        -- Gap: time between this sentence being ready and the next one starting
        -- For serial, gap ≈ synth time of next sentence
        -- For parallel, gap ≈ max(0, next_synth - current_audio)
        if i > 1 then
            local gap = math.max(0, r.synth_ms - results[i-1].duration_ms)
            table.insert(gaps, gap)
        end
    end

    table.sort(synth_times)
    table.sort(gaps)

    local function percentile(arr, p)
        if #arr == 0 then return 0 end
        local idx = math.ceil(#arr * p / 100)
        return arr[math.min(idx, #arr)]
    end

    local avg_gap = 0
    if #gaps > 0 then
        local sum = 0
        for _, g in ipairs(gaps) do sum = sum + g end
        avg_gap = sum / #gaps
    end

    return {
        sentences_total = #results,
        total_synthesis_ms = total_synth,
        total_audio_duration_ms = total_audio,
        realtime_factor = total_synth > 0 and total_audio / total_synth or 0,
        cold_start_ms = results[1] and results[1].synth_ms or 0,
        avg_synth_ms = total_synth / #results,
        median_synth_ms = percentile(synth_times, 50),
        p95_synth_ms = percentile(synth_times, 95),
        avg_gap_ms = avg_gap,
        max_gap_ms = #gaps > 0 and gaps[#gaps] or 0,
        p95_gap_ms = percentile(gaps, 95),
        throughput_chars_per_sec = total_synth > 0 and total_chars * 1000 / total_synth or 0,
        throughput_words_per_sec = total_synth > 0 and total_words * 1000 / total_synth or 0,
        peak_memory_kb = peak_mem,
        wav_total_bytes = total_wav_bytes,
        total_chars = total_chars,
        total_words = total_words,
    }
end

-- ── Results output ───────────────────────────────────────────────────

local function write_results(strategy_name, stats, results, elapsed_ms)
    -- Text report
    local report_path = string.format("%s/%s.txt", Config.results_dir, strategy_name)
    local f = io.open(report_path, "w")
    if not f then return end

    f:write(string.format("═══════════════════════════════════════════════════════════\n"))
    f:write(string.format("  PIPER TTS BENCHMARK — %s\n", strategy_name:upper()))
    f:write(string.format("═══════════════════════════════════════════════════════════\n"))
    f:write(string.format("  Model:        %s\n", Config.model_path))
    f:write(string.format("  Sample Rate:  %d Hz\n", Config.sample_rate))
    f:write(string.format("  Date:         %s\n", os.date()))
    f:write(string.format("  Wall time:    %.1f s\n", elapsed_ms / 1000))
    f:write(string.format("───────────────────────────────────────────────────────────\n"))
    f:write(string.format("  Sentences:           %d\n", stats.sentences_total))
    f:write(string.format("  Total chars:         %d\n", stats.total_chars))
    f:write(string.format("  Total words:         %d\n", stats.total_words))
    f:write(string.format("───────────────────────────────────────────────────────────\n"))
    f:write(string.format("  Total synthesis:     %.1f s\n", stats.total_synthesis_ms / 1000))
    f:write(string.format("  Total audio:         %.1f s\n", stats.total_audio_duration_ms / 1000))
    f:write(string.format("  ★ Realtime factor:   %.3f×\n", stats.realtime_factor))
    f:write(string.format("───────────────────────────────────────────────────────────\n"))
    f:write(string.format("  Cold start:          %d ms\n", stats.cold_start_ms))
    f:write(string.format("  Avg synth/sentence:  %d ms\n", stats.avg_synth_ms))
    f:write(string.format("  Median synth:        %d ms\n", stats.median_synth_ms))
    f:write(string.format("  P95 synth:           %d ms\n", stats.p95_synth_ms))
    f:write(string.format("───────────────────────────────────────────────────────────\n"))
    f:write(string.format("  Avg gap:             %d ms\n", stats.avg_gap_ms))
    f:write(string.format("  Max gap:             %d ms\n", stats.max_gap_ms))
    f:write(string.format("  P95 gap:             %d ms\n", stats.p95_gap_ms))
    f:write(string.format("───────────────────────────────────────────────────────────\n"))
    f:write(string.format("  Throughput:          %.1f chars/s\n", stats.throughput_chars_per_sec))
    f:write(string.format("  Throughput:          %.1f words/s\n", stats.throughput_words_per_sec))
    f:write(string.format("  Peak memory:         %d KB\n", stats.peak_memory_kb))
    f:write(string.format("  WAV total:           %.1f KB\n", stats.wav_total_bytes / 1024))
    f:write(string.format("═══════════════════════════════════════════════════════════\n\n"))

    -- Per-sentence detail
    f:write("Per-sentence detail:\n")
    f:write(string.format("%-4s %-6s %-6s %-6s %-6s %s\n",
        "#", "Synth", "Audio", "RT×", "Chars", "Text"))
    f:write(string.rep("-", 80) .. "\n")
    for i, r in ipairs(results) do
        f:write(string.format("%-4d %5dms %5dms %5.2f× %5d  %s\n",
            i, r.synth_ms, r.duration_ms,
            r.duration_ms > 0 and r.duration_ms / math.max(1, r.synth_ms) or 0,
            r.text_len,
            r.text:sub(1, 60)))
    end

    f:close()
    log("Report written to %s", report_path)

    -- JSON report (simple manual serialization)
    local json_path = string.format("%s/%s.json", Config.results_dir, strategy_name)
    local jf = io.open(json_path, "w")
    if jf then
        jf:write("{\n")
        jf:write(string.format('  "strategy": "%s",\n', strategy_name))
        jf:write(string.format('  "model": "%s",\n', Config.model_path))
        jf:write(string.format('  "sample_rate": %d,\n', Config.sample_rate))
        jf:write(string.format('  "date": "%s",\n', os.date()))
        jf:write(string.format('  "wall_time_ms": %d,\n', elapsed_ms))

        for k, v in pairs(stats) do
            if type(v) == "number" then
                jf:write(string.format('  "%s": %.3f,\n', k, v))
            end
        end

        jf:write('  "per_sentence": [\n')
        for i, r in ipairs(results) do
            local escaped_text = r.text:gsub("\\", "\\\\"):gsub('"', '\\"')
            jf:write(string.format(
                '    {"synth_ms":%d,"duration_ms":%d,"text_len":%d,"mem_kb":%d,"text":"%s"}%s\n',
                r.synth_ms, r.duration_ms, r.text_len, r.mem_kb or 0,
                escaped_text:sub(1, 80),
                i < #results and "," or ""))
        end
        jf:write("  ]\n}\n")
        jf:close()
    end
end

-- ── Summary comparison ───────────────────────────────────────────────

local function write_comparison(all_stats)
    local path = Config.results_dir .. "/COMPARISON.txt"
    local f = io.open(path, "w")
    if not f then return end

    f:write("╔══════════════════════════════════════════════════════════════════════════════╗\n")
    f:write("║              PIPER TTS BENCHMARK — STRATEGY COMPARISON                      ║\n")
    f:write("╠══════════════════════════════════════════════════════════════════════════════╣\n")
    f:write(string.format("║  Model: %-68s ║\n", Config.model_path:match("([^/]+)$") or Config.model_path))
    f:write(string.format("║  Date:  %-68s ║\n", os.date()))
    f:write("╠══════════════════════════════════════════════════════════════════════════════╣\n")
    f:write(string.format("║ %-22s │ %6s │ %6s │ %6s │ %6s │ %6s │ %6s ║\n",
        "Strategy", "RT×", "Cold", "AvgGap", "MaxGap", "Chars/s", "Mem KB"))
    f:write("╠══════════════════════════════════════════════════════════════════════════════╣\n")

    for _, entry in ipairs(all_stats) do
        local s = entry.stats
        f:write(string.format("║ %-22s │ %6.3f │ %5.1fs │ %5.1fs │ %5.1fs │ %6.1f │ %6d ║\n",
            entry.name,
            s.realtime_factor,
            s.cold_start_ms / 1000,
            s.avg_gap_ms / 1000,
            s.max_gap_ms / 1000,
            s.throughput_chars_per_sec,
            s.peak_memory_kb))
    end

    f:write("╚══════════════════════════════════════════════════════════════════════════════╝\n\n")

    -- Winner analysis
    local best_rt = {name = "", val = 0}
    local best_gap = {name = "", val = math.huge}
    local best_cold = {name = "", val = math.huge}
    local best_throughput = {name = "", val = 0}

    for _, entry in ipairs(all_stats) do
        local s = entry.stats
        if s.realtime_factor > best_rt.val then
            best_rt = {name = entry.name, val = s.realtime_factor}
        end
        if s.avg_gap_ms < best_gap.val then
            best_gap = {name = entry.name, val = s.avg_gap_ms}
        end
        if s.cold_start_ms < best_cold.val then
            best_cold = {name = entry.name, val = s.cold_start_ms}
        end
        if s.throughput_chars_per_sec > best_throughput.val then
            best_throughput = {name = entry.name, val = s.throughput_chars_per_sec}
        end
    end

    f:write("WINNERS:\n")
    f:write(string.format("  Best realtime factor:  %s (%.3f×)\n", best_rt.name, best_rt.val))
    f:write(string.format("  Lowest avg gap:        %s (%.1f ms)\n", best_gap.name, best_gap.val))
    f:write(string.format("  Fastest cold start:    %s (%.1f ms)\n", best_cold.name, best_cold.val))
    f:write(string.format("  Highest throughput:    %s (%.1f chars/s)\n", best_throughput.name, best_throughput.val))

    f:close()
    log("Comparison written to %s", path)

    -- Also print to stdout
    local rf = io.open(path, "r")
    if rf then
        io.write("\n" .. rf:read("*a"))
        rf:close()
    end
end

-- ── Main ─────────────────────────────────────────────────────────────

local function main()
    local args = arg or {}

    -- Parse arguments
    local run_strategy = nil
    local quick_mode = false
    local page_filter = nil

    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--list" then
            printf("Available strategies:\n")
            for name, strat in pairs(Strategies) do
                printf("  %-20s  %s\n", name, strat.description or "")
            end
            return
        elseif a == "--quick" then
            quick_mode = true
        elseif a == "--pages" then
            i = i + 1
            page_filter = {}
            for p in args[i]:gmatch("(%d+)") do
                table.insert(page_filter, tonumber(p))
            end
        elseif a == "--help" or a == "-h" then
            printf("Usage: lua benchmark.lua [strategy] [--quick] [--pages 1,2,3] [--list]\n")
            return
        elseif not a:match("^%-") then
            run_strategy = a
        end
        i = i + 1
    end

    -- Resolve configuration
    resolve_config()

    -- Load test document
    local script_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
    local TestDoc = dofile(script_dir .. "testdoc.lua")

    local doc_stats = TestDoc:getStats()
    log("Test document: %d pages, %d paragraphs, %d sentences, %d words, %d chars",
        doc_stats.pages, doc_stats.paragraphs, doc_stats.sentences,
        doc_stats.total_words, doc_stats.total_chars)
    log("Sentence lengths: min=%d median=%d max=%d avg=%.0f",
        doc_stats.min_sentence_len, doc_stats.median_sentence_len,
        doc_stats.max_sentence_len, doc_stats.avg_sentence_len)

    -- Select sentences to test
    local all_sentences = TestDoc:getAllSentences()
    local test_sentences = {}

    if page_filter then
        local page_set = {}
        for _, p in ipairs(page_filter) do page_set[p] = true end
        for _, s in ipairs(all_sentences) do
            if page_set[s.page] then table.insert(test_sentences, s) end
        end
    elseif quick_mode then
        -- Just pages 1 and 4 (short sentences, varied)
        for _, s in ipairs(all_sentences) do
            if s.page == 1 or s.page == 4 then
                table.insert(test_sentences, s)
            end
        end
    else
        test_sentences = all_sentences
    end

    log("Testing %d sentences", #test_sentences)

    -- Determine which strategies to run
    local strategy_order = {
        "baseline", "server_1x1", "server_1x2", "server_2x2", "server_4x2",
        "batch_5", "batch_10", "adaptive",
        "server_2x2_batch3", "server_1x1_batch3",
        "noise_zero", "output_raw", "length_scale_08", "quiet_flag",
        "model_compare", "chunk_profile",
    }

    local strategies_to_run = {}
    if run_strategy then
        if Strategies[run_strategy] then
            table.insert(strategies_to_run, run_strategy)
        else
            io.stderr:write("Unknown strategy: " .. run_strategy .. "\n")
            os.exit(1)
        end
    else
        strategies_to_run = strategy_order
    end

    -- Run benchmarks
    local all_stats = {}

    for _, name in ipairs(strategies_to_run) do
        local strat = Strategies[name]
        if strat then
            log("═══════════════════════════════════════════════════════")
            log("STRATEGY: %s", name)
            log("  %s", strat.description or "")
            log("═══════════════════════════════════════════════════════")

            -- Clean up previous WAV files
            os.execute(string.format('rm -f %s/*.wav %s/*.done',
                Config.output_dir, Config.output_dir))

            -- Kill any leftover piper processes
            os.execute("killall -9 piper 2>/dev/null")
            sleep_ms(500)

            -- Init strategy
            local init_ok, init_err = pcall(function() strat:init(Config) end)
            if not init_ok then
                log("ERROR: Strategy init failed: %s", tostring(init_err))
                goto continue
            end

            -- Run synthesis
            local t0 = timestamp_ms()
            local run_ok, results_or_err = pcall(function()
                return strat:synthesize(test_sentences)
            end)
            local t1 = timestamp_ms()

            if not run_ok then
                log("ERROR: Strategy failed: %s", tostring(results_or_err))
                pcall(function() strat:cleanup() end)
                goto continue
            end

            local results = results_or_err
            local stats = compute_stats(results)

            -- Print summary
            log("───────────────────────────────────────────────────────")
            log("  Realtime factor: %.3f×", stats.realtime_factor)
            log("  Cold start:      %d ms", stats.cold_start_ms)
            log("  Avg gap:         %d ms", stats.avg_gap_ms)
            log("  Max gap:         %d ms", stats.max_gap_ms)
            log("  Throughput:      %.1f chars/s, %.1f words/s",
                stats.throughput_chars_per_sec, stats.throughput_words_per_sec)
            log("  Peak memory:     %d KB", stats.peak_memory_kb)
            log("───────────────────────────────────────────────────────")

            write_results(name, stats, results, t1 - t0)

            table.insert(all_stats, {name = name, stats = stats})

            -- Cleanup strategy
            pcall(function() strat:cleanup() end)

            -- Clean WAVs to free disk space between strategies
            os.execute(string.format('rm -f %s/*.wav %s/*.done',
                Config.output_dir, Config.output_dir))

            ::continue::
        end
    end

    -- Write comparison
    if #all_stats > 1 then
        write_comparison(all_stats)
    end

    log("Benchmark complete. Results in %s", Config.results_dir)
end

main()
