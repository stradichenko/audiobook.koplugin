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
    
    self.text_parser = TextParser:new()
    self.tts_engine = TTSEngine:new{
        plugin = self,
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
                    return self:getSetting("highlight_sentences", false)
                end,
                callback = function()
                    self:toggleSetting("highlight_sentences")
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

function Audiobook:startReadAlong(text, start_pos)
    local page_text = text or self:getCurrentPageText()
    if not page_text or page_text == "" then
        UIManager:show(InfoMessage:new{
            text = _("Could not extract text from this page. The document format may not be fully supported."),
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
    
    -- Show starting notification
    UIManager:show(InfoMessage:new{
        text = _("Starting read-along..."),
        timeout = 1,
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
    
    -- Method 1: Use getFullPageText if available (PDF)
    if document.getFullPageText then
        local page = document:getCurrentPage()
        if page then
            local ok, result = pcall(document.getFullPageText, document, page)
            if ok and result then
                text = result
            end
        end
    end
    
    -- Method 2: Use getPageText if available
    if not text and document.getPageText then
        local page = document:getCurrentPage()
        if page then
            local ok, result = pcall(document.getPageText, document, page)
            if ok and result then
                text = result
            end
        end
    end
    
    -- Method 3: For EPUB/HTML - use ReaderView text extraction
    if not text and self.ui.view and self.ui.view.document then
        local view = self.ui.view
        if view.document.getFullPageText then
            local page = view.document:getCurrentPage()
            if page then
                local ok, result = pcall(view.document.getFullPageText, view.document, page)
                if ok and result then
                    text = result
                end
            end
        end
    end
    
    -- Method 4: Use text_widget's text if available (for EPUB)
    if not text and self.ui.document.getTextFromPositions then
        -- CreDocument (EPUB) - get text via selection interface
        local doc = self.ui.document
        -- Get the current page range
        local start_pos = 0
        local end_pos = doc:getDocumentProps().doc_pages or 10000
        
        if self.ui.rolling then
            -- Rolling mode - EPUB
            start_pos = doc:getCurrentPos()
            end_pos = start_pos + doc:getVisiblePageCount() * 2000 -- approximate chars per page
        end
        
        local ok, result = pcall(doc.getTextFromPositions, doc, start_pos, end_pos)
        if ok and result and result.text then
            text = result.text
        end
    end
    
    if text and text ~= "" then
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

function Audiobook:onPageUpdate()
    if self.sync_controller:isPlaying() and self:getSetting("auto_advance", true) then
        local page_text = self:getCurrentPageText()
        if page_text then
            self.sync_controller:updateText(page_text)
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
