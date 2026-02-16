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
    -- Clear any existing selection
    pcall(function() doc:clearSelection() end)

    -- Get xpointer range for full visible text
    local full_res = doc:getTextFromPositions(
        {x = 0, y = 0},
        {x = Screen:getWidth(), y = Screen:getHeight()},
        true
    )
    if not full_res or not full_res.pos0 or not full_res.pos1 then
        return
    end

    local function ws(s) return s:gsub("%s+", " "):match("^%s*(.-)%s*$") end
    local sent_text = ws(sentence.text)
    if sent_text == "" then return end

    -- Get per-line screen boxes
    local sboxes = doc:getScreenBoxesFromPositions(full_res.pos0, full_res.pos1, true)
    if not sboxes or #sboxes == 0 then return end
    local n = #sboxes

    -- ── Build the visible text line-by-line ──
    -- Query each line individually and concatenate. This guarantees that
    -- our cumulative character offsets are perfectly aligned with the
    -- concatenated text we search through.
    local line_texts = {}   -- normalized text per line
    local built_text = ""   -- concatenated full text
    local cum = {[0] = 0}   -- cum[i] = char offset at END of line i in built_text

    for i = 1, n do
        local box = sboxes[i]
        local r = doc:getTextFromPositions(
            {x = box.x, y = box.y + math.floor(box.h / 2)},
            {x = box.x + box.w - 1, y = box.y + math.floor(box.h / 2)},
            true)
        local lt = (r and r.text) and ws(r.text) or ""
        line_texts[i] = lt
        if i > 1 and lt ~= "" then
            built_text = built_text .. " "
        end
        built_text = built_text .. lt
        cum[i] = #built_text
    end

    -- Find the sentence in our built text
    local vis_start = built_text:find(sent_text, 1, true)
    if not vis_start then
        -- Fall back to first 40 chars
        vis_start = built_text:find(sent_text:sub(1, math.min(40, #sent_text)), 1, true)
    end
    if not vis_start then
        logger.dbg("HighlightManager: sentence not found:",
            sent_text:sub(1, 50))
        return
    end
    local vis_end = vis_start + #sent_text - 1

    -- Find start and end lines
    local start_line = 1
    for i = 1, n do
        if cum[i] >= vis_start then
            start_line = i
            break
        end
    end

    local end_line = n
    for i = start_line, n do
        if cum[i] >= vis_end then
            end_line = i
            break
        end
    end

    local sb = sboxes[start_line]
    local eb = sboxes[end_line]
    if not sb or not eb then return end

    -- Estimate x within the start line
    local sl_total = cum[start_line] - cum[start_line - 1]
    local sl_off   = vis_start - cum[start_line - 1]
    local start_x
    if sl_total > 0 then
        start_x = sb.x + math.floor((sl_off / sl_total) * sb.w)
    else
        start_x = sb.x
    end
    start_x = math.max(sb.x, math.min(sb.x + sb.w - 1, start_x))

    -- Estimate x within the end line
    local el_total = cum[end_line] - cum[end_line - 1]
    local el_off   = vis_end - cum[end_line - 1]
    local end_x
    if el_total > 0 then
        end_x = eb.x + math.floor((el_off / el_total) * eb.w)
    else
        end_x = eb.x + eb.w
    end
    end_x = math.max(eb.x, math.min(eb.x + eb.w - 1, end_x))

    -- Draw the native crengine selection
    local sel = doc:getTextFromPositions(
        {x = start_x, y = sb.y + math.floor(sb.h / 2)},
        {x = end_x,   y = eb.y + math.floor(eb.h / 2)},
        false  -- draw selection
    )

    if sel then
        self._selection_active = true
        self.is_highlighting = true
        UIManager:setDirty(self.ui.dialog or "all", "ui")
        logger.dbg("HighlightManager: Highlighted lines", start_line, "-", end_line,
            "selected:", sel.text and sel.text:sub(1, 40) or "?")
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
