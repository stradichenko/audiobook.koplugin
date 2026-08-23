--[[--
Benchmark Runner
Runs standardized TTS benchmarks on boilerplate text to collect
device performance data.  Users trigger this from the plugin menu
and share the generated report on GitHub.

Tests Piper (danny-low, danny-medium if available) and espeak-ng
on a fixed set of sentences of varying length.

@module benchmarkrunner
--]]

local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local _ = require("audiobook_gettext")

local _utils_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local Utils = dofile(_utils_dir .. "utils.lua")
local WavUtils = dofile(_utils_dir .. "wavutils.lua")

local BenchmarkRunner = {}

-- ── Benchmark sentences ──────────────────────────────────────────────
-- A fixed set of sentences covering short, medium, and long inputs.
-- These are embedded directly so the benchmark works without dev/ files.

local BENCH_SENTENCES = {
    -- Short (dialogue fragments)
    {
        label = "short_dialogue",
        text = '"Did you hear that?" he asked. She shook her head slowly.',
    },
    -- Medium (narrative prose)
    {
        label = "medium_narrative",
        text = "The village of Thornbury had existed for seven hundred years, nestled in the gentle fold between two limestone ridges that ran parallel to the coast. Its church spire, visible for miles around, served as a landmark for sailors navigating the treacherous waters of the bay.",
    },
    -- Medium-long (technical)
    {
        label = "medium_technical",
        text = "The Kobo Clara 2E features an NXP i.MX6 SoloLite processor running at 1 GHz, with 256 MB of RAM and 16 GB of internal storage. The display measures 6 inches diagonally with a resolution of 1448 by 1072 pixels, yielding a pixel density of approximately 300 PPI.",
    },
    -- Long (complex academic)
    {
        label = "long_academic",
        text = "The relationship between computational complexity and real-time audio synthesis presents a fundamental challenge for embedded systems, particularly when neural network architectures are deployed on processors with limited floating-point throughput and constrained memory hierarchies. Contemporary text-to-speech systems based on transformer architectures typically require between fifty and two hundred million parameters.",
    },
    -- Very short (fragments)
    {
        label = "short_fragments",
        text = "Stop. Listen. Nothing. The door creaked open. Darkness beyond. Cold air rushed in.",
    },
}

-- ── Helpers ──────────────────────────────────────────────────────────

local function shellCapture(cmd, timeout_s)
    local full_cmd = cmd .. " 2>/dev/null"
    if timeout_s then
        full_cmd = "timeout " .. timeout_s .. " " .. full_cmd
    end
    local handle = io.popen(full_cmd)
    if not handle then return nil end
    local output = handle:read("*a") or ""
    handle:close()
    output = output:gsub("^%s+", ""):gsub("%s+$", "")
    return output ~= "" and output or nil
end

local function fileExists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

local function getFileSize(path)
    return WavUtils.getFileSize(path)
end

--- Detect CPU cores (same logic as piperqueue.lua).
local function detectCpuCores()
    local f = io.open("/sys/devices/system/cpu/possible", "r")
    if f then
        local s = f:read("*l") or "0"
        f:close()
        local hi = s:match("%-(%d+)")
        if hi then return tonumber(hi) + 1 end
        return 1
    end
    return 1
end

--- Collect basic device info for the report header.
local function collectDeviceHeader()
    local lines = {}
    local platform = Device.getPlatform and Device:getPlatform() or "unknown"
    local model = Device.getDeviceModel and Device:getDeviceModel() or "unknown"
    -- Fallback for newer devices KOReader does not yet recognise.
    if platform == "unknown" then
        if Device.isKindle and Device:isKindle() then
            platform = "kindle"
        elseif Device.isKobo and Device:isKobo() then
            platform = "kobo"
        elseif Device.isPocketBook and Device:isPocketBook() then
            platform = "pocketbook"
        elseif Device.isAndroid and Device:isAndroid() then
            platform = "android"
        end
    end
    if model == "unknown" and Device.model then
        model = tostring(Device.model)
    end
    table.insert(lines, "platform: " .. platform)
    table.insert(lines, "model: " .. model)
    table.insert(lines, "arch: " .. (shellCapture("uname -m", 2) or "unknown"))
    table.insert(lines, "cpu_cores: " .. detectCpuCores())
    local meminfo = shellCapture("grep MemTotal /proc/meminfo 2>/dev/null", 2)
    if meminfo then
        table.insert(lines, "memory: " .. meminfo:gsub("^MemTotal:%s*", ""))
    end
    local memfree = shellCapture("grep MemFree /proc/meminfo 2>/dev/null", 2)
    if memfree then
        table.insert(lines, "mem_free: " .. memfree:gsub("^MemFree:%s*", ""))
    end
    local disk_var = shellCapture("df -h /var 2>/dev/null | tail -1", 2)
    if disk_var then
        table.insert(lines, "disk_var: " .. disk_var)
    end
    local disk_tmp = shellCapture("df -h /tmp 2>/dev/null | tail -1", 2)
    if disk_tmp then
        table.insert(lines, "disk_tmp: " .. disk_tmp)
    end
    local uname = shellCapture("uname -r", 2)
    if uname then
        table.insert(lines, "kernel: " .. uname)
    end
    -- Plugin version
    local ok, meta = pcall(dofile, _utils_dir .. "_meta.lua")
    if ok and meta then
        table.insert(lines, "plugin_version: " .. (meta.version or "unknown"))
    end
    return lines
end

--- Find available Piper voice models matching a pattern.
-- @param engine TTSEngine  The TTS engine instance
-- @param pattern string    Lua pattern to match against model filenames
-- @return table  Array of {name=, path=, size=}
local function findModels(engine, pattern)
    local results = {}
    if not engine or not engine._piper then return results end
    local voices = engine:listPiperVoices()
    for _, v in ipairs(voices) do
        if v.name:match(pattern) then
            table.insert(results, v)
        end
    end
    return results
end

-- ── Synchronous synthesis routines ───────────────────────────────────
-- These block and return timing data.  The benchmark is not interactive
-- so blocking is fine -- we show a progress message between runs.

--- Synthesize one sentence with espeak-ng (blocking).
-- @return table {synth_ms, wav_ms, wav_bytes} or nil on failure
local function benchEspeak(engine, text)
    if not engine.espeak_bin then return nil end
    local temp_dir = "/tmp"
    local audio_file = temp_dir .. "/bench_espeak_" .. os.time() .. "_" .. math.random(1000, 9999) .. ".wav"

    local exec_prefix = ""
    if engine.espeak_linker then
        exec_prefix = string.format(
            "ESPEAK_DATA_PATH=%s %s --library-path %s ",
            engine.espeak_data_path, engine.espeak_linker, engine.espeak_lib_path
        )
    elseif engine.espeak_lib_path then
        exec_prefix = string.format(
            "LD_LIBRARY_PATH=%s ESPEAK_DATA_PATH=%s ",
            engine.espeak_lib_path, engine.espeak_data_path
        )
    end
    local speed = math.floor(175 * (engine.rate or 1.0))
    local voice = engine.voice or "en"
    local cmd = string.format(
        '%s%s -v %s -s %d -a 100 -w "%s" "%s" 2>&1',
        exec_prefix, engine.espeak_bin, voice, speed, audio_file, engine:escapeText(text)
    )

    -- Wall-clock, not os.clock(): os.clock() measures Lua CPU time, which
    -- is ~0 while we block waiting for the child process (it produced the
    -- bogus "synth=5ms rt=0.00x" rows seen on slow devices).
    local t0 = time.now()
    local handle = io.popen(cmd, "r")
    local output = ""
    if handle then
        output = handle:read("*a") or ""
        handle:close()
    end
    local synth_ms = time.to_ms(time.since(t0))

    local wav_bytes = getFileSize(audio_file) or 0
    local wav_ms = WavUtils.getDurationMs(audio_file)
    os.remove(audio_file)

    if wav_bytes == 0 then
        return { synth_ms = synth_ms, wav_ms = 0, wav_bytes = 0, error = output:sub(1, 200) }
    end
    return { synth_ms = synth_ms, wav_ms = wav_ms, wav_bytes = wav_bytes }
end

--- Synthesize one sentence with Piper (blocking, per-process).
-- @param engine TTSEngine
-- @param model_path string  Path to .onnx model
-- @param text string
-- @return table {synth_ms, wav_ms, wav_bytes} or nil on failure
local function benchPiper(engine, model_path, text)
    if not engine.piper_cmd and not engine.backend_cmd then return nil end
    local piper_bin = engine.piper_cmd or engine.backend_cmd
    local temp_dir = "/tmp"
    local audio_file = temp_dir .. "/bench_piper_" .. os.time() .. "_" .. math.random(1000, 9999) .. ".wav"

    -- Clean text for Piper
    local clean = text:gsub("\n", " "):gsub("\r", "")
    clean = clean:gsub("\xe2\x80\xa6", ", ")
    clean = clean:gsub("%.[%.%s]+%.", ", ")
    clean = clean:gsub("%.%.+", ", ")

    -- Write text to a temp file (avoids shell escaping issues)
    local text_file = temp_dir .. "/bench_piper_in_" .. os.time() .. "_" .. math.random(1000, 9999) .. ".txt"
    local tf = io.open(text_file, "w")
    if not tf then return nil end
    tf:write(clean .. "\n")
    tf:close()

    -- Build command similar to PiperQueue:buildBaseCommand
    local model_flag = string.format(' --model "%s"', model_path)
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
        if fileExists(ld_linux) then
            local lib_path = piper_lib .. ":" .. espeak_lib
            exec_prefix = string.format('"%s" --library-path "%s" ',
                ld_linux, lib_path)
            local espeak_data_dir = engine.piper_model_dir .. "/espeak-ng-data"
            if fileExists(espeak_data_dir .. "/phontab") then
                model_flag = model_flag
                    .. string.format(' --espeak_data "%s"', espeak_data_dir)
            end
        else
            exec_prefix = string.format(
                'LD_LIBRARY_PATH="%s" ESPEAK_DATA_PATH="%s" ',
                piper_lib, engine.piper_model_dir)
        end
    end
    local cmd = string.format('nice -n 19 %s%s%s --output_file "%s" < "%s" 2>&1',
        exec_prefix, piper_bin, model_flag, audio_file, text_file)

    local t0 = time.now()
    local handle = io.popen(cmd, "r")
    local output = ""
    if handle then
        output = handle:read("*a") or ""
        handle:close()
    end
    local synth_ms = time.to_ms(time.since(t0))

    os.remove(text_file)

    local wav_bytes = getFileSize(audio_file) or 0
    local wav_ms = WavUtils.getDurationMs(audio_file)
    os.remove(audio_file)

    if wav_bytes == 0 then
        return { synth_ms = synth_ms, wav_ms = 0, wav_bytes = 0, error = output:sub(1, 200) }
    end
    return { synth_ms = synth_ms, wav_ms = wav_ms, wav_bytes = wav_bytes }
end

--- Synthesize one sentence with the Android system TTS (blocking).
-- Uses the same JNI bridge as normal playback but times synthesis only
-- (no audio playback).  Completion callbacks run on the Java worker
-- thread, so blocking the Lua main thread while polling does not stall
-- them.  The per-sentence cap is generous on purpose: a pathologically
-- slow engine is exactly what this benchmark exists to measure (issue
-- #53, engines taking 1-2 minutes per sentence).
-- @param engine TTSEngine
-- @param text string
-- @return table {synth_ms, wav_ms, wav_bytes, error?}
local ANDROID_BENCH_TIMEOUT_S = 120
local function benchAndroid(engine, text)
    local atts = engine._android_tts
    if not atts then return nil end
    local temp_dir = atts:getTempDir() or "/tmp"
    local audio_file = temp_dir .. "/bench_android_" .. os.time() .. "_" .. math.random(1000, 9999) .. ".wav"

    -- Match the settings used for real playback so the numbers reflect
    -- what the user hears.  Both setters queue on the Java worker thread
    -- ahead of the synthesis request, so order is preserved.
    atts:setRate(engine.rate or 1.0)
    local android_pitch = engine:_androidPitchMultiplier(engine.pitch)
    atts:setPitch(android_pitch)

    local dispatch = atts:synthesizeToFile(text, audio_file)
    if dispatch ~= 0 then
        return { synth_ms = 0, wav_ms = 0, wav_bytes = 0,
                 error = "dispatch failed (" .. tostring(dispatch) .. ")" }
    end

    local t0 = time.now()
    local status = -1
    local timed_out = false
    while true do
        status = atts:getSynthStatus()
        if status == 1 or status == 2 then break end
        if time.to_ms(time.since(t0)) > ANDROID_BENCH_TIMEOUT_S * 1000 then
            timed_out = true
            break
        end
        -- 100ms between polls.  usleep is available in every supported
        -- Android shell and already used elsewhere in the plugin.
        os.execute("usleep 100000")
    end
    local synth_ms = time.to_ms(time.since(t0))

    local wav_bytes = getFileSize(audio_file) or 0
    local wav_ms = WavUtils.getDurationMs(audio_file)
    os.remove(audio_file)

    if timed_out then
        -- wav_bytes > 0 here means the engine wrote audio but never
        -- reported completion: a callback problem, not a speed problem.
        return { synth_ms = synth_ms, wav_ms = wav_ms, wav_bytes = wav_bytes,
                 error = "timed out after " .. ANDROID_BENCH_TIMEOUT_S .. "s" }
    end
    if status == 2 or wav_bytes == 0 then
        return { synth_ms = synth_ms, wav_ms = wav_ms, wav_bytes = wav_bytes,
                 error = "synthesis failed (status " .. tostring(status) .. ")" }
    end
    return { synth_ms = synth_ms, wav_ms = wav_ms, wav_bytes = wav_bytes }
end

-- ── Report generation ────────────────────────────────────────────────

--- Format a single engine's benchmark results as text lines.
local function formatEngineResults(engine_label, results)
    local lines = {}
    table.insert(lines, "── " .. engine_label .. " ──")
    if not results or #results == 0 then
        table.insert(lines, "  (no results -- engine not available)")
        return lines
    end

    local total_synth = 0
    local total_wav = 0
    local max_synth = 0

    for _, r in ipairs(results) do
        local rt = "N/A"
        if r.wav_ms and r.wav_ms > 0 and r.synth_ms > 0 then
            rt = string.format("%.2fx", r.synth_ms / r.wav_ms)
        end
        local line = string.format("  %-20s  synth=%5dms  audio=%5dms  size=%6dB  rt=%s",
            r.label, r.synth_ms, r.wav_ms or 0, r.wav_bytes or 0, rt)
        if r.error then
            line = line .. "  ERROR: " .. r.error
        end
        table.insert(lines, line)

        total_synth = total_synth + (r.synth_ms or 0)
        total_wav = total_wav + (r.wav_ms or 0)
        if (r.synth_ms or 0) > max_synth then max_synth = r.synth_ms end
    end

    table.insert(lines, "")
    table.insert(lines, string.format("  total_synth: %dms  total_audio: %dms  max_synth: %dms",
        total_synth, total_wav, max_synth))
    if total_wav > 0 then
        table.insert(lines, string.format("  avg_realtime_factor: %.2fx", total_synth / total_wav))
    end

    return lines
end

--- Run the full benchmark suite synchronously.
-- This is the core function.  It runs all engines/models on all sentences
-- and returns the formatted report string.
-- @param plugin table  The Audiobook plugin instance
-- @param progress_cb function(msg)  Optional callback to update UI
-- @return string  The benchmark report text
function BenchmarkRunner.run(plugin, progress_cb)
    local engine = plugin and plugin.tts_engine
    local report_lines = {}
    local timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")

    -- Header
    local ok_meta, meta = pcall(dofile, _utils_dir .. "_meta.lua")
    local version = (ok_meta and meta) and meta.version or "unknown"
    table.insert(report_lines, "=== Audiobook TTS Benchmark (v" .. version .. ") ===")
    table.insert(report_lines, "Generated: " .. timestamp)
    table.insert(report_lines, "")

    -- Device info
    table.insert(report_lines, "── Device ──")
    local device_lines = collectDeviceHeader()
    for _, line in ipairs(device_lines) do
        table.insert(report_lines, "  " .. line)
    end
    table.insert(report_lines, "")

    -- Sentence inventory
    table.insert(report_lines, "── Test sentences ──")
    for i, s in ipairs(BENCH_SENTENCES) do
        table.insert(report_lines, string.format("  [%d] %s (%d chars)", i, s.label, #s.text))
    end
    table.insert(report_lines, "")

    -- ── Android system TTS benchmark ──
    -- Synthesis-only timing through the JNI bridge.  Placed first because
    -- it is the primary backend on Android devices; the bundled
    -- espeak-ng/Piper binaries are Linux e-ink builds and unused there.
    if engine and engine._android_tts then
        local engine_pkg = "unknown"
        local ok_pkg, pkg = pcall(function() return engine._android_tts:getDefaultEngine() end)
        if ok_pkg and pkg then engine_pkg = pkg end
        local results = {}
        for i, s in ipairs(BENCH_SENTENCES) do
            if progress_cb then
                progress_cb(string.format(
                    "Benchmarking Android TTS (%d/%d)...\nA slow engine can take minutes per sentence.",
                    i, #BENCH_SENTENCES))
            end
            local r = benchAndroid(engine, s.text)
            if r then
                r.label = s.label
            else
                r = { label = s.label, synth_ms = 0, wav_ms = 0, wav_bytes = 0, error = "synthesis failed" }
            end
            table.insert(results, r)
        end
        local lines = formatEngineResults("Android TTS (" .. engine_pkg .. ")", results)
        for _, line in ipairs(lines) do table.insert(report_lines, line) end
        table.insert(report_lines, "")
    end

    -- ── espeak-ng benchmark ──
    local linux_only_note = ""
    if Device.isAndroid and Device:isAndroid() then
        linux_only_note = " (Linux binaries are not used on Android; see the Android section)"
    end
    if engine and engine.espeak_bin then
        if progress_cb then progress_cb("Benchmarking espeak-ng...") end
        local results = {}
        for _, s in ipairs(BENCH_SENTENCES) do
            local r = benchEspeak(engine, s.text)
            if r then
                r.label = s.label
            else
                r = { label = s.label, synth_ms = 0, wav_ms = 0, wav_bytes = 0, error = "synthesis failed" }
            end
            table.insert(results, r)
        end
        local lines = formatEngineResults("espeak-ng", results)
        for _, line in ipairs(lines) do table.insert(report_lines, line) end
        table.insert(report_lines, "")
    else
        table.insert(report_lines, "── espeak-ng ──")
        table.insert(report_lines, "  (not available on this device)" .. linux_only_note)
        table.insert(report_lines, "")
    end

    -- ── Piper benchmarks ──
    if engine and engine.piper_cmd then
        -- Find danny-low model
        local danny_low = findModels(engine, "danny%-low")
        -- Find danny-medium model (user may have installed it)
        local danny_medium = findModels(engine, "danny%-medium")
        -- Also find any lessac model as an alternative medium voice
        local lessac_medium = findModels(engine, "lessac%-medium")

        -- Build model test list
        local piper_tests = {}
        if #danny_low > 0 then
            table.insert(piper_tests, { label = "Piper danny-low", model = danny_low[1] })
        end
        if #danny_medium > 0 then
            table.insert(piper_tests, { label = "Piper danny-medium", model = danny_medium[1] })
        elseif #lessac_medium > 0 then
            table.insert(piper_tests, { label = "Piper lessac-medium", model = lessac_medium[1] })
        end

        -- If no specific models found, try whatever model is available
        if #piper_tests == 0 then
            local all_voices = engine:listPiperVoices()
            if #all_voices > 0 then
                table.insert(piper_tests, { label = "Piper " .. all_voices[1].name, model = all_voices[1] })
            end
        end

        if #piper_tests == 0 then
            table.insert(report_lines, "── Piper ──")
            table.insert(report_lines, "  (no voice models found)")
            table.insert(report_lines, "")
        end

        for _, ptest in ipairs(piper_tests) do
            if progress_cb then
                progress_cb("Benchmarking " .. ptest.label .. "...\nThis may take several minutes on slow devices.")
            end
            local results = {}
            for _, s in ipairs(BENCH_SENTENCES) do
                local r = benchPiper(engine, ptest.model.path, s.text)
                if r then
                    r.label = s.label
                else
                    r = { label = s.label, synth_ms = 0, wav_ms = 0, wav_bytes = 0, error = "synthesis failed" }
                end
                table.insert(results, r)
            end
            local model_info = string.format("%s  (size=%s, sr=%sHz)",
                ptest.label,
                ptest.model.size and string.format("%.1fMB", ptest.model.size / 1048576) or "?",
                ptest.model.sample_rate or "?")
            local lines = formatEngineResults(model_info, results)
            for _, line in ipairs(lines) do table.insert(report_lines, line) end
            table.insert(report_lines, "")
        end
    else
        table.insert(report_lines, "── Piper ──")
        table.insert(report_lines, "  (not available on this device)" .. linux_only_note)
        table.insert(report_lines, "")
    end

    table.insert(report_lines, "=== End of Benchmark ===")
    return table.concat(report_lines, "\n")
end

--- Run benchmarks and save the report to a user-accessible file.
-- @param plugin table  The Audiobook plugin instance
-- @param progress_cb function(msg)  Optional progress callback
-- @return string|nil  Path to saved report, or nil on failure
function BenchmarkRunner.runAndSave(plugin, progress_cb)
    local report = BenchmarkRunner.run(plugin, progress_cb)

    local save_dir
    if Device.isKobo and Device:isKobo() then
        save_dir = "/mnt/onboard"
    elseif Device.isKindle and Device:isKindle() then
        save_dir = "/mnt/us"
    elseif Device.isPocketBook and Device:isPocketBook() then
        save_dir = "/mnt/ext1"
    elseif Device:isAndroid() then
        save_dir = "/sdcard"
    else
        save_dir = os.getenv("HOME") or "/tmp"
    end

    local filename = "audiobook-benchmark-" .. os.date("!%Y%m%d-%H%M%S") .. ".txt"
    local filepath = save_dir .. "/" .. filename

    local f, err = io.open(filepath, "w")
    if not f then
        filepath = "/tmp/" .. filename
        f, err = io.open(filepath, "w")
    end

    if not f then
        logger.err("BenchmarkRunner: Cannot save report:", err)
        return nil
    end

    f:write(report)
    f:close()
    logger.dbg("BenchmarkRunner: Saved to", filepath)
    return filepath
end

--- Sanitize a path for display (same as bugreport.lua).
local function sanitizePath(path)
    if not path then return "nil" end
    path = path:gsub("/home/[^/]+/", "/home/<user>/")
    path = path:gsub("/Users/[^/]+/", "/Users/<user>/")
    path = path:gsub("/storage/emulated/%d+/", "/sdcard/")
    return path
end

--- Menu callback: run benchmarks with progress UI and save results.
-- @param plugin table  The Audiobook plugin instance
function BenchmarkRunner.menuCallback(plugin)
    -- Show initial message
    local msg = InfoMessage:new{
        text = _("Starting TTS benchmark...\n\nThis will synthesize several test sentences with each available TTS engine. On slow devices, Piper tests may take several minutes.\n\nThe screen may appear unresponsive during synthesis."),
        timeout = 3,
    }
    UIManager:show(msg)

    -- Schedule the actual benchmark to run after the message is shown
    UIManager:scheduleIn(0.5, function()
        -- Progress callback: update the info message
        local function showProgress(text)
            UIManager:show(InfoMessage:new{
                text = text,
                timeout = 60,
            })
            -- Force a UI refresh so the message appears
            UIManager:forceRePaint()
        end

        local filepath = BenchmarkRunner.runAndSave(plugin, showProgress)
        if filepath then
            local display_path = sanitizePath(filepath)
            UIManager:show(InfoMessage:new{
                text = _("Benchmark complete!\n\nReport saved to:\n") .. display_path ..
                    _("\n\nConnect your device via USB to retrieve the file. Share it on GitHub to help document device performance."),
                timeout = 30,
            })
        else
            local report = BenchmarkRunner.run(plugin)
            UIManager:show(InfoMessage:new{
                text = _("Could not save benchmark file.\n\nResults:\n\n") .. report:sub(1, 2000),
                timeout = 30,
            })
        end
    end)
end

return BenchmarkRunner
