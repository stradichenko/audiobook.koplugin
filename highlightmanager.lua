--[[--
Highlight Manager Module
Manages visual highlighting of text during TTS playback.
Uses KOReader's built-in highlight system for e-ink friendly display.

@module highlightmanager
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local Screen = Device.screen

local HighlightManager = {
    -- Highlight styles
    STYLES = {
        UNDERLINE = "underline",
        BACKGROUND = "background",
        BOX = "box",
        INVERT = "invert",
    },
}

function HighlightManager:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    
    o.current_style = o.style or self.STYLES.INVERT
    o.current_highlight_rect = nil
    o.highlight_drawer = nil
    o.is_highlighting = false
    
    return o
end

--[[--
Set the highlight style.
@param style string The style to use
--]]
function HighlightManager:setStyle(style)
    self.current_style = style
    if self.plugin then
        self.plugin:setSetting("highlight_style", style)
    end
    logger.dbg("HighlightManager: Style set to", style)
end

--[[--
Get the settings menu for highlight styles.
@return table Menu items
--]]
function HighlightManager:getStyleMenu()
    local menu = {}
    local style_names = {
        { id = "invert", name = _("Invert (best for e-ink)") },
        { id = "underline", name = _("Underline") },
        { id = "box", name = _("Box") },
        { id = "background", name = _("Background") },
    }
    
    for _, style in ipairs(style_names) do
        table.insert(menu, {
            text = style.name,
            checked_func = function()
                return self.current_style == style.id
            end,
            callback = function()
                self:setStyle(style.id)
            end,
        })
    end
    
    return menu
end

--[[--
Highlight a word based on its position in the text.
For now, we'll use a simple overlay approach.
@param word table Word object with text and position info
@param parsed_data table Full parsed text data  
--]]
function HighlightManager:highlightWord(word, parsed_data)
    if not word then
        return
    end
    
    -- Clear previous highlight
    self:clearHighlights()
    
    -- Store current word for reference
    self.current_word = word
    self.is_highlighting = true
    
    -- Try to find word position on screen using document API
    local rect = self:findWordOnScreen(word)
    
    if rect then
        self.current_highlight_rect = rect
        self:drawHighlight(rect)
    else
        -- Fallback: just log that we couldn't find position
        logger.dbg("HighlightManager: Could not find screen position for word:", word.text)
    end
end

--[[--
Try to find the word position on screen.
@param word table Word object
@return table|nil Rectangle {x, y, w, h} or nil
--]]
function HighlightManager:findWordOnScreen(word)
    if not self.ui or not self.ui.document then
        return nil
    end
    
    local doc = self.ui.document
    
    -- Method 1: Try using document's word position lookup
    if doc.getScreenPositionFromCharPos then
        local ok, pos = pcall(doc.getScreenPositionFromCharPos, doc, word.start_pos)
        if ok and pos then
            -- Estimate width based on word length
            local char_width = Screen:scaleBySize(10)
            return {
                x = pos.x,
                y = pos.y,
                w = #word.text * char_width,
                h = Screen:scaleBySize(24),
            }
        end
    end
    
    -- Method 2: For PDF documents with word boxes
    if doc.getPageBoxes then
        local page = doc:getCurrentPage()
        if page then
            local ok, boxes = pcall(doc.getPageBoxes, doc, page, "word")
            if ok and boxes then
                -- Search for matching word in boxes
                for _, box in ipairs(boxes) do
                    if box.word and box.word:find(word.clean_text, 1, true) then
                        return {
                            x = box.x0,
                            y = box.y0,
                            w = box.x1 - box.x0,
                            h = box.y1 - box.y0,
                        }
                    end
                end
            end
        end
    end
    
    -- Can't determine position - highlighting may not be visible
    return nil
end

--[[--
Draw highlight rectangle on screen.
@param rect table Rectangle {x, y, w, h}
--]]
function HighlightManager:drawHighlight(rect)
    if not rect then
        return
    end
    
    -- Create a highlight overlay using KOReader's mechanism
    local style = self.current_style
    
    -- Schedule a partial screen refresh to show the highlight
    UIManager:setDirty("all", function()
        -- Get the screen framebuffer
        local fb = Screen.fb
        if fb then
            local x, y, w, h = rect.x, rect.y, rect.w, rect.h
            
            -- Apply different highlight styles
            if style == self.STYLES.INVERT then
                -- Invert the region - most visible on e-ink
                fb:invertRect(x, y, w, h)
            elseif style == self.STYLES.UNDERLINE then
                -- Draw underline
                local line_y = y + h - 2
                fb:paintRect(x, line_y, w, 3, Blitbuffer.COLOR_BLACK)
            elseif style == self.STYLES.BOX then
                -- Draw border box
                local border = 2
                fb:paintRect(x, y, w, border, Blitbuffer.COLOR_BLACK) -- top
                fb:paintRect(x, y + h - border, w, border, Blitbuffer.COLOR_BLACK) -- bottom
                fb:paintRect(x, y, border, h, Blitbuffer.COLOR_BLACK) -- left
                fb:paintRect(x + w - border, y, border, h, Blitbuffer.COLOR_BLACK) -- right
            elseif style == self.STYLES.BACKGROUND then
                -- Fill with gray
                fb:paintRect(x, y, w, h, Blitbuffer.COLOR_LIGHT_GRAY)
            end
        end
        
        return "ui", Geom:new(rect)
    end)
end

--[[--
Highlight a sentence on the page.
@param sentence table Sentence object with position info
@param parsed_data table Full parsed text data
--]]
function HighlightManager:highlightSentence(sentence, parsed_data)
    -- For now, just highlight the first word of the sentence
    if sentence and sentence.words and #sentence.words > 0 then
        self:highlightWord(sentence.words[1], parsed_data)
    end
end

--[[--
Clear all highlights.
--]]
function HighlightManager:clearHighlights()
    if self.current_highlight_rect then
        -- Request refresh to clear the highlight
        local rect = self.current_highlight_rect
        UIManager:setDirty("all", function()
            return "ui", Geom:new(rect)
        end)
        self.current_highlight_rect = nil
    end
    
    self.current_word = nil
    self.is_highlighting = false
end

--[[--
Clear word highlight.
--]]
function HighlightManager:clearWordHighlight()
    self:clearHighlights()
end

--[[--
Clear sentence highlight.
--]]
function HighlightManager:clearSentenceHighlight()
    -- Currently same as clearHighlights
end

--[[--
Get current highlight style.
@return string Current style
--]]
function HighlightManager:getStyle()
    return self.current_style
end

--[[--
Check if highlights are currently shown.
@return boolean
--]]
function HighlightManager:hasHighlights()
    return self.is_highlighting
end

--[[--
Update highlight for word being spoken.
Called frequently during playback.
@param word table Word object
@param sentence table Sentence object (optional)
@param parsed_data table Full parsed data
--]]
function HighlightManager:updateHighlight(word, sentence, parsed_data)
    if not word then
        return
    end
    
    -- Only update if word changed
    if self.current_word and self.current_word.index == word.index then
        return
    end
    
    self:highlightWord(word, parsed_data)
end

return HighlightManager
