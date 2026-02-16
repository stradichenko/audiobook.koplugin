--[[--
Audiobook TTS Plugin with Word Highlight Sync Read-Along
Provides text-to-speech with synchronized word highlighting.

@module koplugin.audiobook
--]]

local BD = require("ui/bidi")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

-- Get plugin directory for relative requires
local function getPluginPath()
    local callerSource = debug.getinfo(1, "S").source
    if callerSource:find("^@") then
        return callerSource:gsub("^@(.*/)[^/]*", "%1")
    end
    return "./"
end
local PLUGIN_PATH = getPluginPath()

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
        text = _("🔊 Audiobook Read-Along"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("▶ Start reading from current page"),
                callback = function()
                    self:startReadAlong()
                end,
            },
            {
                text = _("⏹ Stop reading"),
                callback = function()
                    self:stopReadAlong()
                end,
                enabled_func = function()
                    return self.sync_controller:isPlaying() or self.sync_controller:isPaused()
                end,
            },
            {
                text = _("⏸ Pause/Resume"),
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
                text = "――――――――――",
                enabled = false,
            },
            {
                text_func = function()
                    return T(_("Speech rate: %1x"), self:getSetting("speech_rate", 1.0))
                end,
                sub_item_table = self:buildSpeechRateMenu(),
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
                sub_item_table = self:buildHighlightStyleMenu(),
            },
            {
                text = "――――――――――",
                enabled = false,
            },
            {
                text = _("Auto-advance pages"),
                checked_func = function()
                    return self:getSetting("auto_advance", true)
                end,
                callback = function()
                    self:toggleSetting("auto_advance")
                end,
            },
            {
                text = _("Highlight words"),
                checked_func = function()
                    return self:getSetting("highlight_words", true)
                end,
                callback = function()
                    self:toggleSetting("highlight_words")
                end,
            },
            {
                text = _("Highlight sentences"),
                checked_func = function()
                    return self:getSetting("highlight_sentences", true)
                end,
                callback = function()
                    self:toggleSetting("highlight_sentences")
                end,
            },
            {
                text = "――――――――――",
                enabled = false,
            },
            {
                text_func = function()
                    return self:btMenuLabel()
                end,
                sub_item_table_func = function()
                    return self:buildBluetoothMenu()
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
        text = _("🔊 Read aloud from here"),
        font_bold = false,
        callback = function()
            local word = dict_popup.word or dict_popup.lookupword
            UIManager:close(dict_popup)
            UIManager:scheduleIn(0.1, function()
                plugin:startReadAlongFromWord(word)
            end)
        end,
    }})
end

function Audiobook:buildSpeechRateMenu()
    local rates = {0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0}
    local menu = {}
    
    for _, rate in ipairs(rates) do
        table.insert(menu, {
            text = string.format("%.2fx", rate),
            checked_func = function()
                return self:getSetting("speech_rate", 1.0) == rate
            end,
            callback = function()
                self:setSetting("speech_rate", rate)
                self.tts_engine:setRate(rate)
            end,
        })
    end
    
    return menu
end

function Audiobook:buildHighlightStyleMenu()
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
                return self:getSetting("highlight_style", "background") == style.id
            end,
            callback = function()
                self:setSetting("highlight_style", style.id)
                self.highlight_manager:setStyle(style.id)
            end,
        })
    end
    
    return menu
end

--- Top-level label for the Bluetooth menu entry.
-- Shows connected device name when available.
function Audiobook:btMenuLabel()
    local bt = self.bt_manager
    if not bt:isPowered() then
        return _("⚫ Bluetooth (off)")
    end
    -- Find a connected device to show its name
    local devices = bt:listAudioDevices()
    for _i, dev in ipairs(devices) do
        if dev.connected then
            local dname = dev.name ~= "" and dev.name or dev.address
            return T(_("🔵 BT: %1"), dname)
        end
    end
    -- Powered but nothing connected
    local saved = self:getSetting("bt_device_name", nil)
    if saved then
        return T(_("🔵 BT: %1 (not connected)"), saved)
    end
    return _("🔵 Bluetooth (on — no device)")
end

function Audiobook:buildBluetoothMenu()
    local bt = self.bt_manager
    local powered = bt:isPowered()
    local menu = {}

    -- Power toggle
    table.insert(menu, {
        text = powered and _("⏻ Turn Bluetooth off") or _("⏻ Turn Bluetooth on"),
        callback = function()
            if powered then
                bt:powerOff()
                self:setSetting("bt_device_addr", nil)
                UIManager:show(InfoMessage:new{
                    text = _("Bluetooth turned off."),
                    timeout = 2,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = _("Turning Bluetooth on…"),
                    timeout = 1,
                })
                local ok = bt:powerOn()
                UIManager:show(InfoMessage:new{
                    text = ok and _("Bluetooth is on.") or _("Failed to power on Bluetooth."),
                    timeout = 2,
                })
            end
        end,
    })

    if not powered then
        return menu
    end

    table.insert(menu, {
        text = "――――――――――",
        enabled = false,
    })

    -- Scan for devices
    table.insert(menu, {
        text = _("🔍 Scan for new devices…"),
        callback = function()
            self:btScanAndShow()
        end,
    })

    table.insert(menu, {
        text = "――――――――――",
        enabled = false,
    })

    -- List known / visible devices — single-tap to connect
    local devices = bt:listAudioDevices()
    if #devices == 0 then
        table.insert(menu, {
            text = _("No devices found. Tap Scan above."),
            enabled = false,
        })
    end
    for _, dev in ipairs(devices) do
        local label = dev.name ~= "" and dev.name or dev.address
        local icon = "  "
        if dev.connected then
            icon = "🔗 "
        elseif dev.paired then
            icon = "✓ "
        end
        table.insert(menu, {
            text = icon .. label,
            -- Tap = connect (or disconnect if already connected)
            callback = function()
                self:btQuickConnect(dev)
            end,
            -- Hold = show more actions (forget, info)
            hold_callback = function(touchmenu_instance)
                self:btDeviceHoldMenu(dev, touchmenu_instance)
            end,
            checked_func = function()
                return dev.connected
            end,
        })
    end

    return menu
end

--- Quick connect/disconnect: tap on a device row in the BT menu.
function Audiobook:btQuickConnect(dev)
    local bt = self.bt_manager
    local name = dev.name ~= "" and dev.name or dev.address

    if dev.connected then
        -- Already connected → disconnect
        bt:disconnect(dev.address)
        self:setSetting("bt_device_addr", nil)
        self:setSetting("bt_device_name", nil)
        UIManager:show(InfoMessage:new{
            text = T(_("Disconnected from %1."), name),
            timeout = 2,
        })
        return
    end

    -- Connecting
    UIManager:show(InfoMessage:new{
        text = T(_("Connecting to %1…"), name),
        timeout = 1,
    })
    UIManager:scheduleIn(0.3, function()
        -- Pair first if needed
        if not dev.paired then
            local ok, err = bt:pair(dev.address)
            if not ok then
                UIManager:show(InfoMessage:new{
                    text = T(_("Pairing failed: %1"), err or "unknown"),
                    timeout = 4,
                })
                return
            end
        end
        local ok, err = bt:connect(dev.address)
        if ok then
            -- Remember this as the preferred device
            self:setSetting("bt_device_addr", dev.address)
            self:setSetting("bt_device_name", name)
            UIManager:show(InfoMessage:new{
                text = T(_("Connected to %1."), name),
                timeout = 2,
            })
        else
            UIManager:show(InfoMessage:new{
                text = T(_("Connection failed: %1"), err or "unknown"),
                timeout = 3,
            })
        end
    end)
end

--- Long-press on a device row: show additional actions.
function Audiobook:btDeviceHoldMenu(dev, touchmenu_instance)
    local bt = self.bt_manager
    local name = dev.name ~= "" and dev.name or dev.address
    local ButtonDialog = require("ui/widget/buttondialog")

    local buttons = {}

    if dev.connected then
        table.insert(buttons, {{
            text = _("Disconnect"),
            callback = function()
                UIManager:close(self._bt_dialog)
                bt:disconnect(dev.address)
                self:setSetting("bt_device_addr", nil)
                self:setSetting("bt_device_name", nil)
                UIManager:show(InfoMessage:new{
                    text = T(_("Disconnected from %1."), name),
                    timeout = 2,
                })
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        }})
    else
        table.insert(buttons, {{
            text = _("Connect"),
            callback = function()
                UIManager:close(self._bt_dialog)
                self:btQuickConnect(dev)
                if touchmenu_instance then
                    UIManager:scheduleIn(4, function()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end)
                end
            end,
        }})
    end

    if dev.paired then
        table.insert(buttons, {{
            text = _("Forget (un-pair)"),
            callback = function()
                UIManager:close(self._bt_dialog)
                bt:remove(dev.address)
                if dev.address == self:getSetting("bt_device_addr", nil) then
                    self:setSetting("bt_device_addr", nil)
                    self:setSetting("bt_device_name", nil)
                end
                UIManager:show(InfoMessage:new{
                    text = T(_("Removed %1."), name),
                    timeout = 2,
                })
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        }})
    end

    table.insert(buttons, {{
        text = T(_("%1"), dev.address),
        enabled = false,
    }})

    table.insert(buttons, {{
        text = _("Cancel"),
        callback = function()
            UIManager:close(self._bt_dialog)
        end,
    }})

    self._bt_dialog = ButtonDialog:new{
        title = name,
        buttons = buttons,
    }
    UIManager:show(self._bt_dialog)
end

function Audiobook:btScanAndShow()
    local bt = self.bt_manager

    -- Ensure powered
    if not bt:isPowered() then
        local ok = bt:powerOn()
        if not ok then
            UIManager:show(InfoMessage:new{
                text = _("Could not power on Bluetooth."),
                timeout = 3,
            })
            return
        end
    end

    UIManager:show(InfoMessage:new{
        text = _("Scanning for Bluetooth devices…\n\nPlease wait 8 seconds."),
        timeout = 2,
    })

    -- Run the scan in a deferred callback so the InfoMessage can render
    UIManager:scheduleIn(0.5, function()
        bt:startDiscovery()
        -- Wait for scan results, then stop and show device list
        UIManager:scheduleIn(8, function()
            bt:stopDiscovery()
            local devices = bt:listAudioDevices()
            local lines = {}
            for _, dev in ipairs(devices) do
                local tag = ""
                if dev.connected then
                    tag = " 🔗"
                elseif dev.paired then
                    tag = " ✓"
                end
                local name = dev.name ~= "" and dev.name or dev.address
                table.insert(lines, name .. tag)
            end
            if #lines == 0 then
                table.insert(lines, _("No audio devices found."))
            end
            UIManager:show(InfoMessage:new{
                text = _("Scan complete:\n\n") .. table.concat(lines, "\n")
                    .. _("\n\nOpen the Bluetooth menu to connect."),
                timeout = 6,
            })
        end)
    end)
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
    
    -- Show starting notification with TTS info
    local backend_name = self.tts_engine.backend or "unknown"
    UIManager:show(InfoMessage:new{
        text = string.format(_("Starting read-along...\n\nUsing: %s\nText: %d characters"), backend_name, #page_text),
        timeout = 2,
    })
    
    self.sync_controller:start(page_text)
end

function Audiobook:startReadAlongFromWord(word)
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
        -- Find first occurrence of the word (escape special pattern chars)
        local pattern = word:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
        start_pos = page_text:find(pattern)
        logger.dbg("Audiobook: Looking for word:", word, "found at:", start_pos)
    end
    
    -- If we couldn't find the word, just start from beginning
    if not start_pos then
        logger.dbg("Audiobook: Word not found, starting from beginning")
        start_pos = 1
    end
    
    -- Start reading from the found position
    self:startReadAlong(page_text, start_pos)
end

function Audiobook:stopReadAlong()
    logger.dbg("Audiobook: Stopping read-along")
    self.sync_controller:stop()
    self.highlight_manager:clearHighlights()
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
        -- Trim to last complete sentence so we don't cut mid-word at page boundary.
        -- Find the last sentence-ending punctuation (.?!) followed by whitespace or end.
        local last_end = nil
        for pos in text:gmatch("()[%.%?!]%s") do
            last_end = pos  -- pos is the index of the punctuation mark
        end
        -- Also check if text ends with sentence-ending punctuation
        if text:match("[%.%?!]%s*$") then
            last_end = #text
        end
        if last_end and last_end < #text and last_end > 20 then
            -- Trim: keep up to and including the punctuation mark
            text = text:sub(1, last_end):match("^(.-)%s*$")  -- also strip trailing space
            logger.dbg("Audiobook: Trimmed to last sentence end at pos", last_end)
        end
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
-- This lets the user interact with menus without TTS talking over them.
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

function Audiobook:toggleSetting(key)
    local current = self:getSetting(key, false)
    self:setSetting(key, not current)
end

return Audiobook
