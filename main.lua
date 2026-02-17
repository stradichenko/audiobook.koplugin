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
    self.tts_engine:setWordGap(self:getSetting("word_gap", 0))
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
                    local voice_label = self:getSetting("tts_voice_label", "English (GB)")
                    local variant_label = self:getSetting("tts_variant_label", "")
                    if variant_label ~= "" and variant_label ~= "Default (male)" then
                        voice_label = voice_label .. " — " .. variant_label
                    end
                    return T(_("Voice settings (%1)"), voice_label)
                end,
                sub_item_table_func = function()
                    return self:buildVoiceSettingsMenu()
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
                sub_item_table = self:buildHighlightStyleMenu(),
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

function Audiobook:buildVoiceSettingsMenu()
    local menu = {}

    -- Speech rate submenu
    table.insert(menu, {
        text_func = function()
            return T(_("Speech rate: %1x"), self:getSetting("speech_rate", 1.0))
        end,
        sub_item_table = self:buildSpeechRateMenu(),
    })

    -- Pitch submenu
    table.insert(menu, {
        text_func = function()
            return T(_("Pitch: %1"), self:getSetting("speech_pitch", 50))
        end,
        sub_item_table = self:buildPitchMenu(),
    })

    -- Volume submenu
    table.insert(menu, {
        text_func = function()
            return T(_("Volume: %1%%"), math.floor(self:getSetting("speech_volume", 1.0) * 100))
        end,
        sub_item_table = self:buildVolumeMenu(),
    })

    -- Pause between sentences (after . ? ! ; :)
    table.insert(menu, {
        text_func = function()
            return T(_("Sentence pause (. ? ! ; :): %1s"), self:getSetting("sentence_pause", 0.1))
        end,
        sub_item_table = self:buildSentencePauseMenu(),
    })

    -- Pause between paragraphs (at newlines)
    table.insert(menu, {
        text_func = function()
            return T(_("Paragraph pause (newlines): %1s"), self:getSetting("paragraph_pause", 0.8))
        end,
        sub_item_table = self:buildParagraphPauseMenu(),
    })

    -- Word gap (silence between words within a sentence)
    table.insert(menu, {
        text_func = function()
            return T(_("Word gap (between words): %1"), self:getSetting("word_gap", 0))
        end,
        sub_item_table = self:buildWordGapMenu(),
    })

    -- Voice / accent selection
    table.insert(menu, {
        text_func = function()
            return T(_("Voice: %1"), self:getSetting("tts_voice_label", "English (GB)"))
        end,
        sub_item_table = self:buildVoiceMenu(),
    })

    return menu
end

function Audiobook:buildSpeechRateMenu()
    local rates = {0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0}
    local menu = {}
    
    for _i, rate in ipairs(rates) do
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

function Audiobook:buildPitchMenu()
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
                return self:getSetting("speech_pitch", 50) == p
            end,
            callback = function()
                self:setSetting("speech_pitch", p)
                self.tts_engine:setPitch(p)
            end,
        })
    end
    return menu
end

function Audiobook:buildVolumeMenu()
    local volumes = {0.25, 0.50, 0.75, 1.0}
    local menu = {}
    for _i, v in ipairs(volumes) do
        table.insert(menu, {
            text = string.format("%d%%", math.floor(v * 100)),
            checked_func = function()
                return self:getSetting("speech_volume", 1.0) == v
            end,
            callback = function()
                self:setSetting("speech_volume", v)
                self.tts_engine:setVolume(v)
            end,
        })
    end
    return menu
end

function Audiobook:buildSentencePauseMenu()
    -- Pause after sentence-ending punctuation (.?!;:) within the same paragraph
    local values = {0, 0.05, 0.1, 0.15, 0.2, 0.3, 0.5, 0.8, 1.0}
    local menu = {}
    for _i, v in ipairs(values) do
        local label = string.format("%.2fs", v)
        if v == 0.1 then label = label .. _(" (default)") end
        table.insert(menu, {
            text = label,
            checked_func = function()
                return self:getSetting("sentence_pause", 0.1) == v
            end,
            callback = function()
                self:setSetting("sentence_pause", v)
            end,
        })
    end
    return menu
end

function Audiobook:buildParagraphPauseMenu()
    -- Pause at paragraph/newline boundaries
    local values = {0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.5, 2.0, 3.0}
    local menu = {}
    for _i, v in ipairs(values) do
        local label = string.format("%.1fs", v)
        if v == 0.8 then label = label .. _(" (default)") end
        table.insert(menu, {
            text = label,
            checked_func = function()
                return self:getSetting("paragraph_pause", 0.8) == v
            end,
            callback = function()
                self:setSetting("paragraph_pause", v)
            end,
        })
    end
    return menu
end

function Audiobook:buildWordGapMenu()
    -- espeak-ng word gap: extra silence (in units of 10ms) between words
    -- 0 = default (no extra gap), higher values slow down speech
    local values = {0, 1, 2, 5, 10, 20, 50}
    local labels = {
        [0] = _("0 (default — no extra gap)"),
        [1] = _("1 (10ms)"),
        [2] = _("2 (20ms)"),
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
                return self:getSetting("word_gap", 0) == v
            end,
            callback = function()
                self:setSetting("word_gap", v)
                self.tts_engine:setWordGap(v)
            end,
        })
    end
    return menu
end

function Audiobook:buildVoiceMenu()
    -- Voices are split into sections: accents (male base) and voice variants
    -- Voice variants use espeak-ng "+variant" syntax: e.g. "en+f1" = English GB female1
    local current_base = self:getSetting("tts_voice", "en")
    local current_variant = self:getSetting("tts_voice_variant", "")
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
                return self:getSetting("tts_voice", "en") == a.id
            end,
            callback = function()
                self:setSetting("tts_voice", a.id)
                self:setSetting("tts_voice_label", a.label)
                local var = self:getSetting("tts_voice_variant", "")
                local full = a.id
                if var ~= "" then full = a.id .. "+" .. var end
                self.tts_engine:setVoice(full)
            end,
        })
    end
    table.insert(menu, {
        text_func = function()
            return T(_("Accent: %1"), self:getSetting("tts_voice_label", "English (GB)"))
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
                    return self:getSetting("tts_voice_variant", "") == v.id
                end,
                callback = function()
                    self:setSetting("tts_voice_variant", v.id)
                    self:setSetting("tts_variant_label", v.label)
                    local base = self:getSetting("tts_voice", "en")
                    local full = base
                    if v.id ~= "" then full = base .. "+" .. v.id end
                    self.tts_engine:setVoice(full)
                end,
            })
        end
    end
    table.insert(menu, {
        text_func = function()
            return T(_("Voice type: %1"), self:getSetting("tts_variant_label", "Default (male)"))
        end,
        sub_item_table = variant_sub,
    })

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
        return _("Bluetooth (off)")
    end
    -- Find a connected device to show its name
    local devices = bt:listAudioDevices()
    for _i, dev in ipairs(devices) do
        if dev.connected then
            local dname = dev.name ~= "" and dev.name or dev.address
            return T(_("BT: %1"), dname)
        end
    end
    -- Powered but nothing connected
    local saved = self:getSetting("bt_device_name", nil)
    if saved then
        return T(_("BT: %1 (not connected)"), saved)
    end
    return _("Bluetooth (on)")
end

function Audiobook:buildBluetoothMenu()
    local bt = self.bt_manager
    local powered = bt:isPowered()
    local menu = {}

    -- Power toggle
    table.insert(menu, {
        text = powered and _("Turn Bluetooth off") or _("Turn Bluetooth on"),
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

    -- Scan for devices
    table.insert(menu, {
        text = _("Scan for new devices..."),
        callback = function()
            self:btScanAndShow()
        end,
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
            icon = "[*] "
        elseif dev.paired then
            icon = "✓ "
        end
        table.insert(menu, {
            text = icon .. label,
            -- Tap = connect (or disconnect if already connected)
            callback = function(touchmenu_instance)
                self:btQuickConnect(dev, touchmenu_instance)
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
function Audiobook:btQuickConnect(dev, touchmenu_instance)
    local bt = self.bt_manager
    local name = dev.name ~= "" and dev.name or dev.address

    if dev.connected then
        -- Already connected → disconnect
        bt:disconnect(dev.address)
        dev.connected = false  -- update captured state so checked_func refreshes
        self:setSetting("bt_device_addr", nil)
        self:setSetting("bt_device_name", nil)
        UIManager:show(InfoMessage:new{
            text = T(_("Disconnected from %1."), name),
            timeout = 2,
        })
        -- Menu auto-refreshes via checked_func after callback returns
        return
    end

    -- Connecting
    UIManager:show(InfoMessage:new{
        text = T(_("Connecting to %1…\nVerifying audio…"), name),
        timeout = 8,
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
            dev.paired = true
        end
        local ok, err = bt:connect(dev.address)
        if ok then
            dev.connected = true  -- update captured state
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
        -- Refresh the menu to show updated connection state
        if touchmenu_instance then
            touchmenu_instance:updateItems()
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
                    tag = " [*]"
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
