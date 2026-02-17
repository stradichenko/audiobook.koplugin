--[[--
Playback Control Bar Widget
Shows play/pause, rewind, forward, and close controls at the bottom of the screen.

@module playbackbar
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local logger = require("logger")
local _ = require("gettext")

local PlaybackBar = InputContainer:extend{
    width = nil,
    height = nil,
    plugin = nil,
    sync_controller = nil,
    is_playing = true,
    current_word = "",
    progress = 0,
    -- Mark as toast so UIManager never blocks events to widgets below us.
    -- Toast widgets receive events but never become the exclusive "top_widget".
    toast = true,
    -- Callbacks from sync_controller
    on_play_pause = nil,
    on_rewind = nil,
    on_forward = nil,
    on_close = nil,
    on_realign = nil,
}

function PlaybackBar:init()
    self.width = self.width or Screen:getWidth()
    self.height = self.height or Screen:scaleBySize(80)
    
    self.dimen = Geom:new{
        w = self.width,
        h = self.height,
    }
    
    self:setupUI()
end

function PlaybackBar:setupUI()
    local button_width = Screen:scaleBySize(60)
    local button_height = Screen:scaleBySize(40)
    local button_font_size = 20
    local spacing = Size.padding.large
    
    -- Rewind button (previous paragraph)
    self.rewind_button = Button:new{
        text = "⏮",
        width = button_width,
        max_width = button_width,
        height = button_height,
        text_font_size = button_font_size,
        callback = function()
            self:onRewind()
        end,
        hold_callback = function()
            self:onRewindHold()
        end,
        bordersize = Size.border.button,
        radius = Size.radius.button,
        show_parent = self,
    }
    
    -- Play/Pause button
    self.play_pause_button = Button:new{
        text = self.is_playing and "⏸" or "▶",
        width = button_width,
        max_width = button_width,
        height = button_height,
        text_font_size = button_font_size,
        callback = function()
            self:onPlayPause()
        end,
        bordersize = Size.border.button,
        radius = Size.radius.button,
        show_parent = self,
    }
    
    -- Forward button (next paragraph)
    self.forward_button = Button:new{
        text = "⏭",
        width = button_width,
        max_width = button_width,
        height = button_height,
        text_font_size = button_font_size,
        callback = function()
            self:onForward()
        end,
        hold_callback = function()
            self:onForwardHold()
        end,
        bordersize = Size.border.button,
        radius = Size.radius.button,
        show_parent = self,
    }
    
    -- Re-align button (go to the page currently being read)
    self.realign_button = Button:new{
        text = "📌",
        width = button_width,
        max_width = button_width,
        height = button_height,
        text_font_size = button_font_size,
        callback = function()
            self:onRealign()
        end,
        bordersize = Size.border.button,
        radius = Size.radius.button,
        show_parent = self,
    }

    -- Close button
    self.close_button = Button:new{
        text = "✕",
        width = button_width,
        max_width = button_width,
        height = button_height,
        text_font_size = button_font_size,
        callback = function()
            self:onClose()
        end,
        bordersize = Size.border.button,
        radius = Size.radius.button,
        show_parent = self,
    }
    
    -- Current word display
    self.word_display = TextWidget:new{
        text = self.current_word or _("Starting..."),
        face = Font:getFace("cfont", 16),
        max_width = self.width - button_width * 5 - spacing * 7,
        truncate_left = true,
    }
    
    -- Progress bar
    self.progress_bar = ProgressWidget:new{
        width = self.width - Size.padding.large * 2,
        height = Screen:scaleBySize(6),
        percentage = self.progress / 100,
        ticks = nil,
        tick_width = 0,
        last = nil,
    }
    
    -- Button row
    local button_row = HorizontalGroup:new{
        align = "center",
        self.rewind_button,
        HorizontalSpan:new{ width = spacing },
        self.play_pause_button,
        HorizontalSpan:new{ width = spacing },
        self.forward_button,
        HorizontalSpan:new{ width = spacing },
        self.realign_button,
        HorizontalSpan:new{ width = spacing * 2 },
        self.close_button,
    }
    
    -- Main layout
    local content = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = Size.padding.small },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.word_display:getSize().h },
            self.word_display,
        },
        VerticalSpan:new{ width = Size.padding.small },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.progress_bar:getSize().h },
            self.progress_bar,
        },
        VerticalSpan:new{ width = Size.padding.default },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = button_height },
            button_row,
        },
        VerticalSpan:new{ width = Size.padding.small },
    }
    
    -- Frame with background
    self[1] = FrameContainer:new{
        width = self.width,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.thin,
        padding = 0,
        content,
    }
    
    -- Position at bottom of screen
    self.dimen = self[1]:getSize()
    self.dimen.x = 0
    self.dimen.y = Screen:getHeight() - self.dimen.h
end

function PlaybackBar:onPlayPause()
    if self.on_play_pause then
        self.on_play_pause()
    elseif self.plugin then
        if self.is_playing then
            self.plugin:pauseReadAlong()
        else
            self.plugin:resumeReadAlong()
        end
    end
end

function PlaybackBar:onRewind()
    if self.on_rewind then
        self.on_rewind()
    elseif self.plugin and self.plugin.sync_controller then
        self.plugin.sync_controller:prevSentence()
    end
end

function PlaybackBar:onRewindHold()
    -- Rewind multiple paragraphs on hold
    for _ = 1, 3 do
        self:onRewind()
    end
end

function PlaybackBar:onForward()
    if self.on_forward then
        self.on_forward()
    elseif self.plugin and self.plugin.sync_controller then
        self.plugin.sync_controller:nextSentence()
    end
end

function PlaybackBar:onForwardHold()
    -- Forward multiple paragraphs on hold
    for _ = 1, 3 do
        self:onForward()
    end
end

function PlaybackBar:onRealign()
    if self.on_realign then
        self.on_realign()
    end
end

function PlaybackBar:onClose()
    if self.on_close then
        self.on_close()
    elseif self.plugin then
        self.plugin:stopReadAlong()
    end
end

function PlaybackBar:updatePlayPauseButton()
    local new_text = self.is_playing and "⏸" or "▶"
    self.play_pause_button:setText(new_text, self.play_pause_button.width)
    UIManager:setDirty(self, function()
        return "ui", self.play_pause_button.dimen
    end)
end

function PlaybackBar:updateCurrentWord(word)
    if word and word ~= self.current_word then
        self.current_word = word
        self.word_display:setText(word)
        UIManager:setDirty(self, function()
            return "ui", self.word_display.dimen
        end)
    end
end

function PlaybackBar:updateProgress(progress)
    if progress ~= self.progress then
        self.progress = progress
        self.progress_bar:setPercentage(progress / 100)
        UIManager:setDirty(self, function()
            return "ui", self.progress_bar.dimen
        end)
    end
end

function PlaybackBar:setPlaying(is_playing)
    if is_playing ~= self.is_playing then
        self.is_playing = is_playing
        self:updatePlayPauseButton()
    end
end

function PlaybackBar:updatePlayState(is_playing)
    self:setPlaying(is_playing)
end

function PlaybackBar:show()
    self.visible = true
    self.dimen.x = 0
    self.dimen.y = Screen:getHeight() - self.dimen.h
    UIManager:show(self, "ui", nil, self.dimen.x, self.dimen.y)
end

function PlaybackBar:hide()
    self.visible = false
    UIManager:close(self)
end

function PlaybackBar:isVisible()
    return self.visible
end

function PlaybackBar:onCloseWidget()
    -- Clean up when widget closes
end

--[[--
Handle screen dimension changes (e.g. after device rotation).
Rebuild the bar layout with the new screen width and reposition at the
new bottom edge.
--]]
function PlaybackBar:onSetDimensions()
    if not self.visible then return end
    logger.warn("PlaybackBar: onSetDimensions, new screen =", Screen:getWidth(), "x", Screen:getHeight())
    -- Preserve current playback state across the rebuild
    local was_playing = self.is_playing
    local word = self.current_word
    local progress = self.progress
    -- Remove from UIManager so the old x,y coordinates are discarded
    UIManager:close(self)
    -- Re-derive width and height from the (potentially rotated) screen
    self.width = Screen:getWidth()
    self.height = Screen:scaleBySize(80)
    -- Rebuild the UI tree with new dimensions
    self:setupUI()
    -- Restore state into the fresh widgets
    self.is_playing = was_playing
    self.current_word = word
    self.progress = progress
    self:updatePlayPauseButton()
    if word and word ~= "" then self.word_display:setText(word) end
    self.progress_bar:setPercentage(progress / 100)
    -- Re-show at the correct position — this registers the new x,y
    -- with UIManager so paintTo receives the right coordinates.
    self:show()
    UIManager:setDirty(self, "ui")
    return true
end

--- Override handleEvent so that we only consume tap gestures within
--- our bar area.  Swipe/pan gestures are ALWAYS passed through so the
--- bottom-swipe ConfigMenu activation works even when the bar is visible.
function PlaybackBar:handleEvent(event)
    local arg1 = event.args and event.args[1]
    if event.handler == "onGesture" or (type(arg1) == "table" and arg1.ges) then
        -- This is a gesture event from GestureDetector
        local ges = type(arg1) == "table" and arg1 or nil
        if ges and (ges.ges == "swipe" or ges.ges == "pan" or ges.ges == "hold" or ges.ges == "hold_pan") then
            -- Let swipe/pan/hold pass through unconditionally
            return false
        end
    end
    -- For taps and everything else, use standard InputContainer dispatch
    return InputContainer.handleEvent(self, event)
end

function PlaybackBar:paintTo(bb, x, y)
    -- Toast widgets are painted on top of everything. To let menus/dialogs
    -- appear above us, skip painting when any non-toast widget besides the
    -- base reader is in the UIManager window stack.
    if self:_isOverlayActive() then
        return
    end
    if self[1] and self[1].paintTo then
        self[1]:paintTo(bb, x or 0, y or self.dimen.y)
    end
end

--- Check if any menu or dialog sits between us and the base reader.
-- In normal operation there is exactly 1 non-toast widget (the reader).
-- When a menu/dialog opens, there are 2+.
function PlaybackBar:_isOverlayActive()
    local stack = UIManager._window_stack
    if not stack then return false end
    local non_toast = 0
    for i = 1, #stack do
        if not stack[i].widget.toast then
            non_toast = non_toast + 1
            if non_toast > 1 then
                return true
            end
        end
    end
    return false
end

return PlaybackBar
