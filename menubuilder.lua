--[[--
Menu builder functions for the Audiobook plugin.
Pure factory functions that return KOReader menu item tables.

All functions take `plugin` (the Audiobook WidgetContainer instance)
as their first parameter to access settings and engine state.

@module menubuilder
--]]

local _ = require("gettext")
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")

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
                ["platform-native"] = _("Platform-native helper"),
            }
            return T(_("TTS engine: %1"), labels[backend] or backend)
        end,
        sub_item_table_func = function()
            return MenuBuilder.buildEngineSelectMenu(plugin)
        end,
    })

    -- Platform-native helper settings (only visible when that backend is active).
    if plugin.tts_engine and plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.NATIVE then
        table.insert(menu, {
            text = _("Platform-native helper settings"),
            sub_item_table_func = function()
                return MenuBuilder.buildNativeTtsSettingsMenu(plugin)
            end,
        })
    end

    -- MBROLA voice selection (espeak-ng backend only).
    -- On Kobo devices with the MTK Bluetooth chip, only mb-en1 works
    -- reliably; all other MBROLA voices trigger mid-sentence audio repeats.
    -- On every other device, expose the full MBROLA voice menu.
    -- See docs/MBROLA_MTK_REPEAT_BUG.md for the full diagnostic report.
    if plugin.tts_engine and plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.ESPEAK then
        if plugin.bt_manager and plugin.bt_manager:isMtkKobo() then
            -- MTK Kobo: restrict to the single known-working MBROLA voice.
            table.insert(menu, {
                text = _("MBROLA voice UK English Male 1"),
                checked_func = function()
                    return plugin:getSetting("tts_mbrola_voice", "") == "en1"
                end,
                callback = function()
                    local current = plugin:getSetting("tts_mbrola_voice", "")
                    if current == "en1" then
                        -- Uncheck: disable MBROLA
                        plugin:setSetting("tts_mbrola_voice", "")
                        plugin:setSetting("tts_mbrola_voice_label", "")
                        local base = plugin:getSetting("tts_voice", "en")
                        local var = plugin:getSetting("tts_voice_variant", "")
                        local full = base
                        if var ~= "" then
                            full = base .. "+" .. var
                        end
                        plugin.tts_engine:setVoice(full)
                        UIManager:show(InfoMessage:new{
                            text = _("MBROLA disabled. Using regular espeak-ng voice."),
                            timeout = 2,
                        })
                    else
                        -- Check: enable mb-en1 only
                        plugin:setSetting("tts_mbrola_voice", "en1")
                        plugin:setSetting("tts_mbrola_voice_label", "UK English Male 1")
                        plugin.tts_engine:setVoice("mb-en1")
                        UIManager:show(InfoMessage:new{
                            text = _(
                                "MBROLA voice enabled: UK English Male 1.\n\n"
                                .. "Other MBROLA voices are unavailable because they trigger "
                                .. "a firmware bug in the MTK Bluetooth chip that causes "
                                .. "mid-sentence audio repeats. See the full report on GitHub."
                            ),
                            timeout = 5,
                        })
                    end
                end,
            })
            -- If user had a different MBROLA voice selected, migrate to disabled
            do
                local current_mb = plugin:getSetting("tts_mbrola_voice", "")
                if current_mb ~= "" and current_mb ~= "en1" then
                    plugin:setSetting("tts_mbrola_voice", "")
                    plugin:setSetting("tts_mbrola_voice_label", "")
                    local base = plugin:getSetting("tts_voice", "en")
                    local var = plugin:getSetting("tts_voice_variant", "")
                    local full = base
                    if var ~= "" then
                        full = base .. "+" .. var
                    end
                    plugin.tts_engine:setVoice(full)
                end
            end
        else
            -- Non-MTK devices: expose all bundled/installed MBROLA voices.
            table.insert(menu, {
                text_func = function()
                    local label = plugin:getSetting("tts_mbrola_voice_label", "")
                    if label == "" then
                        return _("MBROLA voice")
                    end
                    return T(_("MBROLA voice: %1"), label)
                end,
                sub_item_table_func = function()
                    return MenuBuilder.buildMbrolaVoiceMenu(plugin)
                end,
                help_text = _(
                    "Select a bundled or installed MBROLA voice. "
                    .. "Non-English MBROLA voices are available on devices "
                    .. "that do not use the MTK Bluetooth chip."
                ),
            })
        end
    end

    -- Quick start with espeak (Piper-only): play first sentences via espeak
    -- while Piper warms up.  Only relevant when both backends are usable.
    if plugin.tts_engine
       and plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.PIPER
       and plugin.tts_engine.espeak_bin then
        table.insert(menu, {
            text = _("Quick start with espeak (while Piper loads)"),
            checked_func = function()
                return plugin:getSetting("espeak_cold_start", true)
            end,
            callback = function()
                plugin:toggleSetting("espeak_cold_start", true)
            end,
        })
    end

    -- Piper mitigations for underpowered devices (single-core, low RAM).
    -- Both are OFF by default; the RTF auto-degrade can also enable them
    -- for a session when Piper measurably cannot keep up with playback.
    if plugin.tts_engine
       and plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.PIPER then
        table.insert(menu, {
            text = _("Low-resource mode (slow devices)"),
            checked_func = function()
                return plugin:getSetting("piper_low_resource", false)
            end,
            callback = function()
                plugin:toggleSetting("piper_low_resource", false)
            end,
            help_text = _(
                "Synthesizes one sentence at a time and prioritizes the "
                .. "sentence currently being read. Helps on single-core "
                .. "devices where Piper is slower than playback."
            ),
        })
        table.insert(menu, {
            text = _("Split sentences aggressively for Piper"),
            checked_func = function()
                return plugin:getSetting("piper_aggressive_split", false)
            end,
            callback = function()
                plugin:toggleSetting("piper_aggressive_split", false)
            end,
            help_text = _(
                "Limits synthesis chunks to about 150 characters instead "
                .. "of 300. Reduces the wait per sentence and avoids "
                .. "synthesis failures with long sentences on low-memory "
                .. "devices. Applies from the next page."
            ),
        })
    end

    -- Android TTS language override (backend defaults to auto-detection:
    -- CJK script per chunk, else book metadata; issue #45).
    if plugin.tts_engine
       and plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.ANDROID then
        table.insert(menu, {
            text_func = function()
                local lang = plugin:getSetting("android_tts_language", "auto")
                if lang == "auto" then
                    return T(_("Android TTS language: %1"), _("Auto-detect"))
                end
                return T(_("Android TTS language: %1"), lang)
            end,
            sub_item_table_func = function()
                return MenuBuilder.buildAndroidTtsLanguageMenu(plugin)
            end,
            help_text = _(
                "Auto-detect picks the voice from the text script (Chinese, "
                .. "Japanese, Korean) or the book's language metadata. "
                .. "Choose a specific language to override detection."
            ),
        })
    end

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
                return T(_("Clause pause (, ; : -): %1s"), plugin:getSetting("clause_pause", 0))
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
        -- Downloadable Piper voices (HuggingFace upstream) — only relevant when Piper is active
        table.insert(menu, {
            text = _("Download Piper voice…"),
            sub_item_table_func = function()
                local ok, result = pcall(function()
                    local _dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
                    local Downloader = dofile(_dir .. "downloader.lua")
                    return MenuBuilder.buildPiperDownloadMenu(plugin, Downloader)
                end)
                if ok then
                    return result
                else
                    logger.err("MenuBuilder: buildPiperDownloadMenu crashed:", result)
                    return {{
                        text = _("Could not load voice download menu."),
                        enabled = false,
                    }}
                end
            end,
        })
    else
        table.insert(menu, {
            text_func = function()
                if plugin:getSetting("tts_mbrola_voice", "") ~= "" then
                    return _("Voice: (disabled while MBROLA is on)")
                end
                return T(_("Voice: %1"), plugin:getSetting("tts_voice_label", "English (GB)"))
            end,
            sub_item_table = MenuBuilder.buildVoiceMenu(plugin),
            enabled_func = function()
                return plugin:getSetting("tts_mbrola_voice", "") == ""
            end,
            help_text = _(
                "Base voice and accent variant are ignored when a MBROLA voice is active. "
                .. "Disable MBROLA to use regular espeak-ng voices."
            ),
        })
    end

    return menu
end

function MenuBuilder.buildAlsaDeviceMenu(plugin)
    local pb_default = plugin.tts_engine._pb_has_tts_sm and "tts_sm" or ""
    local devices = {
        { id = "tts_sm",   label = _("PocketBook pipeline - tts_sm (recommended)"),
          help = _("Routes through the PocketBook audio daemon (softvol, dmix, resampling). Best compatibility on devices that expose tts_sm in /etc/asound.conf.") },
        { id = "plughw:0", label = _("Direct hardware with resampling - plughw:0"),
          help = _("Direct hardware access through the ALSA plug layer. On some PocketBooks (e.g. PB631) the plug layer does not actually resample; if you hear playback at 2-3x speed, switch back to tts_sm or Auto.") },
        { id = "",         label = _("Auto (default ALSA device)"),
          help = _("Uses the system default ALSA device, then falls back to tts_sm and plughw:0 if the default is unavailable.") },
        { id = "inkview",  label = _("System player (InkView) - experimental"),
          help = _("Uses the PocketBook InkView PlayFile API. Some firmwares (PB740, PB631) export PlayFile but do not actually play audio; if no sound comes out, switch back to tts_sm or Auto.") },
    }
    local menu = {}
    for _, d in ipairs(devices) do
        table.insert(menu, {
            text = d.label,
            help_text = d.help,
            checked_func = function()
                return plugin:getSetting("pb_alsa_device", pb_default) == d.id
            end,
            callback = function()
                plugin:setSetting("pb_alsa_device", d.id)
                -- Invalidate cached player so the next playback uses the new device
                if plugin.tts_engine then
                    plugin.tts_engine._cached_player = nil
                end
            end,
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
    -- Perceptually spaced (roughly 3dB per step): linear amplitude percentage
    -- maps badly onto loudness, so the choices cluster at the quiet end where
    -- a given percentage change is most audible.
    -- Keep in sync with VOLUME_STEPS in synccontroller.lua (the bar's V-/V+).
    local volumes = {0.01, 0.02, 0.03, 0.05, 0.08, 0.12, 0.18, 0.25, 0.35, 0.50, 0.70, 1.0}
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
                -- Invalidate the prefetched next sentence (synthesized at the
                -- old volume) so the change is heard on the next sentence.
                pcall(plugin.tts_engine._cleanPrefetch, plugin.tts_engine)
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
        [2] = _("2 (20ms - default)"),
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
        -- English variants
        { id = "en",              label = _("English (GB)") },
        { id = "en-us",           label = _("English (US)") },
        { id = "en-gb-x-rp",     label = _("English (Received Pronunciation)") },
        { id = "en-gb-scotland",  label = _("English (Scotland)") },
        { id = "en-gb-x-gbclan",  label = _("English (Lancaster)") },
        { id = "en-gb-x-gbcwmd", label = _("English (West Midlands)") },
        { id = "en-029",          label = _("English (Caribbean)") },
        { id = "en-us-nyc",       label = _("English (New York City)") },
        { separator = true },
        -- European languages
        { id = "de",              label = _("German") },
        { id = "es",              label = _("Spanish") },
        { id = "fr",              label = _("French") },
        { id = "it",              label = _("Italian") },
        { id = "pt",              label = _("Portuguese") },
        { id = "pt-br",           label = _("Portuguese (Brazil)") },
        { id = "nl",              label = _("Dutch") },
        { id = "ru",              label = _("Russian") },
        { id = "pl",              label = _("Polish") },
        { id = "cs",              label = _("Czech") },
        { id = "sv",              label = _("Swedish") },
        { id = "tr",              label = _("Turkish") },
        { id = "el",              label = _("Greek") },
        { id = "fi",              label = _("Finnish") },
        { id = "hu",              label = _("Hungarian") },
        { id = "ro",              label = _("Romanian") },
        { separator = true },
        -- Other languages
        { id = "ar",              label = _("Arabic") },
        { id = "zh",              label = _("Chinese (Mandarin)") },
        { id = "ja",              label = _("Japanese") },
        { id = "ko",              label = _("Korean") },
        { id = "hi",              label = _("Hindi") },
        { id = "vi",              label = _("Vietnamese") },
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
        { id = "m4",       label = _("Male 4") },
        { id = "m5",       label = _("Male 5") },
        { id = "m6",       label = _("Male 6") },
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
        if not a.separator then
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

    -- Platform-native helper: user-supplied, device-specific engine wrapper.
    if engine.backend == engine.BACKENDS.NATIVE or engine:_nativeHelperConfigured() then
        table.insert(available, {
            id = engine.BACKENDS.NATIVE,
            label = _("Platform-native helper (user-supplied engine)"),
        })
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
            callback = function(touchmenu_instance)
                engine:setBackend(backend.id)
                plugin:setSetting("tts_backend", backend.id)
                -- An explicit engine choice clears any prior auto-fallback to
                -- espeak-only mode; otherwise the user's selection would be
                -- silently overridden on the next page.
                plugin:setSetting("espeak_only_mode", false)
                -- Close the menu so the user reopens Voice Settings and sees
                -- the correct engine-specific items (pitch, pauses, etc.).
                if touchmenu_instance then
                    touchmenu_instance:closeMenu()
                end
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
            quality_label = string.format(" (%s · %d kHz)",
                voice.quality,
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
                -- One-time-per-session heads-up on underpowered devices:
                -- Piper cannot sustain realtime playback on single-core /
                -- low-RAM hardware (measured ~8x slower than realtime on a
                -- Kobo Clara BW), so set expectations before the first stall.
                if not plugin._piper_weak_device_warned then
                    local cores = Utils.getCpuCores()
                    local mem_kb = Utils.getMemTotalKb()
                    if cores <= 1 or (mem_kb and mem_kb < 512 * 1024) then
                        plugin._piper_weak_device_warned = true
                        UIManager:show(InfoMessage:new{
                            text = _("Note: this device has limited CPU/RAM. Piper voices may pause between sentences or fall back to espeak during playback. Enabling \"Low-resource mode\" in Voice settings can help."),
                            timeout = 8,
                        })
                    end
                end
            end,
        })
    end

    return menu
end

--[[--
Build Android TTS language menu (auto-detect + common overrides).
--]]
function MenuBuilder.buildAndroidTtsLanguageMenu(plugin)
    local choices = {
        { id = "auto",  label = _("Auto-detect (script + book language)") },
        { id = "en-US", label = "English (US)" },
        { id = "en-GB", label = "English (UK)" },
        { id = "zh-CN", label = "Chinese (Simplified)" },
        { id = "zh-TW", label = "Chinese (Traditional)" },
        { id = "ja-JP", label = "Japanese" },
        { id = "ko-KR", label = "Korean" },
        { id = "fr-FR", label = "French" },
        { id = "de-DE", label = "German" },
        { id = "es-ES", label = "Spanish" },
        { id = "it-IT", label = "Italian" },
        { id = "pt-BR", label = "Portuguese (Brazil)" },
        { id = "ru-RU", label = "Russian" },
    }
    local menu = {}
    for _, choice in ipairs(choices) do
        table.insert(menu, {
            text = choice.label,
            checked_func = function()
                return plugin:getSetting("android_tts_language", "auto") == choice.id
            end,
            callback = function()
                plugin:setSetting("android_tts_language", choice.id)
                -- Force re-application (and re-warning) on the next chunk
                if plugin.tts_engine then
                    plugin.tts_engine._android_tts_lang = nil
                    plugin.tts_engine._android_lang_warned = nil
                end
            end,
            radio = true,
        })
    end
    return menu
end

function MenuBuilder.buildPiperDownloadMenu(plugin, Downloader)
    local menu = {}
    -- plugin.plugin_dir may be nil; fall back to deriving from piper_model_dir
    -- which is set during TTSEngine init as plugin_dir .. "/piper".
    local plugin_dir = plugin.plugin_dir
    if not plugin_dir then
        local pmd = plugin.tts_engine and plugin.tts_engine.piper_model_dir
        if pmd then
            plugin_dir = pmd:match("^(.+)/piper$")
        end
    end
    plugin_dir = plugin_dir or "."
    local voices = Downloader:getPiperVoiceList(plugin_dir)
    logger.warn("buildPiperDownloadMenu: plugin_dir=", plugin_dir, "voices=", #voices)

    -- Refresh voice list from internet (hybrid approach)
    table.insert(menu, {
        text = _("Refresh voice list from internet"),
        keep_menu_open = true,
        callback = function()
            local info = InfoMessage:new{
                text = _("Fetching latest voice list…"),
                timeout = 0,
            }
            UIManager:show(info)
            Downloader:refreshVoiceList(plugin_dir, function(ok, result)
                UIManager:close(info)
                if ok then
                    UIManager:show(InfoMessage:new{
                        text = T(_("Voice list updated.\n%1 voices available."), #result),
                        timeout = 3,
                    })
                else
                    UIManager:show(InfoMessage:new{
                        text = _("Could not refresh voice list.\n\n") .. (result or _("unknown error")),
                        timeout = 5,
                    })
                end
            end)
        end,
    })
    table.insert(menu, {
        text = _("─"),
        enabled = false,
    })

    for __idx, voice in ipairs(voices) do
        -- In Lua 5.1 (LuaJIT) loop locals are reused across iterations,
        -- so closures must not capture 'installed' directly.  Re-query
        -- the disk state inside each closure instead.
        local voice_id = voice.id
        local voice_name = voice.name
        local size_mb = voice.size_mb
        local size_str = string.format(" · %d MB", size_mb)
        -- Debug: log first few voices to trace installed status
        if __idx <= 3 then
            local inst = Downloader:hasPiperVoice(voice_id, plugin_dir)
            logger.warn("buildPiperDownloadMenu voice", __idx, voice_id, "installed=", inst)
        end
        table.insert(menu, {
            text_func = function()
                local inst = Downloader:hasPiperVoice(voice_id, plugin_dir)
                local status = inst and _(" ✓ installed") or _("")
                return voice_name .. size_str .. status
            end,
            enabled_func = function()
                return not Downloader:hasPiperVoice(voice_id, plugin_dir)
            end,
            callback = function()
                if Downloader:hasPiperVoice(voice_id, plugin_dir) then return end
                local info = InfoMessage:new{
                    text = _("Downloading ") .. voice_name .. _("…\n(~")
                        .. size_mb .. _(" MB)"),
                    timeout = 0,
                }
                UIManager:show(info)
                Downloader:downloadPiperVoice(voice_id, plugin_dir,
                    function(done, total)
                        -- progress callback (optional)
                    end,
                    function(ok, err)
                        UIManager:close(info)
                        if ok then
                            -- Auto-select the downloaded voice so it appears
                            -- checked in the Piper voice menu immediately.
                            local voice_path = plugin_dir .. "/piper/" .. voice_id .. ".onnx"
                            if plugin.tts_engine then
                                plugin.tts_engine:setPiperModel(voice_path)
                            end
                            plugin:setSetting("piper_model", voice_path)
                            plugin:setSetting("piper_model_label", voice_name)
                            UIManager:show(InfoMessage:new{
                                text = _("Voice installed:\n") .. voice_name
                                    .. _("\n\nIt is now selected as your active Piper voice."),
                                timeout = 3,
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Download failed:\n") .. (err or _("unknown error")),
                                timeout = 5,
                            })
                        end
                    end
                )
            end,
        })
    end

    return menu
end

--[[--
Build the MBROLA voice selection menu.
Lists bundled and installed MBROLA voices. Selecting one switches
espeak-ng to use the MBROLA voice (e.g. mb-us1).
--]]
function MenuBuilder.buildMbrolaVoiceMenu(plugin)
    local menu = {}
    local plugin_dir = plugin.plugin_dir
    if not plugin_dir then
        local esp = plugin.tts_engine and plugin.tts_engine.espeak_data_path
        if esp then
            plugin_dir = esp:match("^(.+)/espeak%-ng/share$")
        end
    end
    plugin_dir = plugin_dir or "."
    local _dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
    local Downloader = dofile(_dir .. "downloader.lua")
    local voices = Downloader:getMbrolaVoiceList(plugin_dir)
    local current_mb = plugin:getSetting("tts_mbrola_voice", "")

    -- Option to disable MBROLA and use regular espeak-ng voice
    table.insert(menu, {
        text = _("Disable MBROLA (use regular espeak-ng voice)"),
        checked_func = function()
            return plugin:getSetting("tts_mbrola_voice", "") == ""
        end,
        callback = function(touchmenu_instance)
            plugin:setSetting("tts_mbrola_voice", "")
            plugin:setSetting("tts_mbrola_voice_label", "")
            -- Restore regular espeak-ng voice
            local base = plugin:getSetting("tts_voice", "en")
            local var = plugin:getSetting("tts_voice_variant", "")
            local full = base
            if var ~= "" then full = base .. "+" .. var end
            plugin.tts_engine:setVoice(full)
            UIManager:show(InfoMessage:new{
                text = _("MBROLA disabled. Using regular espeak-ng voice."),
                timeout = 2,
            })
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
    })

    -- Group voices by language
    local lang_labels = {
        en = _("English"), fr = _("French"), de = _("German"),
        es = _("Spanish"), it = _("Italian"), pt = _("Portuguese"),
        nl = _("Dutch"), pl = _("Polish"), cs = _("Czech"),
        el = _("Greek"), ja = _("Japanese"), zh = _("Chinese"),
        ru = _("Russian"), ar = _("Arabic"), sv = _("Swedish"),
        tr = _("Turkish"),
    }

    local voices_by_lang = {}
    for _, v in ipairs(voices) do
        if v.bundled or v.installed then
            local lang = v.lang or "other"
            voices_by_lang[lang] = voices_by_lang[lang] or {}
            table.insert(voices_by_lang[lang], v)
        end
    end

    local sorted_langs = {}
    for lang in pairs(voices_by_lang) do
        table.insert(sorted_langs, lang)
    end
    table.sort(sorted_langs)

    for i, lang in ipairs(sorted_langs) do
        local lang_voices = voices_by_lang[lang]
        table.sort(lang_voices, function(a, b) return a.id < b.id end)

        for j, v in ipairs(lang_voices) do
            local voice_id = v.id
            local label = v.name
            if v.bundled then
                label = label .. _(" (bundled)")
            end
            table.insert(menu, {
                text_func = function()
                    local sel = plugin:getSetting("tts_mbrola_voice", "")
                    local mark = (sel == voice_id) and " ✓" or ""
                    return label .. mark
                end,
                callback = function(touchmenu_instance)
                    local mb_voice = "mb-" .. voice_id
                    plugin:setSetting("tts_mbrola_voice", voice_id)
                    plugin:setSetting("tts_mbrola_voice_label", v.name)
                    plugin.tts_engine:setVoice(mb_voice)
                    UIManager:show(InfoMessage:new{
                        text = T(_("MBROLA voice selected:\n%1"), v.name),
                        timeout = 2,
                    })
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
            })
        end
    end

    return menu
end

--[[--
Build the MBROLA voice download menu.
Lists downloadable MBROLA voices with size and install status.
--]]
function MenuBuilder.buildMbrolaDownloadMenu(plugin, Downloader)
    local menu = {}
    local plugin_dir = plugin.plugin_dir
    if not plugin_dir then
        local esp = plugin.tts_engine and plugin.tts_engine.espeak_data_path
        if esp then
            plugin_dir = esp:match("^(.+)/espeak%-ng/share$")
        end
    end
    plugin_dir = plugin_dir or "."
    local voices = Downloader:getMbrolaVoiceList(plugin_dir)

    for idx, v in ipairs(voices) do
        if v.bundled then
            -- Bundled voices are already included; skip in download menu
            goto continue
        end
        local voice_id = v.id
        local voice_name = v.name
        local size_str = string.format(" · %.1f MB", v.size_mb)

        table.insert(menu, {
            text_func = function()
                local inst = Downloader:hasMbrolaVoice(voice_id, plugin_dir)
                local status = inst and _(" ✓ installed") or _("")
                return voice_name .. size_str .. status
            end,
            enabled_func = function()
                return not Downloader:hasMbrolaVoice(voice_id, plugin_dir)
            end,
            callback = function()
                if Downloader:hasMbrolaVoice(voice_id, plugin_dir) then return end
                local info = InfoMessage:new{
                    text = _("Downloading ") .. voice_name .. _("…\n(~")
                        .. string.format("%.1f", v.size_mb) .. _(" MB)"),
                    timeout = 0,
                }
                UIManager:show(info)
                Downloader:downloadMbrolaVoice(voice_id, plugin_dir,
                    function(done, total)
                        -- progress callback (optional)
                    end,
                    function(ok, err)
                        UIManager:close(info)
                        if ok then
                            -- Auto-select the downloaded voice
                            plugin:setSetting("tts_mbrola_voice", voice_id)
                            plugin:setSetting("tts_mbrola_voice_label", voice_name)
                            if plugin.tts_engine then
                                plugin.tts_engine:setVoice("mb-" .. voice_id)
                            end
                            UIManager:show(InfoMessage:new{
                                text = _("Voice installed:\n") .. voice_name
                                    .. _("\n\nIt is now selected as your active MBROLA voice."),
                                timeout = 3,
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Download failed:\n") .. (err or _("unknown error")),
                                timeout = 5,
                            })
                        end
                    end
                )
            end,
        })
        ::continue::
    end

    if #menu == 0 then
        table.insert(menu, {
            text = _("All available MBROLA voices are already installed."),
            enabled = false,
        })
    end

    return menu
end

--[[--
Build the platform-native TTS settings menu.
--]]
function MenuBuilder.buildNativeTtsSettingsMenu(plugin)
    local menu = {}

    -- Helper path
    table.insert(menu, {
        text_func = function()
            local path = plugin:getSetting("native_helper_path", "")
            if path == "" then
                return _("Native helper: not set")
            end
            return T(_("Native helper: %1"), path)
        end,
        callback = function(touchmenu_instance)
            MenuBuilder._showNativeHelperPathChooser(plugin, touchmenu_instance)
        end,
    })

    -- Input encoding
    table.insert(menu, {
        text_func = function()
            return T(_("Input encoding: %1"), plugin:getSetting("native_input_encoding", "utf-8"):upper())
        end,
        sub_item_table = {
            {
                text = "UTF-8",
                checked_func = function()
                    return plugin:getSetting("native_input_encoding", "utf-8") == "utf-8"
                end,
                callback = function()
                    plugin:setSetting("native_input_encoding", "utf-8")
                end,
            },
            {
                text = "CP1252",
                checked_func = function()
                    return plugin:getSetting("native_input_encoding", "utf-8") == "cp1252"
                end,
                callback = function()
                    plugin:setSetting("native_input_encoding", "cp1252")
                end,
            },
        },
    })

    -- Speed mode
    table.insert(menu, {
        text_func = function()
            local mode = plugin:getSetting("native_speed_mode", "oneshot")
            local label = (mode == "daemon") and _("daemon/FIFO") or _("one-shot")
            return T(_("Speed mode: %1"), label)
        end,
        sub_item_table = {
            {
                text = _("One-shot (run helper per sentence)"),
                checked_func = function()
                    return plugin:getSetting("native_speed_mode", "oneshot") == "oneshot"
                end,
                callback = function()
                    plugin:setSetting("native_speed_mode", "oneshot")
                end,
            },
            {
                text = _("Daemon/FIFO (keep helper running)"),
                checked_func = function()
                    return plugin:getSetting("native_speed_mode", "oneshot") == "daemon"
                end,
                callback = function()
                    plugin:setSetting("native_speed_mode", "daemon")
                end,
            },
        },
    })

    -- FIFO path
    table.insert(menu, {
        text_func = function()
            local path = plugin:getSetting("native_fifo_path", "")
            if path == "" then
                return _("FIFO path: default")
            end
            return T(_("FIFO path: %1"), path)
        end,
        callback = function(touchmenu_instance)
            MenuBuilder._showNativeFifoPathDialog(plugin, touchmenu_instance)
        end,
    })

    -- Pre-synthesis command
    table.insert(menu, {
        text_func = function()
            local cmd = plugin:getSetting("native_prestep_command", "")
            if cmd == "" then
                return _("Pre-synthesis command: none")
            end
            return T(_("Pre-synthesis command: %1"), cmd)
        end,
        callback = function(touchmenu_instance)
            MenuBuilder._showNativePrestepDialog(plugin, touchmenu_instance)
        end,
    })

    return menu
end

--[[--
Show a PathChooser to select the platform-native helper executable.
--]]
function MenuBuilder._showNativeHelperPathChooser(plugin, touchmenu_instance)
    local PathChooser = require("ui/widget/pathchooser")
    local home_dir = require("datastorage").getDataDir() or "/mnt"
    UIManager:show(PathChooser:new{
        title = _("Select native TTS helper"),
        path = home_dir,
        select_file = true,
        onConfirm = function(file_path)
            plugin:setSetting("native_helper_path", file_path)
            if plugin.tts_engine then
                plugin.tts_engine.backend_cmd = file_path
            end
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
            UIManager:show(InfoMessage:new{
                text = _("Native helper path saved."),
                timeout = 2,
            })
        end,
    })
end

--[[--
Show an InputDialog for the native TTS FIFO path.
--]]
function MenuBuilder._showNativeFifoPathDialog(plugin, touchmenu_instance)
    local InputDialog = require("ui/widget/inputdialog")
    local current = plugin:getSetting("native_fifo_path", "")
    local dialog
    dialog = InputDialog:new{
        title = _("Native TTS FIFO path"),
        input = current,
        input_hint = "/tmp/audiobook_native_tts.fifo",
        description = _(
            "Optional path to the request FIFO used in daemon mode. "
            .. "Leave empty to use the default."
        ),
        buttons = {
            {
                { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        plugin:setSetting("native_fifo_path", dialog:getInputText())
                        UIManager:close(dialog)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

--[[--
Show an InputDialog for the native TTS pre-synthesis command.
--]]
function MenuBuilder._showNativePrestepDialog(plugin, touchmenu_instance)
    local InputDialog = require("ui/widget/inputdialog")
    local current = plugin:getSetting("native_prestep_command", "")
    local dialog
    dialog = InputDialog:new{
        title = _("Pre-synthesis command"),
        input = current,
        input_hint = "",
        description = _(
            "Optional shell command to run before each synthesis request "
            .. "(for example, to wake or restart a device-specific audio path)."
        ),
        buttons = {
            {
                { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        plugin:setSetting("native_prestep_command", dialog:getInputText())
                        UIManager:close(dialog)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

return MenuBuilder
