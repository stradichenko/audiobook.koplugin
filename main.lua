--[[--
Audiobook TTS Plugin with Word Highlight Sync Read-Along
Provides text-to-speech with synchronized word highlighting.

@module koplugin.audiobook
--]]

local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

-- Shared utility modules (DRY: eliminates duplicated getPluginPath, commandExists)
local _utils_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local Utils = dofile(_utils_dir .. "utils.lua")
local MenuBuilder = dofile(_utils_dir .. "menubuilder.lua")
local BtUI = dofile(_utils_dir .. "btui.lua")
local PLUGIN_PATH = _utils_dir

local Audiobook = WidgetContainer:extend{
    name = "audiobook",
    is_doc_only = true,
}

function Audiobook:init()
    -- Load submodules from plugin directory
    local TextParser = dofile(PLUGIN_PATH .. "textparser.lua")
    local TTSEngine = dofile(PLUGIN_PATH .. "ttsengine.lua")
    local HighlightManager = dofile(PLUGIN_PATH .. "highlightmanager.lua")
    local SyncController = dofile(PLUGIN_PATH .. "synccontroller.lua")
    self.bt_manager = dofile(PLUGIN_PATH .. "btmanager.lua")
    
    self.text_parser = TextParser:new()
    self.tts_engine = TTSEngine:new{
        plugin = self,
        plugin_dir = PLUGIN_PATH:sub(1, -2), -- strip trailing slash
    }
    -- Restore saved TTS backend selection (if user explicitly chose one)
    local saved_backend = self:getSetting("tts_backend", nil)
    if saved_backend then
        self.tts_engine:setBackend(saved_backend)
    end
    -- Restore saved voice settings
    self.tts_engine:setRate(self:getSetting("speech_rate", 1.0))
    self.tts_engine:setPitch(self:getSetting("speech_pitch", 50))
    self.tts_engine:setVolume(self:getSetting("speech_volume", 1.0))
    -- Compose full voice id: base accent + optional variant (e.g. "en-us+f1")
    local voice_base = self:getSetting("tts_voice", "en")
    local voice_variant = self:getSetting("tts_voice_variant", "")
    local full_voice = voice_base
    if voice_variant ~= "" then
        full_voice = voice_base .. "+" .. voice_variant
    end
    self.tts_engine:setVoice(full_voice)
    self.tts_engine:setWordGap(self:getSetting("word_gap", 2))
    self.tts_engine:setClausePause(self:getSetting("clause_pause", 0))
    -- Restore Piper-specific settings
    local piper_model = self:getSetting("piper_model", nil)
    if piper_model then
        self.tts_engine:setPiperModel(piper_model)
    end
    self.tts_engine:setPiperSpeaker(self:getSetting("piper_speaker", 0))
    self.tts_engine._gap_test_mode = self:getSetting("gap_test_mode", false)
    self.highlight_manager = HighlightManager:new{
        plugin = self,
        ui = self.ui,
    }
    self.sync_controller = SyncController:new{
        plugin = self,
        tts_engine = self.tts_engine,
        highlight_manager = self.highlight_manager,
        text_parser = self.text_parser,
    }
    
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
end

function Audiobook:onDispatcherRegisterActions()
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

function Audiobook:addToMainMenu(menu_items)
    menu_items.audiobook = {
        text = _("Audiobook Read-Along"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Start reading from current page"),
                callback = function()
                    self:startReadAlong()
                end,
            },
            {
                text = _("Stop reading"),
                callback = function()
                    self:stopReadAlong()
                end,
                enabled_func = function()
                    return self.sync_controller:isPlaying() or self.sync_controller:isPaused()
                end,
            },
            {
                text = _("Pause/Resume"),
                callback = function()
                    if self.sync_controller:isPlaying() then
                        self:pauseReadAlong()
                    elseif self.sync_controller:isPaused() then
                        self:resumeReadAlong()
                    end
                end,
                enabled_func = function()
                    return self.sync_controller:isPlaying() or self.sync_controller:isPaused()
                end,
            },
            {
                text_func = function()
                    if self.tts_engine.backend == self.tts_engine.BACKENDS.PIPER then
                        local model_label = self:getSetting("piper_model_label", "default")
                        return T(_("Voice settings (Piper — %1)"), model_label)
                    end
                    local voice_label = self:getSetting("tts_voice_label", "English (GB)")
                    local variant_label = self:getSetting("tts_variant_label", "")
                    if variant_label ~= "" and variant_label ~= "Default (male)" then
                        voice_label = voice_label .. " — " .. variant_label
                    end
                    return T(_("Voice settings (%1)"), voice_label)
                end,
                sub_item_table_func = function()
                    return MenuBuilder.buildVoiceSettingsMenu(self)
                end,
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
                sub_item_table = MenuBuilder.buildHighlightStyleMenu(self),
            },
            {
                text = _("Auto-advance pages"),
                checked_func = function()
                    return self:getSetting("auto_advance", true)
                end,
                callback = function()
                    self:toggleSetting("auto_advance", true)
                end,
            },
            {
                text = _("Highlight words"),
                checked_func = function()
                    return self:getSetting("highlight_words", true)
                end,
                callback = function()
                    self:toggleSetting("highlight_words", true)
                end,
            },
            {
                text = _("Highlight sentences"),
                checked_func = function()
                    return self:getSetting("highlight_sentences", true)
                end,
                callback = function()
                    self:toggleSetting("highlight_sentences", true)
                end,
            },
            {
                text = _("Quick start with espeak (while Piper loads)"),
                checked_func = function()
                    return self:getSetting("espeak_cold_start", true)
                end,
                callback = function()
                    self:toggleSetting("espeak_cold_start", true)
                end,
                enabled_func = function()
                    return self.tts_engine.backend == self.tts_engine.BACKENDS.PIPER
                        and self.tts_engine.espeak_bin ~= nil
                end,
            },
            {
                text_func = function()
                    local val = self:getSetting("bt_disconnect_check", 30)
                    if val == 0 then
                        return _("BT disconnect alert: off")
                    end
                    return T(_("BT disconnect alert: %1s"), val)
                end,
                sub_item_table = BtUI.buildBTDisconnectMenu(self),
            },
            {
                text_func = function()
                    return BtUI.btMenuLabel(self)
                end,
                sub_item_table_func = function()
                    return BtUI.buildBluetoothMenu(self)
                end,
            },
        },
    }
end

--- Hook into dictionary popup to add "Read aloud from here" button
function Audiobook:onDictButtonsReady(dict_popup, buttons)
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
end

function Audiobook:startReadAlong(text, start_pos)
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
            text = _("No TTS engine found.\n\nPlease install espeak-ng:\n\nOn Kobo: See README for instructions"),
            timeout = 5,
        })
        return
    end

    -- If we're using Bluetooth audio, start a lightweight watcher that
    -- will notify the user if all audio BT devices disconnect while
    -- read-along is active.  This runs infrequently and only while the
    -- plugin is in use to avoid extra battery drain.
    pcall(function()
        -- Ensure audio_player_type is initialized
        if not self.tts_engine.audio_player_type then
            self.tts_engine:findAudioPlayer()
        end
        if self.tts_engine.audio_player_type == "gst-bt" then
            BtUI.startWatcher(self)
        end
    end)

    self.sync_controller:start(page_text)
end

function Audiobook:startReadAlongFromWord(word, context)
    local page_text = self:getCurrentPageText()
    if not page_text or page_text == "" then
        -- Try to get text from the dictionary lookup context instead
        if self.ui.highlight and self.ui.highlight.selected_text then
            local selected = self.ui.highlight.selected_text
            -- Get surrounding context
            if selected.text then
                page_text = selected.text
            end
        end
    end
    
    if not page_text or page_text == "" then
        UIManager:show(InfoMessage:new{
            text = _("Could not retrieve page text. This document type may not be supported yet."),
            timeout = 3,
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

function Audiobook:stopReadAlong()
    logger.dbg("Audiobook: Stopping read-along")
    pcall(function() BtUI.stopWatcher(self) end)
    pcall(function() self.sync_controller:stop() end)
    pcall(function() self.highlight_manager:clearHighlights() end)
    -- Always kill orphan audio processes, even if we think we're not playing.
    -- A stale gst-launch-1.0 holding the BT socket can destabilize the
    -- system when Nickel resumes after KOReader exits.
    pcall(function() self.tts_engine:forceKillAll() end)
end

function Audiobook:pauseReadAlong()
    self.sync_controller:pause()
end

function Audiobook:resumeReadAlong()
    self.sync_controller:resume()
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
    self:stopReadAlong()
    return true
end

-- NOTE: onPageUpdate intentionally removed.
-- Our SyncController manages page flow via advanceToNextPage().
-- Having onPageUpdate here caused an infinite restart loop:
-- highlight → screen refresh → PageUpdate → updateText → stop audio → restart → highlight → ...

-- Auto-pause TTS when any KOReader menu or popup opens.
-- NOTE: ShowConfigMenu event is consumed by ReaderConfig before reaching us,
-- so onShowConfigMenu may never fire. The PlaybackBar handles its own
-- visibility via paintTo (checks for overlay widgets in the stack).
function Audiobook:onShowReaderMenu()
    if self.sync_controller:isPlaying() then
        self._paused_by_menu = true
        self.sync_controller:pause()
    end
end

function Audiobook:onCloseReaderMenu()
    if self._paused_by_menu then
        self._paused_by_menu = false
        if self.sync_controller:isPaused() then
            self.sync_controller:resume()
        end
    end
end

-- Also pause for the config/bottom menu
function Audiobook:onShowConfigMenu()
    if self.sync_controller:isPlaying() then
        self._paused_by_menu = true
        self.sync_controller:pause()
    end
end

function Audiobook:onCloseConfigMenu()
    if self._paused_by_menu then
        self._paused_by_menu = false
        if self.sync_controller:isPaused() then
            self.sync_controller:resume()
        end
    end
end

-- Pause on device suspend (sleep)
function Audiobook:onSuspend()
    if self.sync_controller:isPlaying() then
        self._paused_by_menu = true
        self.sync_controller:pause()
    end
end

function Audiobook:onResume()
    if self._paused_by_menu then
        self._paused_by_menu = false
        if self.sync_controller:isPaused() then
            self.sync_controller:resume()
        end
    end
end

function Audiobook:onCloseDocument()
    self:stopReadAlong()
end

-- Safety net: if UIManager tears down the widget tree (exit, doc switch)
-- without CloseDocument firing first, force-stop everything.
function Audiobook:onCloseWidget()
    self:stopReadAlong()
end

-- Handle screen rotation: pause TTS, rebuild the PlaybackBar for the new
-- screen dimensions, then resume.
-- NOTE: SetDimensions is dispatched via self.ui:handleEvent() which only
-- reaches reader plugins — standalone UIManager widgets like PlaybackBar
-- never receive it.  We must explicitly tell the bar to rebuild here.
function Audiobook:onSetRotationMode()
    local Device = require("device")
    local Screen = Device.screen
    local mode = Screen:getScreenMode()
    local cur_w, cur_h = Screen:getWidth(), Screen:getHeight()
    logger.warn("Audiobook: onSetRotationMode — mode=", mode,
        "dims=", cur_w, "x", cur_h,
        "rotation=", Screen.getRotationMode and Screen:getRotationMode() or "?")
    local was_playing = self.sync_controller:isPlaying()
    if was_playing then
        self.sync_controller:pause()
    end
    -- Rebuild the PlaybackBar for the new screen size.
    -- Screen dimensions have already been updated by ReaderView before
    -- this event reaches us.
    local bar = self.sync_controller and self.sync_controller.playback_bar
    if bar and bar.visible then
        bar:onSetDimensions()
    end
    if was_playing then
        -- Resume after a short delay to let the rotation redraw settle
        UIManager:scheduleIn(0.5, function()
            if self.sync_controller:isPaused() then
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
end

function Audiobook:toggleSetting(key, default)
    local current = self:getSetting(key, default or false)
    self:setSetting(key, not current)
end

return Audiobook
