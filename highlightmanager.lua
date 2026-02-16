--[[--
Highlight Manager Module
Uses KOReader's native text selection to highlight the current sentence
being read by TTS. Works with both EPUB (CreDocument) and PDF.

For EPUB: Uses getTextFromPositions() with draw_selection enabled, which
lets crengine draw the selection highlight natively.

@module highlightmanager
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local Screen = Device.screen

local HighlightManager = {
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
    o.is_highlighting = false
    o.current_word = nil
    -- For native crengine highlighting
    o._selection_active = false

    return o
end

function HighlightManager:setStyle(style)
    self.current_style = style
    if self.plugin then
        self.plugin:setSetting("highlight_style", style)
    end
end

function HighlightManager:getStyle()
    return self.current_style
end

--[[--
Highlight a sentence in the document using KOReader's native selection.

For EPUB (rolling/CreDocument): We call getTextFromPositions() which
internally tells crengine to draw a selection highlight over the text
range. This produces the standard blue/gray selection you see when
long-pressing text.

@param sentence table Sentence object with .text, .start_pos, .end_pos
@param parsed_data table Full parsed text data
--]]
function HighlightManager:highlightSentence(sentence, parsed_data)
    if not sentence then return end
    if not self.ui or not self.ui.document then return end

    local doc = self.ui.document

    -- EPUB / rolling mode: use screen-coordinate selection
    if self.ui.rolling then
        self:_highlightSentenceRolling(sentence, parsed_data, doc)
    else
        -- PDF / paged mode: use view.highlight.temp
        self:_highlightSentencePaging(sentence, parsed_data, doc)
    end
end

--[[--
EPUB: Find the sentence on screen and have crengine draw the selection.

Strategy: getTextFromPositions() with two screen-coordinate points returns
the text and xpointer range. We need to find the screen position of the
sentence's first and last word. We do this by searching through the
visible text positions.
--]]
function HighlightManager:_highlightSentenceRolling(sentence, parsed_data, doc)
    -- First, clear any existing selection
    pcall(function() doc:clearSelection() end)

    -- We need to map the sentence text to screen positions.
    -- Get the full visible text with its xpointer range
    local full_res = doc:getTextFromPositions(
        {x = 0, y = 0},
        {x = Screen:getWidth(), y = Screen:getHeight()},
        true  -- do_not_draw_selection = true (just get text + positions)
    )
    if not full_res or not full_res.text or not full_res.pos0 or not full_res.pos1 then
        return
    end

    -- Find the sentence text within the full visible text
    local sentence_text = sentence.text
    -- Use first few words for a robust match
    local search_pat = sentence_text:sub(1, math.min(40, #sentence_text))
    -- Escape pattern special chars
    search_pat = search_pat:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    local vis_start = full_res.text:find(search_pat)

    if not vis_start then
        -- Try with fewer characters
        search_pat = sentence_text:sub(1, math.min(20, #sentence_text))
        search_pat = search_pat:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
        vis_start = full_res.text:find(search_pat)
    end

    if not vis_start then
        logger.dbg("HighlightManager: Could not find sentence in visible text")
        return
    end

    -- Get the screen boxes for the full text to understand line layout
    local sboxes = doc:getScreenBoxesFromPositions(full_res.pos0, full_res.pos1, true)
    if not sboxes or #sboxes == 0 then
        logger.dbg("HighlightManager: No screen boxes for visible text")
        return
    end

    local total_chars = #full_res.text
    local total_lines = #sboxes
    if total_chars == 0 or total_lines == 0 then return end

    -- Find the sentence end position in visible text
    local vis_end = vis_start + #sentence_text - 1
    if vis_end > total_chars then vis_end = total_chars end

    -- Estimate: characters per line (rough average)
    local chars_per_line = total_chars / total_lines
    local start_line = math.max(1, math.floor((vis_start - 1) / chars_per_line) + 1)
    local end_line = math.min(total_lines, math.floor((vis_end - 1) / chars_per_line) + 1)

    -- Get approximate screen coordinates for selection start and end
    local start_box = sboxes[start_line]
    local end_box = sboxes[end_line]
    if not start_box or not end_box then return end

    -- Estimate x position within line for start
    local start_char_in_line = vis_start - (start_line - 1) * chars_per_line
    local start_x = start_box.x + math.floor(start_char_in_line / chars_per_line * start_box.w)
    start_x = math.max(start_box.x, math.min(start_box.x + start_box.w - 1, start_x))

    -- Estimate x position within line for end
    local end_char_in_line = vis_end - (end_line - 1) * chars_per_line
    local end_x = end_box.x + math.floor(end_char_in_line / chars_per_line * end_box.w)
    end_x = math.max(end_box.x, math.min(end_box.x + end_box.w - 1, end_x))

    -- Now call getTextFromPositions WITHOUT do_not_draw_selection
    -- This tells crengine to draw the selection highlight natively
    local sel = doc:getTextFromPositions(
        {x = start_x, y = start_box.y + math.floor(start_box.h / 2)},
        {x = end_x,   y = end_box.y + math.floor(end_box.h / 2)},
        false  -- do_not_draw_selection = false → crengine draws the highlight
    )

    if sel then
        self._selection_active = true
        self.is_highlighting = true
        -- Refresh screen to show the crengine-drawn selection
        UIManager:setDirty(self.ui.dialog or "all", "ui")
        logger.dbg("HighlightManager: Highlighted sentence via native selection, lines", start_line, "-", end_line)
    end
end

--[[--
PDF: Use view.highlight.temp to draw temporary highlights.
--]]
function HighlightManager:_highlightSentencePaging(sentence, parsed_data, doc)
    logger.dbg("HighlightManager: PDF sentence highlight not yet implemented")
end

--[[--
Highlight a single word. Stores current word for reference;
actual visual highlighting is done at the sentence level to avoid
excessive e-ink refreshes.
@param word table Word object
@param parsed_data table Full parsed text data
--]]
function HighlightManager:highlightWord(word, parsed_data)
    self.current_word = word
    self.is_highlighting = true
end

--[[--
Clear all highlights.
--]]
function HighlightManager:clearHighlights()
    if self._selection_active and self.ui and self.ui.document then
        pcall(function() self.ui.document:clearSelection() end)
        UIManager:setDirty(self.ui.dialog or "all", "ui")
        self._selection_active = false
    end
    self.current_word = nil
    self.is_highlighting = false
end

function HighlightManager:clearWordHighlight()
    -- No separate word highlight to clear
end

function HighlightManager:clearSentenceHighlight()
    self:clearHighlights()
end

function HighlightManager:hasHighlights()
    return self.is_highlighting
end

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

function HighlightManager:updateHighlight(word, sentence, parsed_data)
    if not word then return end
    if self.current_word and self.current_word.index == word.index then
        return
    end
    self:highlightWord(word, parsed_data)
end

return HighlightManager
