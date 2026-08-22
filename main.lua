--[[--
Audiobook TTS Plugin with Word Highlight Sync Read-Along
Provides text-to-speech with synchronized word highlighting.

@module koplugin.audiobook
--]]

-- CRITICAL: Only require() modules that have existed in every KOReader version.
-- If ANY top-level statement throws, KOReader's pcall(dofile, "main.lua") fails
-- and the plugin vanishes from menus entirely -- no error shown to the user.
-- Newer / optional modules (Dispatcher) and plugin dofile() submodules are
-- loaded inside init() where failures are caught and reported gracefully.
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
-- Prefer plugin-local catalogs (l10n/fr, l10n/es); fall back to core gettext.
do
    local dir = (debug.getinfo(1, "S").source or ""):match("^@(.*/)") or "./"
    package.path = dir .. "?.lua;" .. package.path
end
local _
do
    local ok_gt, gt = pcall(require, "audiobook_gettext")
    if ok_gt then
        _ = gt
    else
        _ = require("gettext")
    end
end

-- Forward-declared module-level locals.  Populated by init() Phase 1.
-- Every function in this file can reference them as upvalues; they start
-- as nil and become usable after init() succeeds.
local Device, UIManager, InfoMessage, T, Time
local BtUI, BtMediaControl, BugReport, BenchmarkRunner, MenuBuilder, Utils, Updater
local SessionRecorder
local PLUGIN_PATH

--- Plugin debug.log (included in bug reports). No book text. Never throws.
local function dlog(...)
    local DL = package.loaded["audiobook_debuglog"]
    if DL and DL.log then
        pcall(DL.log, ...)
    end
end

local Audiobook = WidgetContainer:extend{
    name = "audiobook",
    is_doc_only = false,
}

function Audiobook:init()
    -- ── Phase 1: Load ancillary modules ─────────────────────────────
    -- These are loaded here (not at module top level) because a failed
    -- top-level require/dofile makes KOReader silently drop the entire
    -- plugin.  Loading them inside init() lets us catch errors and still
    -- show a menu entry with a helpful error message.
    --
    -- The forward-declared module-level locals (Device, UIManager, etc.)
    -- are assigned here.  All functions defined below this point see the
    -- assignments through their upvalue references.
    local load_ok, load_err = pcall(function()
        Device = require("device")
        UIManager = require("ui/uimanager")
        InfoMessage = require("ui/widget/infomessage")
        T = require("ffi/util").template
        Time = require("ui/time")

        -- Kill audio pipelines orphaned by a previous KOReader instance.
        -- Playback (and the A2DP keepalive, which is infinite) runs as
        -- detached background processes: if KOReader is killed or crashes
        -- they keep playing, and the next session's audio mixes on top.
        -- The patterns are specific to this plugin's pipelines.
        if Device:isKindle() then
            -- [c]/[f] character classes keep the pattern from matching the
            -- pkill wrapper shell's own cmdline.
            os.execute("pkill -f 'mixersink stream-type=Musi[c]' 2>/dev/null")
            os.execute("pkill -f 'audiobook.koplugin/bin/[f]fmpeg' 2>/dev/null")
        end

        -- Resolve plugin directory from self.path (set by KOReader's plugin
        -- loader) with a debug.getinfo fallback for dev/testing.
        local _utils_dir = self.path and (self.path .. "/")
            or debug.getinfo(2, "S").source:match("^@(.*/)[^/]*$")
            or "./"
        -- Collapse double slashes and ensure exactly one trailing slash.
        _utils_dir = _utils_dir:gsub("//+", "/"):gsub("/+$", "") .. "/"
        PLUGIN_PATH = _utils_dir

        -- Load each submodule independently so a failure in one
        -- (e.g. btui.lua) doesn't prevent BugReport from loading.
        local function try_dofile(path)
            local ok, mod = pcall(dofile, path)
            if ok then return mod end
            logger.warn("Audiobook: failed to load", path, ":", mod)
            return nil
        end
        -- Prefer *.fix25.lua / *.v25.lua when present (Boox MTP often fails to
        -- overwrite large same-name files; unique names always land).
        local function try_dofile_v25(name)
            return try_dofile(_utils_dir .. name .. ".fix31.lua")
                or try_dofile(_utils_dir .. name .. ".fix30.lua")
                or try_dofile(_utils_dir .. name .. ".fix29.lua")
                or try_dofile(_utils_dir .. name .. ".fix28.lua")
                or try_dofile(_utils_dir .. name .. ".fix27.lua")
                or try_dofile(_utils_dir .. name .. ".fix26.lua")
                or try_dofile(_utils_dir .. name .. ".fix25.lua")
                or try_dofile(_utils_dir .. name .. ".v25.lua")
                or try_dofile(_utils_dir .. name .. ".lua")
        end
        BtUI = try_dofile(_utils_dir .. "btui.lua")
        BtMediaControl = try_dofile_v25("btmediacontrol")
        BugReport = try_dofile(_utils_dir .. "bugreport.lua")
        BenchmarkRunner = try_dofile(_utils_dir .. "benchmarkrunner.lua")
        MenuBuilder = try_dofile(_utils_dir .. "menubuilder.lua")
        Utils = try_dofile(_utils_dir .. "utils.lua")
        SessionRecorder = try_dofile(_utils_dir .. "sessionrecorder.lua")
        -- Persistent debug ring for Android/Boox (included in bug reports).
        local DebugLog = try_dofile(_utils_dir .. "debuglog.lua")
        if DebugLog and DebugLog.init then
            pcall(function() DebugLog.init(_utils_dir) end)
            self._debug_log = DebugLog
            package.loaded["audiobook_debuglog"] = DebugLog
        end
    end)
    if not load_ok then
        logger.warn("Audiobook: module loading failed:", load_err)
        self._init_error = tostring(load_err)
        -- Still register the menu so the user sees *something*.
        pcall(function() self.ui.menu:registerToMainMenu(self) end)
        return
    end

    -- ── Phase 2: Register menu and dispatcher actions ───────────────
    -- Register the menu so the plugin always appears, even if heavy
    -- submodule loading (Phase 3) fails.  Callbacks check self._init_ok.
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()

    -- Heavy initialization is wrapped in pcall so a crash in any
    -- submodule (e.g. FFI on Android, missing library) doesn't
    -- prevent the plugin from showing in the menu at all.
    local ok, err = pcall(function() self:_initSubmodules() end)
    if not ok then
        logger.warn("Audiobook: init failed:", err)
        self._init_error = tostring(err)
        return
    end
    self._init_ok = true

    -- Install SleepCover event override so we can prevent device suspend
    -- while audio is playing (when the user enables the setting).
    self:_installSleepCoverOverride()

    -- If the user chose "Play aligned/enriched audiobook" from the browser,
    -- the FileManager plugin instance stored a pending request before ReaderUI
    -- loaded. Handle it now that we have a document.
    self:_checkPendingAlignedStart()

    -- Add "Read aloud from here" to the text selection / highlight popup.
    -- This appears when the user selects a paragraph or multiple words
    -- (as opposed to the single-word dictionary popup, which is handled
    -- by _registerDictButtons on KOReader >= 2026.07 and by the legacy
    -- onDictButtonsReady event handler on older releases).
    if self.ui.highlight and self.ui.highlight.addToHighlightDialog then
        self.ui.highlight:addToHighlightDialog("15_read_aloud", function(this)
            return {
                text = _("Read aloud from here"),
                callback = function()
                    if not self._init_ok then
                        self:_showInitError()
                        return
                    end
                    local selected_text = this.selected_text
                    local context = nil
                    if selected_text then
                        context = {
                            pos0 = selected_text.pos0,
                            pos1 = selected_text.pos1,
                        }
                    end
                    this:onClose()
                    UIManager:scheduleIn(0.3, function()
                        local word = selected_text and selected_text.text
                        if word then
                            -- Use the first word for position matching
                            word = word:match("^%s*(%S+)") or word
                        end
                        self:startReadAlongFromWord(word, context)
                    end)
                end,
            }
        end)
        self.ui.highlight:addToHighlightDialog("16_play_aligned", function(this)
            return {
                text = _("Play aligned audiobook from here"),
                callback = function()
                    if not self._init_ok then
                        self:_showInitError()
                        return
                    end
                    local selected_text = this.selected_text
                    this:onClose()
                    UIManager:scheduleIn(0.3, function()
                        self:startAlignedAudioFromSelection(selected_text)
                    end)
                end,
            }
        end)
    end

    -- Single-word dictionary popup buttons.  KOReader 2026.07
    -- (koreader/koreader#15184) removed the DictButtonsReady broadcast in
    -- favor of a registration API; on older releases onDictButtonsReady()
    -- below still receives the event and appends the same buttons.
    self:_registerDictButtons()
end

--[[--
Register "Read aloud from here" / "Play aligned audiobook from here" in the
single-word dictionary popup via ReaderDictionary:addToDictButtons (KOReader
>= 2026.07).  No-op on older KOReader, where the DictButtonsReady event is
still broadcast and handled by onDictButtonsReady().

Both buttons use conditional = true: transient rows appended at the end,
mirroring the old table.insert(buttons, ...) placement.
--]]
function Audiobook:_registerDictButtons()
    if not (self.ui.dictionary and self.ui.dictionary.addToDictButtons) then
        return
    end
    local plugin = self

    self.ui.dictionary:addToDictButtons({
        id = "audiobook_read",
        text = _("Read aloud from here"),
        font_bold = false,
        conditional = true,
        show_func = function(dict_popup)
            return plugin._init_ok and not dict_popup.is_wiki_fullpage
        end,
        callback = function(dict_popup)
            local word = dict_popup.word or dict_popup.lookupword
            -- Capture surrounding text context from the highlight selection
            -- so we can find the correct occurrence of the word on the page,
            -- not just the first one.
            local selected_text_context = nil
            if dict_popup.highlight and dict_popup.highlight.selected_text then
                local sel = dict_popup.highlight.selected_text
                -- For CRe docs, pos0 is an xpointer string with an offset;
                -- for paged docs it's a table.  Either way, save the surrounding
                -- selected text or the raw pos0 for position matching.
                selected_text_context = {
                    pos0 = sel.pos0,
                    pos1 = sel.pos1,
                }
            end
            UIManager:close(dict_popup)
            -- Give the dictionary popup and any parent highlight enough time
            -- to fully close and leave the UIManager window stack before we
            -- add the PlaybackBar.  Too short a delay means _isOverlayActive()
            -- still sees stale non-toast widgets and suppresses the bar.
            UIManager:scheduleIn(0.3, function()
                plugin:startReadAlongFromWord(word, selected_text_context)
            end)
        end,
    })

    self.ui.dictionary:addToDictButtons({
        id = "audiobook_play_aligned",
        text = _("Play aligned audiobook from here"),
        font_bold = false,
        conditional = true,
        show_func = function(dict_popup)
            return plugin._init_ok and not dict_popup.is_wiki_fullpage
        end,
        callback = function(dict_popup)
            local selected_text = nil
            if dict_popup.highlight and dict_popup.highlight.selected_text then
                selected_text = dict_popup.highlight.selected_text
            end
            UIManager:close(dict_popup)
            UIManager:scheduleIn(0.3, function()
                plugin:startAlignedAudioFromSelection(selected_text)
            end)
        end,
    })
end

function Audiobook:_initSubmodules()
    -- ── Orphan cleanup from previous crash/SIGKILL ──
    self:_killOrphanProcessesFromPreviousSession()

    local pp = PLUGIN_PATH
    local has_document = self.ui and self.ui.document

    -- ── TTS / read-along modules (only when a document is open) ──
    if has_document then
        local ok_tts, err_tts = pcall(function()
            local TextParser = dofile(pp .. "textparser.lua")
            local TTSEngine = dofile(pp .. "ttsengine.lua")
            local HighlightManager = dofile(pp .. "highlightmanager.lua")
            local SyncController = dofile(pp .. "synccontroller.lua")
            self.bt_manager = dofile(pp .. "btmanager.lua")

            self.text_parser = TextParser:new()
            self.tts_engine = TTSEngine:new{
                plugin = self,
                plugin_dir = Utils.normalizeDirPath(pp),
            }
            local saved_backend = self:getSetting("tts_backend", nil)
            if saved_backend then
                self.tts_engine:setBackend(saved_backend)
            end
            -- Ensure the native backend has the latest helper path after restore.
            if saved_backend == self.tts_engine.BACKENDS.NATIVE
               and self.tts_engine:_nativeHelperConfigured() then
                self.tts_engine.backend_cmd = self:getSetting("native_helper_path", "")
            end
            self.tts_engine:setRate(self:getSetting("speech_rate", 1.0))
            self.tts_engine:setPitch(self:getSetting("speech_pitch", 50))
            self.tts_engine:setVolume(self:getSetting("speech_volume", 1.0))
            local mbrola_voice = self:getSetting("tts_mbrola_voice", "")
            if mbrola_voice ~= "" then
                self.tts_engine:setVoice("mb-" .. mbrola_voice)
            else
                local voice_base = self:getSetting("tts_voice", "en")
                local voice_variant = self:getSetting("tts_voice_variant", "")
                local full_voice = voice_base
                if voice_variant ~= "" then
                    full_voice = voice_base .. "+" .. voice_variant
                end
                self.tts_engine:setVoice(full_voice)
            end
            self.tts_engine:setWordGap(self:getSetting("word_gap", 2))
            self.tts_engine:setClausePause(self:getSetting("clause_pause", 0))
            local piper_model = self:getSetting("piper_model", nil)
            if piper_model then
                self.tts_engine:setPiperModel(piper_model)
            end
            self.tts_engine:setPiperSpeaker(self:getSetting("piper_speaker", 0))
            self.tts_engine._gap_test_mode = self:getSetting("gap_test_mode", false)
            -- Aggressive long-sentence splitting for Piper (setting + session
            -- auto-degrade).  Evaluated lazily at every parse() call.
            self.text_parser.max_chunk_fn = function()
                if self.tts_engine and self.tts_engine:_piperAggressiveSplit() then
                    return TextParser.AGGRESSIVE_CHUNK_CHARS
                end
                return nil  -- default cap
            end
            self.highlight_manager = HighlightManager:new{
                plugin = self,
                ui = self.ui,
                style = self:getSetting("highlight_style", "background"),
            }
            self.sync_controller = SyncController:new{
                plugin = self,
                tts_engine = self.tts_engine,
                highlight_manager = self.highlight_manager,
                text_parser = self.text_parser,
            }
        end)
        if not ok_tts then
            logger.warn("Audiobook: TTS modules failed to load:", err_tts)
        end
    end

    -- ── Bluetooth manager (needed for BT settings even without a document) ──
    if not self.bt_manager then
        pcall(function()
            self.bt_manager = dofile(pp .. "btmanager.lua")
        end)
    end

    -- ── Clean old cached cover art ──
    pcall(function()
        local MetadataParser = dofile(pp .. "m4bparser.lua")
        if MetadataParser then
            MetadataParser:clearOldCoverArt(pp, 30)
        end
    end)

    -- ── Clean old transcoded files ──
    pcall(function()
        local Transcoder = dofile(pp .. "transcoder.lua")
        if Transcoder then
            Transcoder:new{plugin_dir = pp}:clearOldTranscodes(30)
        end
    end)

    -- ── Media playback modules (always load; works without a document) ──
    local ok_media, err_media = pcall(function()
        local function dofile_v25(name)
            for _, suffix in ipairs({ ".fix31.lua", ".fix30.lua", ".fix29.lua", ".fix28.lua", ".fix27.lua", ".fix26.lua", ".fix25.lua", ".v25.lua", ".lua" }) do
                local path = pp .. name .. suffix
                local f = io.open(path, "r")
                if f then
                    f:close()
                    return dofile(path)
                end
            end
            return dofile(pp .. name .. ".lua")
        end
        local MediaEngine = dofile_v25("mediaengine")
        local MediaSync = dofile_v25("mediasync")
        local Transcoder = dofile(pp .. "transcoder.lua")
        self.media_engine = MediaEngine:new{plugin = self, plugin_dir = pp:sub(1, -2)}
        self.transcoder = Transcoder:new{plugin_dir = pp}
        self.media_sync = MediaSync:new{
            plugin = self,
            media_engine = self.media_engine,
            highlight_manager = self.highlight_manager, -- may be nil
        }
    end)
    if not ok_media then
        logger.warn("Audiobook: media modules failed to load:", err_media)
        self._media_modules_error = tostring(err_media)
        self.media_engine = nil
        self.media_sync = nil
        self.transcoder = nil
    end

    -- ── Audiobookshelf modules (always load; works without a document) ──
    local ok_abs, err_abs = pcall(function()
        local ABSSync = dofile(pp .. "abssync.lua")
        if ABSSync then
            self._abs_sync = ABSSync:new{
                plugin = self,
                plugin_dir = pp:sub(1, -2),
            }
            self:_startAbsSyncTimer()
        end
    end)
    if not ok_abs then
        logger.warn("Audiobook: ABS sync module failed to load:", err_abs)
        self._abs_sync = nil
    end

    -- ── Session recorder (always load; works without a document) ──
    if SessionRecorder then
        local ok_rec, err_rec = pcall(function()
            self.session_recorder = SessionRecorder:new{
                plugin = self,
                plugin_dir = pp:sub(1, -2),
            }
            self.session_recorder:init()
        end)
        if not ok_rec then
            logger.warn("Audiobook: session recorder failed to load:", err_rec)
            self.session_recorder = nil
        end
    end
end

function Audiobook:onDispatcherRegisterActions()
    local ok, Dispatcher = pcall(require, "dispatcher")
    if not ok then return end
    Dispatcher:registerAction("audiobook_toggle", {
        category = "none",
        event = "AudiobookToggle",
        title = _("Toggle Read-Along"),
        reader = true,
    })
    Dispatcher:registerAction("audiobook_stop", {
        category = "none",
        event = "AudiobookStop",
        title = _("Stop Read-Along"),
        reader = true,
    })
end

function Audiobook:_showInitError()
    if not UIManager or not InfoMessage then
        logger.warn("Audiobook: init failed:", self._init_error or "Unknown error")
        return
    end
    UIManager:show(InfoMessage:new{
        text = _("Audiobook plugin failed to initialize.\n\n") .. (self._init_error or "Unknown error"),
        timeout = 8,
    })
end

function Audiobook:addToMainMenu(menu_items)
    -- If Phase 1 module loading failed, show a minimal error menu.
    -- The full menu references modules (BtUI, MenuBuilder, T) that are nil
    -- when loading fails, so we must not build it.
    -- Check MenuBuilder directly: Phase 1 loads UIManager *before* the
    -- plugin submodules, so UIManager can be set even when loading failed.
    if not MenuBuilder then
        menu_items.audiobook = {
            text = _("Audiobook Read-Along (error)"),
            sorting_hint = "tools",
            sub_item_table = {
                {
                    text = _("Plugin failed to load"),
                    callback = function()
                        logger.warn("Audiobook: init failed:", self._init_error)
                    end,
                    help_text = self._init_error,
                },
                {
                    text = _("Generate bug report"),
                    callback = function()
                        if BugReport then
                            BugReport.menuCallback(self)
                        elseif UIManager and InfoMessage then
                            UIManager:show(InfoMessage:new{
                                text = _("Bug report module failed to load.\n\nRun generate-report.sh via SSH or the terminal emulator instead."),
                                timeout = 10,
                            })
                        end
                    end,
                },
            },
        }
        return
    end

    menu_items.audiobook = {
        text = _("Audiobook Read-Along"),
        sorting_hint = "tools",
        sub_item_table = {
            -- ── TTS read-along (document required) ──
            {
                text = _("Start Text-to-Speech from current page"),
                enabled_func = function() return (self.ui and self.ui.document) or false end,
                callback = function(touchmenu_instance)
                    if touchmenu_instance then touchmenu_instance:closeMenu() end
                    if not self._init_ok then self:_showInitError(); return end
                    self:startReadAlong()
                end,
            },
            -- ── Media playback (audio files & EPUB overlays) ──
            {
                text = _("Play aligned/enriched audiobook"),
                enabled_func = function()
                    return (self._init_ok and self.media_sync ~= nil
                            and ((self.ui and self.ui.document) or self:_isFileManager())) or false
                end,
                callback = function(touchmenu_instance)
                    if touchmenu_instance then touchmenu_instance:closeMenu() end
                    self:startMediaPlayback()
                end,
            },
            {
                text = _("Start music playlist"),
                enabled_func = function()
                    return (self._init_ok and self.media_sync ~= nil) or false
                end,
                callback = function(touchmenu_instance)
                    if touchmenu_instance then touchmenu_instance:closeMenu() end
                    self:openMusicPlaylist()
                end,
            },
            {
                text = _("Play unaligned audiobook"),
                enabled_func = function()
                    return (self._init_ok and self.media_sync ~= nil) or false
                end,
                callback = function(touchmenu_instance)
                    if touchmenu_instance then touchmenu_instance:closeMenu() end
                    self:openAudioFile()
                end,
            },
            -- ── Audiobookshelf ──
            -- Configuration/log-in should be reachable even if the media
            -- player failed to initialize on a particular firmware.  Playback
            -- actions inside the submenu still guard against a missing
            -- media_sync.
            {
                text = _("Audiobookshelf"),
                enabled_func = function()
                    return self._init_ok
                end,
                sub_item_table_func = function()
                    return self:_buildAudiobookshelfMenu()
                end,
            },
            -- ── Bluetooth settings ──
            {
                text = _("Bluetooth settings"),
                sub_item_table = {
                    {
                        text_func = function()
                            return BtUI.btMenuLabel(self)
                        end,
                        sub_item_table_func = function()
                            return BtUI.buildBluetoothMenu(self)
                        end,
                    },
                    {
                        text = _("Headset media buttons"),
                        checked_func = function()
                            return self:getSetting("bt_media_control", true)
                        end,
                        callback = function()
                            self:toggleSetting("bt_media_control", true)
                            if self:getSetting("bt_media_control", true) then
                                BtMediaControl.start(self)
                            else
                                BtMediaControl.stop()
                            end
                        end,
                        help_text = _("When enabled, play/pause/next/prev buttons on a Bluetooth headset or speaker will control playback. The connected device will also show playback status.\n\nOn Kindle, stem clicks are read from Lab126 LIPC (playermgr / audiomgrd) because this firmware has no AVRCP evdev node."),
                    },
                    {
                        text = _("Reconnect BT on track change"),
                        enabled_func = function()
                            return Device.isKindle and Device:isKindle()
                        end,
                        checked_func = function()
                            return self:getSetting("kindle_bt_reconnect_on_track", false)
                        end,
                        callback = function()
                            self:toggleSetting("kindle_bt_reconnect_on_track", false)
                        end,
                        help_text = _("Kindle + AirPods: when enabled, each playlist/Storyteller audio-file boundary runs a Bluetooth Disconnect→Connect cycle before the next file starts (~5–10 s gap). Off by default; the plugin still keeps a silent A2DP keepalive across the gap. Turn this on only if audio goes silent at chapter/chunk transitions."),
                    },
                    {
                        text_func = function()
                            local val = self:getSetting("bt_disconnect_check", 30)
                            if val == 0 then
                                return _("Disconnect alert: off")
                            end
                            return T(_("Disconnect alert: %1s"), val)
                        end,
                        sub_item_table_func = function()
                            return BtUI.buildBTDisconnectMenu(self)
                        end,
                    },
                },
            },
            -- ── Voice settings (document required) ──
            {
                text_func = function()
                    if not self._init_ok then return _("Voice settings") end
                    if not self.tts_engine then return _("Voice settings (N/A)") end
                    if self.tts_engine.backend == self.tts_engine.BACKENDS.PIPER then
                        local model_label = self:getSetting("piper_model_label", "default")
                        return T(_("Voice settings (Piper - %1)"), model_label)
                    end
                    local voice_label = self:getSetting("tts_voice_label", "English (GB)")
                    local variant_label = self:getSetting("tts_variant_label", "")
                    if variant_label ~= "" and variant_label ~= "Default (male)" then
                        voice_label = voice_label .. " - " .. variant_label
                    end
                    return T(_("Voice settings (%1)"), voice_label)
                end,
                enabled_func = function() return (self.ui and self.ui.document and self._init_ok and self.tts_engine ~= nil) or false end,
                sub_item_table_func = function()
                    return MenuBuilder.buildVoiceSettingsMenu(self)
                end,
            },
            -- ── General settings ──
            {
                text = _("General settings"),
                sub_item_table = {
                    {
                        text = _("Session recorder settings"),
                        sub_item_table = {
                            {
                                text_func = function()
                                    local fps = self:getSetting("session_recorder_video_fps", 1)
                                    return T(_("Video FPS: %1"), fps)
                                end,
                                sub_item_table = {
                                    { text = "1", checked_func = function() return self:getSetting("session_recorder_video_fps", 1) == 1 end, callback = function() self:setSetting("session_recorder_video_fps", 1) end },
                                    { text = "2", checked_func = function() return self:getSetting("session_recorder_video_fps", 1) == 2 end, callback = function() self:setSetting("session_recorder_video_fps", 2) end },
                                    { text = "5", checked_func = function() return self:getSetting("session_recorder_video_fps", 1) == 5 end, callback = function() self:setSetting("session_recorder_video_fps", 5) end },
                                },
                                help_text = _("Frames per second for the video capture. Higher values use more CPU and storage."),
                            },
                            {
                                text_func = function()
                                    local scale = self:getSetting("session_recorder_video_scale", 0.5)
                                    return T(_("Video scale: %1"), scale)
                                end,
                                sub_item_table = {
                                    { text = "25%", checked_func = function() return self:getSetting("session_recorder_video_scale", 0.5) == 0.25 end, callback = function() self:setSetting("session_recorder_video_scale", 0.25) end },
                                    { text = "50%", checked_func = function() return self:getSetting("session_recorder_video_scale", 0.5) == 0.5 end, callback = function() self:setSetting("session_recorder_video_scale", 0.5) end },
                                    { text = "75%", checked_func = function() return self:getSetting("session_recorder_video_scale", 0.5) == 0.75 end, callback = function() self:setSetting("session_recorder_video_scale", 0.75) end },
                                    { text = "100%", checked_func = function() return self:getSetting("session_recorder_video_scale", 0.5) == 1.0 end, callback = function() self:setSetting("session_recorder_video_scale", 1.0) end },
                                },
                                help_text = _("Resolution scaling for the video. Lower values reduce file size and CPU load."),
                            },
                            {
                                text_func = function()
                                    local q = self:getSetting("session_recorder_video_quality", 8)
                                    return T(_("Video quality: %1"), q)
                                end,
                                sub_item_table = {
                                    { text = "4", checked_func = function() return self:getSetting("session_recorder_video_quality", 8) == 4 end, callback = function() self:setSetting("session_recorder_video_quality", 4) end },
                                    { text = "8", checked_func = function() return self:getSetting("session_recorder_video_quality", 8) == 8 end, callback = function() self:setSetting("session_recorder_video_quality", 8) end },
                                    { text = "12", checked_func = function() return self:getSetting("session_recorder_video_quality", 8) == 12 end, callback = function() self:setSetting("session_recorder_video_quality", 12) end },
                                    { text = "16", checked_func = function() return self:getSetting("session_recorder_video_quality", 8) == 16 end, callback = function() self:setSetting("session_recorder_video_quality", 16) end },
                                    { text = "24", checked_func = function() return self:getSetting("session_recorder_video_quality", 8) == 24 end, callback = function() self:setSetting("session_recorder_video_quality", 24) end },
                                },
                                help_text = _("MJPEG quality (2 = best, 31 = worst). Lower values produce larger files."),
                            },
                            {
                                text = _("Include audio in video file"),
                                enabled_func = function()
                                    return false
                                end,
                                checked_func = function()
                                    return self:getSetting("session_recorder_video_include_audio", false)
                                end,
                                callback = function()
                                    self:toggleSetting("session_recorder_video_include_audio", false)
                                end,
                                help_text = _("When enabled, the recorder tries to mux ALSA audio into the video file in real time. This requires a working ALSA capture device and fails on most e-ink devices, so it is disabled."),
                            },
                            {
                                text = _("Save separate audio files"),
                                checked_func = function()
                                    return self:getSetting("session_recorder_save_separate_audio", true)
                                end,
                                callback = function()
                                    self:toggleSetting("session_recorder_save_separate_audio", true)
                                end,
                                help_text = _("When enabled, TTS and playback audio are saved as WAV files in the audio/ folder. When disabled, only the video file is kept."),
                            },
                            {
                                text_func = function()
                                    local max_s = self:getSetting("session_recorder_max_interval_s", 5)
                                    return T(_("Screenshot max interval: %1s"), max_s)
                                end,
                                sub_item_table = {
                                    { text = "5s", checked_func = function() return self:getSetting("session_recorder_max_interval_s", 5) == 5 end, callback = function() self:setSetting("session_recorder_max_interval_s", 5) end },
                                    { text = "10s", checked_func = function() return self:getSetting("session_recorder_max_interval_s", 5) == 10 end, callback = function() self:setSetting("session_recorder_max_interval_s", 10) end },
                                    { text = "30s", checked_func = function() return self:getSetting("session_recorder_max_interval_s", 5) == 30 end, callback = function() self:setSetting("session_recorder_max_interval_s", 30) end },
                                    { text = "60s", checked_func = function() return self:getSetting("session_recorder_max_interval_s", 5) == 60 end, callback = function() self:setSetting("session_recorder_max_interval_s", 60) end },
                                },
                                help_text = _("Maximum time between forced screenshot frames when the screen is static."),
                            },
                        },
                    },
                    {
                        text_func = function()
                            if not self._init_ok or not self.tts_engine or not self.tts_engine._wav_play_bin then
                                return _("Audio output (PocketBook): N/A")
                            end
                            local pb_default = self.tts_engine._pb_has_tts_sm and "tts_sm" or ""
                            local dev = self:getSetting("pb_alsa_device", pb_default)
                            local labels = {
                                ["tts_sm"] = _("PocketBook pipeline"),
                                [""] = _("Auto"),
                            }
                            return T(_("Audio output (PocketBook): %1"), labels[dev] or dev)
                        end,
                        sub_item_table_func = function()
                            return MenuBuilder.buildAlsaDeviceMenu(self)
                        end,
                        enabled_func = function()
                            return (self._init_ok and self.tts_engine and self.tts_engine._wav_play_bin ~= nil) or false
                        end,
                        help_text = _("PocketBook devices route audio through different paths depending on firmware. The default works on most devices. Change this only if you hear no sound, distorted sound, or playback at 2-3x speed (known issue on PB631). Each option in the submenu has its own help text describing what to try."),
                    },
                    {
                        text = _("Allow speaker playback without Bluetooth"),
                        checked_func = function()
                            return self:getSetting("pb_speaker_without_bt", false)
                        end,
                        callback = function()
                            self:toggleSetting("pb_speaker_without_bt", false)
                        end,
                        enabled_func = function()
                            return (self._init_ok and self.tts_engine and self.tts_engine._wav_play_bin ~= nil) or false
                        end,
                        help_text = _("By default, PocketBooks with a Bluetooth adapter only play through Bluetooth audio, because direct hardware access can damage the amplifier. This toggle lifts the Bluetooth requirement ONLY for daemon-routed devices (tts_sm, hwout_mix), which go through the PocketBook audio daemon like the system's own TTS and never touch the hardware directly. Direct-hardware choices (plughw:0) remain blocked without Bluetooth. Use at your own risk."),
                    },
                    {
                        text_func = function()
                            if self.tts_engine and self.tts_engine._android_pcm_auto then
                                return _("Android: persistent audio stream (auto-enabled)")
                            end
                            return _("Android: persistent audio stream")
                        end,
                        checked_func = function()
                            return self:getSetting("android_pcm_stream", false)
                                or (self.tts_engine and self.tts_engine._android_pcm_auto) or false
                        end,
                        callback = function()
                            self:toggleSetting("android_pcm_stream", false)
                        end,
                        enabled_func = function()
                            return (Device.isAndroid and Device:isAndroid()) or false
                        end,
                        help_text = _("Workaround for Android devices where read-aloud audio cuts off mid-sentence and stalls (seen on some MTK e-readers). Plays synthesized audio through one persistent, continuously-fed audio track instead of a fresh media player per sentence, the same way the system's own TTS plays. Off by default; the plugin also switches to it automatically for the rest of the session when it detects a stalled clip. Takes effect from the next sentence."),
                    },
                    {
                        text = _("Keep playing when lid is closed"),
                        checked_func = function()
                            return self:getSetting("keep_playing_on_lid_close", false)
                        end,
                        callback = function()
                            self:toggleSetting("keep_playing_on_lid_close", false)
                        end,
                        help_text = _("When enabled, closing the case/cover will not stop audio playback. When disabled (default), playback pauses on lid close and resumes when reopened. Disabling prevents device crashes caused by audio processes running during hardware suspend."),
                    },
                    {
                        text = _("Hide control bar while playing (experimental)"),
                        enabled_func = function() return (self.ui and self.ui.document) or false end,
                        checked_func = function()
                            return self:getSetting("playback_bar_visibility", "always") == "paused_only"
                        end,
                        callback = function()
                            local cur = self:getSetting("playback_bar_visibility", "always")
                            local new_val = (cur == "paused_only") and "always" or "paused_only"
                            self:setSetting("playback_bar_visibility", new_val)
                            if self.sync_controller and self.sync_controller._applyBarVisibility then
                                self.sync_controller:_applyBarVisibility()
                            end
                        end,
                        help_text = _("Experimental: when enabled, the playback control bar disappears while TTS is playing so the bottom of the page is fully visible for read-along. Pause playback (via tap-to-pause overlay or BT headset button) to bring the bar back."),
                    },
                    {
                        text = _("Hide progress bar during read-along"),
                        checked_func = function()
                            return self:getSetting("hide_tts_progress_bar", false)
                        end,
                        callback = function()
                            self:toggleSetting("hide_tts_progress_bar", false)
                            -- Rebuild the bar so the change is visible right
                            -- away rather than at the next start.
                            local sc = self.sync_controller
                            if sc and sc.playback_bar then
                                sc:showPlaybackBar()
                                if sc.playback_bar and sc.isPlaying then
                                    sc.playback_bar:updatePlayState(sc:isPlaying())
                                end
                            end
                        end,
                        help_text = _("When enabled, the progress bar row is left out of the control bar during TTS read-along, making the bar one row shorter and leaving more of the page visible. The sentence highlight already shows how far along the page you are. The progress bar is always shown for audiobook playback, where it doubles as the seek control."),
                    },
                    {
                        text_func = function()
                            local styles = {
                                background = _("Background"),
                                underline = _("Underline"),
                                box = _("Box"),
                                invert = _("Invert"),
                            }
                            return T(_("Highlight style: %1"), styles[self:getSetting("highlight_style", "background")] or _("Background"))
                        end,
                        enabled_func = function() return (self.ui and self.ui.document) or false end,
                        sub_item_table_func = function()
                            return MenuBuilder.buildHighlightStyleMenu(self)
                        end,
                    },
                    {
                        text = _("Auto-advance pages"),
                        enabled_func = function() return (self.ui and self.ui.document) or false end,
                        checked_func = function()
                            return self:getSetting("auto_advance", true)
                        end,
                        callback = function()
                            self:toggleSetting("auto_advance", true)
                        end,
                    },
                    {
                        text = _("Highlight sentences"),
                        enabled_func = function() return (self.ui and self.ui.document) or false end,
                        checked_func = function()
                            return self:getSetting("highlight_sentences", true)
                        end,
                        callback = function()
                            self:toggleSetting("highlight_sentences", true)
                        end,
                    },
                    {
                        text = _("Follow narration page (aligned)"),
                        enabled_func = function() return (self.ui and self.ui.document) or false end,
                        checked_func = function()
                            return self:getSetting("media_follow_page_turn", true)
                        end,
                        callback = function()
                            self:toggleSetting("media_follow_page_turn", true)
                        end,
                        help_text = _("When enabled (default), the book view auto-turns to keep the current narration sentence on screen while you stay with the read-aloud. Manually turning a page never seeks or restarts audio: highlighting pauses and a “Return to read-aloud” cue appears until you jump back or the narration catches up."),
                    },
                    {
                        text = _("Keep the audiobook bar"),
                        enabled_func = function() return (self.ui and self.ui.document) or false end,
                        checked_func = function()
                            return self:getSetting("keep_media_overlay_bar", false)
                        end,
                        callback = function()
                            self:toggleSetting("keep_media_overlay_bar", false)
                            local now = self:getSetting("keep_media_overlay_bar", false)
                            local ms = self.media_sync
                            if not ms then return end
                            if now then
                                if self:_hasMediaOverlays() then
                                    pcall(function() ms:pinOverlayChrome() end)
                                end
                            else
                                pcall(function()
                                    if ms.playback_bar then
                                        ms.playback_bar:hide()
                                        ms.playback_bar = nil
                                    end
                                    ms:_releaseMiniBarSpace()
                                end)
                            end
                        end,
                        help_text = _("When enabled, the mini audiobook bar stays on screen after you stop narration. When disabled (default), the bar hides when idle."),
                    },
                    {
                        text = _("Lock KOReader page margins"),
                        enabled_func = function()
                            return (self.ui and self.ui.document
                                and self:getSetting("keep_media_overlay_bar", false)) and true or false
                        end,
                        checked_func = function()
                            return self:getSetting("lock_koreader_page_margins", false)
                        end,
                        callback = function()
                            self:toggleSetting("lock_koreader_page_margins", false)
                            local now = self:getSetting("lock_koreader_page_margins", false)
                            local ms = self.media_sync
                            if not ms then return end
                            if now then
                                if self:_hasMediaOverlays() then
                                    pcall(function() ms:pinOverlayChrome() end)
                                end
                            else
                                pcall(function() ms:_releaseMiniBarSpace() end)
                            end
                        end,
                        help_text = _("When enabled, the plugin writes this book’s bottom page margin into KOReader’s own settings before CRE typesets. The next open rebuilds the layout once (text stays above the audiobook bar); after that, KOReader reuses that layout. Disable to restore your original margins and edit them with KOReader’s usual controls."),
                    },
                    {
                        text = _("Keep status bars during read-aloud"),
                        enabled_func = function() return (self.ui and self.ui.document) or false end,
                        checked_func = function()
                            return self:getSetting("keep_reader_status_bars", false)
                        end,
                        callback = function()
                            self:toggleSetting("keep_reader_status_bars", false)
                        end,
                        help_text = _("When enabled, the minimized read-aloud mini player sits above KOReader’s bottom status bar / progress bar (alt status bar at the top is unchanged). The page always reflows so book text ends above the mini player — the player never covers readable text. When disabled (default), the mini player sits at the bottom of the screen (may cover the status bar) but text is still reflowed above it."),
                    },
                    {
                        text = _("Sleep timer"),
                        sub_item_table = {
                            {
                                text = _("Off"),
                                checked_func = function()
                                    return self:getSetting("sleep_timer_minutes", 0) == 0
                                end,
                                callback = function()
                                    self:_cancelSleepTimer()
                                    self:setSetting("sleep_timer_minutes", 0)
                                end,
                            },
                            {
                                text = _("15 min"),
                                checked_func = function()
                                    return self:getSetting("sleep_timer_minutes", 0) == 15
                                end,
                                callback = function()
                                    self:setSetting("sleep_timer_minutes", 15)
                                    self:_startSleepTimer(15)
                                end,
                            },
                            {
                                text = _("30 min"),
                                checked_func = function()
                                    return self:getSetting("sleep_timer_minutes", 0) == 30
                                end,
                                callback = function()
                                    self:setSetting("sleep_timer_minutes", 30)
                                    self:_startSleepTimer(30)
                                end,
                            },
                            {
                                text = _("45 min"),
                                checked_func = function()
                                    return self:getSetting("sleep_timer_minutes", 0) == 45
                                end,
                                callback = function()
                                    self:setSetting("sleep_timer_minutes", 45)
                                    self:_startSleepTimer(45)
                                end,
                            },
                            {
                                text = _("60 min"),
                                checked_func = function()
                                    return self:getSetting("sleep_timer_minutes", 0) == 60
                                end,
                                callback = function()
                                    self:setSetting("sleep_timer_minutes", 60)
                                    self:_startSleepTimer(60)
                                end,
                            },
                            {
                                text = _("1 hour"),
                                checked_func = function()
                                    return self:getSetting("sleep_timer_minutes", 0) == 120
                                end,
                                callback = function()
                                    self:setSetting("sleep_timer_minutes", 120)
                                    self:_startSleepTimer(120)
                                end,
                            },
                            {
                                text = _("2 hours"),
                                checked_func = function()
                                    return self:getSetting("sleep_timer_minutes", 0) == 180
                                end,
                                callback = function()
                                    self:setSetting("sleep_timer_minutes", 180)
                                    self:_startSleepTimer(180)
                                end,
                            },
                            {
                                text = _("3 hours"),
                                checked_func = function()
                                    return self:getSetting("sleep_timer_minutes", 0) == 240
                                end,
                                callback = function()
                                    self:setSetting("sleep_timer_minutes", 240)
                                    self:_startSleepTimer(240)
                                end,
                            },
                            {
                                text = _("Custom..."),
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:_showCustomSleepTimerDialog(touchmenu_instance)
                                end,
                            },
                        },
                        help_text = _("Automatically pause playback after the selected time. Useful for listening before sleep."),
                    },
                    {
                        text = _("Put device to sleep when timer ends"),
                        checked_func = function()
                            return self:getSetting("sleep_timer_suspend_device", false)
                        end,
                        callback = function()
                            self:toggleSetting("sleep_timer_suspend_device", false)
                        end,
                        help_text = _("When enabled, the device will suspend after the sleep timer stops playback."),
                    },
                    {
                        text_func = function()
                            local off = self:getSetting("smil_sync_offset_ms", 0)
                            return T(_("Overlay sync offset: %1 s"), string.format("%+.1f", off / 1000))
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            local SpinWidget = require("ui/widget/spinwidget")
                            local cur = self:getSetting("smil_sync_offset_ms", 0)
                            UIManager:show(SpinWidget:new{
                                title_text = _("Overlay sync offset"),
                                info_text = _("Positive values delay the highlight (use when the highlight runs ahead of the narration); negative values advance it."),
                                value = cur / 1000,
                                value_min = -60,
                                value_max = 60,
                                value_step = 0.5,
                                value_hold_step = 5,
                                precision = "%.1f",
                                ok_text = _("Set"),
                                callback = function(spin)
                                    self:setSetting("smil_sync_offset_ms", math.floor(spin.value * 1000))
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            })
                        end,
                        help_text = _("Shifts EPUB Media Overlay sentence highlighting relative to the audio. Some audiobooks (e.g. with publisher intros) have timing tables offset from the embedded audio."),
                    },
                },
            },
            -- ── Diagnostics ──
            {
                text_func = function()
                    if self.session_recorder and self.session_recorder:isRecording() then
                        return _("Stop session recorder")
                    end
                    return _("Start session recorder")
                end,
                enabled_func = function()
                    return self.session_recorder ~= nil
                end,
                callback = function(touchmenu_instance)
                    if not self.session_recorder then return end
                    if self.session_recorder:isRecording() then
                        self.session_recorder:stop()
                    else
                        self.session_recorder:start()
                    end
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
                help_text = _("Records the current audiobook or TTS session. Audio, video/screenshots, and optional touch events are saved to a folder on device storage."),
            },
            {
                text = _("Generate bug report"),
                callback = function()
                    BugReport.menuCallback(self)
                end,
                help_text = _("Saves a diagnostic report to your device storage. The report contains device model, TTS engine status, and audio configuration — no personal data or book content. Share it when reporting issues on GitHub."),
            },
            {
                text = _("Run device benchmark"),
                callback = function()
                    if not self._init_ok then self:_showInitError(); return end
                    if BenchmarkRunner then
                        BenchmarkRunner.menuCallback(self)
                    end
                end,
                enabled_func = function()
                    return (self.ui and self.ui.document and self._init_ok and BenchmarkRunner ~= nil) or false
                end,
                help_text = _("Runs a standardized TTS benchmark on test sentences using each available engine (espeak-ng, Piper). Saves a report you can share on GitHub to help document device performance. Piper tests may take several minutes on slow devices."),
            },
            {
                text = _("Check for updates"),
                callback = function()
                    if not Updater then
                        -- PLUGIN_PATH already ends with a slash; adding
                        -- another one gives updater.lua a "//" chunk path,
                        -- which breaks its parent-directory derivation.
                        local ok, mod = pcall(dofile, PLUGIN_PATH .. "updater.lua")
                        if not ok then
                            local UIManager = require("ui/uimanager")
                            local InfoMessage = require("ui/widget/infomessage")
                            UIManager:show(InfoMessage:new{
                                text = _("Could not load updater module."),
                            })
                            return
                        end
                        Updater = mod
                    end
                    Updater.checkForUpdate(self)
                end,
                help_text = _("Checks GitHub for a newer release. If an update is available, downloads and installs it. Requires Wi-Fi."),
            },
            {
                text = _("About / Debug info"),
                callback = function()
                    local lines = {}
                    -- Plugin version
                    local ok, meta = pcall(dofile, PLUGIN_PATH .. "_meta.lua")
                    if ok and meta then
                        table.insert(lines, T(_("Plugin: Audiobook Read-Along %1"), meta.version or "unknown"))
                    end
                    -- KOReader version
                    local rev = "unknown"
                    local ok_v, Version = pcall(require, "version")
                    if ok_v and Version and Version.getCurrentRevision then
                        rev = Version:getCurrentRevision() or rev
                    else
                        local rev_file = io.open("git-rev", "r")
                        if rev_file then
                            rev = rev_file:read("*l") or rev
                            rev_file:close()
                        end
                    end
                    table.insert(lines, T(_("KOReader: %1"), rev))
                    -- Device info
                    local model = (Device.getDeviceModel and Device:getDeviceModel())
                        or (Device.model or "unknown")
                    local platform = (Device.getPlatform and Device:getPlatform())
                        or (Device.platform or "unknown")
                    table.insert(lines, T(_("Device: %1 (%2)"), model, platform))
                    -- TTS backend
                    local engine = self.tts_engine
                    if engine then
                        local backend_name = engine.backend or "none"
                        local backend_labels = {
                            espeak = "espeak-ng",
                            piper = "Piper",
                            pico = "Pico",
                            flite = "Flite",
                            festival = "Festival",
                            android = "Android",
                        }
                        table.insert(lines, T(_("TTS backend: %1"), backend_labels[backend_name] or backend_name))
                        -- Audio player
                        -- findAudioPlayer() only runs at first playback, so
                        -- before that the type is unset; on Android the JNI
                        -- bridge alone tells us the player is MediaPlayer.
                        local player = engine.audio_player_type
                            or (engine._android_tts and "android" or "none")
                        table.insert(lines, T(_("Audio player: %1"), player))
                    end
                    -- Plugin directory
                    table.insert(lines, T(_("Plugin path: %1"), PLUGIN_PATH or "unknown"))
                    UIManager:show(InfoMessage:new{
                        text = table.concat(lines, "\n"),
                        timeout = 10,
                    })
                end,
                help_text = _("Shows plugin version, KOReader version, device model, active TTS backend, and audio player. Useful when reporting issues."),
            },
        },
    }
end

--- Legacy hook: dictionary popup "DictButtonsReady" event (KOReader <= 2026.03).
--- KOReader 2026.07 removed the broadcast; _registerDictButtons() covers the
--- new addToDictButtons API instead.  Keep this handler so older releases
--- still get the buttons.
function Audiobook:onDictButtonsReady(dict_popup, buttons)
    if not self._init_ok then return end
    if dict_popup.is_wiki_fullpage then
        return
    end
    
    local plugin = self
    
    -- Add "Read aloud from here" button at the end (below Wikipedia/Search/Close)
    table.insert(buttons, {{
        id = "audiobook_read",
        text = _("Read aloud from here"),
        font_bold = false,
        callback = function()
            local word = dict_popup.word or dict_popup.lookupword
            -- Capture surrounding text context from the highlight selection
            -- so we can find the correct occurrence of the word on the page,
            -- not just the first one.
            local selected_text_context = nil
            if dict_popup.highlight and dict_popup.highlight.selected_text then
                local sel = dict_popup.highlight.selected_text
                -- For CRe docs, pos0 is an xpointer string with an offset;
                -- for paged docs it's a table.  Either way, save the surrounding
                -- selected text or the raw pos0 for position matching.
                selected_text_context = {
                    pos0 = sel.pos0,
                    pos1 = sel.pos1,
                }
            end
            UIManager:close(dict_popup)
            -- Give the dictionary popup and any parent highlight enough time
            -- to fully close and leave the UIManager window stack before we
            -- add the PlaybackBar.  Too short a delay means _isOverlayActive()
            -- still sees stale non-toast widgets and suppresses the bar.
            UIManager:scheduleIn(0.3, function()
                plugin:startReadAlongFromWord(word, selected_text_context)
            end)
        end,
    }})
    table.insert(buttons, {{
        id = "audiobook_play_aligned",
        text = _("Play aligned audiobook from here"),
        font_bold = false,
        callback = function()
            local selected_text = nil
            if dict_popup.highlight and dict_popup.highlight.selected_text then
                selected_text = dict_popup.highlight.selected_text
            end
            UIManager:close(dict_popup)
            UIManager:scheduleIn(0.3, function()
                plugin:startAlignedAudioFromSelection(selected_text)
            end)
        end,
    }})
end

function Audiobook:startReadAlong(text, start_pos)
    if not self._init_ok then self:_showInitError(); return end
    if not self:_audioOutputReady() then return end
    local page_text = text or self:getCurrentPageText()
    if not page_text or page_text == "" then
        UIManager:show(InfoMessage:new{
            text = _("Could not extract text from this page.\n\nThe document format may not be fully supported."),
            timeout = 3,
        })
        return
    end
    
    logger.dbg("Audiobook: Starting read-along with text length:", #page_text)
    
    -- If start position provided, extract text from that point
    if start_pos and start_pos > 1 then
        -- Find the beginning of the sentence containing this word
        local sentence_start = start_pos
        for i = start_pos, 1, -1 do
            local char = page_text:sub(i, i)
            if char:match("[%.%?!]") then
                sentence_start = i + 1
                break
            end
            if i == 1 then
                sentence_start = 1
            end
        end
        
        -- Trim leading whitespace
        while sentence_start <= #page_text and page_text:sub(sentence_start, sentence_start):match("%s") do
            sentence_start = sentence_start + 1
        end
        
        page_text = page_text:sub(sentence_start)
        logger.dbg("Audiobook: Starting from position", sentence_start)
    end
    
    -- Check if TTS engine has a backend
    if not self.tts_engine.backend then
        UIManager:show(InfoMessage:new{
            text = self.tts_engine.backend_error
                or _("No TTS engine found.\n\nPlease install espeak-ng."),
            timeout = 8,
        })
        return
    end

    -- If we're using Bluetooth audio, start a lightweight watcher that
    -- will notify the user if all audio BT devices disconnect while
    -- read-along is active.  This runs infrequently and only while the
    -- plugin is in use to avoid extra battery drain.
    --
    -- Also probe for an audio player now, before synthesis starts, so we
    -- can warn the user immediately if no audio output is available instead
    -- of making them wait through TTS synthesis only to get an error.
    pcall(function()
        if not self.tts_engine.audio_player_type then
            self.tts_engine:findAudioPlayer()
        end
        if self.tts_engine.audio_player_type == "gst-bt" then
            BtUI.startWatcher(self)
            -- Start listening for BT headset media buttons (play/pause/next/prev)
            if self:getSetting("bt_media_control", true) then
                BtMediaControl.start(self)
            end
        end
    end)

    -- v0.1.9.6: Pre-synthesis warning when Piper (or another WAV-producing
    -- backend) is selected on a stripped-GStreamer Kindle.  The fallback to
    -- native Ivona TTS happens automatically, but users should know *before*
    -- synthesis starts so they aren't surprised by the voice change.
    if self.tts_engine._kindle_wav_playback_limited
        and self.tts_engine.backend == self.tts_engine.BACKENDS.PIPER then
        UIManager:show(InfoMessage:new{
            text = _(
                "Piper TTS is selected, but this Kindle model cannot play WAV files.\n\n"
                .. "Audio will use the built-in Kindle voice instead. "
                .. "Word highlighting may be slightly less precise."
            ),
            timeout = 6,
        })
    end

    -- Early no-audio warning: if the probe found no usable audio player
    -- and there is no BT device connected, warn before synthesis runs.
    if self.tts_engine._no_real_audio_output and not self.tts_engine._cached_player then
        if Device.isKindle and Device:isKindle() then
            -- A speakerless Kindle can only play over Bluetooth, routed through
            -- the Amazon audio framework (audiomgrd) or the native Ivona voice.
            -- When no path is found, "Start anyway" would synthesize into a dead
            -- aplay device (pure silence), so show actionable guidance instead of
            -- a misleading Start button.  This matches the runtime refusal in
            -- ttsengine.lua and avoids suggesting the non-existent "native voice"
            -- menu entry (the Ivona path is selected automatically when usable).
            UIManager:show(InfoMessage:new{
                text = _("No audio output available.\n\nThis Kindle has no built-in speaker, so audio must play over Bluetooth, and the plugin could not find a working audio route.\n\nTry this:\n1. Pair and connect Bluetooth headphones from the Kindle top-swipe menu (Settings), then start read-along again.\n2. If they are already connected, restart KOReader so the plugin re-detects the audio output.\n\nIf it still fails, generate a bug report (Audiobook > Generate bug report) and share it on the GitHub issue."),
                timeout = 12,
            })
            return
        end
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = _("No audio output device found.\n\nTTS synthesis will run but audio may not play. Start anyway?"),
            ok_text = _("Start"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                pcall(function() BtMediaControl.sendPlaybackStatus("playing") end)
                if self.media_sync then
                    pcall(function()
                        self.media_sync:stop(nil, { drop_chrome = true })
                    end)
                end
                self.sync_controller:start(page_text)
            end,
        })
        return
    end

    -- Notify BT device that playback is starting
    pcall(function() BtMediaControl.sendPlaybackStatus("playing") end)

    -- Built-in audiobook chrome (mini bar) must not stay on screen: the TTS
    -- sync loop treats extra window-stack widgets as a menu and auto-pauses
    -- forever (UI appears frozen).
    if self.media_sync then
        pcall(function()
            self.media_sync:stop(nil, { drop_chrome = true })
        end)
    end

    self.sync_controller:start(page_text)
end

-- ---------------------------------------------------------------------------
-- Media playback functions (audio files & EPUB Media Overlays)
-- ---------------------------------------------------------------------------

function Audiobook:_documentHasMediaOverlays(doc_path)
    if not doc_path then return false end
    local ext = doc_path:match("%.([^.]+)$") or ""
    if ext:lower() ~= "epub" then return false end
    -- Quick zip listing check for .smil files
    local h = io.popen('unzip -l "' .. doc_path:gsub('"', '\\"') .. '" 2>/dev/null | grep -i "\\.smil"')
    if h then
        local out = h:read("*a") or ""
        h:close()
        if out:match("%.smil") then
            return true
        end
    end
    return false
end

function Audiobook:_hasMediaOverlays()
    if not self.ui or not self.ui.document then return false end
    if not self.ui.rolling then return false end
    local doc_path = self.ui.document.file_path or self.ui.document.file
    return self:_documentHasMediaOverlays(doc_path)
end

--- On Kindle there is no speaker/ALSA: audio only plays over Bluetooth A2DP.
--- Returns true if playback can proceed; otherwise prompts and returns false.
--- Non-Kindle devices always pass (their audio paths differ).
function Audiobook:_audioOutputReady()
    if not (Device.isKindle and Device:isKindle()) then return true end
    local connected = false
    local h = io.popen("lipc-get-prop com.lab126.audiomgrd audioOutputConnected 2>/dev/null")
    if h then
        local out = h:read("*a") or ""
        h:close()
        connected = tonumber(out:match("(%d+)")) == 1
    end
    if not connected then
        -- Nudge the Kindle BT stack to (re)connect the last-used device
        -- (KinAMP trick), then ask the user to retry once it is up.
        os.execute("lipc-set-prop com.lab126.btfd ensureBTconnection 1 2>/dev/null")
        os.execute("lipc-set-prop com.lab126.btfd BTenable '1:1' 2>/dev/null")
        UIManager:show(InfoMessage:new{
            text = _("No Bluetooth audio device connected.\n\nReconnecting your headphones\226\128\166 once connected, try again."),
            timeout = 5,
        })
        return false
    end
    return true
end

function Audiobook:startMediaPlayback()
    if not self._init_ok or not self.media_sync then
        self:_showInitError()
        return
    end
    if not self:_audioOutputReady() then return end

    local doc_path = self.ui and self.ui.document and (self.ui.document.file_path or self.ui.document.file)
    if doc_path then
        -- Reader mode: keep existing auto-detection behavior.
        self:_startMediaPlaybackForDocument(doc_path)
        return
    end

    -- FileManager / browser mode
    if self:_isFileManager() then
        self:_startAlignedPlaybackFromFileManager(self.ui)
        return
    end

    UIManager:show(InfoMessage:new{
        text = _("No document is currently open."),
        timeout = 3,
    })
end

function Audiobook:_startMediaPlaybackForDocument(doc_path)
    -- Try SMIL Media Overlays first
    if self:_hasMediaOverlays() then
        self:_startSmilPlayback(doc_path, nil, true)
        return
    end

    -- No SMIL: try to auto-detect a matching audiobook file
    local matching_audio = self:_findMatchingAudiobook(doc_path)
    if matching_audio then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = T(_("No embedded narration found for this book.\n\nFound matching audiobook:\n%1\n\nPlay it?"), matching_audio:match("([^/]+)$") or matching_audio),
            ok_text = _("Play"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                self:_playAudioFile(matching_audio)
            end,
        })
        return
    end

    -- Nothing found
    UIManager:show(InfoMessage:new{
        text = _("This book has no embedded narration.\n\nPlace an audiobook file with the same name in the same folder, or use Play unaligned audiobook to play a separate file."),
        timeout = 5,
    })
end

function Audiobook:_isFileManager()
    return self.ui and self.ui.file_chooser and not self.ui.document
end

function Audiobook:_getFileManagerSelectedFile(file_manager)
    local ok, selected = pcall(function()
        if file_manager.file_chooser and file_manager.file_chooser.getSelectedFile then
            return file_manager.file_chooser:getSelectedFile()
        end
        if file_manager.file_chooser and file_manager.file_chooser.selected then
            local sel = file_manager.file_chooser.selected
            if type(sel) == "table" then
                return sel[1] or sel.path
            end
            return sel
        end
        return nil
    end)
    if ok then return selected end
    return nil
end

function Audiobook:_isBookFile(path)
    local ext = (path:match("%.([^.]+)$") or ""):lower()
    local book_exts = {
        epub = true, mobi = true, azw = true, azw3 = true, prc = true,
        fb2 = true, pdf = true, djvu = true, cbz = true, cbr = true,
        cbt = true, txt = true, html = true, htm = true, xhtml = true,
        rtf = true, doc = true, docx = true,
    }
    return book_exts[ext] == true
end

function Audiobook:_startAlignedPlaybackFromFileManager(file_manager)
    local selected = self:_getFileManagerSelectedFile(file_manager)
    if selected then
        self:_startAlignedPlaybackFromBrowserPath(file_manager, selected)
        return
    end

    -- No file selected: ask the user to pick one.
    local PathChooser = require("ui/widget/pathchooser")
    local home_dir = require("datastorage").getDataDir() or "/mnt"
    UIManager:show(PathChooser:new{
        title = _("Select a book"),
        path = home_dir,
        select_file = true,
        onConfirm = function(file_path)
            self:_startAlignedPlaybackFromBrowserPath(file_manager, file_path)
        end,
    })
end

function Audiobook:_startAlignedPlaybackFromBrowserPath(file_manager, path)
    if not path then return end
    local ext = (path:match("%.([^.]+)$") or ""):lower()

    if not self:_isBookFile(path) then
        UIManager:show(InfoMessage:new{
            text = T(_("Unsupported file type for aligned audiobook: %1"), ext),
            timeout = 4,
        })
        return
    end

    -- Check for SMIL overlays before opening the book so we can decide
    -- cleanly whether to start playback or show the missing-metadata warning
    -- once ReaderUI loads.
    local has_overlays = (ext == "epub") and self:_documentHasMediaOverlays(path)

    -- Open the book. The FileManager plugin instance is about to be torn
    -- down and replaced by a ReaderUI plugin instance, so we cannot poll
    -- self:_hasMediaOverlays() here. Store a pending request and let the
    -- ReaderUI instance handle it after its document loads.
    local ok, err = pcall(function()
        file_manager:openFile(path)
    end)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Could not open the book: %1"), tostring(err)),
            timeout = 4,
        })
        return
    end

    Audiobook._pending_aligned_start = {
        path = path,
        action = has_overlays and "start" or "warn",
    }
end

function Audiobook:_checkPendingAlignedStart()
    local pending = Audiobook._pending_aligned_start
    if not pending then return end
    if not self._init_ok or not self.media_sync then return end
    if not self.ui or not self.ui.document then return end

    local doc_path = self.ui.document.file_path or self.ui.document.file
    if not doc_path or doc_path ~= pending.path then return end

    Audiobook._pending_aligned_start = nil
    UIManager:scheduleIn(0.5, function()
        if pending.action == "start" then
            self:_startMediaPlaybackForDocument(doc_path)
        else
            UIManager:show(InfoMessage:new{
                text = _("This book does not contain embedded narration/alignment metadata. Use Play unaligned audiobook or Start music playlist to play a separate audio file."),
                timeout = 6,
            })
        end
    end)
end

function Audiobook:addToFileManager(file_manager, menu_items)
    if not menu_items.audiobook_browser then
        menu_items.audiobook_browser = {
            text = _("Play aligned/enriched audiobook"),
            enabled_func = function()
                return (self._init_ok and self.media_sync ~= nil) or false
            end,
            callback = function()
                self:_startAlignedPlaybackFromFileManager(file_manager)
            end,
        }
    end
end

function Audiobook:onShowFileDialog(file_manager, file)
    local ok = pcall(function()
        local dialog = file_manager.file_dialog or file_manager.dialog
        local buttons = dialog and dialog.buttons
        if not buttons then return end
        table.insert(buttons, {{
            id = "audiobook_aligned_browser",
            text = _("Play aligned/enriched audiobook"),
            callback = function()
                UIManager:close(dialog)
                self:_startAlignedPlaybackFromBrowserPath(file_manager, file)
            end,
        }})
    end)
    if not ok then
        logger.warn("Audiobook: failed to add browser aligned-audiobook button")
    end
end

--- @param opts table|nil  { prepare_only = true } arms the overlay (bar, SMIL,
--- saved position) without starting audio; Play continues from the mark.
function Audiobook:_startSmilPlayback(doc_path, start_entry, allow_resume, opts)
    opts = opts or {}
    allow_resume = (allow_resume == true)

    -- Reuse a just-loaded cache (e.g. "Play aligned from here") so we don't
    -- re-parse the whole EPUB and invalidate start_entry.audio_path keys.
    -- Drop the in-memory cache when the EPUB was replaced in-place (Storyteller
    -- re-export keeps the same path but changes size/mtime).
    local function epub_fp(path)
        local ok, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok and lfs and lfs.attributes then
            local attr = lfs.attributes(path)
            if attr and attr.size and attr.modification then
                return string.format("%d:%d", attr.size, attr.modification)
            end
        end
        return nil
    end
    local cur_fp = epub_fp(doc_path)
    if self._smil_doc_path == doc_path and cur_fp and self._smil_epub_fp
        and self._smil_epub_fp ~= cur_fp then
        logger.warn("Audiobook: EPUB replaced on disk — clearing SMIL memory cache")
        self._smil_parser = nil
        self._smil_timing_data = nil
        self._smil_by_file = nil
        self._smil_page_index = nil
    end

    local parser = self._smil_parser
    local timing_data = self._smil_timing_data
    if not (parser and timing_data and self._smil_doc_path == doc_path) then
        local ok, EpubMediaOverlay = pcall(dofile, PLUGIN_PATH .. "epubmediaoverlay.lua")
        if not ok or not EpubMediaOverlay then
            UIManager:show(InfoMessage:new{
                text = _("Failed to load EPUB Media Overlay parser."),
                timeout = 3,
            })
            return
        end

        local loading_msg = InfoMessage:new{
            text = _("Loading Media Overlays..."),
            timeout = 3600,
        }
        UIManager:show(loading_msg)
        UIManager:forceRePaint()

        parser = EpubMediaOverlay:new()
        local plugin_dir = PLUGIN_PATH:sub(1, -2)
        local err
        timing_data, err = parser:loadFromEpub(doc_path, plugin_dir, function(prog)
            if not prog then return end
            if prog.phase == "smil" and prog.total then
                local name = prog.detail and tostring(prog.detail):match("([^/]+)$") or ""
                loading_msg.text = T(_("Parsing overlays: %1 / %2\n%3"),
                    prog.current, prog.total, name)
            elseif prog.phase == "done" then
                loading_msg.text = T(_("Loaded %1 timing entries"), prog.current)
            end
            -- forceRePaint so e-ink shows live progress during the blocking parse.
            UIManager:setDirty(loading_msg, function()
                return "ui", loading_msg.dimen
            end)
            UIManager:forceRePaint()
        end)

        UIManager:close(loading_msg)
        UIManager:forceRePaint()

        if not timing_data then
            UIManager:show(InfoMessage:new{
                text = _("No Media Overlays found: ") .. tostring(err),
                timeout = 4,
            })
            return
        end
    end

    -- Group timing entries by audio file
    -- Clip times restart at zero for every audio file, so each file plays
    -- with its own timing slice; the playlist mechanism chains the files
    -- and _playAudioFile installs the matching slice on every switch.
    local files, by_file = {}, {}
    for _, entry in ipairs(timing_data) do
        local p = entry.audio_path
        if p then
            if not by_file[p] then
                by_file[p] = { timing = {}, chapters = {} }
                table.insert(files, p)
            end
            table.insert(by_file[p].timing, entry)
        end
    end

    if #files == 0 then
        UIManager:show(InfoMessage:new{
            text = _("Could not extract audio from EPUB."),
            timeout = 3,
        })
        return
    end

    -- Chapters: a boundary wherever the source content document changes,
    -- titled from the NCX when available.
    local titles = parser._chapter_titles or {}
    for _, p in ipairs(files) do
        local slot = by_file[p]
        local last_doc = nil
        for _, e in ipairs(slot.timing) do
            if e.text_doc and e.text_doc ~= last_doc then
                last_doc = e.text_doc
                local base = e.text_doc:match("([^/]+)$") or e.text_doc
                table.insert(slot.chapters, {
                    title = titles[base] or base,
                    start_time = e.start_time,
                    fragment_id = e.fragment_id,
                    text_doc = e.text_doc,
                })
            end
        end
    end

    local playlist = {}
    for _, p in ipairs(files) do
        local slot = by_file[p]
        local nm = (slot.chapters[1] and slot.chapters[1].title)
            or p:match("([^/]+)$") or p
        table.insert(playlist, { name = nm, path = p })
    end

    -- Flat chapter list for the Chapters menu / scrubber.  One row per
    -- (audio_file × content-doc boundary).  The UI dedupes by text_doc so a
    -- chapter that spans many ~4 min MP4 parts appears once with its full duration.
    self._smil_overlay_chapters = {}
    for _, p in ipairs(files) do
        for _, ch in ipairs(by_file[p].chapters) do
            table.insert(self._smil_overlay_chapters, {
                title = ch.title,
                start_time = ch.start_time,
                audio_path = p,
                fragment_id = ch.fragment_id,
                text_doc = ch.text_doc,
            })
        end
    end

    local unique_n = 0
    do
        local seen = {}
        for _, ch in ipairs(self._smil_overlay_chapters) do
            local key = ch.text_doc or ch.title
            if key and not seen[key] then
                seen[key] = true
                unique_n = unique_n + 1
            end
        end
    end

    UIManager:show(InfoMessage:new{
        text = T(_("%1 sentences · %2 chapters · %3 audio parts"),
            #timing_data, unique_n, #files),
        timeout = 3,
    })

    -- Common startup logic used both for direct starts and after the resume prompt.
    local function do_start(chosen_entry)
        -- Start from the reader's current position, unless a specific entry was
        -- requested (e.g., "Play aligned audiobook from here").
        local start_file, start_time
        if chosen_entry and chosen_entry.audio_path then
            start_file = chosen_entry.audio_path
            start_time = chosen_entry.start_time
            -- Make "Continue listening" pick up a "Play from here" start so
            -- the two entry points stay in sync.
            local chapter_title
            local base = chosen_entry.text_doc and chosen_entry.text_doc:match("([^/]+)$")
            if base and parser._chapter_titles then
                chapter_title = parser._chapter_titles[base]
            end
            self:_saveAlignedPosition(doc_path, chosen_entry.audio_path, chosen_entry.start_time, chapter_title)
        else
            -- Map the current crengine DocFragment index through the spine to a
            -- content document, then to that document's first timing entry
            -- (scanning forward past front matter that has no narration).
            local cur_xp = self.ui and self.ui.document
                and self.ui.document:getXPointer()
            local frag_idx = cur_xp and tonumber(cur_xp:match("DocFragment%[(%d+)%]"))
            local spine = parser._spine_hrefs or {}
            if frag_idx and spine[frag_idx] then
                for si = frag_idx, #spine do
                    local base = spine[si]
                    for _, e in ipairs(timing_data) do
                        if e.audio_path and e.text_doc
                            and (e.text_doc:match("([^/]+)$") == base) then
                            start_file, start_time = e.audio_path, e.start_time
                            break
                        end
                    end
                    if start_file then break end
                end
            end
            logger.warn("Audiobook: SMIL start-position cur_xp=", tostring(cur_xp),
                "frag_idx=", frag_idx, "#spine=", #spine,
                "start_file=", start_file and start_file:match("([^/]+)$") or "nil",
                "start_time=", start_time)
        end

        if not opts.prepare_only then
            pcall(function() self:_ensureBtMediaControl() end)
        end

        -- Cache parser/timing for page-follow and selection restarts.
        -- If we are switching to a different EPUB, drop the resolved-xpointer
        -- cache we built for the previous book.
        if self._smil_doc_path and self._smil_doc_path ~= doc_path and self.media_sync then
            self.media_sync._xpointer_cache = {}
        end
        self._smil_parser = parser
        self._smil_timing_data = timing_data
        self._smil_by_file = by_file
        self._smil_page_index = nil
        self._smil_doc_path = doc_path
        self._smil_epub_fp = cur_fp or epub_fp(doc_path)
        local first = start_file or files[1]
        -- Guard against a saved resume audio_path that no longer matches the
        -- parsed timing data (e.g., path normalization differences).
        if first and not by_file[first] then
            first = files[1]
        end
        -- If a specific start entry was requested, resume playback directly at
        -- that time instead of starting at 0:00 and seeking after a delay.
        local start_position = nil
        if start_time then
            start_position = start_time
        end
        -- Suppress page-crawl auto-follow until we have jumped to the target
        -- sentence.  Without this, a late seek / failed #id scroll triggers
        -- GotoViewRel(1) on every sentence and freezes the Kindle touch UI.
        if Time then
            self._suppress_media_sync_auto_page_follow = Time.now() + Time.s(4.0)
        end

        local started = self.media_sync:start(first, by_file[first].timing,
            by_file[first].chapters, nil, playlist, first, start_position, opts)
        if started and start_position then
            logger.warn("Audiobook: SMIL", opts.prepare_only and "prepared" or "playback started",
                "at", start_position, "for", first:match("([^/]+)$"))
        end
        -- Jump the book view straight to the chosen SMIL entry (by fragment),
        -- not a page-by-page crawl and not a fragile start_time lookup.
        if started and self.media_sync.overlay_mode then
            logger.warn("Audiobook: navigating view to entry",
                chosen_entry and chosen_entry.fragment_id, "t=", start_position)
            local ok_nav, nav_err = pcall(function()
                if chosen_entry and chosen_entry.fragment_id then
                    self.media_sync:navigateToSentenceEntry(chosen_entry)
                else
                    self.media_sync:navigateToSentenceAtTime(start_position or 0)
                end
            end)
            if not ok_nav then
                logger.warn("Audiobook: navigate to entry error:", nav_err)
            end
            if opts.prepare_only then
                pcall(function() self.media_sync:_refreshPlaybackTimeUi() end)
            end
            -- Extra seek after start: some Kindle backends ignore #t= on the
            -- first play(); seekToTime restarts at the correct clip time.
            -- Skip when MediaEngine already started at start_position — a
            -- redundant seek-by-restart kills A2DP (AirPods: brief sound then silence).
            -- Skip entirely when we only armed the overlay (no audio yet).
            if not opts.prepare_only
                and start_position and start_position > 0 and self.media_sync.seekToTime then
                UIManager:scheduleIn(0.8, function()
                    pcall(function()
                        if not self.media_sync or not self.media_sync.media_engine then return end
                        local eng = self.media_sync.media_engine
                        if not eng.is_playing or eng.is_paused then return end
                        local pos = eng:getPosition() or 0
                        local started_at = eng._seek_offset or 0
                        if math.abs(pos - start_position) < 1.0
                            or math.abs(started_at - start_position) < 0.25 then
                            logger.warn("Audiobook: skip post-start seek (already near",
                                start_position, "pos=", pos, "seek_offset=", started_at, ")")
                            return
                        end
                        self.media_sync:seekToTime(start_position)
                    end)
                end)
            end
            if Time then
                self._suppress_media_sync_auto_page_follow = Time.now() + Time.s(2.0)
            end
            self:_hideReturnToReadAloudButton()
        end
    end

    if opts.prepare_only then
        -- Arming the pinned bar on book open: resume the saved mark silently
        -- (no prompt, no audio); Play continues from there.
        if allow_resume and not (start_entry and start_entry.audio_path) then
            local saved_pos = self:_getSavedAlignedPosition(doc_path)
            if saved_pos and saved_pos > 10 then
                start_entry = self:_resumeEntryFromSave(doc_path, timing_data, by_file)
            end
        end
        if not (start_entry and start_entry.audio_path) then
            pcall(function() self.media_sync:pinOverlayChrome() end)
            return
        end
        do_start(start_entry)
        return
    end

    -- When invoked from the main menu, offer to resume from the last saved position.
    if allow_resume then
        self:_promptResumeAlignedPlayback(doc_path, timing_data, start_entry, function(chosen_entry)
            do_start(chosen_entry)
        end)
    else
        do_start(start_entry)
    end
end

function Audiobook:_findMatchingAudiobook(doc_path)
    if not doc_path then return nil end
    local folder = doc_path:match("^(.*)/[^/]+$") or "."
    local basename = doc_path:match("([^/]+)%.[^./]+$") or ""
    if basename == "" then return nil end

    local audio_exts = { "m4b", "mp3", "m4a", "ogg", "opus", "flac", "wav" }
    for _, ext in ipairs(audio_exts) do
        local candidate = folder .. "/" .. basename .. "." .. ext
        local f = io.open(candidate, "r")
        if f then
            f:close()
            return candidate
        end
    end
    return nil
end

function Audiobook:openAudioFile()
    if not self._init_ok or not self.media_sync then
        self:_showInitError()
        return
    end
    if not self:_audioOutputReady() then return end
    local PathChooser = require("ui/widget/pathchooser")
    local home_dir = require("datastorage").getDataDir() or "/mnt"
    UIManager:show(PathChooser:new{
        title = _("Select audio file"),
        path = home_dir,
        select_file = true,
        onConfirm = function(file_path)
            self:_playAudioFile(file_path)
        end,
    })
end

--- Show audio files in a folder as a playable playlist.
--- Pick an audio file via PathChooser, then immediately play it
-- along with all other audio files in the same folder as a playlist.
function Audiobook:openMusicPlaylist()
    if not self._init_ok or not self.media_sync then
        self:_showInitError()
        return
    end
    if not self:_audioOutputReady() then return end
    local PathChooser = require("ui/widget/pathchooser")
    local home_dir = require("datastorage").getDataDir() or "/mnt"
    UIManager:show(PathChooser:new{
        title = _("Select audio file"),
        path = home_dir,
        select_file = true,
        onConfirm = function(file_path)
            local folder = file_path:match("^(.*)/[^/]+$")
            if not folder then return end
            self:setSetting("playlist_last_folder", folder)

            local lfs = require("libs/libkoreader-lfs")
            local files = {}
            for entry in lfs.dir(folder) do
                if entry ~= "." and entry ~= ".." then
                    local full = folder .. "/" .. entry
                    local attr = lfs.attributes(full)
                    if attr and attr.mode == "file" then
                        local ext = entry:match("%.([^.]+)$") or ""
                        ext = ext:lower()
                        local audio_exts = {
                            mp3 = true, m4a = true, m4b = true,
                            ogg = true, opus = true, flac = true,
                            wav = true, aac = true, wma = true,
                        }
                        if audio_exts[ext] then
                            table.insert(files, {
                                name = entry,
                                path = full,
                            })
                        end
                    end
                end
            end

            table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)

            if #files == 0 then
                UIManager:show(InfoMessage:new{
                    text = T(_("No audio files found in\n%1"), folder),
                    timeout = 3,
                })
                return
            end

            self:_playAudioFile(file_path, files)
        end,
    })
end

function Audiobook:_playAudioFile(file_path, playlist_files)
    if not file_path or not self.media_sync then return end

    -- EPUB Media Overlay playlist transition: install this file's timing
    -- slice and chapters directly, skipping the resume prompt so chained
    -- chapter files flow without interruption.
    if self._smil_by_file and self._smil_by_file[file_path] then
        local slot = self._smil_by_file[file_path]
        self.media_sync:start(file_path, slot.timing, slot.chapters, nil,
            playlist_files or self.media_sync.playlist_files, file_path)
        pcall(function() self:_ensureBtMediaControl() end)
        return
    end

    -- Check for saved position and prompt to resume
    local saved_pos, saved_time = self:_getSavedPosition(file_path)
    if saved_pos and saved_pos > 30 then
        local ConfirmBox = require("ui/widget/confirmbox")
        local book_title = file_path:match("([^/]+)%.[^./]+$") or file_path:match("([^/]+)$") or _("Unknown book")
        local chapters = {}
        local ok_mp, MetadataParser = pcall(dofile, PLUGIN_PATH .. "m4bparser.lua")
        if ok_mp and MetadataParser then
            local parser = MetadataParser:new{plugin_dir = PLUGIN_PATH}
            local parsed = parser:parse(file_path)
            if parsed then chapters = parsed end
        end
        local chapter_title = self:_findChapterTitle(chapters, saved_pos)
        local lines = {
            T(_("Resume from %1?"), self:_formatAudioTime(saved_pos)),
            "",
            T(_("Book: %1"), book_title),
        }
        if chapter_title then
            table.insert(lines, T(_("Chapter: %1"), chapter_title))
        end
        table.insert(lines, "")
        table.insert(lines, T(_("Last played: %1"), os.date("%Y-%m-%d %H:%M", saved_time)))
        UIManager:show(ConfirmBox:new{
            text = table.concat(lines, "\n"),
            ok_text = _("Resume"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                self:_doPlayAudioFile(file_path, playlist_files, saved_pos)
            end,
            cancel_callback = function() end,
            other_buttons = {{
                {
                    text = _("From start"),
                    callback = function()
                        self:_clearPosition(file_path)
                        self:_doPlayAudioFile(file_path, playlist_files, 0)
                    end,
                },
            }},
        })
        return
    end

    self:_doPlayAudioFile(file_path, playlist_files, 0)
end

function Audiobook:_doPlayAudioFile(file_path, playlist_files, start_position, abs_item_id, abs_item_metadata)
    if not file_path or not self.media_sync then return end
    local playable_path = file_path

    -- Transcode unsupported formats (M4B, OGG, FLAC, etc.) to MP3.
    -- The transcoded MP3 preserves chapters and cover art.
    if self.transcoder and not self.transcoder:isPlayable(file_path) then
        local cached = self.transcoder:getPlayablePath(file_path)
        if cached then
            playable_path = cached
            logger.warn("Audiobook: using cached transcode", cached)
        else
            local InfoMessage = require("ui/widget/infomessage")
            local busy = InfoMessage:new{
                text = _("Transcoding to MP3...\nThis may take a minute."),
                timeout = 0,
            }
            UIManager:show(busy)
            UIManager:forceRePaint()

            local ok_trans, trans_path_or_err = pcall(function()
                return self.transcoder:transcode(file_path)
            end)

            UIManager:close(busy)
            UIManager:forceRePaint()

            if ok_trans and trans_path_or_err then
                playable_path = trans_path_or_err
                logger.warn("Audiobook: transcoded to", playable_path)
            else
                local err_msg = type(trans_path_or_err) == "string" and trans_path_or_err or "unknown error"
                logger.err("Audiobook: transcoding failed:", err_msg)
                UIManager:show(InfoMessage:new{
                    text = _("Transcoding failed: ") .. err_msg,
                    timeout = 3,
                })
                return
            end
        end
    end

    -- Probe duration and chapters from the playable file (original MP3 or transcoded)
    local duration = self.media_engine:probeDuration(playable_path)
    local chapters = {}
    local cover_path = nil
    logger.warn("Audiobook: loading parser for", playable_path)
    local ok, MetadataParser = pcall(dofile, PLUGIN_PATH .. "m4bparser.lua")
    if ok and MetadataParser then
        logger.warn("Audiobook: parser loaded, creating instance")
        local parser = MetadataParser:new{plugin_dir = PLUGIN_PATH}
        chapters = parser:parse(playable_path)
        cover_path = parser:extractCoverArt(playable_path, PLUGIN_PATH)
        logger.warn("Audiobook: parser returned", chapters and #chapters or "nil", "chapters, cover=", cover_path)
    else
        logger.warn("Audiobook: parser load FAILED:", ok, MetadataParser)
    end

    -- If this is an ABS item, use ABS metadata when local extraction fails
    if abs_item_id and abs_item_metadata then
        if (not chapters or #chapters == 0) and abs_item_metadata.chapters then
            chapters = abs_item_metadata.chapters
            logger.warn("Audiobook: using ABS chapters for", abs_item_id, "(" .. #chapters .. " chapters)")
        end
        if not cover_path and abs_item_metadata.cover_path then
            local cf = io.open(abs_item_metadata.cover_path, "r")
            if cf then
                cf:close()
                cover_path = abs_item_metadata.cover_path
            end
        end
        -- Store ABS tracking on media_sync
        self.media_sync._abs_item_id = abs_item_id
        self.media_sync._abs_duration = duration or abs_item_metadata.duration or 0
    else
        -- Clear ABS tracking for non-ABS playback
        self.media_sync._abs_item_id = nil
        self.media_sync._abs_duration = nil
    end

    -- For standalone audio without text alignment, we create a single
    -- synthetic timing entry covering the whole file.
    -- Use ABS metadata duration when ffprobe fails (common on Kobo).
    local known_duration = duration
    if not known_duration and abs_item_metadata and abs_item_metadata.duration then
        known_duration = abs_item_metadata.duration
    end
    local timing_data = {{
        start_time = 0,
        end_time = known_duration or 3600,
        text = _("Audio playback"),
    }}
    self.media_sync:start(playable_path, timing_data, chapters, cover_path, playlist_files, file_path, start_position)

    -- Start BT media button listener if enabled
    pcall(function()
        if self:getSetting("bt_media_control", true) and BtMediaControl then
            BtMediaControl.start(self)
        end
    end)
end

function Audiobook:_formatAudioTime(seconds)
    seconds = math.floor(seconds or 0)
    local mins = math.floor(seconds / 60)
    local secs = seconds % 60
    if mins >= 60 then
        local hours = math.floor(mins / 60)
        mins = mins % 60
        return string.format("%d:%02d:%02d", hours, mins, secs)
    end
    return string.format("%d:%02d", mins, secs)
end

function Audiobook:_findChapterTitle(chapters, position)
    if not chapters or #chapters == 0 or not position then
        return nil
    end
    local title = nil
    for _, ch in ipairs(chapters) do
        if ch.start_time and position >= ch.start_time then
            title = ch.title or title
        else
            break
        end
    end
    return title
end

-- ---------------------------------------------------------------------------
-- Playback position persistence
-- ---------------------------------------------------------------------------

function Audiobook:_getAudioPositionKey(file_path)
    -- Use a simple hash of the path as the key to avoid special chars
    local hash = 5381
    for i = 1, #file_path do
        hash = ((hash * 32) + hash) + file_path:byte(i)
        hash = hash % 4294967296
    end
    return string.format("pos_%08x", hash)
end

function Audiobook:_getSavedPosition(file_path)
    local positions = self:getSetting("audio_positions", {})
    local key = self:_getAudioPositionKey(file_path)
    local entry = positions[key]
    if entry and entry.path == file_path then
        return entry.position, entry.timestamp
    end
    return nil, nil
end

function Audiobook:_savePosition(file_path, position)
    if not file_path or not position then return end
    local positions = self:getSetting("audio_positions", {})
    local key = self:_getAudioPositionKey(file_path)
    positions[key] = {
        path = file_path,
        position = position,
        timestamp = os.time(),
    }
    -- Prune old entries (keep last 50)
    local count = 0
    for _ in pairs(positions) do count = count + 1 end
    if count > 50 then
        local oldest_key, oldest_time = nil, math.huge
        for k, v in pairs(positions) do
            if v.timestamp and v.timestamp < oldest_time then
                oldest_time = v.timestamp
                oldest_key = k
            end
        end
        if oldest_key then positions[oldest_key] = nil end
    end
    self:setSetting("audio_positions", positions)
end

function Audiobook:_clearPosition(file_path)
    if not file_path then return end
    local positions = self:getSetting("audio_positions", {})
    local key = self:_getAudioPositionKey(file_path)
    positions[key] = nil
    self:setSetting("audio_positions", positions)
end

function Audiobook:_clearAlignedPosition(doc_path)
    if not doc_path then return end
    local positions = self:getSetting("aligned_positions", {})
    local key = self:_getAudioPositionKey(doc_path)
    positions[key] = nil
    self:setSetting("aligned_positions", positions)
end

function Audiobook:_getSavedAlignedPosition(doc_path)
    if not doc_path then return nil, nil, nil, nil, nil, nil end
    local positions = self:getSetting("aligned_positions", {})
    local key = self:_getAudioPositionKey(doc_path)
    local entry = positions[key]
    if entry and entry.path == doc_path then
        return entry.position, entry.timestamp, entry.audio_path, entry.chapter_title,
            entry.fragment_id, entry.text_doc
    end
    return nil, nil, nil, nil, nil, nil
end

function Audiobook:_saveAlignedPosition(doc_path, audio_path, position, chapter_title, fragment_id, text_doc)
    if not doc_path or not audio_path then return end
    position = tonumber(position)
    if not position or position < 0 then return end
    local positions = self:getSetting("aligned_positions", {})
    local key = self:_getAudioPositionKey(doc_path)
    positions[key] = {
        path = doc_path,
        audio_path = audio_path,
        position = position,
        chapter_title = chapter_title,
        fragment_id = fragment_id,
        text_doc = text_doc,
        timestamp = os.time(),
    }
    -- Prune old entries (keep last 50)
    local count = 0
    for _ in pairs(positions) do count = count + 1 end
    if count > 50 then
        local oldest_key, oldest_time = nil, math.huge
        for k, v in pairs(positions) do
            if v.timestamp and v.timestamp < oldest_time then
                oldest_time = v.timestamp
                oldest_key = k
            end
        end
        if oldest_key then positions[oldest_key] = nil end
    end
    self:setSetting("aligned_positions", positions)
end

--- Snapshot the current overlay sentence so the next open can restore it
--- without a resume dialog.
function Audiobook:_saveCurrentAlignedProgress(pos)
    local ms = self.media_sync
    if not ms or not ms.overlay_mode then return end
    local eng = ms.media_engine
    if not eng then return end
    local path = eng.current_path
    if not path then return end
    if pos == nil then
        local ok_pos, p = pcall(function() return eng:getPosition() end)
        pos = (ok_pos and p) or eng._paused_position or eng._seek_offset or 0
    end
    pos = tonumber(pos) or 0
    local doc_path = (self.ui and self.ui.document
        and (self.ui.document.file_path or self.ui.document.file))
        or self._smil_doc_path
    if not doc_path then return end
    local chapter_title
    if ms.getCurrentChapter then
        local ok_ch, ch = pcall(function() return ms:getCurrentChapter() end)
        if ok_ch and ch then chapter_title = ch.title end
    end
    local fragment_id, text_doc
    local idx = ms._current_sentence_idx
    local sent = idx and ms.timing_data and ms.timing_data[idx]
    if sent then
        fragment_id = sent.fragment_id
        text_doc = sent.text_doc
    end
    self:_saveAlignedPosition(doc_path, path, pos, chapter_title, fragment_id, text_doc)
end

--- Rebuild a SMIL start entry from the last saved overlay position.
function Audiobook:_resumeEntryFromSave(doc_path, timing_data, by_file)
    local saved_pos, _, saved_audio, _, frag, text_doc = self:_getSavedAlignedPosition(doc_path)
    saved_pos = tonumber(saved_pos)
    if not saved_pos or saved_pos < 0 then return nil end
    if not saved_audio and not frag then return nil end

    local function match_file(path)
        if not path then return nil end
        if by_file and by_file[path] then return path end
        if by_file then
            local base = path:match("([^/]+)$")
            for p, _ in pairs(by_file) do
                if p == path or (base and p:match("([^/]+)$") == base) then
                    return p
                end
            end
        end
        return path
    end

    local audio = match_file(saved_audio)

    -- Prefer the exact SMIL fragment (sentence-precision resume).
    if frag and timing_data then
        for _, e in ipairs(timing_data) do
            if e.fragment_id == frag
                and (not text_doc or not e.text_doc or e.text_doc == text_doc) then
                return {
                    audio_path = e.audio_path or audio,
                    start_time = saved_pos,
                    fragment_id = e.fragment_id,
                    text_doc = e.text_doc,
                }
            end
        end
    end

    -- Fall back to file+time: find the clip containing the saved position.
    if audio and by_file and by_file[audio] then
        local slice = by_file[audio].timing or {}
        for _, e in ipairs(slice) do
            local t0 = e.start_time or 0
            local t1 = e.end_time or math.huge
            if saved_pos >= t0 and saved_pos < t1 then
                return {
                    audio_path = audio,
                    start_time = saved_pos,
                    fragment_id = e.fragment_id,
                    text_doc = e.text_doc,
                }
            end
        end
        local last = slice[#slice]
        if last then
            return {
                audio_path = audio,
                start_time = saved_pos,
                fragment_id = last.fragment_id,
                text_doc = last.text_doc,
            }
        end
    end

    return {
        audio_path = audio,
        start_time = saved_pos,
        fragment_id = frag,
        text_doc = text_doc,
    }
end

function Audiobook:_promptResumeAlignedPlayback(doc_path, timing_data, default_start_entry, on_start_entry)
    if not doc_path then
        on_start_entry(default_start_entry)
        return
    end
    local saved_pos, saved_time, saved_audio, saved_chapter = self:_getSavedAlignedPosition(doc_path)
    -- Threshold: offer to resume only if we have more than 10 s of progress.
    if not saved_pos or saved_pos <= 10 then
        on_start_entry(default_start_entry)
        return
    end

    local resume = self:_resumeEntryFromSave(doc_path, timing_data, self._smil_by_file)

    if Device:isAndroid() then
        -- Android: resume silently and say where we landed (no modal prompt).
        if resume then
            on_start_entry(resume)
            UIManager:show(InfoMessage:new{
                text = T(_("Resumed from %1"), self:_formatAudioTime(saved_pos)),
                timeout = 2,
            })
        else
            on_start_entry(default_start_entry)
        end
        return
    end

    local ConfirmBox = require("ui/widget/confirmbox")
    local default_label = default_start_entry and _("Start from current page")
        or _("Cancel")
    local book_title = doc_path:match("([^/]+)%.[^./]+$") or doc_path:match("([^/]+)$") or _("Unknown book")
    local lines = {
        T(_("Continue listening from %1?"), self:_formatAudioTime(saved_pos)),
        "",
        T(_("Book: %1"), book_title),
    }
    if saved_chapter and saved_chapter ~= "" then
        table.insert(lines, T(_("Chapter: %1"), saved_chapter))
    end
    table.insert(lines, "")
    if saved_time then
        table.insert(lines, T(_("Last played: %1"), os.date("%Y-%m-%d %H:%M", saved_time)))
    end

    local function from_start()
        self:_clearAlignedPosition(doc_path)
        if timing_data and timing_data[1] then
            on_start_entry(timing_data[1])
        else
            on_start_entry(default_start_entry)
        end
    end

    UIManager:show(ConfirmBox:new{
        text = table.concat(lines, "\n"),
        ok_text = _("Resume"),
        cancel_text = default_label,
        ok_callback = function()
            on_start_entry(resume or {
                audio_path = saved_audio,
                start_time = saved_pos,
            })
        end,
        cancel_callback = function()
            if default_start_entry then
                on_start_entry(default_start_entry)
            end
        end,
        other_buttons = {{
            {
                text = _("From start"),
                callback = from_start,
            },
        }},
    })
end

-- ---------------------------------------------------------------------------
-- Sleep timer
-- ---------------------------------------------------------------------------

function Audiobook:_startSleepTimer(minutes)
    if not minutes or minutes <= 0 then return end
    self:_cancelSleepTimer()
    self._sleep_timer_minutes = minutes
    self._sleep_timer_end = os.time() + (minutes * 60)
    local display
    if minutes >= 60 then
        local h = math.floor(minutes / 60)
        local m = minutes % 60
        if m == 0 then
            display = T(_("%1 h"), h)
        else
            display = T(_("%1 h %2 min"), h, m)
        end
    else
        display = T(_("%1 min"), minutes)
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Sleep timer set: %1"), display),
        timeout = 2,
    })
    if self.media_sync and self.media_sync.playback_bar then
        pcall(function()
            self.media_sync.playback_bar:updateSleepTimer(minutes * 60, true)
        end)
    end
    self:_scheduleSleepTimerCheck()
end

function Audiobook:_showCustomSleepTimerDialog(touchmenu_instance)
    self:_showSleepTimerDialog(touchmenu_instance)
end

function Audiobook:_showSleepTimerDialog(touchmenu_instance, on_set_callback)
    -- Prefer DateTimeWidget because it shows hour + minute pickers at once.
    local ok_dt, DateTimeWidget = pcall(require, "ui/widget/datetimewidget")
    if ok_dt and DateTimeWidget then
        UIManager:show(DateTimeWidget:new{
            title_text = _("Sleep timer"),
            info_text = _("Select hours and minutes."),
            hour = 0,
            min = 15,
            hour_min = 0,
            hour_max = 3,
            min_min = 0,
            min_max = 55,
            min_step = 5,
            min_hold_step = 5,
            ok_text = _("Set"),
            cancel_text = _("Cancel"),
            callback = function(time)
                local total = (time.hour or 0) * 60 + (time.min or 0)
                if total > 0 then
                    if on_set_callback then
                        on_set_callback(total)
                    else
                        self:setSetting("sleep_timer_minutes", total)
                        self:_startSleepTimer(total)
                    end
                else
                    if on_set_callback then
                        on_set_callback(0)
                    else
                        self:_cancelSleepTimer()
                        self:setSetting("sleep_timer_minutes", 0)
                    end
                end
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        })
        return
    end

    -- Fallback for older KOReader builds: sequential SpinWidgets.
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = _("Sleep timer: hours"),
        info_text = _("Select the number of hours."),
        value = 0,
        value_min = 0,
        value_max = 3,
        value_step = 1,
        value_hold_step = 1,
        ok_text = _("Next"),
        callback = function(hours_spin)
            UIManager:show(SpinWidget:new{
                title_text = _("Sleep timer: minutes"),
                info_text = _("Select the number of minutes."),
                value = 0,
                value_min = 0,
                value_max = 55,
                value_step = 5,
                value_hold_step = 5,
                ok_text = _("Set"),
                callback = function(minutes_spin)
                    local total = hours_spin.value * 60 + minutes_spin.value
                    if total > 0 then
                        if on_set_callback then
                            on_set_callback(total)
                        else
                            self:setSetting("sleep_timer_minutes", total)
                            self:_startSleepTimer(total)
                        end
                    else
                        if on_set_callback then
                            on_set_callback(0)
                        else
                            self:_cancelSleepTimer()
                            self:setSetting("sleep_timer_minutes", 0)
                        end
                    end
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
    })
end

function Audiobook:_cancelSleepTimer()
    self._sleep_timer_end = nil
    self._sleep_timer_minutes = nil
    if self._sleep_timer_check then
        UIManager:unschedule(self._sleep_timer_check)
        self._sleep_timer_check = nil
    end
    if self.media_sync and self.media_sync.playback_bar then
        pcall(function()
            self.media_sync.playback_bar:updateSleepTimer(0, false)
        end)
    end
end

function Audiobook:_scheduleSleepTimerCheck()
    if not self._sleep_timer_end then return end
    local function check()
        if not self._sleep_timer_end then return end
        local remaining = self._sleep_timer_end - os.time()
        if remaining <= 0 then
            self:_cancelSleepTimer()
            self:stopReadAlong()
            UIManager:show(InfoMessage:new{
                text = _("Sleep timer: playback paused."),
                timeout = 3,
            })
            if self:getSetting("sleep_timer_suspend_device", false) then
                pcall(function()
                    Device:suspend()
                end)
            end
            return
        end
        -- Update playback bar / overlay if it shows timer
        if self.media_sync and self.media_sync.playback_bar then
            pcall(function()
                self.media_sync.playback_bar:updateSleepTimer(remaining, true)
            end)
        end
        self._sleep_timer_check = UIManager:scheduleIn(5, check)
    end
    self._sleep_timer_check = UIManager:scheduleIn(5, check)
end

function Audiobook:getSleepTimerRemaining()
    if not self._sleep_timer_end then return 0 end
    return math.max(0, self._sleep_timer_end - os.time())
end

function Audiobook:_fragmentFromXPointer(xp)
    if type(xp) ~= "string" then return nil end
    -- CRe selections rarely carry a trailing #id; Storyteller spans show up as
    -- [@id='html39-s12'] inside the internal xpointer.
    return xp:match("#([^#]+)$")
        or xp:match("%[@id%s*=%s*['\"]([^'\"]+)['\"]%]")
        or xp:match("%[@id%s*=%s*([^%]]+)%]")
end

function Audiobook:_normalizeSelText(text)
    return Utils.normalizeForMatching(text)
end

function Audiobook:_matchSmilEntryFromSelection(selected_text, timing_data, parser)
    -- Resolve the SMIL timing entry that best matches a user selection.
    -- Prefer fragment id from the CRe xpointer, then scored text matches in
    -- the current DocFragment (never the first hit earlier in the book).
    if not selected_text or not timing_data then return nil end

    local frag = self:_fragmentFromXPointer(selected_text.pos0)
        or self:_fragmentFromXPointer(selected_text.pos1)
    if frag then
        for _, e in ipairs(timing_data) do
            if e.fragment_id == frag then
                logger.warn("Audiobook: matched selection via fragment id", frag)
                return e
            end
        end
    end

    local sel_text = self:_normalizeSelText(selected_text.text)
    if sel_text == "" then return nil end

    -- Expand short selections with nearby on-screen text.
    local word_count = 0
    for _ in sel_text:gmatch("%S+") do word_count = word_count + 1 end
    if word_count <= 3 and selected_text.pos0 and self.ui and self.ui.document
        and self.ui.document.getScreenPositionFromXPointer
        and self.ui.document.getTextFromPositions then
        local ok_y, screen_y = pcall(
            self.ui.document.getScreenPositionFromXPointer,
            self.ui.document, selected_text.pos0)
        if ok_y and screen_y then
            local ScreenDev = Device.screen
            local y0 = math.max(0, screen_y - 60)
            local y1 = math.min(ScreenDev:getHeight(), screen_y + 100)
            local ok_t, res = pcall(
                self.ui.document.getTextFromPositions,
                self.ui.document,
                {x = 0, y = y0},
                {x = ScreenDev:getWidth(), y = y1},
                true)
            if ok_t and res and res.text and #res.text > #sel_text then
                local expanded = self:_normalizeSelText(res.text)
                if expanded:find(sel_text, 1, true) then
                    sel_text = expanded
                end
            end
        end
    end

    local cur_xp = self.ui and self.ui.document and self.ui.document:getXPointer()
    local frag_idx = cur_xp and tonumber(cur_xp:match("DocFragment%[(%d+)%]"))
    local spine = parser and parser._spine_hrefs or {}
    local cur_base = frag_idx and spine[frag_idx]

    local function in_current_doc(e)
        if not cur_base then return true end
        return e.text_doc and e.text_doc:match("([^/]+)$") == cur_base
    end

    -- Needle: prefer a distinctive prefix of the selection.
    local needle = sel_text
    if #needle > 80 then needle = needle:sub(1, 80) end

    local sel_y = nil
    if selected_text.pos0 and self.ui and self.ui.document
        and self.ui.document.getScreenPositionFromXPointer then
        local ok_y, y = pcall(
            self.ui.document.getScreenPositionFromXPointer,
            self.ui.document, selected_text.pos0)
        if ok_y then sel_y = y end
    end

    local best, best_score = nil, -1
    for _, e in ipairs(timing_data) do
        if in_current_doc(e) and e.text and e.text ~= "" then
            local et = self:_normalizeSelText(e.text)
            local score = 0
            if et == sel_text then
                score = 10000
            elseif et:find(sel_text, 1, true) then
                score = 5000 + math.min(#sel_text, 200)
            elseif sel_text:find(et, 1, true) then
                score = 4000 + math.min(#et, 200)
            elseif et:find(needle, 1, true) then
                score = 2000 + math.min(#needle, 80)
            elseif needle:find(et:sub(1, math.min(40, #et)), 1, true) then
                score = 1000
            end
            if score > 0 and sel_y and e.fragment_id and self.ui.document.getScreenPositionFromXPointer then
                local ok_fy, fy = pcall(
                    self.ui.document.getScreenPositionFromXPointer,
                    self.ui.document, "#" .. e.fragment_id)
                if ok_fy and fy then
                    -- Closer on screen → higher score (up to +500).
                    local dist = math.abs(fy - sel_y)
                    score = score + math.max(0, 500 - math.floor(dist / 2))
                end
            end
            if score > best_score then
                best_score = score
                best = e
            end
        end
    end

    if best then
        logger.warn("Audiobook: matched selection by scored text",
            best.fragment_id, "score", best_score, "needle", needle:sub(1, 60))
        return best
    end
    return nil
end

function Audiobook:startAlignedAudioFromSelection(selected_text)
    if not self._init_ok or not self.media_sync then
        self:_showInitError()
        return
    end
    if not self:_audioOutputReady() then return end

    local doc_path = self.ui and self.ui.document and (self.ui.document.file_path or self.ui.document.file)
    if not doc_path then
        UIManager:show(InfoMessage:new{
            text = _("No document is currently open."),
            timeout = 3,
        })
        return
    end

    if not self:_hasMediaOverlays() then
        UIManager:show(InfoMessage:new{
            text = _("This book has no embedded narration/alignment metadata."),
            timeout = 4,
        })
        return
    end

    self:_startSmilPlaybackFromSelection(doc_path, selected_text, false)
end

function Audiobook:_startSmilPlaybackFromSelection(doc_path, selected_text, allow_resume)
    allow_resume = (allow_resume ~= false)
    local ok, EpubMediaOverlay = pcall(dofile, PLUGIN_PATH .. "epubmediaoverlay.lua")
    if not ok or not EpubMediaOverlay then
        UIManager:show(InfoMessage:new{
            text = _("Failed to load EPUB Media Overlay parser."),
            timeout = 3,
        })
        return
    end

    local parser = self._smil_parser
    local timing_data = self._smil_timing_data
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local cur_fp
    if ok_lfs and lfs and lfs.attributes then
        local attr = lfs.attributes(doc_path)
        if attr and attr.size and attr.modification then
            cur_fp = string.format("%d:%d", attr.size, attr.modification)
        end
    end
    if parser and timing_data and (self._smil_doc_path ~= doc_path
        or (cur_fp and self._smil_epub_fp and self._smil_epub_fp ~= cur_fp)) then
        -- Cached data belongs to a different book or a replaced EPUB.
        logger.warn("Audiobook: SMIL cache stale for", doc_path, "; reloading")
        parser = nil
        timing_data = nil
        self._smil_parser = nil
        self._smil_timing_data = nil
        self._smil_by_file = nil
        self._smil_page_index = nil
        self._smil_doc_path = nil
    end
    if not parser or not timing_data then
        local loading_msg = InfoMessage:new{
            text = _("Loading Media Overlays..."),
            timeout = 3600,
        }
        UIManager:show(loading_msg)
        UIManager:forceRePaint()
        parser = EpubMediaOverlay:new()
        local err
        timing_data, err = parser:loadFromEpub(doc_path, PLUGIN_PATH:sub(1, -2), function(prog)
            if not prog then return end
            if prog.phase == "smil" and prog.total then
                local name = prog.detail and tostring(prog.detail):match("([^/]+)$") or ""
                loading_msg.text = T(_("Parsing overlays: %1 / %2\n%3"),
                    prog.current, prog.total, name)
            elseif prog.phase == "done" then
                loading_msg.text = T(_("Loaded %1 timing entries"), prog.current)
            end
            UIManager:setDirty(loading_msg, function()
                return "ui", loading_msg.dimen
            end)
            UIManager:forceRePaint()
        end)
        UIManager:close(loading_msg)
        UIManager:forceRePaint()
        if not timing_data then
            UIManager:show(InfoMessage:new{
                text = _("No Media Overlays found: ") .. tostring(err),
                timeout = 3,
            })
            return
        end
        self._smil_parser = parser
        self._smil_timing_data = timing_data
        self._smil_page_index = nil
        self._smil_doc_path = doc_path
        self._smil_epub_fp = cur_fp
    end

    local start_entry = self:_matchSmilEntryFromSelection(selected_text, timing_data, parser)

    if not start_entry then
        -- Fall back to the first timing entry for the current page.
        start_entry = self:_findCurrentPageSmilEntry()
    end

    if not start_entry then
        start_entry = timing_data[1]
    end

    logger.warn("Audiobook: Play-from-here entry",
        start_entry and start_entry.fragment_id,
        "t=", start_entry and start_entry.start_time,
        "doc=", start_entry and start_entry.text_doc)

    if allow_resume then
        self:_promptResumeAlignedPlayback(doc_path, timing_data, start_entry, function(chosen_entry)
            self:_startSmilPlayback(doc_path, chosen_entry)
        end)
    else
        self:_startSmilPlayback(doc_path, start_entry)
    end
end

function Audiobook:startReadAlongFromWord(word, context)
    if not self._init_ok then self:_showInitError(); return end
    if not self.tts_engine then
        local hint = ""
        if self:_hasMediaOverlays() then
            hint = _("\n\nThis book has embedded narration — use \"Play aligned audiobook from here\" instead.")
        end
        UIManager:show(InfoMessage:new{
            text = _("TTS engine is not available.") .. hint,
            timeout = 6,
        })
        return
    end
    if not self:_audioOutputReady() then return end

    local ok_page, page_text = pcall(function() return self:getCurrentPageText() end)
    if not ok_page then
        logger.warn("Audiobook: getCurrentPageText error:", page_text)
        page_text = nil
    end
    if not page_text or page_text == "" then
        -- Try to get text from the dictionary lookup context instead
        if self.ui.highlight and self.ui.highlight.selected_text then
            local selected = self.ui.highlight.selected_text
            if selected.text then
                page_text = selected.text
            end
        end
    end

    if not page_text or page_text == "" then
        local hint = ""
        if self:_hasMediaOverlays() then
            hint = _("\n\nFor this read-aloud EPUB, use \"Play aligned audiobook from here\".")
        end
        UIManager:show(InfoMessage:new{
            text = _("Could not retrieve page text for TTS.") .. hint,
            timeout = 5,
        })
        return
    end
    
    -- Find the word position in the page text
    local start_pos = nil
    if word then
        -- Escape special pattern chars
        local pattern = word:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")

        -- Helper: find the occurrence of `pattern` in page_text closest to
        -- `target_offset` (a character index into page_text).
        local function find_closest_occurrence(target_offset)
            local best_pos = nil
            local best_dist = math.huge
            local search_start = 1
            while true do
                local found = page_text:find(pattern, search_start)
                if not found then break end
                local dist = math.abs(found - target_offset)
                if dist < best_dist then
                    best_dist = dist
                    best_pos = found
                end
                search_start = found + 1
            end
            return best_pos, best_dist
        end

        -- Primary approach: convert the xpointer to a screen position,
        -- then ask CRe for all text from the top of the page down to that
        -- screen position.  The length of that text is the char offset
        -- into page_text.
        if context and context.pos0 and self.ui.document
                and self.ui.rolling
                and self.ui.document.getScreenPositionFromXPointer then
            local ok, screen_y, screen_x = pcall(
                self.ui.document.getScreenPositionFromXPointer,
                self.ui.document, context.pos0)
            if ok and screen_y then
                local ScreenDev = Device.screen
                -- Clamp screen_y to visible area
                if screen_y < 0 then screen_y = 0 end
                -- Get text from top-left of page to the word's position.
                -- Use the word's screen_x so we stop in the middle of the
                -- line rather than grabbing the whole line.
                local use_x = (screen_x and screen_x > 0) and screen_x or ScreenDev:getWidth()
                local ok2, res = pcall(
                    self.ui.document.getTextFromPositions,
                    self.ui.document,
                    {x = 0, y = 0},
                    {x = use_x, y = screen_y},
                    true)
                if ok2 and res and res.text then
                    local approx_offset = #res.text
                    local best, dist = find_closest_occurrence(approx_offset)
                    if best then
                        start_pos = best
                        logger.warn("Audiobook: Found word '", word,
                            "' via screen-pos at", start_pos,
                            "(approx_offset=", approx_offset,
                            "screen_y=", screen_y, "dist=", dist, ")")
                    end
                end
            end
        end

        -- Final fallback: first occurrence
        if not start_pos then
            start_pos = page_text:find(pattern)
            logger.warn("Audiobook: Found word '", word, "' via first-occurrence at", start_pos)
        end
    end
    
    -- If we couldn't find the word, just start from beginning
    if not start_pos then
        logger.warn("Audiobook: Word not found, starting from beginning")
        start_pos = 1
    end
    
    -- Start reading from the found position
    self:startReadAlong(page_text, start_pos)
end

--[[--
Kill orphan processes from a previous KOReader session that was SIGKILL'd.
Checks for PID files and known process names left behind when cleanup
didn't run (OOM kill, watchdog, hard reboot).
Called once at plugin init — idempotent and safe when no orphans exist.
--]]
function Audiobook:_killOrphanProcessesFromPreviousSession()
    -- These orphan cleanup commands (pgrep, killall, pkill) are Linux-specific
    -- and don't exist on Android.  Skip entirely on Android.
    if Device:isAndroid() then return end

    local dominated = false

    -- 1. Kill orphan gst-launch-1.0 (frees the exclusive BT A2DP socket)
    --    and gst-launch-0.10 (Kindle mixersink pipelines).
    --    Check if any gst-launch is running before paying the killall cost.
    local h = io.popen("pgrep -c gst-launch 2>/dev/null")
    if h then
        local count = tonumber(h:read("*a"))
        h:close()
        if count and count > 0 then
            os.execute("killall -9 gst-launch-1.0 2>/dev/null")
            os.execute("killall -9 gst-launch-0.10 2>/dev/null")
            dominated = true
            logger.warn("Audiobook: Startup cleanup — killed orphan gst-launch processes")
        end
    end

    -- 2. Kill orphan piper processes
    h = io.popen("pgrep -c piper 2>/dev/null")
    if h then
        local count = tonumber(h:read("*a"))
        h:close()
        if count and count > 0 then
            os.execute("killall -9 piper 2>/dev/null")
            dominated = true
            logger.warn("Audiobook: Startup cleanup — killed orphan piper")
        end
    end

    -- 3. Kill orphan feeder/server shell scripts by PID file
    local pid_files = {
        "/tmp/audiobook_ctrl/gst_pid",    -- persistent pipeline gst PID
        "/tmp/piper_server_1.pid",         -- piper server 1 reader PID
        "/tmp/piper_server_1.piper_pid",   -- piper server 1 piper PID
        "/tmp/piper_server_2.pid",         -- piper server 2 reader PID
        "/tmp/piper_server_2.piper_pid",   -- piper server 2 piper PID
    }
    for _, pf_path in ipairs(pid_files) do
        local pf = io.open(pf_path, "r")
        if pf then
            local pid = pf:read("*a"):gsub("%s+", "")
            pf:close()
            if pid ~= "" then
                os.execute(string.format("kill -9 %s 2>/dev/null", pid))
                dominated = true
                logger.warn("Audiobook: Startup cleanup — killed PID", pid, "from", pf_path)
            end
            os.remove(pf_path)
        end
    end

    -- 4. Kill the feeder wrapper shell by finding /bin/sh audiobook_pipeline
    --    This catches the wrapper that io.popen("script & echo $!") spawned.
    os.execute("pkill -9 -f 'audiobook_pipeline\\.sh' 2>/dev/null")

    -- 5. Kill orphan server wrapper shells
    os.execute("pkill -9 -f 'piper_server_.*\\.sh' 2>/dev/null")

    -- 6. Clean up stale temp files
    os.execute("rm -f /tmp/audiobook_fifo /tmp/audiobook_pipeline.sh /tmp/audiobook_ctrl/gst_pid /tmp/audiobook_ctrl/stop /tmp/audiobook_ctrl/play /tmp/audiobook_ctrl/done 2>/dev/null")
    os.execute("rm -f /tmp/piper_server_*.pid /tmp/piper_server_*.piper_pid /tmp/piper_server_*.sh /tmp/piper_server_*.log 2>/dev/null")

    if dominated then
        -- Give kernel time to release sockets after SIGKILL
        os.execute("usleep 300000")
    end
end

function Audiobook:stopReadAlong(opts)
    opts = opts or {}
    if not self._init_ok then return end
    logger.warn("Audiobook: stopReadAlong() called")
    -- Save media playback position before stopping
    if self.media_sync and self.media_sync.state ~= "stopped" then
        local ok_pos, pos = pcall(function()
            return self.media_sync.media_engine and self.media_sync.media_engine:getPosition()
        end)
        local ok_path, path = pcall(function()
            return self.media_sync.media_engine and self.media_sync.media_engine.current_path
        end)
        if ok_pos and ok_path and pos and path and pos > 10 then
            self:_savePosition(path, pos)
            logger.warn("Audiobook: saved position", pos, "for", path)

            -- Also save aligned-audiobook position keyed by the EPUB path,
            -- so we can offer "continue listening" on the next start.
            if self.media_sync and self.media_sync.overlay_mode then
                local doc_path = self.ui and self.ui.document
                    and (self.ui.document.file_path or self.ui.document.file)
                if doc_path then
                    local chapter_title = nil
                    if self.media_sync.getCurrentChapter then
                        local ok_ch, ch = pcall(function()
                            return self.media_sync:getCurrentChapter()
                        end)
                        if ok_ch and ch then chapter_title = ch.title end
                    end
                    self:_saveAlignedPosition(doc_path, path, pos, chapter_title)
                    logger.warn("Audiobook: saved aligned position", pos, "for", doc_path)
                end
            end

            -- Sync to Audiobookshelf if this is an ABS item
            if self.media_sync._abs_item_id and self._abs_sync then
                local dur = self.media_sync._abs_duration or 0
                self._abs_sync:recordProgress(
                    self.media_sync._abs_item_id,
                    path, pos, dur, false
                )
                -- Attempt immediate flush
                local ABSClient
                pcall(function()
                    ABSClient = dofile(self.path .. "/absclient.lua")
                end)
                if ABSClient then
                    local server_url = self:getSetting("abs_server_url", "")
                    local token = self:getSetting("abs_api_token", "")
                    if server_url ~= "" and token ~= "" then
                        local client = ABSClient:new{ server_url = server_url, token = token }
                        self._abs_sync:flush(client)
                    end
                end
            end
        end
        pcall(function() self.media_sync:stop(false, { drop_chrome = opts.drop_chrome }) end)
    elseif self.media_sync and opts.drop_chrome then
        pcall(function() self.media_sync:stop(false, { drop_chrome = true }) end)
    end
    pcall(function() BtUI.stopWatcher(self) end)
    pcall(function() BtMediaControl.stop() end)
    pcall(function() BtMediaControl.sendPlaybackStatus("stopped") end)
    pcall(function() self.sync_controller:stop() end)
    pcall(function() self.highlight_manager:clearHighlights() end)
    -- Always kill orphan audio processes, even if we think we're not playing.
    -- A stale gst-launch-1.0 holding the BT socket can destabilize the
    -- system when Nickel resumes after KOReader exits.
    pcall(function() self.tts_engine:forceKillAll() end)
end

--- Ensure headset media buttons are listened for.
-- The setting defaults to on; an explicit user "off" is always honored,
-- including on Kindle (AVRCP scan does not run without consent).
function Audiobook:_ensureBtMediaControl()
    if not BtMediaControl then return end
    if self:getSetting("bt_media_control", true) then
        BtMediaControl.start(self)
    end
end

function Audiobook:pauseReadAlong()
    if not self._init_ok then return end
    -- Pause media playback if active
    if self.media_sync and self.media_sync.state ~= "stopped" then
        pcall(function() self.media_sync:pause() end)
        pcall(function() BtMediaControl.sendPlaybackStatus("paused") end)
        return
    end
    -- TTS fallback: guard nil controller (e.g. BT event after audio stopped).
    if self.sync_controller then
        pcall(function() self.sync_controller:pause() end)
        pcall(function() BtMediaControl.sendPlaybackStatus("paused") end)
    end
end

function Audiobook:resumeReadAlong()
    if not self._init_ok then return end
    -- Resume media playback if active
    if self.media_sync and self.media_sync.state == "paused" then
        pcall(function() self:_ensureBtMediaControl() end)
        pcall(function() self.media_sync:resume() end)
        pcall(function() BtMediaControl.sendPlaybackStatus("playing") end)
        return
    end
    if self.sync_controller then
        pcall(function() self:_ensureBtMediaControl() end)
        pcall(function() self.sync_controller:resume() end)
        pcall(function() BtMediaControl.sendPlaybackStatus("playing") end)
    end
end


function Audiobook:getCurrentPageText()
    if not self.ui or not self.ui.document then
        logger.warn("Audiobook: No UI or document")
        return nil
    end

    local document = self.ui.document
    local text = nil
    local Screen = Device.screen

    -- EPUB / CreDocument (rolling mode):
    -- Select all visible text by spanning the full screen rectangle.
    -- This is exactly how KOReader's own ReaderView:getCurrentPageLineWordCounts() works.
    if self.ui.rolling then
        local ok, res = pcall(document.getTextFromPositions, document,
            {x = 0, y = 0},
            {x = Screen:getWidth(), y = Screen:getHeight()},
            true)  -- do_not_draw_selection
        if ok and res and res.text and res.text ~= "" then
            text = res.text
        end
    end

    -- PDF / DjVu (paged mode):
    -- Get structured word boxes for the current page and concatenate them.
    if not text and self.ui.paging then
        local page = self.ui:getCurrentPage()
        if page then
            local ok, page_boxes = pcall(document.getTextBoxes, document, page)
            if ok and page_boxes and page_boxes[1] then
                local lines = {}
                for _, line in ipairs(page_boxes) do
                    local words = {}
                    for _, wb in ipairs(line) do
                        if wb.word and wb.word ~= "" then
                            table.insert(words, wb.word)
                        end
                    end
                    if #words > 0 then
                        table.insert(lines, table.concat(words, " "))
                    end
                end
                text = table.concat(lines, "\n")
            end
        end
    end

    if text and text ~= "" then
        -- Don't trim to last complete sentence — the visible text rectangle
        -- from getTextFromPositions doesn't overlap between pages, so partial
        -- sentences at page boundaries must be kept or they'll be skipped.
        logger.dbg("Audiobook: Got page text, length:", #text)
        return text
    end

    logger.warn("Audiobook: Could not get page text")
    return nil
end

-- Event handlers
function Audiobook:onAudiobookToggle()
    if not self._init_ok then self:_showInitError(); return true end
    -- When media playback is active (no document needed), toggle that
    if self.media_sync and self.media_sync.state ~= "stopped" then
        if self.media_sync:isPlaying() then
            self:pauseReadAlong()
        elseif self.media_sync:isPaused() then
            self:resumeReadAlong()
        end
        return true
    end
    -- Otherwise toggle TTS read-along (requires document)
    if not self.sync_controller then return true end
    if self.sync_controller:isPlaying() then
        self:pauseReadAlong()
    elseif self.sync_controller:isPaused() then
        self:resumeReadAlong()
    else
        self:startReadAlong()
    end
    return true
end

function Audiobook:onAudiobookStop()
    if not self._init_ok then return true end
    logger.warn("Audiobook: onAudiobookStop event received")
    self:stopReadAlong()
    return true
end

-- ── BT media button event handlers (AVRCP) ──────────────────────────
-- These are dispatched by KOReader's input system when the AVRCP evdev
-- device sends key events (play/pause/next/prev from a BT headset).

function Audiobook:onMediaPlayPause()
    if not self._init_ok then return true end
    -- Prefer media_sync (Storyteller / audiobook) over TTS sync_controller.
    local media_active = self.media_sync and self.media_sync.state ~= "stopped"
    if media_active then
        if self.media_sync.state == "playing" then
            self:pauseReadAlong()
        elseif self.media_sync.state == "paused" then
            self:resumeReadAlong()
        end
        return true
    end
    if self.sync_controller and self.sync_controller:isPlaying() then
        self:pauseReadAlong()
    elseif self.sync_controller and self.sync_controller:isPaused() then
        self:resumeReadAlong()
    end
    return true
end

function Audiobook:onMediaPlay()
    if not self._init_ok then return true end
    self:resumeReadAlong()
    return true
end

function Audiobook:onMediaPause()
    if not self._init_ok then return true end
    self:pauseReadAlong()
    return true
end

function Audiobook:onMediaStop()
    if not self._init_ok then return true end
    logger.warn("Audiobook: onMediaStop event received")
    self:stopReadAlong()
    return true
end

function Audiobook:onMediaNext()
    if not self._init_ok then return true end
    if self.media_sync and self.media_sync.state ~= "stopped" then
        self.media_sync:nextChapter()
        return true
    end
    if self.sync_controller and (self.sync_controller:isPlaying() or self.sync_controller:isPaused()) then
        self.sync_controller:nextSentence()
    end
    return true
end

function Audiobook:onMediaPrev()
    if not self._init_ok then return true end
    if self.media_sync and self.media_sync.state ~= "stopped" then
        self.media_sync:prevChapter()
        return true
    end
    if self.sync_controller and (self.sync_controller:isPlaying() or self.sync_controller:isPaused()) then
        self.sync_controller:prevSentence()
    end
    return true
end

-- NOTE: onPageUpdate intentionally removed.
-- Our SyncController manages page flow via advanceToNextPage().
-- Having onPageUpdate here caused an infinite restart loop:
-- highlight → screen refresh → PageUpdate → updateText → stop audio → restart → highlight → ...

-- When the user manually turns a page while an aligned audiobook is playing,
-- optionally seek narration to the new page.
-- onPosUpdate is intentionally not hooked here; onPageUpdate already covers
-- page changes, and reacting to every position update caused an infinite
-- restart loop (highlight -> refresh -> PosUpdate -> seek -> highlight ...).
function Audiobook:onPosUpdate(pos, refresh_type)
end

function Audiobook:onPageUpdate(cur_page, prev_page)
    self:_handlePageTurnFollow()
end

function Audiobook:_currentAudioSentenceVisible()
    -- True when the sentence currently tied to the audio position appears on
    -- the visible page (so we should keep the highlight / hide "return").
    -- A wrapping sentence is visible if either its prefix or its tail is here.
    if not self.media_sync or not self.media_sync.overlay_mode then return false end
    local idx = self.media_sync._current_sentence_idx
    local sent = idx and self.media_sync.timing_data and self.media_sync.timing_data[idx]
    if not sent or not sent.text then return false end
    local page_text = self:getCurrentPageText()
    if not page_text or page_text == "" then return false end
    local needle = self:_normalizeSelText(sent.text)
    page_text = self:_normalizeSelText(page_text)
    if needle == "" then return false end
    if page_text:find(needle, 1, true) then return true end
    local words = Utils.splitWords(needle)
    if #words == 0 then return false end
    local prefix_n = Utils.sentencePrefixOnPage(words, page_text)
    if prefix_n >= math.min(3, #words) then return true end
    local suffix_n = Utils.sentenceSuffixOnPage(words, page_text)
    return suffix_n >= math.min(2, #words)
end

function Audiobook:_showReturnToReadAloudButton()
    -- Drive the cue through AudiobookPlayer's mini bar: that widget already
    -- owns bottom-screen taps. A separate BottomContainer overlay looked
    -- tappable but never received gestures (player sat above / ate events).
    local bar = self.media_sync and self.media_sync.playback_bar
    if not bar or not bar.setReturnHint then return end
    pcall(function() bar:setReturnHint(true) end)
end

function Audiobook:_hideReturnToReadAloudButton()
    local bar = self.media_sync and self.media_sync.playback_bar
    if bar and bar.setReturnHint then
        pcall(function() bar:setReturnHint(false) end)
    end
    -- Clean up any leftover overlay from older builds.
    if self._return_to_readaloud_widget then
        pcall(function()
            UIManager:close(self._return_to_readaloud_widget)
        end)
        self._return_to_readaloud_widget = nil
    end
end

function Audiobook:_handlePageTurnFollow()
    if not self._init_ok then return end
    if not self.media_sync then return end
    if not self.media_sync.overlay_mode then return end
    if self.media_sync.state ~= self.media_sync.STATE.PLAYING
       and self.media_sync.state ~= self.media_sync.STATE.PAUSED then
        self._readaloud_browsing_away = false
        self:_hideReturnToReadAloudButton()
        return
    end
    -- Ignore page events caused by MediaSync's own auto-follow.
    if (self._media_sync_page_follow_count or 0) > 0 then return end
    -- Re-entry / rapid-repeat guard.
    if self._in_handle_page_turn_follow then return end
    if Time then
        local now = Time.now()
        if self._page_turn_follow_deadline and now < self._page_turn_follow_deadline then
            return
        end
        self._page_turn_follow_deadline = now + Time.s(0.8)
    end

    self._in_handle_page_turn_follow = true
    local ok, err = pcall(function()
        local on_audio_page = self:_currentAudioSentenceVisible()

        -- Manual page turns must NEVER seek/restart audio. Audio keeps
        -- playing; we only pause highlighting and show a return cue
        -- (Readest-style) until the user jumps back or narration catches up.
        if on_audio_page then
            self._readaloud_browsing_away = false
            self:_hideReturnToReadAloudButton()
        else
            self._readaloud_browsing_away = true
            pcall(function() self.media_sync:clearSentenceHighlight() end)
            self:_showReturnToReadAloudButton()
        end
    end)
    self._in_handle_page_turn_follow = false
    if not ok then
        logger.warn("Audiobook: _handlePageTurnFollow error:", err)
    end
end

-- Resolve a SMIL fragment id to a crengine xpointer, but only when the
-- content document that contains the fragment is already loaded.  Raw EPUB
-- internal paths like "text/part0009.html#id14-s0" are not accepted by
-- crengine; cross-document navigation uses the SMIL page index or a direct
-- text search fallback instead.
function Audiobook:_resolveSmilXPointer(text_doc, fragment_id)
    local doc = self.ui and self.ui.document
    if not doc or not fragment_id then return nil end
    local ok, norm = pcall(function()
        return doc:getNormalizedXPointer("#" .. fragment_id)
    end)
    if ok and norm and norm ~= false then
        return norm
    end
    return nil
end

function Audiobook:_buildSmilPageIndex()
    if self._smil_page_index then return end
    -- Map each EPUB content document referenced by the Media Overlays to a
    -- page number where that document is rendered.  This is built once per
    -- SMIL playback session, lazily and in small chunks, so cross-document
    -- auto-follow does not have to guess DocFragment indices or scan pages.
    self._smil_page_index = {}
end

-- Normalize sentence text before handing it to crengine's findText.  The
-- extracted SMIL text and the rendered text can differ in whitespace,
-- punctuation, and zero-width characters.
function Audiobook:_normalizeSearchText(text)
    return Utils.normalizeForMatching(text)
end

-- Find a page number that belongs to the target content document.
-- The previous DocFragment scan and findText fallbacks were unreliable and
-- caused severe UI lag, so this now only returns a previously cached page.
function Audiobook:_ensureSmilPageIndexEntry(text_doc)
    self:_buildSmilPageIndex()
    local cached = self._smil_page_index[text_doc]
    if cached ~= nil and cached ~= false then
        return cached.page
    end
    return nil
end

-- Keep the old helpers unused for now; they may be removed after the next
-- round of testing.
function Audiobook:_getSmilSampleEntries(text_doc, max_samples)
    return {}
end

-- Disabled: the DocFragment scan / findText index builders caused severe UI
-- lag and did not work on this device.  Cross-document navigation now relies
-- on cached full xpointers and a fast getPageFromXPointer probe.
function Audiobook:_scheduleSmilPageIndexBuild()
    -- no-op
end

function Audiobook:_findCurrentPageSmilEntry()
    local parser = self._smil_parser
    local timing_data = self._smil_timing_data
    if not parser or not timing_data then return nil end

    local doc = self.ui and self.ui.document
    local cur_xp = doc and doc:getXPointer()
    local frag_idx = cur_xp and tonumber(cur_xp:match("DocFragment%[(%d+)%]"))
    local spine = parser._spine_hrefs or {}
    if not frag_idx or not spine[frag_idx] then return nil end

    -- Find the first timing entry whose content document matches the current
    -- spine document (or a later one, in case the current document has no narration).
    for si = frag_idx, #spine do
        local base = spine[si]
        for _, e in ipairs(timing_data) do
            if e.audio_path and e.text_doc
                and (e.text_doc:match("([^/]+)$") == base) then
                return e
            end
        end
    end

    return nil
end

-- Auto-pause TTS when any KOReader menu or popup opens.
-- NOTE: ShowConfigMenu event is consumed by ReaderConfig before reaching us,
-- so onShowConfigMenu may never fire. The PlaybackBar handles its own
-- visibility via paintTo (checks for overlay widgets in the stack).
function Audiobook:onShowReaderMenu()
    if not self._init_ok then return end
    if self.sync_controller and self.sync_controller:isPlaying() then
        self._paused_by_menu = true
        self.sync_controller:pause()
    end
end

function Audiobook:onCloseReaderMenu()
    if not self._init_ok then return end
    if self._paused_by_menu then
        self._paused_by_menu = false
        if self.sync_controller and self.sync_controller:isPaused() then
            self.sync_controller:resume()
        end
    end
end

-- Also pause for the config/bottom menu
function Audiobook:onShowConfigMenu()
    if not self._init_ok then return end
    if self.sync_controller and self.sync_controller:isPlaying() then
        self._paused_by_menu = true
        self.sync_controller:pause()
    end
end

function Audiobook:onCloseConfigMenu()
    if not self._init_ok then return end
    if self._paused_by_menu then
        self._paused_by_menu = false
        if self.sync_controller and self.sync_controller:isPaused() then
            self.sync_controller:resume()
        end
    end
end

-- ── Suspend / Resume (lid close, power button) ──────────────────────
-- On suspend we MUST kill all audio processes (gst-launch, piper) before
-- the kernel enters hardware sleep.  Merely freezing them with SIGSTOP
-- leaves them holding audio hardware resources, which can crash the
-- entire device on some Kobo models.
function Audiobook:onSuspend()
    if self.session_recorder then
        pcall(function() self.session_recorder:stop() end)
    end
    if not self._init_ok then return end
    -- Handle media playback suspend
    if self.media_sync and (self.media_sync:isPlaying() or self.media_sync:isPaused()) then
        self._media_was_playing = self.media_sync:isPlaying()
        pcall(function() self.media_sync:pause() end)
        self._paused_by_suspend = true
        logger.warn("Audiobook: Suspend — paused media playback")
        return
    end
    -- Handle TTS read-along suspend
    if self.sync_controller and (self.sync_controller:isPlaying() or self.sync_controller:isPaused()) then
        self._suspend_sentence_idx = self.sync_controller.reading_sentence_idx
        self._suspend_was_playing = self.sync_controller:isPlaying()
        pcall(function() self.tts_engine:forceKillAll() end)
        self.sync_controller.state = self.sync_controller.STATE.PAUSED
        self.sync_controller._user_paused = false
        if self.sync_controller.playback_bar then
            self.sync_controller.playback_bar:updatePlayState(false)
            if self.sync_controller._applyBarVisibility then
                self.sync_controller:_applyBarVisibility()
            end
        end
        self._paused_by_suspend = true
        logger.warn("Audiobook: Suspend — killed audio processes, will resume from sentence",
            self._suspend_sentence_idx)
    end
end

function Audiobook:onResume()
    if not self._init_ok then return end
    if not self._paused_by_suspend then return end
    self._paused_by_suspend = false

    -- Resume media playback
    if self.media_sync and self._media_was_playing then
        self._media_was_playing = nil
        pcall(function() self.media_sync:resume() end)
        logger.warn("Audiobook: Resume — resumed media playback")
        return
    end

    -- Resume TTS read-along
    local sentence_idx = self._suspend_sentence_idx
    local was_playing = self._suspend_was_playing
    self._suspend_sentence_idx = nil
    self._suspend_was_playing = nil

    if was_playing and sentence_idx and self.sync_controller
            and self.sync_controller.parsed_data then
        UIManager:scheduleIn(1.5, function()
            self.sync_controller.reading_sentence_idx = sentence_idx - 1
            self.sync_controller.state = self.sync_controller.STATE.PLAYING
            if self.sync_controller.playback_bar then
                self.sync_controller.playback_bar:updatePlayState(true)
            end
            if self.tts_engine and self.tts_engine.backend == self.tts_engine.BACKENDS.PIPER then
                self.sync_controller._piper_warmed_up = false
            end
            logger.warn("Audiobook: Resume — restarting from sentence", sentence_idx)
            self.sync_controller:readNextSentence()
        end)
    else
        if self.sync_controller and self.sync_controller._applyBarVisibility then
            self.sync_controller:_applyBarVisibility()
        end
    end
end

function Audiobook:_shouldLockKoreaderMargins()
    return self:getSetting("lock_koreader_page_margins", false)
        and self:getSetting("keep_media_overlay_bar", false)
end

function Audiobook:_defaultOverlayBottomUnscaled()
    local screen = Device and Device.screen
    if not screen then
        return 46
    end
    local bar_h = screen:scaleBySize(44)
    if screen.unscaleBySize then
        return screen:unscaleBySize(bar_h) + 2
    end
    return 46
end

function Audiobook:_docWantsLockedOverlayMargins(config, document)
    if not self:_shouldLockKoreaderMargins() then return false end
    if not config then return false end
    -- copt_b_page_margin is a CRE (rolling) setting; fixed-layout documents
    -- never read it, and aligned overlay books are EPUB anyway.
    local path = document and (document.file or document.file_path)
    local ext = path and path:lower():match("%.([^.]+)$")
    if ext == "pdf" or ext == "djvu" or ext == "cbz" or ext == "zip" then
        return false
    end
    if config:readSetting("audiobook_overlay_margin_locked") then return true end
    if config:readSetting("audiobook_overlay_bottom") then return true end
    if config:readSetting("audiobook_overlay_orig_bottom") then return true end
    if path then
        local pos = self:_getSavedAlignedPosition(path)
        if pos then return true end
    end
    return false
end

-- Apply the overlay inset as KOReader's own bottom margin *before* CRE
-- typesets. That is the one durable reload: later opens hit the new cache.
-- Never SetPageMargins after the page is on screen (Android ANR).
function Audiobook:onDocSettingsLoad(config, document)
    if not config then return end
    if not self:_docWantsLockedOverlayMargins(config, document) then return end
    local needed = tonumber(config:readSetting("audiobook_overlay_bottom"))
        or self:_defaultOverlayBottomUnscaled()
    if not needed or needed <= 0 then return end
    local copt = tonumber(config:readSetting("copt_b_page_margin"))
    if config:readSetting("audiobook_overlay_orig_bottom") == nil
        and copt ~= nil and math.abs(copt - needed) > 1 then
        config:saveSetting("audiobook_overlay_orig_bottom", copt)
    end
    config:saveSetting("copt_b_page_margin", needed)
    config:saveSetting("audiobook_overlay_bottom", needed)
    config:saveSetting("audiobook_overlay_margin_locked", true)
    local cfg = document and document.configurable
    if cfg then
        cfg.b_page_margin = needed
    end
    pcall(function() config:flush() end)
    dlog("overlay-margin", "docsettings-copt", "needed", needed, "was", copt)
end

--- Pin the overlay mini-bar and restore the last sentence (highlighted,
--- audio armed, not playing) so Play continues from there.
function Audiobook:onReaderReady()
    if not self._init_ok or not self.media_sync then return end
    if not self:getSetting("keep_media_overlay_bar", false) then return end
    if not (self.ui and self.ui.rolling and self.ui.document) then return end
    local ds = self.ui.doc_settings
    local locked = ds and ds:readSetting("audiobook_overlay_margin_locked")
    if not locked and not self:_hasMediaOverlays() then return end
    local delay = locked and 0.2 or 0.9
    UIManager:scheduleIn(delay, function()
        if not self.ui or not self.ui.document then return end
        if not self:getSetting("keep_media_overlay_bar", false) then return end
        pcall(function() self:_restoreAlignedOverlaySession() end)
    end)
end

function Audiobook:_restoreAlignedOverlaySession()
    local doc_path = self.ui.document.file_path or self.ui.document.file
    if not doc_path or not self.media_sync then return end
    -- Already armed for this EPUB (play-from-here, or a previous restore).
    if self._smil_doc_path == doc_path
        and self.media_sync.media_engine
        and self.media_sync.media_engine.current_path then
        pcall(function() self.media_sync:pinOverlayChrome() end)
        return
    end
    if not self:_hasMediaOverlays() then
        pcall(function() self.media_sync:pinOverlayChrome() end)
        return
    end
    self:_startSmilPlayback(doc_path, nil, true, { prepare_only = true })
end

function Audiobook:onCloseDocument()
    logger.warn("Audiobook: onCloseDocument event received")
    -- Re-assert the overlay inset into the sidecar before ReaderConfig writes
    -- copt_* (SaveSettings fires before CloseDocument, so this only covers
    -- paths that bypassed it). Dropping chrome must not restore the original
    -- bottom margin while keep-bar is on.
    if self.media_sync then
        pcall(function() self.media_sync:_persistLockedOverlayMargin() end)
    end
    -- Do NOT stop the session recorder here: opening a new book from the
    -- file browser fires CloseDocument, and the user expects the recording
    -- to persist across book changes. The recorder still stops on suspend,
    -- sleep-cover close, or explicit Stop.
    self:stopReadAlong({ drop_chrome = true })
end

-- Safety net: if UIManager tears down the widget tree (exit, doc switch)
-- without CloseDocument firing first, force-stop everything.
function Audiobook:onCloseWidget()
    logger.warn("Audiobook: onCloseWidget event received")
    -- Do NOT stop the session recorder here for the same reason as above:
    -- widget teardown can happen when switching documents, and we want the
    -- recording to continue.
    self:stopReadAlong({ drop_chrome = true })
    if self._init_ok then
        self:_removeSleepCoverOverride()
    end
end

--[[--
Install custom SleepCoverClosed/Opened handlers.
When "keep playing on lid close" is enabled AND audio is playing, the
override prevents the device from entering full hardware suspend so
audio continues uninterrupted.  When the setting is off (or audio isn't
playing), the original KOReader handlers are called normally.
--]]
function Audiobook:_installSleepCoverOverride()
    if self._orig_sleep_cover_closed then return end  -- already installed

    -- Only install on devices that actually have SleepCover support
    if not UIManager.event_handlers
            or not UIManager.event_handlers.SleepCoverClosed then
        return
    end

    -- Save original handlers
    self._orig_sleep_cover_closed = UIManager.event_handlers.SleepCoverClosed
    self._orig_sleep_cover_opened = UIManager.event_handlers.SleepCoverOpened

    local plugin = self

    UIManager.event_handlers.SleepCoverClosed = function()
        -- Stop any active session recording when the cover closes.
        if plugin.session_recorder then
            pcall(function() plugin.session_recorder:stop() end)
        end
        -- Check if anything is playing (TTS or media file)
        local is_playing = false
        if plugin.sync_controller and (plugin.sync_controller:isPlaying() or plugin.sync_controller:isPaused()) then
            is_playing = true
        end
        if plugin.media_sync and (plugin.media_sync:isPlaying() or plugin.media_sync:isPaused()) then
            is_playing = true
        end
        -- If "keep playing" is on AND we're actively playing, prevent suspend
        if plugin:getSetting("keep_playing_on_lid_close", false) and is_playing then
            if Device.is_cover_closed ~= nil then
                Device.is_cover_closed = true
            end
            plugin._prevented_lid_suspend = true
            logger.warn("Audiobook: SleepCover closed — keeping audio alive (suspend prevented)")
            return
        end
        -- Setting off or not playing: use original KOReader behavior
        if plugin._orig_sleep_cover_closed then
            plugin._orig_sleep_cover_closed()
        end
    end

    UIManager.event_handlers.SleepCoverOpened = function()
        if Device.is_cover_closed ~= nil then
            Device.is_cover_closed = false
        end
        if plugin._prevented_lid_suspend then
            -- We blocked suspend on close, so there's nothing to resume from
            plugin._prevented_lid_suspend = false
            logger.warn("Audiobook: SleepCover opened — no resume needed (suspend was prevented)")
            return
        end
        -- Normal resume path
        if plugin._orig_sleep_cover_opened then
            plugin._orig_sleep_cover_opened()
        end
    end

    logger.dbg("Audiobook: SleepCover override installed")
end

--[[--
Restore original SleepCover handlers.
Called on plugin teardown to leave KOReader in a clean state.
--]]
function Audiobook:_removeSleepCoverOverride()
    if not self._orig_sleep_cover_closed then return end

    if UIManager.event_handlers then
        UIManager.event_handlers.SleepCoverClosed = self._orig_sleep_cover_closed
        UIManager.event_handlers.SleepCoverOpened = self._orig_sleep_cover_opened
    end
    self._orig_sleep_cover_closed = nil
    self._orig_sleep_cover_opened = nil
    self._prevented_lid_suspend = nil
    logger.dbg("Audiobook: SleepCover override removed")
end

-- Handle screen rotation: pause TTS, rebuild the PlaybackBar for the new
-- screen dimensions, then resume.
-- NOTE: SetDimensions is dispatched via self.ui:handleEvent() which only
-- reaches reader plugins — standalone UIManager widgets like PlaybackBar
-- never receive it.  We must explicitly tell the bar to rebuild here.
function Audiobook:onSetRotationMode()
    if not self._init_ok then return end
    local Device = require("device")
    local Screen = Device.screen
    local mode = Screen:getScreenMode()
    local cur_w, cur_h = Screen:getWidth(), Screen:getHeight()
    logger.warn("Audiobook: onSetRotationMode — mode=", mode,
        "dims=", cur_w, "x", cur_h,
        "rotation=", Screen.getRotationMode and Screen:getRotationMode() or "?")
    -- Handle media playback overlay rotation.
    -- AudiobookPlayer also catches SetRotationMode via its own handleEvent,
    -- but we pass explicit dims here (Screen is already updated in this context).
    local media_bar = self.media_sync and self.media_sync.playback_bar
    logger.warn("Audiobook: onSetRotationMode — media_bar=", media_bar and "Y" or "N",
        "visible=", media_bar and media_bar.visible or "N/A",
        "minimized=", media_bar and media_bar._minimized or "N/A")
    if media_bar and media_bar.visible then
        local media_playing = self.media_sync:isPlaying()
        if media_playing then
            self.media_sync:pause()
        end
        logger.warn("Audiobook: calling media_bar:onSetDimensions(", cur_w, "x", cur_h, ")")
        media_bar:onSetDimensions({ w = cur_w, h = cur_h })
        if media_playing then
            UIManager:scheduleIn(0.5, function()
                if self.media_sync and self.media_sync:isPaused() then
                    self.media_sync:resume()
                end
            end)
        end
        return
    end

    -- Handle TTS PlaybackBar rotation
    local was_playing = self.sync_controller and self.sync_controller:isPlaying()
    if was_playing then
        self.sync_controller:pause()
    end
    local bar = self.sync_controller and self.sync_controller.playback_bar
    if bar and bar.visible then
        bar:onSetDimensions()
    end
    if was_playing then
        UIManager:scheduleIn(0.5, function()
            if self.sync_controller and self.sync_controller:isPaused() then
                self.sync_controller:resume()
            end
        end)
    end
end

-- Settings management
function Audiobook:getSetting(key, default)
    local settings = G_reader_settings:readSetting("audiobook_settings") or {}
    if settings[key] ~= nil then
        return settings[key]
    end
    return default
end

function Audiobook:setSetting(key, value)
    local settings = G_reader_settings:readSetting("audiobook_settings") or {}
    settings[key] = value
    G_reader_settings:saveSetting("audiobook_settings", settings)
    -- Force an immediate disk flush so the value survives a crash or forced
    -- restart (e.g. the chapter-list crash that triggered issue #38).
    if G_reader_settings and G_reader_settings.flush then
        G_reader_settings:flush()
    end
end

function Audiobook:toggleSetting(key, default)
    local current = self:getSetting(key, default or false)
    self:setSetting(key, not current)
end

--[[--
Delete all plugin settings from KOReader's persistent storage.
Called by KOReader's "Delete plugin settings" UI action.
--]]
function Audiobook:deletePluginSettings()
    G_reader_settings:delSetting("audiobook_settings")
    -- Reset in-memory state to defaults
    self.current_speed = 1.0
    self.current_pitch = 1.0
    self.current_volume = 1.0
    self.tts_engine_type = "espeak"
    self.voice = nil
    self.highlight_style = "background"
end

-- ---------------------------------------------------------------------------
-- Persistent SMIL xpointer cache
-- ---------------------------------------------------------------------------
--
-- crengine does not expose a reliable "go to file#id" API from Lua.  The
-- workaround is to capture the full internal xpointer for a fragment the
-- first time it is highlighted during normal playback, save it to KOReader
-- settings, and reuse it later for resume/refocus/Play-from-here.

-- Build a stable cache key for a fragment.  The key includes the EPUB path
-- so different books do not collide.
function Audiobook:_smilXPointerCacheKey(doc_path, text_doc, fragment_id)
    if not doc_path or not fragment_id then return nil end
    local fragment_key = fragment_id
    if text_doc and text_doc ~= "" then
        fragment_key = text_doc .. "#" .. fragment_id
    end
    return doc_path .. "|" .. fragment_key
end

-- Load the persisted xpointer cache for the current EPUB.
function Audiobook:_loadSmilXPointerCache(doc_path)
    if not doc_path then return {} end
    local all = self:getSetting("smil_xpointer_cache", {})
    local book_cache = all[doc_path] or {}
    local copy = {}
    for k, v in pairs(book_cache) do
        copy[k] = v
    end
    logger.warn("Audiobook: loaded", self:_countTable(copy), "SMIL xpointer entries for", doc_path:match("([^/]+)$"))
    return copy
end

-- Save the in-memory xpointer cache back to KOReader settings.
function Audiobook:_saveSmilXPointerCache(doc_path, cache)
    if not doc_path or not cache then return end
    local all = self:getSetting("smil_xpointer_cache", {})
    all[doc_path] = cache
    self:setSetting("smil_xpointer_cache", all)
end

-- Count entries in a table for logging.
function Audiobook:_countTable(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- ---------------------------------------------------------------------------
-- Audiobookshelf integration
-- ---------------------------------------------------------------------------

--[[--
Build the Audiobookshelf submenu.
Loads absbrowse.lua dynamically to avoid plugin load failures.
--]]
function Audiobook:_buildAudiobookshelfMenu()
    local ABSBrowse
    local pp = self.path and (self.path .. "/") or "./"
    pcall(function()
        ABSBrowse = dofile(pp .. "absbrowse.lua")
    end)
    if ABSBrowse and ABSBrowse.buildMainMenu then
        return ABSBrowse.buildMainMenu(self)
    end
    return {{
        text = _("Audiobookshelf modules not available."),
        enabled = false,
    }}
end

--[[--
Play a cached Audiobookshelf item.
Handles resume prompt and delegates to _doPlayAudioFile with ABS metadata.
@param item_id string  ABS item ID
@param audio_path string  Local audio file path
@param metadata table  {title, author, narrator, duration, chapters, cover_path}
--]]
function Audiobook:_playAbsItem(item_id, audio_path, metadata)
    if not audio_path or not self.media_sync then
        return
    end

    -- Update "last played" settings
    self:setSetting("abs_last_item_id", item_id)
    self:setSetting("abs_last_library_id", metadata and metadata.library_id or "")

    -- Check for saved position (from local audio_positions or ABS sync)
    local saved_pos = nil
    local saved_time = nil

    -- First check local saved position
    local local_pos, local_time = self:_getSavedPosition(audio_path)
    if local_pos and local_pos > 30 then
        saved_pos = local_pos
        saved_time = local_time
    end

    -- If we have ABS sync, also check remote position
    if self._abs_sync then
        local ABSClient
        local pp = self.path and (self.path .. "/") or "./"
        pcall(function()
            ABSClient = dofile(pp .. "absclient.lua")
        end)
        if ABSClient then
            local server_url = self:getSetting("abs_server_url", "")
            local token = self:getSetting("abs_api_token", "")
            if server_url ~= "" and token ~= "" then
                local client = ABSClient:new{ server_url = server_url, token = token }
                local remote_pos, err = self._abs_sync:getRemotePosition(client, item_id)
                if remote_pos and remote_pos > 30 then
                    -- Use remote position if it's newer (we don't have timestamps for local_pos here,
                    -- so prefer remote when it's significantly ahead)
                    if not saved_pos or math.abs(remote_pos - saved_pos) > 60 then
                        saved_pos = remote_pos
                        saved_time = os.time()
                    end
                end
            end
        end
    end

    if saved_pos and saved_pos > 30 then
        local ConfirmBox = require("ui/widget/confirmbox")
        local book_title = metadata and metadata.title
            or audio_path:match("([^/]+)%.[^./]+$") or audio_path:match("([^/]+)$") or _("Unknown book")
        local chapter_title = self:_findChapterTitle(metadata and metadata.chapters, saved_pos)
        local lines = {
            T(_("Resume from %1?"), self:_formatAudioTime(saved_pos)),
            "",
            T(_("Book: %1"), book_title),
        }
        if chapter_title then
            table.insert(lines, T(_("Chapter: %1"), chapter_title))
        end
        table.insert(lines, "")
        table.insert(lines, T(_("Last played: %1"), os.date("%Y-%m-%d %H:%M", saved_time or os.time())))
        UIManager:show(ConfirmBox:new{
            text = table.concat(lines, "\n"),
            ok_text = _("Resume"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                self:_doPlayAudioFile(audio_path, nil, saved_pos, item_id, metadata)
            end,
            cancel_callback = function() end,
            other_buttons = {{
                {
                    text = _("From start"),
                    callback = function()
                        self:_clearPosition(audio_path)
                        self:_doPlayAudioFile(audio_path, nil, 0, item_id, metadata)
                    end,
                },
            }},
        })
        return
    end

    self:_doPlayAudioFile(audio_path, nil, 0, item_id, metadata)
end

--[[--
Start the periodic ABS sync timer.
Flushes progress updates to the server every 60 seconds.
--]]
function Audiobook:_startAbsSyncTimer()
    if self._abs_sync_timer_running then
        return
    end
    self._abs_sync_timer_running = true

    local function tick()
        if not self._abs_sync_timer_running then
            return
        end
        if self._abs_sync then
            -- Record current playback position if an ABS item is playing
            if self.media_sync and self.media_sync._abs_item_id
                    and (self.media_sync:isPlaying() or self.media_sync:isPaused()) then
                local ok_pos, pos = pcall(function()
                    return self.media_sync.media_engine and self.media_sync.media_engine:getPosition()
                end)
                local ok_path, path = pcall(function()
                    return self.media_sync.media_engine and self.media_sync.media_engine.current_path
                end)
                if ok_pos and ok_path and pos and path then
                    self:_savePosition(path, pos)
                    self._abs_sync:recordProgress(
                        self.media_sync._abs_item_id,
                        path, pos,
                        self.media_sync._abs_duration or 0,
                        false
                    )
                end
            end

            -- Flush pending updates to ABS
            local ABSClient
            local pp = self.path and (self.path .. "/") or "./"
            pcall(function()
                ABSClient = dofile(pp .. "absclient.lua")
            end)
            if ABSClient then
                local server_url = self:getSetting("abs_server_url", "")
                local token = self:getSetting("abs_api_token", "")
                if server_url ~= "" and token ~= "" then
                    local client = ABSClient:new{ server_url = server_url, token = token }
                    self._abs_sync:flush(client)
                end
            end
        end
        -- Reschedule in 60 seconds
        UIManager:scheduleIn(60, tick)
    end
    UIManager:scheduleIn(60, tick)
end

return Audiobook
