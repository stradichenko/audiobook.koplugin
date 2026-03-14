--[[--
Gap Simulator
Takes benchmark results (JSON) and simulates real-time playback to predict
actual user-perceived gaps between sentences.

This is the key metric: even if overall throughput is good, a single long
gap ruins the experience. This simulator models:
  - Pipeline fill time (cold start)
  - Continuous playback with prefetch buffer
  - Gap = max(0, next_sentence_synth_time - accumulated_audio_buffer)

Usage:
    lua gap_simulator.lua results/baseline.json
    lua gap_simulator.lua results/server_2x2.json results/batch_5.json

@module gap_simulator
--]]

local function read_json_results(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()

    -- Simple JSON parsing for our structured output
    local results = {
        strategy = content:match('"strategy"%s*:%s*"([^"]+)"') or "unknown",
        per_sentence = {},
    }

    -- Extract per_sentence array entries
    for entry in content:gmatch('{%s*"synth_ms"%s*:%s*(%d+)%s*,%s*"duration_ms"%s*:%s*(%d+)') do
        -- This won't work well, let's parse differently
    end

    -- Better: extract each sentence object
    for synth, dur, textlen in content:gmatch(
        '"synth_ms"%s*:%s*(%d+)%s*,%s*"duration_ms"%s*:%s*(%d+)%s*,%s*"text_len"%s*:%s*(%d+)') do
        table.insert(results.per_sentence, {
            synth_ms = tonumber(synth),
            duration_ms = tonumber(dur),
            text_len = tonumber(textlen),
        })
    end

    return results
end

local function simulate_playback(results, strategy_name, server_count, pipeline_depth)
    server_count = server_count or 1
    pipeline_depth = pipeline_depth or 1
    local max_inflight = server_count * pipeline_depth

    local sentences = results.per_sentence
    if #sentences == 0 then
        print("No sentences to simulate")
        return
    end

    -- Simulation state
    local clock = 0           -- wall clock (ms)
    local audio_buffer = 0    -- buffered audio ahead of playback position (ms)
    local playing = false
    local gaps = {}           -- perceived gaps
    local first_audio_at = 0
    local total_gap_ms = 0

    -- Simulate concurrent synthesis
    -- Each "slot" finishes at a certain time
    local slots = {}  -- {finish_time, sentence_idx}
    local next_to_synth = 1
    local next_to_play = 1
    local ready = {}  -- synthesized but not yet played, keyed by index

    -- Fill initial pipeline
    local function fill_slots()
        while #slots < max_inflight and next_to_synth <= #sentences do
            local s = sentences[next_to_synth]
            local finish = clock + s.synth_ms
            -- For multiple servers, work is distributed
            if #slots > 0 and server_count > 1 then
                -- Find the slot that finishes earliest
                local min_finish = math.huge
                for _, slot in ipairs(slots) do
                    min_finish = math.min(min_finish, slot.finish_time)
                end
                -- New work starts when a slot frees up
                finish = math.max(clock, min_finish) + s.synth_ms
            end
            table.insert(slots, {
                finish_time = finish,
                sentence_idx = next_to_synth,
            })
            next_to_synth = next_to_synth + 1
        end
    end

    -- Advance clock to next event
    local function next_event_time()
        local t = math.huge
        for _, slot in ipairs(slots) do
            t = math.min(t, slot.finish_time)
        end
        return t
    end

    local function collect_ready()
        local new_slots = {}
        for _, slot in ipairs(slots) do
            if slot.finish_time <= clock then
                ready[slot.sentence_idx] = sentences[slot.sentence_idx]
            else
                table.insert(new_slots, slot)
            end
        end
        slots = new_slots
    end

    -- Simulate
    fill_slots()

    while next_to_play <= #sentences do
        -- Advance to next event
        local event_t = next_event_time()
        if event_t == math.huge then break end

        -- Time passes: audio buffer drains
        local dt = event_t - clock
        if playing and audio_buffer > 0 then
            audio_buffer = audio_buffer - dt
            if audio_buffer < 0 then
                -- Buffer ran out while waiting
                local underrun = -audio_buffer
                audio_buffer = 0
                playing = false
            end
        end

        clock = event_t
        collect_ready()
        fill_slots()

        -- Try to play ready sentences in order
        while ready[next_to_play] do
            local s = ready[next_to_play]
            if first_audio_at == 0 then
                first_audio_at = clock
            end

            if not playing and audio_buffer <= 0 then
                -- Gap! User perceives silence
                if next_to_play > 1 then
                    -- Gap was the time since the previous sentence finished playing
                    -- For simplicity, track any clock time where buffer was empty
                end
            end

            audio_buffer = audio_buffer + s.duration_ms
            playing = true
            ready[next_to_play] = nil
            next_to_play = next_to_play + 1
        end

        -- If buffer is empty and next sentence isn't ready, we have a gap
        if audio_buffer <= 0 and next_to_play <= #sentences and not ready[next_to_play] then
            -- How long until the next sentence is ready?
            local next_ready_time = math.huge
            for _, slot in ipairs(slots) do
                if slot.sentence_idx == next_to_play then
                    next_ready_time = slot.finish_time
                    break
                end
            end
            if next_ready_time < math.huge then
                local gap = next_ready_time - clock
                table.insert(gaps, {
                    at_sentence = next_to_play,
                    gap_ms = gap,
                    clock_ms = clock,
                })
                total_gap_ms = total_gap_ms + gap
                -- Jump to when it's ready
                clock = next_ready_time
                audio_buffer = 0
                collect_ready()
                fill_slots()
            end
        end
    end

    -- Print simulation results
    local total_audio = 0
    for _, s in ipairs(sentences) do total_audio = total_audio + s.duration_ms end

    print(string.format("\n══ Playback Simulation: %s ══", strategy_name))
    print(string.format("  Servers: %d, Pipeline depth: %d", server_count, pipeline_depth))
    print(string.format("  Sentences: %d", #sentences))
    print(string.format("  Total audio: %.1f s", total_audio / 1000))
    print(string.format("  Cold start (first audio): %.1f s", first_audio_at / 1000))
    print(string.format("  Total wall time: %.1f s", clock / 1000))
    print(string.format("  Total gap time: %.1f s", total_gap_ms / 1000))
    print(string.format("  Number of gaps: %d", #gaps))

    if #gaps > 0 then
        local max_gap = 0
        local gap_sum = 0
        for _, g in ipairs(gaps) do
            max_gap = math.max(max_gap, g.gap_ms)
            gap_sum = gap_sum + g.gap_ms
        end
        print(string.format("  Avg gap: %.1f s", gap_sum / #gaps / 1000))
        print(string.format("  Max gap: %.1f s", max_gap / 1000))

        print("\n  Gap details:")
        for _, g in ipairs(gaps) do
            print(string.format("    at sentence %d: %.1fs gap (clock: %.1fs)",
                g.at_sentence, g.gap_ms / 1000, g.clock_ms / 1000))
        end
    else
        print("  ★ NO GAPS — continuous playback achieved!")
    end
    print("")
end

-- ── Main ─────────────────────────────────────────────────────────────

local args = arg or {}
if #args == 0 then
    print("Usage: lua gap_simulator.lua <results.json> [results2.json ...]")
    print("       lua gap_simulator.lua results/*.json")
    os.exit(1)
end

for _, path in ipairs(args) do
    local results = read_json_results(path)
    if results then
        local name = path:match("([^/]+)%.json$") or path

        -- Determine server count from strategy name
        local servers, depth = 1, 1
        if name:match("server_(%d+)x(%d+)") then
            servers = tonumber(name:match("server_(%d+)")) or 1
            depth = tonumber(name:match("x(%d+)")) or 1
        elseif name:match("4x") then
            servers, depth = 4, 2
        elseif name:match("2x") then
            servers, depth = 2, 2
        end

        simulate_playback(results, name, servers, depth)
    else
        io.stderr:write("Could not read: " .. path .. "\n")
    end
end
