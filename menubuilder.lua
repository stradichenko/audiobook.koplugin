--[[--
Menu builder functions for the Audiobook plugin.
Pure factory functions that return KOReader menu item tables.

All functions take `plugin` (the Audiobook WidgetContainer instance)
as their first parameter to access settings and engine state.

@module menubuilder
--]]

local _ = require("gettext")
local T = require("ffi/util").template

-- Shared utility module
local _dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local Utils = dofile(_dir .. "utils.lua")

local MenuBuilder = {}

function MenuBuilder.buildVoiceSettingsMenu(plugin)
    local menu = {}

    -- TTS Engine selector (espeak-ng vs Piper)
    table.insert(menu, {
        text_func = function()
            local backend = plugin.tts_engine.backend or "none"
            local labels = {
                espeak = _("espeak-ng"),
                piper = _("Piper (neural)"),
                pico = _("Pico TTS"),
                flite = _("Flite"),
                festival = _("Festival"),
                android = _("Android"),
            }
            return T(_("TTS engine: %1"), labels[backend] or backend)
        end,
        sub_item_table_func = function()
            return MenuBuilder.buildEngineSelectMenu(plugin)
        end,
    })

    -- Speech rate submenu
    table.insert(menu, {
        text_func = function()
            return T(_("Speech rate: %1x"), plugin:getSetting("speech_rate", 1.0))
        end,
        sub_item_table = MenuBuilder.buildSpeechRateMenu(plugin),
    })

    -- Pitch submenu (espeak-ng only)
    if plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.ESPEAK then
        table.insert(menu, {
            text_func = function()
                return T(_("Pitch: %1"), plugin:getSetting("speech_pitch", 50))
            end,
            sub_item_table = MenuBuilder.buildPitchMenu(plugin),
        })
    end

    -- Volume submenu
    table.insert(menu, {
        text_func = function()
            return T(_("Volume: %1%%"), math.floor(plugin:getSetting("speech_volume", 1.0) * 100))
        end,
        sub_item_table = MenuBuilder.buildVolumeMenu(plugin),
    })

    -- Pause between sentences / paragraphs (espeak-ng only — neural TTS has natural prosody)
    if plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.ESPEAK then
        table.insert(menu, {
            text_func = function()
                return T(_("Sentence pause (. ? !): %1s"), plugin:getSetting("sentence_pause", 0.1))
            end,
            sub_item_table = MenuBuilder.buildSentencePauseMenu(plugin),
        })

        table.insert(menu, {
            text_func = function()
                return T(_("Paragraph pause (newlines): %1s"), plugin:getSetting("paragraph_pause", 0.8))
            end,
            sub_item_table = MenuBuilder.buildParagraphPauseMenu(plugin),
        })
    end

    -- Piper inter-sentence gaps (natural pacing + synthesis buffer)
    if plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.PIPER then
        table.insert(menu, {
            text_func = function()
                return T(_("Sentence gap (. ? !): %1s"), plugin:getSetting("piper_sentence_gap", 0.3))
            end,
            sub_item_table = MenuBuilder.buildPiperSentenceGapMenu(plugin),
        })

        table.insert(menu, {
            text_func = function()
                return T(_("Paragraph gap (newlines): %1s"), plugin:getSetting("piper_paragraph_gap", 1.0))
            end,
            sub_item_table = MenuBuilder.buildPiperParagraphGapMenu(plugin),
        })

        -- Gap test mode: replaces silence with audible tones so the user
        -- can hear exactly where each gap is placed.  Sentence gaps use a
        -- 220 Hz tone; paragraph gaps use 330 Hz.
        table.insert(menu, {
            text = _("Gap test mode (audible tones)"),
            checked_func = function()
                return plugin:getSetting("gap_test_mode", false)
            end,
            callback = function()
                local new_val = not plugin:getSetting("gap_test_mode", false)
                plugin:setSetting("gap_test_mode", new_val)
                if plugin.tts_engine then
                    plugin.tts_engine._gap_test_mode = new_val
                end
            end,
        })
    end

    -- Clause pause (espeak-ng only — uses SSML)
    if plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.ESPEAK then
        table.insert(menu, {
            text_func = function()
                return T(_("Clause pause (, ; : —): %1s"), plugin:getSetting("clause_pause", 0))
            end,
            sub_item_table = MenuBuilder.buildClausePauseMenu(plugin),
        })

        -- Word gap (espeak-ng only)
        table.insert(menu, {
            text_func = function()
                return T(_("Word gap (between words): %1"), plugin:getSetting("word_gap", 2))
            end,
            sub_item_table = MenuBuilder.buildWordGapMenu(plugin),
        })
    end

    -- Voice / accent selection (differs by backend)
    if plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.PIPER then
        table.insert(menu, {
            text_func = function()
                local model = plugin:getSetting("piper_model_label", "default")
                return T(_("Piper voice: %1"), model)
            end,
            sub_item_table_func = function()
                return MenuBuilder.buildPiperVoiceMenu(plugin)
            end,
        })
    else
        table.insert(menu, {
            text_func = function()
                return T(_("Voice: %1"), plugin:getSetting("tts_voice_label", "English (GB)"))
            end,
            sub_item_table = MenuBuilder.buildVoiceMenu(plugin),
        })
    end

    return menu
end

function MenuBuilder.buildSpeechRateMenu(plugin)
    local rates = {0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0}
    local menu = {}

    for _i, rate in ipairs(rates) do
        table.insert(menu, {
            text = string.format("%.2fx", rate),
            checked_func = function()
                return plugin:getSetting("speech_rate", 1.0) == rate
            end,
            callback = function()
                plugin:setSetting("speech_rate", rate)
                plugin.tts_engine:setRate(rate)
            end,
        })
    end

    return menu
end

function MenuBuilder.buildPitchMenu(plugin)
    -- espeak-ng pitch range: 0–99, default 50
    local pitches = {0, 10, 20, 30, 40, 50, 60, 70, 80, 99}
    local labels = {
        [0] = _("0 (very low)"),
        [10] = "10", [20] = "20", [30] = "30", [40] = "40",
        [50] = _("50 (default)"),
        [60] = "60", [70] = "70", [80] = "80",
        [99] = _("99 (very high)"),
    }
    local menu = {}
    for _i, p in ipairs(pitches) do
        table.insert(menu, {
            text = labels[p] or tostring(p),
            checked_func = function()
                return plugin:getSetting("speech_pitch", 50) == p
            end,
            callback = function()
                plugin:setSetting("speech_pitch", p)
                plugin.tts_engine:setPitch(p)
            end,
        })
    end
    return menu
end

function MenuBuilder.buildVolumeMenu(plugin)
    local volumes = {0.25, 0.50, 0.75, 1.0}
    local menu = {}
    for _i, v in ipairs(volumes) do
        table.insert(menu, {
            text = string.format("%d%%", math.floor(v * 100)),
            checked_func = function()
                return plugin:getSetting("speech_volume", 1.0) == v
            end,
            callback = function()
                plugin:setSetting("speech_volume", v)
                plugin.tts_engine:setVolume(v)
            end,
        })
    end
    return menu
end

function MenuBuilder.buildSentencePauseMenu(plugin)
    -- Pause after sentence-ending punctuation (.?!;:) within the same paragraph
    local values = {0, 0.05, 0.1, 0.15, 0.2, 0.3, 0.5, 0.8, 1.0}
    local menu = {}
    for _i, v in ipairs(values) do
        local label = string.format("%.2fs", v)
        if v == 0.1 then label = label .. _(" (default)") end
        table.insert(menu, {
            text = label,
            checked_func = function()
                return plugin:getSetting("sentence_pause", 0.1) == v
            end,
            callback = function()
                plugin:setSetting("sentence_pause", v)
            end,
        })
    end
    return menu
end

function MenuBuilder.buildParagraphPauseMenu(plugin)
    -- Pause at paragraph/newline boundaries
    local values = {0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.5, 2.0, 3.0}
    local menu = {}
    for _i, v in ipairs(values) do
        local label = string.format("%.1fs", v)
        if v == 0.8 then label = label .. _(" (default)") end
        table.insert(menu, {
            text = label,
            checked_func = function()
                return plugin:getSetting("paragraph_pause", 0.8) == v
            end,
            callback = function()
                plugin:setSetting("paragraph_pause", v)
            end,
        })
    end
    return menu
end

-- Piper sentence gap: silence inserted between sentences for natural pacing.
-- Also acts as a synthesis buffer — the pipeline plays silence while Piper
-- keeps working on the next batch.
function MenuBuilder.buildPiperSentenceGapMenu(plugin)
    local values = {0, 0.1, 0.2, 0.3, 0.5, 0.8, 1.0, 1.5, 2.0}
    local menu = {}
    for _i, v in ipairs(values) do
        local label = string.format("%.1fs", v)
        if v == 0.3 then label = label .. _(" (default)") end
        table.insert(menu, {
            text = label,
            checked_func = function()
                return plugin:getSetting("piper_sentence_gap", 0.3) == v
            end,
            callback = function()
                plugin:setSetting("piper_sentence_gap", v)
            end,
        })
    end
    return menu
end

-- Piper paragraph gap: longer silence at paragraph boundaries (newlines).
function MenuBuilder.buildPiperParagraphGapMenu(plugin)
    local values = {0, 0.3, 0.5, 0.8, 1.0, 1.5, 2.0}
    local menu = {}
    for _i, v in ipairs(values) do
        local label = string.format("%.1fs", v)
        if v == 1.0 then label = label .. _(" (default)") end
        table.insert(menu, {
            text = label,
            checked_func = function()
                return plugin:getSetting("piper_paragraph_gap", 1.0) == v
            end,
            callback = function()
                plugin:setSetting("piper_paragraph_gap", v)
            end,
        })
    end
    return menu
end

function MenuBuilder.buildClausePauseMenu(plugin)
    -- Pause at clause-level punctuation (commas, semicolons, colons, hyphens)
    -- Injected as silence in the espeak text via SSML-like pauses
    local values = {0, 0.05, 0.1, 0.15, 0.2, 0.3, 0.5}
    local menu = {}
    for _i, v in ipairs(values) do
        local label = string.format("%.2fs", v)
        if v == 0 then label = label .. _(" (default / off)") end
        table.insert(menu, {
            text = label,
            checked_func = function()
                return plugin:getSetting("clause_pause", 0) == v
            end,
            callback = function()
                plugin:setSetting("clause_pause", v)
                plugin.tts_engine:setClausePause(v)
            end,
        })
    end
    return menu
end

function MenuBuilder.buildWordGapMenu(plugin)
    -- espeak-ng word gap: extra silence (in units of 10ms) between words
    -- 0 = default (no extra gap), higher values slow down speech
    local values = {0, 1, 2, 5, 10, 20, 50}
    local labels = {
        [0] = _("0 (no extra gap)"),
        [1] = _("1 (10ms)"),
        [2] = _("2 (20ms — default)"),
        [5] = _("5 (50ms)"),
        [10] = _("10 (100ms)"),
        [20] = _("20 (200ms)"),
        [50] = _("50 (500ms)"),
    }
    local menu = {}
    for _i, v in ipairs(values) do
        table.insert(menu, {
            text = labels[v] or tostring(v),
            checked_func = function()
                return plugin:getSetting("word_gap", 2) == v
            end,
            callback = function()
                plugin:setSetting("word_gap", v)
                plugin.tts_engine:setWordGap(v)
            end,
        })
    end
    return menu
end

function MenuBuilder.buildVoiceMenu(plugin)
    -- Voices are split into sections: accents (male base) and voice variants
    -- Voice variants use espeak-ng "+variant" syntax: e.g. "en+f1" = English GB female1
    local current_base = plugin:getSetting("tts_voice", "en")
    local current_variant = plugin:getSetting("tts_voice_variant", "")
    local current_full = current_base
    if current_variant ~= "" then
        current_full = current_base .. "+" .. current_variant
    end

    local accents = {
        { id = "en",              label = _("English (GB)") },
        { id = "en-us",           label = _("English (US)") },
        { id = "en-gb-x-rp",     label = _("English (Received Pronunciation)") },
        { id = "en-gb-scotland",  label = _("English (Scotland)") },
        { id = "en-gb-x-gbclan",  label = _("English (Lancaster)") },
        { id = "en-gb-x-gbcwmd", label = _("English (West Midlands)") },
        { id = "en-029",          label = _("English (Caribbean)") },
        { id = "en-us-nyc",       label = _("English (New York City)") },
    }

    local variants = {
        { id = "",         label = _("Default (male)") },
        { separator = true },
        -- Female voices
        { id = "f1",       label = _("Female 1") },
        { id = "f2",       label = _("Female 2") },
        { id = "f3",       label = _("Female 3") },
        { id = "f4",       label = _("Female 4 (breathy)") },
        { id = "f5",       label = _("Female 5") },
        { separator = true },
        { id = "Annie",    label = _("Annie (F)") },
        { id = "Alicia",   label = _("Alicia (F)") },
        { id = "belinda",  label = _("Belinda (F)") },
        { id = "linda",    label = _("Linda (F)") },
        { id = "steph",    label = _("Steph (F)") },
        { id = "Andrea",   label = _("Andrea (F)") },
        { id = "anika",    label = _("Anika (F)") },
        { id = "aunty",    label = _("Aunty (F)") },
        { id = "grandma",  label = _("Grandma (F)") },
        { separator = true },
        -- Male voices
        { id = "m1",       label = _("Male 1") },
        { id = "m2",       label = _("Male 2") },
        { id = "m3",       label = _("Male 3") },
        { id = "m7",       label = _("Male 7") },
        { id = "Alex",     label = _("Alex (M)") },
        { id = "Andy",     label = _("Andy (M)") },
        { id = "Gene",     label = _("Gene (M)") },
        { id = "Lee",      label = _("Lee (M)") },
        { id = "shelby",   label = _("Shelby (M, smooth)") },
        { separator = true },
        -- Softer / less robotic
        { id = "robosoft",  label = _("Robosoft 1 (softer)") },
        { id = "robosoft2", label = _("Robosoft 2 (softer)") },
        { id = "robosoft3", label = _("Robosoft 3 (softer)") },
        { id = "robosoft4", label = _("Robosoft 4 (softer)") },
        { id = "robosoft5", label = _("Robosoft 5 (softer)") },
        { id = "robosoft6", label = _("Robosoft 6 (softer)") },
        { id = "robosoft7", label = _("Robosoft 7 (softer)") },
        { id = "robosoft8", label = _("Robosoft 8 (softer)") },
        { separator = true },
        -- Special
        { id = "whisper",  label = _("Whisper") },
        { id = "whisperf", label = _("Whisper (female)") },
        { id = "croak",    label = _("Croak") },
    }

    local menu = {}

    -- Accent submenu
    local accent_sub = {}
    for _i, a in ipairs(accents) do
        table.insert(accent_sub, {
            text = a.label,
            checked_func = function()
                return plugin:getSetting("tts_voice", "en") == a.id
            end,
            callback = function()
                plugin:setSetting("tts_voice", a.id)
                plugin:setSetting("tts_voice_label", a.label)
                local var = plugin:getSetting("tts_voice_variant", "")
                local full = a.id
                if var ~= "" then full = a.id .. "+" .. var end
                plugin.tts_engine:setVoice(full)
            end,
        })
    end
    table.insert(menu, {
        text_func = function()
            return T(_("Accent: %1"), plugin:getSetting("tts_voice_label", "English (GB)"))
        end,
        sub_item_table = accent_sub,
    })

    -- Voice / gender variant submenu
    local variant_sub = {}
    for _i, v in ipairs(variants) do
        if not v.separator then
            table.insert(variant_sub, {
                text = v.label,
                checked_func = function()
                    return plugin:getSetting("tts_voice_variant", "") == v.id
                end,
                callback = function()
                    plugin:setSetting("tts_voice_variant", v.id)
                    plugin:setSetting("tts_variant_label", v.label)
                    local base = plugin:getSetting("tts_voice", "en")
                    local full = base
                    if v.id ~= "" then full = base .. "+" .. v.id end
                    plugin.tts_engine:setVoice(full)
                end,
            })
        end
    end
    table.insert(menu, {
        text_func = function()
            return T(_("Voice type: %1"), plugin:getSetting("tts_variant_label", "Default (male)"))
        end,
        sub_item_table = variant_sub,
    })

    return menu
end

function MenuBuilder.buildHighlightStyleMenu(plugin)
    local styles = {
        { id = "background", text = _("Background highlight") },
        { id = "underline", text = _("Underline") },
        { id = "box", text = _("Box border") },
        { id = "invert", text = _("Invert colors") },
    }
    local menu = {}

    for _, style in ipairs(styles) do
        table.insert(menu, {
            text = style.text,
            checked_func = function()
                return plugin:getSetting("highlight_style", "background") == style.id
            end,
            callback = function()
                plugin:setSetting("highlight_style", style.id)
                plugin.highlight_manager:setStyle(style.id)
            end,
        })
    end

    return menu
end

--[[--
Build TTS engine selection menu.
Lists all detected backends so the user can switch between espeak-ng and Piper.
--]]
function MenuBuilder.buildEngineSelectMenu(plugin)
    local menu = {}
    local engine = plugin.tts_engine

    -- Build a list of available backends with friendly labels
    local available = {}

    -- espeak-ng: available if we detected it during init
    if engine.espeak_lib_path or Utils.commandExists("espeak-ng") or Utils.commandExists("espeak") then
        table.insert(available, {
            id = engine.BACKENDS.ESPEAK,
            label = _("espeak-ng (formant, fast, robotic)"),
        })
    end

    -- Piper: available if bundled binary or on PATH
    if engine.piper_cmd or Utils.commandExists("piper") then
        table.insert(available, {
            id = engine.BACKENDS.PIPER,
            label = _("Piper (neural, natural-sounding)"),
        })
    end

    -- Other system backends
    if Utils.commandExists("pico2wave") then
        table.insert(available, { id = engine.BACKENDS.PICO, label = _("Pico TTS") })
    end
    if Utils.commandExists("flite") then
        table.insert(available, { id = engine.BACKENDS.FLITE, label = _("Flite") })
    end
    if Utils.commandExists("festival") then
        table.insert(available, { id = engine.BACKENDS.FESTIVAL, label = _("Festival") })
    end

    if #available == 0 then
        table.insert(menu, {
            text = _("No TTS engines found"),
            enabled = false,
        })
        return menu
    end

    for _, backend in ipairs(available) do
        table.insert(menu, {
            text = backend.label,
            checked_func = function()
                return engine.backend == backend.id
            end,
            callback = function()
                engine:setBackend(backend.id)
                plugin:setSetting("tts_backend", backend.id)
            end,
        })
    end

    return menu
end

--[[--
Build Piper voice model selection menu.
Lists .onnx files found in the bundled piper/ directory.
--]]
function MenuBuilder.buildPiperVoiceMenu(plugin)
    local menu = {}
    local voices = plugin.tts_engine:listPiperVoices()

    if #voices == 0 then
        table.insert(menu, {
            text = _("No voice models found"),
            enabled = false,
        })
        table.insert(menu, {
            text = _("Place .onnx files in plugins/audiobook.koplugin/piper/"),
            enabled = false,
        })
        return menu
    end

    -- Sort: medium before low (better quality first)
    table.sort(voices, function(a, b)
        local order = { high = 1, medium = 2, low = 3 }
        local oa = order[a.quality or "medium"] or 9
        local ob = order[b.quality or "medium"] or 9
        if oa ~= ob then return oa < ob end
        return a.name < b.name
    end)

    for _, voice in ipairs(voices) do
        local quality_label = ""
        if voice.quality then
            local icons = { high = "★★★", medium = "★★☆", low = "★☆☆" }
            quality_label = string.format(" %s %s · %d kHz",
                icons[voice.quality] or "", voice.quality,
                (voice.sample_rate or 22050) / 1000)
        end
        local size_mb = voice.size and string.format(" · %.0f MB", voice.size / 1024 / 1024) or ""
        table.insert(menu, {
            text = voice.name .. quality_label .. size_mb,
            checked_func = function()
                return plugin:getSetting("piper_model", nil) == voice.path
                    or plugin.tts_engine.piper_model == voice.path
            end,
            callback = function()
                plugin.tts_engine:setPiperModel(voice.path)
                plugin:setSetting("piper_model", voice.path)
                -- Use quality-annotated label for the parent menu
                local label = voice.name
                if voice.quality then
                    label = label .. " (" .. voice.quality .. ")"
                end
                plugin:setSetting("piper_model_label", label)
            end,
        })
    end

    return menu
end

return MenuBuilder
