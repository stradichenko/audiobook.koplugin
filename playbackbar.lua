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
    -- Do NOT set toast = true.  Toast widgets cannot consume events: returning
    -- true from handleEvent has no effect and the reader below still receives
    -- the same tap, triggering its own gesture handler (showing the reader
    -- toolbar and hiding the playback bar).  As a non-toast widget we sit on
    -- top of the reader in the UIManager window stack and returning true from
    -- handleEvent actually stops propagation.  Swipe/hold/pan events are still
    -- passed through explicitly in handleEvent below.
    -- Callbacks from sync_controller
    on_play_pause = nil,
    on_rewind = nil,
    on_forward = nil,
    on_close = nil,
    on_realign = nil,
    on_volume_down = nil,
    on_volume_up = nil,
    on_speed_down = nil,
    on_speed_up = nil,
    -- Scrubber mode for audio file playback
    scrubber_mode = false,
    on_seek = nil,
    current_time_str = "",
    -- Show the progress row during TTS read-along.  Defaults to true (the
    -- long-standing behaviour); the user can turn it off to make the bar one
    -- row shorter, which on a rolling document is one more line of book text.
    -- Ignored in scrubber mode, where the bar is an interactive seek control.
    show_progress = true,
}

function PlaybackBar:init()
    self.width = self.width or Screen:getWidth()
    self.height = self.height or Screen:scaleBySize(100)
    
    self.dimen = Geom:new{
        w = self.width,
        h = self.height,
    }
    
    self:setupUI()
end

-- Buttons in the row: rewind, play/pause, forward, S-, S+, V-, V+, realign, close.
local BUTTON_COUNT = 9

function PlaybackBar:setupUI()
    local button_height = Screen:scaleBySize(40)
    local button_font_size = 20

    -- Size the buttons to the screen instead of hardcoding a width: the row
    -- now holds 9 buttons (S-/S+ and V-/V+ were added), which overflows a
    -- narrow screen at the old fixed 60px.  Fit them to the space actually
    -- available and cap at the original width on roomy screens.
    local row_spacing = Size.padding.default
    local row_inset = Size.padding.large * 2
    local avail = self.width - row_inset - row_spacing * (BUTTON_COUNT - 1)
    local button_width = math.floor(avail / BUTTON_COUNT)
    local max_button_width = Screen:scaleBySize(60)
    if button_width > max_button_width then button_width = max_button_width end
    local min_button_width = Screen:scaleBySize(28)
    if button_width < min_button_width then button_width = min_button_width end

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
        show_parent = self,
    }
    
    -- Re-align button (go to the page currently being read)
    self.realign_button = Button:new{
        text = "○",
        width = button_width,
        max_width = button_width,
        height = button_height,
        text_font_size = button_font_size,
        callback = function()
            self:onRealign()
        end,
        bordersize = Size.border.button,
        show_parent = self,
    }

    -- Speed down / up buttons (step the speech rate).
    -- Plain ASCII-ish labels on purpose: KOReader's bundled fonts have no
    -- reliable glyphs for the tempo/speaker symbols one would reach for first.
    self.speed_down_button = Button:new{
        text = "S−",
        width = button_width,
        max_width = button_width,
        height = button_height,
        text_font_size = button_font_size,
        callback = function()
            if self.on_speed_down then self.on_speed_down() end
        end,
        bordersize = Size.border.button,
        show_parent = self,
    }
    self.speed_up_button = Button:new{
        text = "S+",
        width = button_width,
        max_width = button_width,
        height = button_height,
        text_font_size = button_font_size,
        callback = function()
            if self.on_speed_up then self.on_speed_up() end
        end,
        bordersize = Size.border.button,
        show_parent = self,
    }

    -- Volume down / up buttons (step the speech volume)
    self.vol_down_button = Button:new{
        text = "V−",
        width = button_width,
        max_width = button_width,
        height = button_height,
        text_font_size = button_font_size,
        callback = function()
            if self.on_volume_down then self.on_volume_down() end
        end,
        bordersize = Size.border.button,
        show_parent = self,
    }
    self.vol_up_button = Button:new{
        text = "V+",
        width = button_width,
        max_width = button_width,
        height = button_height,
        text_font_size = button_font_size,
        callback = function()
            if self.on_volume_up then self.on_volume_up() end
        end,
        bordersize = Size.border.button,
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
        show_parent = self,
    }
    
    -- Current word display (time in scrubber mode, word in TTS mode)
    local display_text = self.current_word or _("Starting...")
    if self.scrubber_mode then
        display_text = self.current_time_str ~= "" and self.current_time_str or "0:00 / 0:00"
    end
    self.word_display = TextWidget:new{
        text = display_text,
        face = Font:getFace("cfont", 16),
        max_width = self.width - row_inset,
        truncate_left = true,
    }
    
    -- Progress bar — tall enough to be clearly visible on e-ink
    -- In scrubber mode we enlarge the touch target vertically
    local bar_height = Screen:scaleBySize(10)
    self.progress_bar = ProgressWidget:new{
        width = self.width - Size.padding.large * 2,
        height = bar_height,
        percentage = self.progress / 100,
        fillcolor = Blitbuffer.COLOR_BLACK,
        bgcolor = Blitbuffer.COLOR_LIGHT_GRAY,
        bordersize = 0,
        margin_h = 0,
        margin_v = 0,
        radius = Screen:scaleBySize(5),
        ticks = nil,
        tick_width = 0,
        last = nil,
    }
    -- Scrubber touch area: larger than the visual bar for easier targeting
    self._scrubber_touch_height = Screen:scaleBySize(30)
    self._scrubber_dragging = false
    self._scrubber_drag_pct = nil
    
    -- Button row.  Gaps are Size.padding.default rather than .large: with 9
    -- buttons the wider spacing pushed the row past the edge of a 6" screen.
    local button_row = HorizontalGroup:new{
        align = "center",
        self.rewind_button,
        HorizontalSpan:new{ width = row_spacing },
        self.play_pause_button,
        HorizontalSpan:new{ width = row_spacing },
        self.forward_button,
        HorizontalSpan:new{ width = row_spacing },
        self.speed_down_button,
        HorizontalSpan:new{ width = row_spacing },
        self.speed_up_button,
        HorizontalSpan:new{ width = row_spacing },
        self.vol_down_button,
        HorizontalSpan:new{ width = row_spacing },
        self.vol_up_button,
        HorizontalSpan:new{ width = row_spacing },
        self.realign_button,
        HorizontalSpan:new{ width = row_spacing },
        self.close_button,
    }
    
    -- Main layout — generous spacing so progress bar and buttons
    -- are clearly separated from each other and the bottom edge.
    --
    -- The progress row is included in scrubber mode (where it is an
    -- interactive seek control) and, during TTS read-along, only when the
    -- user leaves show_progress on.  In read-along the sentence highlight
    -- already shows position, so dropping the row buys back a line of book
    -- text.  The widget itself always exists — the scrubber code and
    -- updateProgress() reference it — it is simply not in the visible tree.
    self._progress_shown = self.scrubber_mode or self.show_progress ~= false
    local content = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = Size.padding.small },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.word_display:getSize().h },
            self.word_display,
        },
    }
    if self._progress_shown then
        table.insert(content, VerticalSpan:new{ width = Size.padding.default })
        table.insert(content, CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.progress_bar:getSize().h },
            self.progress_bar,
        })
    end
    table.insert(content, VerticalSpan:new{ width = Size.padding.large })
    table.insert(content, CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = button_height },
        button_row,
    })
    table.insert(content, VerticalSpan:new{ width = Size.padding.fullscreen })
    
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
    for _iter = 1, 3 do
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
    for _iter = 1, 3 do
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
        -- When the progress row is not in the visible tree the widget has
        -- never been painted, so it has no dimen to refresh (and nothing to
        -- show).  Keep the value up to date but skip the repaint.
        if self._progress_shown then
            UIManager:setDirty(self, function()
                return "ui", self.progress_bar.dimen
            end)
        end
    end
end

function PlaybackBar:_formatTime(seconds)
    seconds = math.floor(seconds or 0)
    local mins = math.floor(seconds / 60)
    local secs = seconds % 60
    return string.format("%d:%02d", mins, secs)
end

function PlaybackBar:updateTimeDisplay(current_sec, total_sec)
    if not self.scrubber_mode then return end
    local text = self:_formatTime(current_sec) .. " / " .. self:_formatTime(total_sec)
    if text ~= self.current_time_str then
        self.current_time_str = text
        self.word_display:setText(text)
        UIManager:setDirty(self, function()
            return "ui", self.word_display.dimen
        end)
    end
end

function PlaybackBar:_xToPercentage(x)
    if not self.progress_bar or not self.progress_bar.dimen then return nil end
    local bar_left = self.progress_bar.dimen.x
    local bar_width = self.progress_bar.dimen.w
    if not bar_left or not bar_width or bar_width <= 0 then return nil end
    local pct = (x - bar_left) / bar_width
    pct = math.max(0, math.min(1, pct))
    return pct
end

function PlaybackBar:_updateScrubberPreview(x)
    local pct = self:_xToPercentage(x)
    if not pct then return end
    self._scrubber_drag_pct = pct
    -- Update progress bar visually without triggering seek
    self.progress_bar:setPercentage(pct)
    UIManager:setDirty(self, function()
        return "ui", self.progress_bar.dimen
    end)
end

function PlaybackBar:setScrubberMode(enabled)
    enabled = enabled and true or false
    if self.scrubber_mode == enabled then return end
    self.scrubber_mode = enabled
    if enabled then
        self.word_display:setText(self.current_time_str)
    else
        self.word_display:setText(self.current_word or _("Starting..."))
    end
    UIManager:setDirty(self, function()
        return "ui", self.word_display.dimen
    end)
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
    self.suppressed = false
    self.dimen.x = 0
    self.dimen.y = Screen:getHeight() - self.dimen.h
    UIManager:show(self, "ui", nil, self.dimen.x, self.dimen.y)
end

function PlaybackBar:hide()
    self.visible = false
    self.suppressed = false
    UIManager:close(self)
    -- Force refresh of the bar area to clear ghosting on e-ink
    UIManager:setDirty("all", "ui")
end

--- Suppress / un-suppress painting without removing the widget from the
-- UIManager window stack.  Used by the "paused_only" visibility mode so
-- that:
--   * Taps on the reading area still toggle play/pause via handleEvent.
--   * The overlay auto-pause poller keeps detecting menus opening.
--   * The screen below shows through (paintTo is a no-op while suppressed).
--
-- This avoids the v0.1.5.79 bugs where UIManager:close()'ing the bar dropped
-- it from the stack entirely: taps fell through to the reader (page turns,
-- dictionary), the bar could never be restored, and the top-menu pull-down
-- froze KOReader because the auto-pause path tried to re-show a stale widget.
function PlaybackBar:setSuppressed(suppressed)
    suppressed = suppressed and true or false
    if self.suppressed == suppressed then return end
    self.suppressed = suppressed
    -- Repaint the bar's region: when un-suppressing draw the bar; when
    -- suppressing redraw the area behind it (now empty paintTo).
    UIManager:setDirty("all", "ui")
end

function PlaybackBar:isSuppressed()
    return self.suppressed and true or false
end

--- True when the bar widget is mounted in the UIManager window stack,
-- regardless of whether it is currently painted.  SyncController uses this
-- to decide whether to call show()/setSuppressed() on the next visibility
-- transition.
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
    self.height = Screen:scaleBySize(100)
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

--- Override handleEvent so that:
--- 1. Taps on the reading area toggle play/pause (tap-to-pause).
---    This prevents stray taps from triggering dictionary lookup on
---    the CRE selection that the highlight manager maintains, and
---    gives 6" screen users an easy way to control playback.
--- 2. Taps inside the bar area go to the buttons normally.
--- 3. Swipe/pan/hold gestures ALWAYS pass through so the bottom-swipe
---    ConfigMenu and long-press dictionary still work.
--- 4. When any overlay (menu/dialog) is active, ALL events pass through
---    so the overlay can handle its own taps and dismiss correctly.
function PlaybackBar:handleEvent(event)
    local arg1 = event.args and event.args[1]
    if event.handler == "onGesture" or (type(arg1) == "table" and arg1.ges) then
        local ges = type(arg1) == "table" and arg1 or nil
        if ges and self.plugin and self.plugin.session_recorder then
            self.plugin.session_recorder:recordGesture(ges, "playbackbar")
        end
        if ges then
            -- Let swipe/pan/hold pass through unconditionally
            if ges.ges == "swipe" or ges.ges == "pan" or ges.ges == "hold" or ges.ges == "hold_pan" then
                return false
            end
            -- When a menu or dialog is open, pass through so it can handle
            -- its own events (e.g. dismiss on outside tap).
            if self:_isOverlayActive() then
                return false
            end
            -- Scrubber drag: update visual indicator during drag
            if ges.ges == "pan" and self.scrubber_mode and self.visible
                and ges.pos and self.dimen and ges.pos.y >= self.dimen.y then
                local bar_y_center = self.dimen.y + self.progress_bar.dimen.y +
                                     self.progress_bar.dimen.h / 2
                if math.abs(ges.pos.y - bar_y_center) <= self._scrubber_touch_height / 2 then
                    self:_updateScrubberPreview(ges.pos.x)
                    self._scrubber_dragging = true
                    return true
                end
            end
            -- Scrubber release: perform seek
            if (ges.ges == "hold_release" or ges.ges == "pan_release")
                and self.scrubber_mode and self._scrubber_dragging then
                self._scrubber_dragging = false
                if self._scrubber_drag_pct and self.on_seek then
                    self.on_seek(self._scrubber_drag_pct)
                    self._scrubber_drag_pct = nil
                end
                return true
            end
            -- Tap during active playback
            if ges.ges == "tap" and self.visible then
                -- When the bar is suppressed (paused_only mode while playing)
                -- the whole screen acts as a tap-to-pause zone.  This also
                -- restores the bar via _applyBarVisibility on pause().
                if self.suppressed then
                    self:onPlayPause()
                    return true
                end
                -- Scrubber tap on progress bar
                if self.scrubber_mode and ges.pos and self.dimen
                    and ges.pos.y >= self.dimen.y then
                    local bar_y_center = self.dimen.y + self.progress_bar.dimen.y +
                                         self.progress_bar.dimen.h / 2
                    if math.abs(ges.pos.y - bar_y_center) <= self._scrubber_touch_height / 2 then
                        local pct = self:_xToPercentage(ges.pos.x)
                        if pct and self.on_seek then
                            self.on_seek(pct)
                        end
                        return true
                    end
                end
                -- Taps inside the bar area: dispatch to buttons
                if ges.pos and self.dimen and ges.pos.y >= self.dimen.y then
                    return InputContainer.handleEvent(self, event)
                end
                -- Taps on the reading area: toggle play/pause
                self:onPlayPause()
                return true
            end
        end
    end
    -- Non-gesture events or when not visible: standard dispatch
    return InputContainer.handleEvent(self, event)
end

function PlaybackBar:paintTo(bb, x, y)
    -- Toast widgets are painted on top of everything. To let menus/dialogs
    -- appear above us, skip painting when any non-toast widget besides the
    -- base reader is in the UIManager window stack.
    if self:_isOverlayActive() then
        return
    end
    -- Suppressed mode: keep the widget in the stack (so taps still pause and
    -- overlay auto-pause still works) but render nothing.
    if self.suppressed then
        return
    end
    if self[1] and self[1].paintTo then
        self[1]:paintTo(bb, x or 0, y or self.dimen.y)
    end
end

--- Check if any menu or dialog sits between us and the base reader.
-- In normal operation there is exactly 1 non-toast widget (the reader)
-- plus ourselves.  When a menu/dialog opens, there are 3+.
function PlaybackBar:_isOverlayActive()
    local stack = UIManager._window_stack
    if not stack then return false end
    local non_toast = 0
    for i = 1, #stack do
        local w = stack[i].widget
        if w ~= self and not w.toast then
            non_toast = non_toast + 1
            if non_toast > 1 then
                return true
            end
        end
    end
    return false
end

return PlaybackBar
