--[[--
Highlight Manager Module
Manages visual highlighting of text during TTS playback.

@module highlightmanager
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local HighlightManager = WidgetContainer:extend{
    -- Highlight styles
    STYLES = {
        UNDERLINE = "underline",
        BACKGROUND = "background",
        BOX = "box",
        INVERT = "invert",
    },
    
    -- Default colors (for color screens)
    COLORS = {
        WORD_HIGHLIGHT = Blitbuffer.COLOR_YELLOW,
        SENTENCE_HIGHLIGHT = Blitbuffer.COLOR_LIGHT_GRAY,
    },
}

function HighlightManager:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    
    o.current_style = o.style or self.STYLES.BACKGROUND
    o.highlights = {}
    o.word_highlight = nil
    o.sentence_highlight = nil
    o.highlight_layer = nil
    
    return o
end

--[[--
Initialize the highlight manager.
--]]
function HighlightManager:init()
    self:createHighlightLayer()
end

--[[--
Create the overlay layer for highlights.
--]]
function HighlightManager:createHighlightLayer()
    if not self.ui or not self.ui.document then
        return
    end
    
    -- Create an overlay widget for highlights
    self.highlight_layer = WidgetContainer:new{
        dimen = Geom:new{
            x = 0,
            y = 0,
            w = self.ui.dimen.w,
            h = self.ui.dimen.h,
        },
    }
end

--[[--
Get the settings menu for highlight styles.
@return table Menu items
--]]
function HighlightManager:getStyleMenu()
    local menu = {}
    
    for name, style in pairs(self.STYLES) do
        table.insert(menu, {
            text = _(name:gsub("^%l", string.upper):gsub("_", " ")),
            checked_func = function()
                return self.current_style == style
            end,
            callback = function()
                self:setStyle(style)
            end,
        })
    end
    
    return menu
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
Highlight a word on the page.
@param word table Word object with position info
@param parsed_data table Full parsed text data
--]]
function HighlightManager:highlightWord(word, parsed_data)
    if not word then
        return
    end
    
    -- Clear previous word highlight
    self:clearWordHighlight()
    
    -- Get word positions on screen
    local positions = self:getTextPositions(word.start_pos, word.end_pos)
    if not positions or #positions == 0 then
        logger.dbg("HighlightManager: Could not find word positions for:", word.text)
        return
    end
    
    -- Create highlight based on style
    self.word_highlight = self:createHighlight(positions, "word")
    
    -- Draw the highlight
    self:drawHighlight(self.word_highlight)
    
    logger.dbg("HighlightManager: Highlighted word:", word.text)
end

--[[--
Highlight a sentence on the page.
@param sentence table Sentence object with position info
@param parsed_data table Full parsed text data
--]]
function HighlightManager:highlightSentence(sentence, parsed_data)
    if not sentence then
        return
    end
    
    -- Clear previous sentence highlight
    self:clearSentenceHighlight()
    
    -- Get sentence positions on screen
    local positions = self:getTextPositions(sentence.start_pos, sentence.end_pos)
    if not positions or #positions == 0 then
        logger.dbg("HighlightManager: Could not find sentence positions")
        return
    end
    
    -- Create highlight based on style
    self.sentence_highlight = self:createHighlight(positions, "sentence")
    
    -- Draw the highlight
    self:drawHighlight(self.sentence_highlight)
    
    logger.dbg("HighlightManager: Highlighted sentence:", sentence.index)
end

--[[--
Get screen positions for a text range.
@param start_pos number Start character position
@param end_pos number End character position
@return table Array of position rectangles
--]]
function HighlightManager:getTextPositions(start_pos, end_pos)
    if not self.ui or not self.ui.document then
        return {}
    end
    
    local positions = {}
    
    -- Try to get character positions from document
    local doc = self.ui.document
    
    -- Different document types have different APIs
    if doc.getTextFromPositions then
        -- For EPUB/HTML documents with text layer
        local page = doc:getCurrentPage()
        local char_boxes = doc:getPageTextBoxes(page)
        
        if char_boxes then
            -- Find boxes that overlap with our text range
            for _, box in ipairs(char_boxes) do
                if box.pos >= start_pos and box.pos <= end_pos then
                    table.insert(positions, {
                        x = box.x0,
                        y = box.y0,
                        w = box.x1 - box.x0,
                        h = box.y1 - box.y0,
                    })
                end
            end
        end
    elseif doc.getWordFromPosition then
        -- For PDF documents
        -- This is more complex and requires mapping character positions to words
        local page = doc:getCurrentPage()
        local text = doc:getPageText(page)
        
        -- Estimate position based on text layout
        positions = self:estimateTextPositions(text, start_pos, end_pos)
    end
    
    -- If no positions found, create estimated positions
    if #positions == 0 then
        positions = self:estimateTextPositions(nil, start_pos, end_pos)
    end
    
    return self:mergeAdjacentPositions(positions)
end

--[[--
Estimate text positions when document doesn't provide them.
@param text string The full page text (optional)
@param start_pos number Start character position
@param end_pos number End character position
@return table Array of position rectangles
--]]
function HighlightManager:estimateTextPositions(text, start_pos, end_pos)
    if not self.ui then
        return {}
    end
    
    -- Get page dimensions
    local screen = self.ui.dimen or Geom:new{w = 600, h = 800}
    
    -- Estimate character dimensions
    local char_width = 10  -- approximate
    local line_height = 24 -- approximate
    local margin_x = 40
    local margin_y = 60
    local chars_per_line = math.floor((screen.w - 2 * margin_x) / char_width)
    
    -- Calculate positions
    local positions = {}
    local current_pos = start_pos
    
    while current_pos <= end_pos do
        local line = math.floor(current_pos / chars_per_line)
        local col = current_pos % chars_per_line
        
        local x = margin_x + col * char_width
        local y = margin_y + line * line_height
        
        -- How many characters until end of word or end of line
        local chars_to_end = math.min(end_pos - current_pos + 1, chars_per_line - col)
        
        table.insert(positions, {
            x = x,
            y = y,
            w = chars_to_end * char_width,
            h = line_height,
        })
        
        current_pos = current_pos + chars_to_end
    end
    
    return positions
end

--[[--
Merge adjacent position rectangles.
@param positions table Array of position rectangles
@return table Merged rectangles
--]]
function HighlightManager:mergeAdjacentPositions(positions)
    if #positions <= 1 then
        return positions
    end
    
    local merged = {}
    local current = positions[1]
    
    for i = 2, #positions do
        local next_pos = positions[i]
        
        -- Check if on same line and adjacent
        if current.y == next_pos.y and 
           math.abs((current.x + current.w) - next_pos.x) < 5 then
            -- Merge
            current.w = (next_pos.x + next_pos.w) - current.x
        else
            table.insert(merged, current)
            current = next_pos
        end
    end
    
    table.insert(merged, current)
    return merged
end

--[[--
Create highlight objects for positions.
@param positions table Array of position rectangles
@param highlight_type string "word" or "sentence"
@return table Highlight data
--]]
function HighlightManager:createHighlight(positions, highlight_type)
    local color = highlight_type == "word" 
        and self.COLORS.WORD_HIGHLIGHT 
        or self.COLORS.SENTENCE_HIGHLIGHT
    
    return {
        type = highlight_type,
        style = self.current_style,
        color = color,
        positions = positions,
        widgets = {},
    }
end

--[[--
Draw a highlight on screen.
@param highlight table Highlight data
--]]
function HighlightManager:drawHighlight(highlight)
    if not highlight or not highlight.positions then
        return
    end
    
    for _, pos in ipairs(highlight.positions) do
        self:drawHighlightRect(pos, highlight.style, highlight.color)
    end
    
    -- Request screen refresh
    UIManager:setDirty(self.ui, function()
        local refresh_region = self:getHighlightBounds(highlight)
        return "ui", refresh_region
    end)
end

--[[--
Draw a single highlight rectangle.
@param pos table Position rectangle {x, y, w, h}
@param style string Highlight style
@param color userdata Blitbuffer color
--]]
function HighlightManager:drawHighlightRect(pos, style, color)
    local fb = self.ui and self.ui.screen and self.ui.screen.fb
    if not fb then
        -- Fallback: use UIManager to get screen
        local Screen = require("device").screen
        if Screen then
            fb = Screen.fb
        end
    end
    
    if not fb then
        logger.dbg("HighlightManager: No framebuffer available")
        return
    end
    
    local rect = Geom:new{
        x = pos.x,
        y = pos.y,
        w = pos.w,
        h = pos.h,
    }
    
    if style == self.STYLES.BACKGROUND then
        -- Fill with semi-transparent color
        fb:paintRect(rect.x, rect.y, rect.w, rect.h, color)
    elseif style == self.STYLES.UNDERLINE then
        -- Draw underline
        local line_y = rect.y + rect.h - 2
        fb:paintRect(rect.x, line_y, rect.w, 2, Blitbuffer.COLOR_BLACK)
    elseif style == self.STYLES.BOX then
        -- Draw border
        local border = 2
        fb:paintRect(rect.x, rect.y, rect.w, border, Blitbuffer.COLOR_BLACK) -- top
        fb:paintRect(rect.x, rect.y + rect.h - border, rect.w, border, Blitbuffer.COLOR_BLACK) -- bottom
        fb:paintRect(rect.x, rect.y, border, rect.h, Blitbuffer.COLOR_BLACK) -- left
        fb:paintRect(rect.x + rect.w - border, rect.y, border, rect.h, Blitbuffer.COLOR_BLACK) -- right
    elseif style == self.STYLES.INVERT then
        -- Invert colors
        fb:invertRect(rect.x, rect.y, rect.w, rect.h)
    end
end

--[[--
Get bounding rectangle for a highlight.
@param highlight table Highlight data
@return table Geometry rectangle
--]]
function HighlightManager:getHighlightBounds(highlight)
    if not highlight or not highlight.positions or #highlight.positions == 0 then
        return nil
    end
    
    local min_x, min_y = math.huge, math.huge
    local max_x, max_y = 0, 0
    
    for _, pos in ipairs(highlight.positions) do
        min_x = math.min(min_x, pos.x)
        min_y = math.min(min_y, pos.y)
        max_x = math.max(max_x, pos.x + pos.w)
        max_y = math.max(max_y, pos.y + pos.h)
    end
    
    return Geom:new{
        x = min_x,
        y = min_y,
        w = max_x - min_x,
        h = max_y - min_y,
    }
end

--[[--
Clear word highlight.
--]]
function HighlightManager:clearWordHighlight()
    if self.word_highlight then
        self:eraseHighlight(self.word_highlight)
        self.word_highlight = nil
    end
end

--[[--
Clear sentence highlight.
--]]
function HighlightManager:clearSentenceHighlight()
    if self.sentence_highlight then
        self:eraseHighlight(self.sentence_highlight)
        self.sentence_highlight = nil
    end
end

--[[--
Clear all highlights.
--]]
function HighlightManager:clearHighlights()
    self:clearWordHighlight()
    self:clearSentenceHighlight()
    
    -- Request full refresh to clear any remaining artifacts
    if self.ui then
        UIManager:setDirty(self.ui, "partial")
    end
    
    logger.dbg("HighlightManager: Cleared all highlights")
end

--[[--
Erase a highlight from screen.
@param highlight table Highlight data
--]]
function HighlightManager:eraseHighlight(highlight)
    if not highlight then
        return
    end
    
    -- Request refresh for the highlight area
    local bounds = self:getHighlightBounds(highlight)
    if bounds and self.ui then
        UIManager:setDirty(self.ui, function()
            return "partial", bounds
        end)
    end
end

--[[--
Update highlight position after page scroll/zoom.
@param word table Current word object
@param sentence table Current sentence object
@param parsed_data table Full parsed data
--]]
function HighlightManager:updatePositions(word, sentence, parsed_data)
    if word then
        self:highlightWord(word, parsed_data)
    end
    if sentence and self.plugin and self.plugin:getSetting("highlight_sentences", false) then
        self:highlightSentence(sentence, parsed_data)
    end
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
    return self.word_highlight ~= nil or self.sentence_highlight ~= nil
end

return HighlightManager
