--[[--
AudiobookPlayer -- Full-screen overlay widget for standalone audio playback.
Designed for e-ink: large tap targets, minimal refreshes, no images.

Layout:
  [☰]         Title        [spd] [▼] [✕]
  +---------------------------+
  |       Cover art           |
  +---------------------------+
        Chapter / metadata
           3:24 / 12:45
  [======== progress bar =====]
  [⏴30] [⏮] [⏸] [⏭] [30⏵]

Minimized: a small bottom bar with restore + play/pause + title

@module koplugin.audiobook.audiobookplayer
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
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local RenderText = require("ui/rendertext")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local logger = require("logger")
local _ = require("audiobook_gettext")
local T = require("ffi/util").template

local AudiobookPlayer = InputContainer:extend{
    plugin = nil,
    is_playing = true,
    progress = 0,
    current_time_str = "0:00 / 0:00",
    title = "",
    chapter_title = "",
    output_name = "",
    cover_image_path = nil,
    playback_speed = 1.0,
    -- Plugin chrome: the TTS PlaybackBar:_isOverlayActive must not treat this
    -- mini bar as a menu/dialog (and vice versa).
    _plugin_chrome = true,
    -- Time display mode: "book" = position-in-book, "chapter" = position-in-chapter
    _time_display_mode = "book",
    _current_chapter_start = 0,
    _current_chapter_end = 0,
    _sleep_timer_remaining = 0,
    _sleep_timer_active = false,
    -- Callbacks
    on_play_pause = nil,
    on_skip_back = nil,
    on_skip_forward = nil,
    on_fix_audio = nil,
    show_fix_audio = false,
    -- When true, mini bar sits above KOReader's bottom status bar.
    keep_reader_status_bars = false,
    on_prev_chapter = nil,
    on_next_chapter = nil,
    on_seek = nil,
    on_close = nil,
    on_minimize = nil,
    on_chapter_list = nil,
    on_speed = nil,
    on_shuffle = nil,
    show_shuffle = false,
    shuffle_active = false,
    on_loop = nil,
    show_loop = false,
    loop_active = false,
    on_volume = nil,
    volume_pct = 100,
    on_sleep_timer_set = nil,
    on_sleep_timer_cancel = nil,
    on_refocus = nil,
    -- Reference to the underlying ReaderUI or FileManager widget for event
    -- forwarding when minimized (since UIManager only dispatches to the top
    -- widget, we must manually forward events to the UI below).
    ui_widget = nil,
}

-- Read JPEG width/height from file headers without loading the image.
local function _jpegDimensions(path)
    local f = io.open(path, "rb")
    if not f then return nil, nil end
    local data = f:read(2)
    if data ~= "\xff\xd8" then
        f:close()
        return nil, nil
    end
    while true do
        local marker = f:read(2)
        if not marker then break end
        if marker:byte(1) ~= 0xFF then
            f:close()
            return nil, nil
        end
        local mtype = marker:byte(2)
        while mtype == 0xFF do
            local b = f:read(1)
            if not b then f:close(); return nil, nil end
            mtype = b:byte(1)
        end
        if mtype == 0xD9 then break end -- EOI
        -- markers without payload
        if mtype == 0xD8 or mtype == 0x01 then
            -- continue
        elseif mtype >= 0xD0 and mtype <= 0xD9 then
            -- continue
        else
            local len_b = f:read(2)
            if not len_b or #len_b < 2 then break end
            local len = len_b:byte(1) * 256 + len_b:byte(2)
            -- SOF0 / SOF1 / SOF2 contain dimensions
            if mtype == 0xC0 or mtype == 0xC1 or mtype == 0xC2 then
                local sof = f:read(5)
                if sof and #sof == 5 then
                    local h = sof:byte(2) * 256 + sof:byte(3)
                    local w = sof:byte(4) * 256 + sof:byte(5)
                    f:close()
                    return w, h
                end
                break
            else
                if len > 2 then
                    f:seek("cur", len - 2)
                end
            end
        end
    end
    f:close()
    return nil, nil
end

function AudiobookPlayer:_isEink()
    return Device.hasEinkScreen and Device:hasEinkScreen()
end

--- Sit above KOReader's footer when the user asked to keep it, or when the
--- footer is a real page chrome (Overlap status bar off). Otherwise the mini
--- player paints on top of the progress bar and e-ink ghosts a second bar.
function AudiobookPlayer:_shouldSitAboveFooter()
    if self.keep_reader_status_bars then return true end
    local ui = self.ui_widget or (self.plugin and self.plugin.ui)
    local view = ui and ui.view
    if not (view and view.footer_visible and view.footer) then return false end
    return not view.footer.reclaim_height
end

function AudiobookPlayer:init()
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self._minimized = false
    -- Do not claim the whole screen / footer while the mini player is up —
    -- otherwise ReaderFooter may skip updates ("lost" status bar).
    self.covers_fullscreen = false
    self.covers_footer = not self:_shouldSitAboveFooter()
    self._return_hint_active = false
    self._rotation_mode = Screen:getRotationMode()
    self:setupUI()
end

function AudiobookPlayer:setupUI()
    local button_size = Screen:scaleBySize(56)
    local spacing = Size.padding.large

    -- ── Top row: chapter list | title | speed | minimize | close ──
    self.chapter_list_button = Button:new{
        text = "☰",
        width = button_size,
        height = button_size,
        text_font_size = 20,
        callback = function() self:onChapterList() end,
        bordersize = 0,
        show_parent = self,
    }

    self.sleep_timer_button = Button:new{
        text = "⏲",
        width = button_size,
        height = button_size,
        text_font_size = 20,
        callback = function() self:onSleepTimer() end,
        bordersize = 0,
        show_parent = self,
    }

    self.speed_button = Button:new{
        text = self:_speedText(),
        width = button_size,
        height = button_size,
        text_font_size = 14,
        callback = function() self:onSpeed() end,
        bordersize = 0,
        show_parent = self,
    }

    self.minimize_button = Button:new{
        text = "▼",
        width = button_size,
        height = button_size,
        text_font_size = 20,
        callback = function() self:onMinimize() end,
        bordersize = 0,
        show_parent = self,
    }

    self.close_button = Button:new{
        text = "✕",
        width = button_size,
        height = button_size,
        text_font_size = 22,
        callback = function() self:onClose() end,
        bordersize = 0,
        show_parent = self,
    }

    self.shuffle_button = Button:new{
        text = "⇄",
        width = button_size,
        height = button_size,
        text_font_size = 20,
        callback = function() self:onShuffle() end,
        bordersize = self.shuffle_active and Size.border.default or 0,
        radius = Screen:scaleBySize(4),
        show_parent = self,
    }

    self.loop_button = Button:new{
        text = "⟳",
        width = button_size,
        height = button_size,
        text_font_size = 20,
        callback = function() self:onLoop() end,
        bordersize = self.loop_active and Size.border.default or 0,
        radius = Screen:scaleBySize(4),
        show_parent = self,
    }

    -- Kindle AirPods: reconnect A2DP when the stream goes silent mid-play.
    self.fix_audio_button = Button:new{
        text = _("BT"),
        width = button_size,
        height = button_size,
        text_font_size = 14,
        callback = function() self:onFixAudio() end,
        bordersize = 0,
        show_parent = self,
    }

    -- Count visible buttons for title width calculation
    local visible_buttons = 5 -- chapter_list, sleep_timer, speed, minimize, close
    if self.show_shuffle then visible_buttons = visible_buttons + 1 end
    if self.show_loop then visible_buttons = visible_buttons + 1 end
    if self.show_fix_audio then visible_buttons = visible_buttons + 1 end
    self.title_widget = TextWidget:new{
        text = self.title or _("Audiobook"),
        face = Font:getFace("cfont", 18),
        max_width = self.width - button_size * visible_buttons - spacing * visible_buttons,
        truncate_left = true,
    }

    -- Build top row left-to-right explicitly
    local top_row_items = {
        align = "center",
        self.chapter_list_button,
        HorizontalSpan:new{ width = spacing },
        self.sleep_timer_button,
        HorizontalSpan:new{ width = math.floor(spacing / 2) },
    }
    if self.show_shuffle then
        table.insert(top_row_items, self.shuffle_button)
        table.insert(top_row_items, HorizontalSpan:new{ width = math.floor(spacing / 2) })
    end
    if self.show_loop then
        table.insert(top_row_items, self.loop_button)
        table.insert(top_row_items, HorizontalSpan:new{ width = math.floor(spacing / 2) })
    end
    if self.show_fix_audio then
        table.insert(top_row_items, self.fix_audio_button)
        table.insert(top_row_items, HorizontalSpan:new{ width = math.floor(spacing / 2) })
    end
    table.insert(top_row_items, CenterContainer:new{
        dimen = Geom:new{ w = self.title_widget:getSize().w, h = button_size },
        self.title_widget,
    })
    table.insert(top_row_items, HorizontalSpan:new{ width = spacing })
    table.insert(top_row_items, self.speed_button)
    table.insert(top_row_items, HorizontalSpan:new{ width = math.floor(spacing / 2) })
    table.insert(top_row_items, self.minimize_button)
    table.insert(top_row_items, HorizontalSpan:new{ width = math.floor(spacing / 2) })
    table.insert(top_row_items, self.close_button)
    local top_row = HorizontalGroup:new(top_row_items)

    -- ── Cover art placeholder ──
    -- Compute cover frame size dynamically based on the actual image aspect ratio.
    -- The frame is sized to match the image shape, capped at 45% of screen height.
    local padding = Size.padding.small
    local max_cover_h = math.floor(math.min(self.width, self.height) * 0.45)
    local img_w, img_h = nil, nil
    if self.cover_image_path then
        img_w, img_h = _jpegDimensions(self.cover_image_path)
    end
    if img_w and img_h and img_w > 0 and img_h > 0 then
        local avail_w = self.width - padding * 2
        local scale = math.min(avail_w / img_w, max_cover_h / img_h)
        self._cover_width = math.floor(img_w * scale)
        self._cover_height = math.floor(img_h * scale)
    else
        -- Fallback: use a generous square-ish frame when no image is available
        self._cover_width = math.floor(self.width * 0.6)
        self._cover_height = math.min(self._cover_width, max_cover_h)
    end
    self.cover_frame = self:_buildCoverFrame()

    -- ── Metadata under cover ──
    self.chapter_widget = TextWidget:new{
        text = self.chapter_title or "",
        face = Font:getFace("cfont", 16),
        max_width = self.width - spacing * 4,
        truncate_left = true,
    }

    -- Multi-line filename: wrap into up to 2 lines so long filenames are readable.
    self.output_widget = self:_buildOutputWidget(self.output_name or "")

    -- ── Time display ──
    self.time_widget = TextWidget:new{
        text = self.current_time_str or "0:00 / 0:00",
        face = Font:getFace("cfont", 18),
        max_width = self.width - spacing * 4,
    }

    -- ── Progress bar ──
    local bar_height = Screen:scaleBySize(10)
    self.progress_bar = ProgressWidget:new{
        width = self.width - spacing * 4,
        height = bar_height,
        percentage = self.progress / 100,
        fillcolor = Blitbuffer.COLOR_BLACK,
        bgcolor = Blitbuffer.COLOR_LIGHT_GRAY,
        bordersize = 0,
        margin_h = 0,
        margin_v = 0,
        radius = Screen:scaleBySize(5),
    }

    self._scrubber_touch_height = Screen:scaleBySize(40)
    self._scrubber_dragging = false
    self._scrubber_drag_pct = nil

    -- ── Playback controls: all same size ──
    self.skip_back_button = Button:new{
        text = "⏴30",
        width = button_size,
        height = button_size,
        text_font_size = 13,
        callback = function() self:onSkipBack() end,
        bordersize = Size.border.thin,
        radius = Screen:scaleBySize(6),
        show_parent = self,
    }

    self.prev_chapter_button = Button:new{
        text = "⏮",
        width = button_size,
        height = button_size,
        text_font_size = 18,
        callback = function() self:onPrevChapter() end,
        bordersize = Size.border.thin,
        radius = Screen:scaleBySize(6),
        show_parent = self,
    }

    self.play_pause_button = Button:new{
        text = self.is_playing and "⏸" or "▶",
        width = button_size,
        height = button_size,
        text_font_size = 28,
        callback = function() self:onPlayPause() end,
        bordersize = Size.border.thin,
        radius = Screen:scaleBySize(6),
        show_parent = self,
    }

    self.next_chapter_button = Button:new{
        text = "⏭",
        width = button_size,
        height = button_size,
        text_font_size = 18,
        callback = function() self:onNextChapter() end,
        bordersize = Size.border.thin,
        radius = Screen:scaleBySize(6),
        show_parent = self,
    }

    self.skip_forward_button = Button:new{
        text = "30⏵",
        width = button_size,
        height = button_size,
        text_font_size = 13,
        callback = function() self:onSkipForward() end,
        bordersize = Size.border.thin,
        radius = Screen:scaleBySize(6),
        show_parent = self,
    }

    -- ── Volume controls (used in both orientations) ──
    self.volume_widget = TextWidget:new{
        text = self:_volumeText(),
        face = Font:getFace("cfont", 16),
    }
    self.vol_minus_button = Button:new{
        text = "−",
        width = button_size,
        height = button_size,
        text_font_size = 24,
        callback = function() self:_applyVolume(-10) end,
        bordersize = Size.border.thin,
        radius = Screen:scaleBySize(6),
        show_parent = self,
    }
    self.vol_plus_button = Button:new{
        text = "+",
        width = button_size,
        height = button_size,
        text_font_size = 24,
        callback = function() self:_applyVolume(10) end,
        bordersize = Size.border.thin,
        radius = Screen:scaleBySize(6),
        show_parent = self,
    }

    local is_landscape = self.width > self.height
    local control_row, volume_row
    if is_landscape then
        -- Landscape: single row [-] [<30] [<<] [play] [>>] [30>] [+] [90%]
        -- Transport/volume buttons are centered on the full screen width;
        -- the percentage label sits at the right edge and does not shift the center.
        local inner_span = math.floor(spacing / 2)
        local button_group_w = button_size * 7
            + inner_span * 2
            + spacing * 6
        local vol_w = self.volume_widget:getSize().w
        local right_span = spacing
        local left_span = math.max(0, math.floor((self.width - button_group_w) / 2))
        local mid_span = math.max(0, self.width - left_span - button_group_w - vol_w - right_span)
        control_row = HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = left_span },
            self.vol_minus_button,
            HorizontalSpan:new{ width = inner_span },
            self.skip_back_button,
            HorizontalSpan:new{ width = spacing },
            self.prev_chapter_button,
            HorizontalSpan:new{ width = spacing * 2 },
            self.play_pause_button,
            HorizontalSpan:new{ width = spacing * 2 },
            self.next_chapter_button,
            HorizontalSpan:new{ width = spacing },
            self.skip_forward_button,
            HorizontalSpan:new{ width = inner_span },
            self.vol_plus_button,
            HorizontalSpan:new{ width = mid_span },
            self.volume_widget,
            HorizontalSpan:new{ width = right_span },
        }
    else
        -- Portrait: separate transport and volume rows
        control_row = HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = spacing },
            self.skip_back_button,
            HorizontalSpan:new{ width = spacing },
            self.prev_chapter_button,
            HorizontalSpan:new{ width = spacing * 2 },
            self.play_pause_button,
            HorizontalSpan:new{ width = spacing * 2 },
            self.next_chapter_button,
            HorizontalSpan:new{ width = spacing },
            self.skip_forward_button,
            HorizontalSpan:new{ width = spacing },
        }
        volume_row = HorizontalGroup:new{
            align = "center",
            self.vol_minus_button,
            HorizontalSpan:new{ width = spacing * 2 },
            CenterContainer:new{
                dimen = Geom:new{ w = button_size * 2, h = button_size },
                self.volume_widget,
            },
            HorizontalSpan:new{ width = spacing * 2 },
            self.vol_plus_button,
        }
    end

    -- ── Assemble full layout ──
    local content = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = Size.padding.small },
        top_row,
        VerticalSpan:new{ width = self.height * 0.025 },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self._cover_height },
            self.cover_frame,
        },
        VerticalSpan:new{ width = self.height * 0.015 },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.chapter_widget:getSize().h },
            self.chapter_widget,
        },
        VerticalSpan:new{ width = math.floor(self.height * 0.006) },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.output_widget:getSize().h },
            self.output_widget,
        },
        VerticalSpan:new{ width = self.height * 0.015 },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.time_widget:getSize().h },
            self.time_widget,
        },
        VerticalSpan:new{ width = spacing },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = bar_height + self._scrubber_touch_height },
            self.progress_bar,
        },
        VerticalSpan:new{ width = self.height * 0.025 },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = button_size },
            control_row,
        },
    }
    if not is_landscape then
        table.insert(content,
            VerticalSpan:new{ width = self.height * 0.02 })
        table.insert(content,
            CenterContainer:new{
                dimen = Geom:new{ w = self.width, h = button_size },
                volume_row,
            })
    end
    table.insert(content, VerticalSpan:new{ width = Size.padding.small })

    -- Match the reader's configured background color so the player blends with
    -- the user's theme instead of forcing pure white.
    local bg_color = self:_getThemeBackground()
    self[1] = FrameContainer:new{
        width = self.width,
        height = self.height,
        background = bg_color,
        bordersize = 0,
        padding = 0,
        content,
    }

    self.dimen = self[1]:getSize()
    self.dimen.x = 0
    self.dimen.y = 0

    -- ── Mini-player bar (shown when minimized) ──
    self._mini_height = Screen:scaleBySize(44)
    local mini_btn_size = self._mini_height - 20  -- keep clear of the mini bar border

    self._mini_play_pause = Button:new{
        text = self.is_playing and "⏸" or "▶",
        width = mini_btn_size,
        height = mini_btn_size,
        text_font_size = 18,
        callback = function() self:onPlayPause() end,
        bordersize = 0,
        show_parent = self,
    }

    self._mini_close = Button:new{
        text = "✕",
        width = mini_btn_size,
        height = mini_btn_size,
        text_font_size = 16,
        callback = function() self:onClose() end,
        bordersize = 0,
        show_parent = self,
    }

    local refocus_group = {}
    if self.on_refocus then
        self._mini_refocus = Button:new{
            text = "○",
            width = mini_btn_size,
            height = mini_btn_size,
            text_font_size = 18,
            callback = function() self:onRefocus() end,
            bordersize = 0,
            show_parent = self,
        }
        refocus_group = {
            self._mini_refocus,
            HorizontalSpan:new{ width = math.floor(spacing / 2) },
        }
    end

    -- Center: title + time stacked and centered.
    -- Width is reduced as optional side button groups are added; the actual
    -- TextWidgets are created after center_max_width is final.
    local center_max_width = self.width - mini_btn_size * 2 - spacing * 4
    if self.on_refocus then
        center_max_width = center_max_width - mini_btn_size - spacing
    end

    -- Read-along: live sync-offset nudge buttons.  The sync loop reads the
    -- setting every tick, so each press shifts the highlight immediately;
    -- the new value flashes in the mini time display until the next
    -- regular time update overwrites it.
    local nudge_group = {}
    if self.on_sync_nudge then
        local function nudge(delta_ms)
            local v = self.on_sync_nudge(delta_ms)
            if v then
                self._mini_time:setText(string.format("sync %+.1f s", v / 1000))
                UIManager:setDirty(self, function()
                    return "ui", self._minimized and self.dimen or nil
                end)
            end
        end
        self._mini_sync_minus = Button:new{
            text = "−",
            width = mini_btn_size,
            height = mini_btn_size,
            text_font_size = 16,
            callback = function() nudge(-100) end,
            bordersize = 0,
            show_parent = self,
        }
        self._mini_sync_plus = Button:new{
            text = "+",
            width = mini_btn_size,
            height = mini_btn_size,
            text_font_size = 16,
            callback = function() nudge(100) end,
            bordersize = 0,
            show_parent = self,
        }
        center_max_width = center_max_width - (mini_btn_size + spacing) * 2
        nudge_group = {
            self._mini_sync_minus,
            HorizontalSpan:new{ width = spacing },
            self._mini_sync_plus,
            HorizontalSpan:new{ width = spacing },
        }
    end

    -- Volume nudge buttons (♪− / ♪+), shown on the left of the mini bar so
    -- they sit apart from the sync buttons on the right.  Reuses _applyVolume,
    -- which flashes the level in the time slot and debounces the apply.
    local vol_group = {}
    if self.on_volume then
        self._mini_vol_minus = Button:new{
            text = "♪−",
            width = mini_btn_size,
            height = mini_btn_size,
            text_font_size = 13,
            callback = function() self:_applyVolume(-10) end,
            bordersize = 0,
            show_parent = self,
        }
        self._mini_vol_plus = Button:new{
            text = "♪+",
            width = mini_btn_size,
            height = mini_btn_size,
            text_font_size = 13,
            callback = function() self:_applyVolume(10) end,
            bordersize = 0,
            show_parent = self,
        }
        center_max_width = center_max_width - (mini_btn_size + spacing) * 2
        vol_group = {
            self._mini_vol_minus,
            HorizontalSpan:new{ width = spacing },
            self._mini_vol_plus,
            HorizontalSpan:new{ width = spacing },
        }
    end

    -- Chapter list on the mini bar (overlay): avoids expanding the fullscreen
    -- player just to tap ☰, which was crashing on Boox.
    local chapter_group = {}
    if self.on_chapter_list then
        self._mini_chapters = Button:new{
            text = "☰",
            width = mini_btn_size,
            height = mini_btn_size,
            text_font_size = 16,
            callback = function() self:onChapterList() end,
            bordersize = 0,
            show_parent = self,
        }
        center_max_width = center_max_width - mini_btn_size - spacing
        chapter_group = {
            self._mini_chapters,
            HorizontalSpan:new{ width = spacing },
        }
    end

    -- Create the centered title/time stack now that side buttons have reserved
    -- their full width, so the text cannot overlap the volume/sync buttons.
    self._mini_title = TextWidget:new{
        text = (self.chapter_title and self.chapter_title ~= "" and self.chapter_title)
            or self.output_name or self.title or _("Audiobook"),
        face = Font:getFace("cfont", 13),
        max_width = center_max_width,
        truncate_left = false,
    }
    self._mini_time = TextWidget:new{
        text = self.current_time_str or "",
        face = Font:getFace("cfont", 11),
        max_width = center_max_width,
    }
    local mini_center = VerticalGroup:new{
        align = "center",
        self._mini_title,
        self._mini_time,
    }

    local mini_row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = spacing },
        self._mini_play_pause,
        HorizontalSpan:new{ width = spacing },
        chapter_group[1] or HorizontalSpan:new{ width = 0 },
        chapter_group[2] or HorizontalSpan:new{ width = 0 },
        vol_group[1] or HorizontalSpan:new{ width = 0 },
        vol_group[2] or HorizontalSpan:new{ width = 0 },
        vol_group[3] or HorizontalSpan:new{ width = 0 },
        vol_group[4] or HorizontalSpan:new{ width = 0 },
        CenterContainer:new{
            dimen = Geom:new{ w = center_max_width, h = self._mini_height },
            mini_center,
        },
        nudge_group[1] or HorizontalSpan:new{ width = 0 },
        nudge_group[2] or HorizontalSpan:new{ width = 0 },
        nudge_group[3] or HorizontalSpan:new{ width = 0 },
        nudge_group[4] or HorizontalSpan:new{ width = 0 },
        HorizontalSpan:new{ width = spacing },
        refocus_group[1] or HorizontalSpan:new{ width = 0 },
        refocus_group[2] or HorizontalSpan:new{ width = 0 },
        self._mini_close,
        HorizontalSpan:new{ width = spacing },
    }
    self._mini_bar = FrameContainer:new{
        width = self.width,
        height = self._mini_height,
        background = self:_getThemeBackground(),
        bordersize = Size.border.thin,
        padding = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self._mini_height - Size.border.thin * 2 },
            mini_row,
        },
    }

    -- EPUB read-along mode: stay on the book page (highlights + page
    -- follow are the UI) with only the mini bar for transport control,
    -- instead of covering the text with the full-screen player.
    if self.start_minimized then
        self:_applyMinimizedGeometry()
        self:_updateMiniWidgets()
    end
end

--- Bottom inset so the mini player can sit above KOReader's status/progress bar.
--- MediaSync also reflows page margins by this chrome height + mini bar so
--- book text never renders underneath the player.
function AudiobookPlayer:_statusBarInset()
    if not self:_shouldSitAboveFooter() then return 0 end
    local ui = self.ui_widget or (self.plugin and self.plugin.ui)
    local view = ui and ui.view
    if not view or not view.footer_visible or not view.footer then return 0 end
    local ok, h = pcall(function() return view.footer:getHeight() end)
    if ok and type(h) == "number" and h > 0 then return h end
    ok, h = pcall(function()
        local d = view.footer.dimen
        return d and d.h or 0
    end)
    if ok and type(h) == "number" and h > 0 then return h end
    -- Last resort: typical status+progress stack on PW11-class screens.
    return Screen:scaleBySize(36)
end

function AudiobookPlayer:_miniBarY()
    return self.height - self._mini_height - self:_statusBarInset()
end

function AudiobookPlayer:_applyMinimizedGeometry()
    self._minimized = true
    self.covers_fullscreen = false
    self.covers_footer = not self:_shouldSitAboveFooter()
    self.dimen.h = self._mini_height
    self.dimen.y = self:_miniBarY()
end

-- Callback handlers
function AudiobookPlayer:onPlayPause()
    if self.on_play_pause then self.on_play_pause() end
end

function AudiobookPlayer:onSkipBack()
    if self.on_skip_back then self.on_skip_back() end
end

function AudiobookPlayer:onSkipForward()
    if self.on_skip_forward then self.on_skip_forward() end
end

function AudiobookPlayer:onPrevChapter()
    if self.on_prev_chapter then self.on_prev_chapter() end
end

function AudiobookPlayer:onNextChapter()
    if self.on_next_chapter then self.on_next_chapter() end
end

function AudiobookPlayer:onClose()
    if self.on_close then self.on_close() end
end

function AudiobookPlayer:onMinimize()
    self._scrubber_dragging = false
    self._scrubber_drag_pct = nil
    self:_updateMiniWidgets()
    -- Shrink dimen to only cover the mini bar area at the bottom
    -- so touch events pass through to the rest of the screen.
    self:_applyMinimizedGeometry()
    logger.warn("AudiobookPlayer: minimized, dimen=",
        self.dimen.x, self.dimen.y, self.dimen.w, self.dimen.h)
    -- Full refresh to erase the full-screen player image and redraw only the
    -- mini bar, avoiding a ghost of the full player controls on e-ink.
    UIManager:setDirty("all", "full")
    if self.on_minimize then self.on_minimize() end
end

function AudiobookPlayer:_restore()
    self._minimized = false
    self._scrubber_dragging = false
    self._scrubber_drag_pct = nil
    -- Full-screen player covers the book (and status bars) while expanded.
    self.covers_fullscreen = true
    self.covers_footer = true
    -- Restore dimen to full screen so we receive all events again
    self.dimen.h = self.height
    self.dimen.y = 0
    UIManager:setDirty("all", "full")
end

function AudiobookPlayer:onChapterList()
    if not self.on_chapter_list then return end
    local cb = self.on_chapter_list
    -- Boox crashes when a second top-level dialog is stacked on the fullscreen
    -- player (covers_fullscreen + OpenGL).  Collapse to the mini bar first,
    -- then open the chapter picker on the next tick.
    if not self._minimized then
        pcall(function() self:onMinimize() end)
    end
    UIManager:scheduleIn(0.25, function()
        local ok, err = pcall(cb)
        if not ok then
            logger.err("AudiobookPlayer: chapter list failed:", err)
            local DL = package.loaded["audiobook_debuglog"]
            if DL and DL.log then
                pcall(DL.log, DL, "player: onChapterList failed:", tostring(err))
            end
            UIManager:show(require("ui/widget/infomessage"):new{
                text = _("Could not open chapter list.") .. "\n" .. tostring(err),
                timeout = 6,
            })
        end
    end)
end

function AudiobookPlayer:onShuffle()
    if self.on_shuffle then self.on_shuffle() end
end

function AudiobookPlayer:onLoop()
    if self.on_loop then self.on_loop() end
end

function AudiobookPlayer:onFixAudio()
    if self.on_fix_audio then self.on_fix_audio() end
end

function AudiobookPlayer:onSeek(pct)
    if self.on_seek then self.on_seek(pct) end
end

function AudiobookPlayer:onSpeed()
    if self.on_speed then self.on_speed() end
end

-- UI update helpers
function AudiobookPlayer:setPlaying(is_playing)
    -- Always push the icon/text even when the boolean is unchanged: on Boox
    -- the mini-bar dirty region sometimes misses the first toggle.
    self.is_playing = is_playing and true or false
    local txt = self.is_playing and "⏸" or "▶"
    if self.play_pause_button then
        self.play_pause_button:setText(txt, self.play_pause_button.width)
    end
    if self._mini_play_pause then
        self._mini_play_pause:setText(txt, self._mini_play_pause.width)
    end
    self:_dirtyChrome(self._minimized
        and (self._mini_play_pause and self._mini_play_pause.dimen)
        or (self.play_pause_button and self.play_pause_button.dimen))
end

--- Refresh a rectangle. Never fall back to the whole mini bar for a clock
--- tick — that is what made the entire chrome jump on Kindle e-ink.
function AudiobookPlayer:_dirtyChrome(region)
    local mode = self:_isEink() and "fast" or "ui"
    if not (region and region.w and region.h and region.w > 0 and region.h > 0) then
        if self._minimized then
            region = self:_miniTimeDirtyRegion()
        else
            UIManager:setDirty(self, mode)
            return
        end
    end
    UIManager:setDirty(self, function()
        return mode, region
    end)
end

--- Tight screen rect around the elapsed/total label (the only 1 Hz change).
function AudiobookPlayer:_miniTimeDirtyRegion()
    local t = self._mini_time
    if t and t.dimen and t.dimen.w and t.dimen.w > 0 then
        local d = t.dimen
        local pad = 2
        return Geom:new{
            x = math.max(0, d.x - pad),
            y = math.max(0, d.y - pad),
            w = d.w + pad * 2,
            h = d.h + pad * 2,
        }
    end
    local y = self:_miniBarY()
    local h = math.max(12, math.floor(self._mini_height * 0.42))
    local w = math.min(Screen:scaleBySize(180), self.width)
    return Geom:new{
        x = math.floor((self.width - w) / 2),
        y = y + self._mini_height - h - 2,
        w = w,
        h = h,
    }
end

function AudiobookPlayer:updateTimeDisplay(current_sec, total_sec, force)
    local text
    if self._time_display_mode == "chapter" and self._current_chapter_end > self._current_chapter_start then
        local chapter_pos = math.max(0, current_sec - self._current_chapter_start)
        local chapter_dur = self._current_chapter_end - self._current_chapter_start
        text = self:_formatTime(chapter_pos) .. " / " .. self:_formatTime(chapter_dur)
    else
        text = self:_formatTime(current_sec) .. " / " .. self:_formatTime(total_sec)
    end
    if text == self.current_time_str and not force then return end
    self.current_time_str = text
    self.time_widget:setText(text)
    if self._mini_time then
        self._mini_time:setText(text)
    end
    if self._minimized then
        self:_dirtyChrome(self:_miniTimeDirtyRegion())
    else
        self:_dirtyChrome(self.time_widget and self.time_widget.dimen)
    end
end

function AudiobookPlayer:updateProgress(progress, force)
    -- Suppress poller updates while user is dragging the scrubber
    if self._scrubber_dragging then return end
    if progress == self.progress and not force then return end
    self.progress = progress
    self.progress_bar:setPercentage(progress / 100)
    -- Mini chrome has no scrubber; time text is the 1 Hz progress. Dirtying
    -- the whole bar here is what made Kindle jump.
    if self._minimized then return end
    self:_dirtyChrome(self.progress_bar and self.progress_bar.dimen)
end

function AudiobookPlayer:updateChapterTitle(title)
    if title and title ~= self.chapter_title then
        self.chapter_title = title
        if self.chapter_widget then
            self.chapter_widget:setText(title)
        end
        -- Mini bar prefers chapter_title for read-aloud (see _updateMiniWidgets).
        if self._mini_title then
            self:_updateMiniWidgets()
            self:_dirtyChrome(self._mini_title.dimen or self:_miniTimeDirtyRegion())
        else
            self:_dirtyChrome(self.chapter_widget and self.chapter_widget.dimen)
        end
    end
end

function AudiobookPlayer:_formatSleepTimerText(remaining_seconds, active)
    if not active or remaining_seconds <= 0 then
        return "⏲"
    end
    return "⏲✓"
end

function AudiobookPlayer:_formatSleepTimerRemaining(remaining_seconds)
    local m = math.floor(remaining_seconds / 60)
    local s = remaining_seconds % 60
    if m >= 60 then
        local h = math.floor(m / 60)
        m = m % 60
        return T(_("%1 h %2 min %3 s"), h, m, s)
    end
    return T(_("%1 min %2 s"), m, s)
end

function AudiobookPlayer:updateSleepTimer(remaining_seconds, active)
    self._sleep_timer_remaining = remaining_seconds or 0
    self._sleep_timer_active = active and remaining_seconds > 0
    local text = self:_formatSleepTimerText(self._sleep_timer_remaining, self._sleep_timer_active)
    if self.sleep_timer_button then
        self.sleep_timer_button:setText(text, self.sleep_timer_button.width)
    end
    UIManager:setDirty(self, function()
        if self._minimized then
            return "ui", self.dimen
        end
        if self.sleep_timer_button and self.sleep_timer_button.dimen then
            return "ui", self.sleep_timer_button.dimen
        end
        return "ui", self.dimen
    end)
end

function AudiobookPlayer:onSleepTimer()
    if self._sleep_timer_active then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = T(_("Sleep timer active.\nTime remaining: %1\n\nCancel the timer?"), self:_formatSleepTimerRemaining(self._sleep_timer_remaining)),
            ok_text = _("Cancel"),
            cancel_text = _("Keep"),
            ok_callback = function()
                if self.on_sleep_timer_cancel then
                    self.on_sleep_timer_cancel()
                end
                self:updateSleepTimer(0, false)
            end,
        })
    else
        -- Let the plugin show a single hours+minutes picker (DateTimeWidget
        -- when available, sequential SpinWidget fallback).
        if self.plugin and self.plugin._showSleepTimerDialog then
            self.plugin:_showSleepTimerDialog(nil, function(total_minutes)
                if total_minutes and total_minutes > 0 and self.on_sleep_timer_set then
                    self.on_sleep_timer_set(total_minutes)
                    self:updateSleepTimer(total_minutes * 60, true)
                end
            end)
        else
            -- Fallback for unusual plugin states: use a single SpinWidget in minutes.
            local SpinWidget = require("ui/widget/spinwidget")
            UIManager:show(SpinWidget:new{
                title_text = _("Sleep timer"),
                info_text = _("Select minutes."),
                value = 15,
                value_min = 1,
                value_max = 180,
                value_step = 5,
                value_hold_step = 15,
                ok_text = _("Set"),
                callback = function(spin)
                    local total = spin.value
                    if total > 0 and self.on_sleep_timer_set then
                        self.on_sleep_timer_set(total)
                        self:updateSleepTimer(total * 60, true)
                    end
                end,
            })
        end
    end
end

function AudiobookPlayer:onRefocus()
    logger.warn("ABP: onRefocus called, on_refocus=", self.on_refocus and "set" or "nil")
    if self.on_refocus then
        self.on_refocus()
    end
    return true
end

function AudiobookPlayer:setCurrentChapter(chapter)
    if chapter then
        self._current_chapter_start = chapter.start_time or 0
        self._current_chapter_end = chapter.end_time or 0
    else
        self._current_chapter_start = 0
        self._current_chapter_end = 0
    end
end

function AudiobookPlayer:setTitle(title)
    self.title = title or _("Audiobook")
    if self.title_widget then
        self.title_widget:setText(self.title)
        UIManager:setDirty(self, function()
            return "ui", self.title_widget.dimen
        end)
    end
end

function AudiobookPlayer:setShuffleActive(active)
    if self.shuffle_button then
        self.shuffle_button.bordersize = active and Size.border.default or 0
        self.shuffle_button:init()
        UIManager:setDirty(self, function()
            return "ui", self.shuffle_button.dimen
        end)
    end
end

function AudiobookPlayer:setLoopActive(active)
    if self.loop_button then
        self.loop_button.bordersize = active and Size.border.default or 0
        self.loop_button:init()
        UIManager:setDirty(self, function()
            return "ui", self.loop_button.dimen
        end)
    end
end

function AudiobookPlayer:_buildOutputWidget(name)
    local max_w = self.width - Size.padding.small * 4
    local face = Font:getFace("cfont", 12)
    -- Simple word-wrap: split into up to 2 lines at word boundaries.
    local lines = {}
    if name and name ~= "" then
        local words = {}
        for w in name:gmatch("%S+") do
            table.insert(words, w)
        end
        local line1, line2 = "", ""
        for i, w in ipairs(words) do
            local test = line1 .. (line1 ~= "" and " " or "") .. w
            local tw = RenderText:sizeUtf8Text(0, max_w, face, test, true).x
            if tw <= max_w then
                line1 = test
            else
                -- remaining words go to line 2
                line2 = table.concat(words, " ", i)
                break
            end
        end
        if line1 ~= "" then table.insert(lines, line1) end
        if line2 ~= "" then
            local tw = RenderText:sizeUtf8Text(0, max_w, face, line2, true).x
            if tw > max_w then
                -- Truncate with ellipsis if still too long
                line2 = line2:sub(1, math.floor(#line2 * 0.8)) .. "…"
            end
            table.insert(lines, line2)
        end
    end
    if #lines == 0 then
        lines = { name or "" }
    end
    local widgets = {}
    for _, line in ipairs(lines) do
        table.insert(widgets, TextWidget:new{
            text = line,
            face = face,
            max_width = max_w,
        })
    end
    local vg = VerticalGroup:new{ align = "center" }
    for _, w in ipairs(widgets) do
        table.insert(vg, w)
    end
    return vg
end

function AudiobookPlayer:updateOutputName(name)
    if name and name ~= self.output_name then
        self.output_name = name
        self.output_widget = self:_buildOutputWidget(name)
        if self._minimized then
            self:_updateMiniWidgets()
            UIManager:setDirty(self, function()
                return "ui", self.dimen
            end)
        else
            UIManager:setDirty(self, function()
                return "ui", self.output_widget and self.output_widget.dimen or self.dimen
            end)
        end
    end
end

function AudiobookPlayer:_buildCoverFrame()
    local cover_height = self._cover_height or math.floor(math.min(self.width, self.height) * 0.32)
    local cover_width = self._cover_width or math.floor(cover_height * 0.75)

    -- Cache cover frames by path + dimensions so rotation does not re-decode and
    -- re-scale the image every time.
    local cache_key = string.format("%s|%dx%d", self.cover_image_path or "", cover_width, cover_height)
    if self._cover_frame_cache and self._cover_frame_cache[cache_key] then
        return self._cover_frame_cache[cache_key]
    end

    local frame
    if self.cover_image_path then
        local padding = Size.padding.small
        local max_w = cover_width - padding * 2
        local max_h = cover_height - padding * 2

        -- Let ImageWidget auto-scale the image to fit inside max_w x max_h
        -- without cropping.  scale_factor = 0 uses math.min so the entire
        -- image is visible, centered with blank space on the shorter side.
        local scale_factor = 0

        local function try_image(path)
            local widget = ImageWidget:new{
                file = path,
                width = max_w,
                height = max_h,
                scale_factor = scale_factor,
            }
            -- Force an early render so image-cache exhaustion is caught here
            -- instead of during the widget paint cycle (which would crash).
            widget:getSize()
            return widget
        end

        local ok, image_widget = pcall(try_image, self.cover_image_path)

        -- If the full-size cover exhausted KOReader's image cache, try a
        -- small thumbnail generated by ffmpeg (fits in ~200 kB vs ~4 MB).
        if not ok or not image_widget then
            local thumb_path = self.cover_image_path .. ".thumb.jpg"
            local ffmpeg_cmd = string.format(
                '"plugins/audiobook.koplugin/bin/ffmpeg" -y -i "%s" -vf "scale=300:-1" -q:v 2 -f image2 -vframes 1 "%s" 2>/dev/null',
                self.cover_image_path:gsub('"', '\\"'),
                thumb_path:gsub('"', '\\"')
            )
            os.execute(ffmpeg_cmd)
            local f = io.open(thumb_path, "r")
            if f then
                f:close()
                ok, image_widget = pcall(try_image, thumb_path)
            end
        end

        if ok and image_widget then
            frame = FrameContainer:new{
                width = cover_width,
                height = cover_height,
                background = self:_getThemeBackground(),
                bordersize = 0,
                padding = 0,
                CenterContainer:new{
                    dimen = Geom:new{ w = cover_width, h = cover_height },
                    image_widget,
                },
            }
        end
    end

    if not frame then
        -- Fallback: placeholder inside a framed box that blends with the theme
        local inner_widget = TextWidget:new{
            text = "♪",
            face = Font:getFace("cfont", 36),
        }
        frame = FrameContainer:new{
            width = cover_width,
            height = cover_height,
            background = self:_getThemeBackground(),
            bordersize = Size.border.thin,
            radius = Screen:scaleBySize(4),
            padding = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = cover_width, h = cover_height },
                inner_widget,
            },
        }
    end

    if not self._cover_frame_cache then self._cover_frame_cache = {} end
    self._cover_frame_cache[cache_key] = frame
    return frame
end

function AudiobookPlayer:setCoverImage(path)
    self.cover_image_path = path
    self._cover_frame_cache = nil
    -- Rebuild the cover frame widget
    if self.cover_frame then
        self.cover_frame = self:_buildCoverFrame()
        -- Rebuild the main layout with the new cover frame
        self:setupUI()
        -- Restore other state
        if self.chapter_title and self.chapter_title ~= "" then
            self.chapter_widget:setText(self.chapter_title)
        end
        if self.output_name and self.output_name ~= "" then
            self.output_widget = self:_buildOutputWidget(self.output_name)
        end
        self.time_widget:setText(self.current_time_str or "0:00 / 0:00")
        self.progress_bar:setPercentage((self.progress or 0) / 100)
        self.play_pause_button:setText(self.is_playing and "⏸" or "▶", self.play_pause_button.width)
        self.speed_button:setText(self:_speedText(), self.speed_button.width)
        UIManager:setDirty(self, "ui")
    end
end

function AudiobookPlayer:updateSpeed(speed)
    speed = tonumber(speed) or 1.0
    if speed ~= self.playback_speed then
        self.playback_speed = speed
        self.speed_button:setText(self:_speedText(), self.speed_button.width)
        UIManager:setDirty(self, function()
            return "ui", self.speed_button.dimen
        end)
    end
end

function AudiobookPlayer:_volumeText()
    return string.format("♪ %d%%", self.volume_pct or 100)
end

--- Nudge the volume by delta percent.  The on-screen value updates instantly;
--- non-Android backends debounce the apply (pipeline restart).  Android uses
--- MediaPlayer.setVolume live, so apply immediately for responsive ♪ buttons.
function AudiobookPlayer:_applyVolume(delta)
    local pct = (self.volume_pct or 100) + delta
    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end
    if pct == self.volume_pct then return end
    self.volume_pct = pct

    if self.volume_widget then
        self.volume_widget:setText(self:_volumeText())
    end
    -- Mini bar: flash the level in the time slot, like the sync nudge.
    if self._mini_time then
        self._mini_time:setText(string.format("vol %d%%", pct))
    end
    UIManager:setDirty(self, function()
        if self._minimized then return "ui", self.dimen end
        return "ui", self.volume_widget and self.volume_widget.dimen or nil
    end)

    local Device = require("device")
    local live = Device.isAndroid and Device:isAndroid()
    if live then
        if self._vol_apply_timer then
            UIManager:unschedule(self._vol_apply_timer)
            self._vol_apply_timer = nil
        end
        if self.on_volume then self.on_volume(self.volume_pct) end
        return
    end

    if self._vol_apply_timer then
        UIManager:unschedule(self._vol_apply_timer)
    end
    self._vol_apply_timer = UIManager:scheduleIn(0.6, function()
        self._vol_apply_timer = nil
        if self.on_volume then self.on_volume(self.volume_pct) end
    end)
end

--- External sync of the displayed volume (e.g. when restored from settings).
function AudiobookPlayer:updateVolume(pct)
    pct = tonumber(pct)
    if not pct then return end
    self.volume_pct = pct
    if self.volume_widget then
        self.volume_widget:setText(self:_volumeText())
        UIManager:setDirty(self, function()
            return "ui", self.volume_widget.dimen
        end)
    end
end

function AudiobookPlayer:_speedText()
    local s = self.playback_speed or 1.0
    if s == 1.0 then return "1×" end
    if s == math.floor(s) then return string.format("%d×", s) end
    return string.format("%.2f×", s):gsub("0×", "×"):gsub("%.(%d)0×", ".%1×")
end

function AudiobookPlayer:_formatTime(seconds)
    seconds = math.floor(seconds or 0)
    local mins = math.floor(seconds / 60)
    local secs = seconds % 60
    if mins >= 60 then
        local hours = math.floor(mins / 60)
        mins = mins % 60
        return string.format("%d:%02d:%02d", hours, mins, secs)
    end
    return string.format("%d:%02d", mins, secs)
end

-- Return the reader's configured background color so the overlay matches the
-- user's theme (white, sepia, dark, etc.) instead of forcing pure white.
-- KOReader widgets must manually invert for night mode; the framebuffer does
-- not do it automatically.
function AudiobookPlayer:_getThemeBackground()
    local bg_color

    -- Try ReaderUI's current page background first
    if self.plugin and self.plugin.ui and self.plugin.ui.view then
        local view = self.plugin.ui.view
        if view.page_bgcolor then
            bg_color = view.page_bgcolor
        end
    end

    if not bg_color then
        local ok, defaults = pcall(require, "defaults")
        if ok and defaults and defaults.readSetting then
            local bg_val = defaults:readSetting("DBACKGROUND_COLOR")
            if bg_val then
                bg_color = Blitbuffer.gray(bg_val * (1 / 15))
            end
        end
    end

    if not bg_color then
        bg_color = Blitbuffer.COLOR_WHITE
    end

    -- Night mode: invert the grayscale value so white becomes black.
    -- KOReader uses 8-bit e-ink colors where 0x00 = white and 0xFF = black.
    if Screen.night_mode then
        local gray_val = (type(bg_color) == "number") and bg_color or (bg_color.a or 0)
        bg_color = Blitbuffer.gray(0xFF - gray_val)
    end

    return bg_color
end

function AudiobookPlayer:_xToPercentage(x)
    if not self.progress_bar or not self.progress_bar.dimen then return nil end
    local bar_left = self.progress_bar.dimen.x
    local bar_width = self.progress_bar.dimen.w
    if not bar_left or not bar_width or bar_width <= 0 then return nil end
    local pct = (x - bar_left) / bar_width
    return math.max(0, math.min(1, pct))
end

function AudiobookPlayer:_updateScrubberPreview(x)
    local pct = self:_xToPercentage(x)
    if not pct then return end
    self._scrubber_drag_pct = pct
    self.progress_bar:setPercentage(pct)
    -- Use "fast" mode for drag updates: it refreshes the entire widget
    -- region more thoroughly than "ui", which reduces ghosting on e-ink
    -- screens during rapid scrubber movements.
    UIManager:setDirty(self, "fast")
end

function AudiobookPlayer:_updateMiniWidgets()
    -- Read-aloud: show the live SMIL chapter title. Fall back to output_name
    -- (track/book) when no chapter is known yet.
    -- When browsing away from the audio page, the title becomes a clear
    -- "Return to read-aloud" cue (tapping the bar centers on the sentence).
    local track
    if self._return_hint_active then
        track = _("Return to read-aloud")
    else
        track = self.chapter_title
        if not track or track == "" then
            track = self.output_name
        end
        if not track or track == "" then
            track = self.title or _("Audiobook")
        end
    end
    if self._mini_title then
        self._mini_title:setText(track)
    end
    if self._mini_time then
        self._mini_time:setText(self.current_time_str or "")
    end
    if self._mini_play_pause then
        local txt = self.is_playing and "⏸" or "▶"
        self._mini_play_pause:setText(txt, self._mini_play_pause.width)
    end
    if self._mini_refocus then
        -- Make the existing ○ control more obvious while the hint is active.
        local label = self._return_hint_active and "◎" or "○"
        self._mini_refocus:setText(label, self._mini_refocus.width)
    end
end

--- Toggle Readest-style "return to read-aloud" cue on the mini bar.
-- When active, tapping the mini bar (outside transport buttons) refocuses
-- instead of expanding the full player.
function AudiobookPlayer:setReturnHint(active)
    active = not not active
    if self._return_hint_active == active then return end
    self._return_hint_active = active
    if self._minimized then
        self:_updateMiniWidgets()
        UIManager:setDirty(self, function()
            return "ui", self.dimen
        end)
    end
end

-- Show / hide
function AudiobookPlayer:show()
    self.visible = true
    -- If setupUI already minimized us (read-along mode), keep it minimized
    -- and avoid a disruptive full-screen flash.
    UIManager:show(self, self._minimized and "ui" or "full")
end

function AudiobookPlayer:hide()
    self.visible = false
    self._minimized = false
    UIManager:close(self)
    UIManager:setDirty("all", "full")
end

function AudiobookPlayer:isVisible()
    return self.visible
end

-- Event handling
function AudiobookPlayer:handleEvent(event)
    -- Rotation support: KOReader dispatches SetRotationMode first, then
    -- SetDimensions.  On Kobo the framebuffer size never changes, so we
    -- track rotation mode and swap width/height ourselves.
    -- Rotation handling: UIManager:sendEvent only reaches the top widget.
    -- We must let ReaderUI handle rotation FIRST (it checks old Screen mode),
    -- then rotate Screen, then rebuild ourselves.  Order is critical:
    -- 1) ReaderUI sees old mode -> does full re-layout
    -- 2) Screen rotates atomically
    -- 3) Our widget rebuilds for the new orientation
    if event.handler == "onSetRotationMode" then
        local new_mode = event.args and event.args[1]
        logger.warn("ABP onSetRotationMode event, mode=", new_mode,
            "current=", self._rotation_mode)
        -- Hide our widget before the underlying UI rotates so the user never
        -- sees the old layout stretched into the new orientation.
        if self.visible then
            UIManager:close(self)
        end
        -- Let ReaderUI/FileManager do its rotation handling while Screen
        -- still reports the old mode (ReaderUI compares old vs new).
        if self.ui_widget then
            self.ui_widget:handleEvent(event)
        end
        -- Rotate the display atomically
        Screen:setRotationMode(new_mode)
        UIManager:onRotation()
        -- Rebuild and show for the new orientation now that Screen is updated.
        if self.visible then
            self:onSetDimensions(nil, new_mode)
        end
        return false
    end
    if event.handler == "onSetDimensions" then
        local size = event.args and event.args[1]
        return self:onSetDimensions(size)
    end

    -- When minimized, handle taps on the mini bar; forward ALL other gestures
    -- to the underlying UI widget (ReaderUI/FileManager) so the user can
    -- interact with menus, swipe pages, pull down the top bar, etc.
    if self._minimized then
        local arg1 = event.args and event.args[1]
        local is_gesture = event.handler == "onGesture" or (type(arg1) == "table" and arg1.ges)
        if is_gesture then
            local ges = type(arg1) == "table" and arg1 or nil
            if ges and self.plugin and self.plugin.session_recorder then
                self.plugin.session_recorder:recordGesture(ges, "audiobookplayer")
            end
            if ges and ges.pos then
                local mini_y = self:_miniBarY()
                local on_bar = ges.pos.y >= mini_y
                    and ges.pos.y < mini_y + self._mini_height
                    if on_bar and ges.ges == "tap" then
                    -- Tap on play/pause button?
                    if self:_isTapOnWidget(ges.pos, self._mini_play_pause) then
                        self:onPlayPause()
                        return true
                    end
                    -- Tap on chapter list (mini ☰)?
                    if self._mini_chapters
                        and self:_isTapOnWidget(ges.pos, self._mini_chapters) then
                        if self._mini_chapters.callback then
                            self._mini_chapters.callback()
                        end
                        return true
                    end
                    -- Tap on close button?
                    if self:_isTapOnWidget(ges.pos, self._mini_close) then
                        self:onClose()
                        return true
                    end
                    -- Tap on the read-along sync-nudge buttons?  These only
                    -- exist on the mini bar (read-along is always minimized),
                    -- so without handling them here the tap would fall through
                    -- to _restore() and the buttons would appear dead.  Invoke
                    -- the same callback the Button carries.
                    if self._mini_sync_minus
                        and self:_isTapOnWidget(ges.pos, self._mini_sync_minus) then
                        if self._mini_sync_minus.callback then
                            self._mini_sync_minus.callback()
                        end
                        return true
                    end
                    if self._mini_sync_plus
                        and self:_isTapOnWidget(ges.pos, self._mini_sync_plus) then
                        if self._mini_sync_plus.callback then
                            self._mini_sync_plus.callback()
                        end
                        return true
                    end
                    -- Tap on the volume buttons?
                    if self._mini_vol_minus
                        and self:_isTapOnWidget(ges.pos, self._mini_vol_minus) then
                        if self._mini_vol_minus.callback then
                            self._mini_vol_minus.callback()
                        end
                        return true
                    end
                    if self._mini_vol_plus
                        and self:_isTapOnWidget(ges.pos, self._mini_vol_plus) then
                        if self._mini_vol_plus.callback then
                            self._mini_vol_plus.callback()
                        end
                        return true
                    end
                    -- Tap on the refocus button?
                    if self._mini_refocus
                        and self:_isTapOnWidget(ges.pos, self._mini_refocus) then
                        logger.warn("ABP: refocus button tapped")
                        if self._mini_refocus.callback then
                            logger.warn("ABP: invoking refocus callback")
                            self._mini_refocus.callback()
                        else
                            logger.warn("ABP: refocus button has no callback")
                        end
                        return true
                    end
                    -- While browsing away from the narration page, a tap on
                    -- the unused mini-bar area means "return to read-aloud"
                    -- (same as ○), not "expand full player".
                    if self._return_hint_active and self.on_refocus then
                        logger.warn("ABP: return-hint bar tap -> refocus")
                        self:onRefocus()
                        return true
                    end
                    -- Tap anywhere else on the mini bar -> restore full player
                    self:_restore()
                    return true
                end
                -- Gesture outside mini bar (or non-tap on bar) -> forward to underlying UI
                if self.ui_widget then
                    return self.ui_widget:handleEvent(event)
                end
                return false
            end
        end
        -- Non-gesture events pass through
        return false
    end

    local arg1 = event.args and event.args[1]
    if event.handler == "onGesture" or (type(arg1) == "table" and arg1.ges) then
        local ges = type(arg1) == "table" and arg1 or nil
        if ges and self.plugin and self.plugin.session_recorder then
            self.plugin.session_recorder:recordGesture(ges, "audiobookplayer")
        end
        if not ges then return false end

        -- DEBUG: log every gesture we receive
        logger.warn("ABP gesture:", ges.ges,
            "pos=", ges.pos and (tostring(ges.pos.x) .. "," .. tostring(ges.pos.y)) or "nil",
            "minimized=", self._minimized,
            "dragging=", self._scrubber_dragging)

        -- Let hold pass through unconditionally.
        -- Swipe is treated as a release when we're in the middle of a drag.
        if ges.ges == "hold" then
            return false
        end
        if ges.ges == "swipe" and self._scrubber_dragging then
            -- Gesture detector sometimes emits swipe instead of pan_release.
            -- Treat it as a release and perform the seek.
            logger.warn("ABP swipe while dragging -> seek")
            self._scrubber_dragging = false
            if self._scrubber_drag_pct and self.on_seek then
                self:onSeek(self._scrubber_drag_pct)
                self._scrubber_drag_pct = nil
            end
            return true
        end

        -- Pan / hold_pan on progress bar: visual drag preview
        -- NOTE: hold_pan is what KOReader emits for press-and-drag on e-ink.
        -- pan is what KOReader emits for quick drags (move > PAN_THRESHOLD while down).
        if (ges.ges == "pan" or ges.ges == "hold_pan") and ges.pos then
            if self.progress_bar and self.progress_bar.dimen then
                local bar_y = self.progress_bar.dimen.y
                local bar_h = self.progress_bar.dimen.h
                local in_zone = ges.pos.y >= bar_y - self._scrubber_touch_height / 2
                    and ges.pos.y <= bar_y + bar_h + self._scrubber_touch_height / 2
                logger.warn("ABP pan/hold_pan bar_y=", bar_y, "bar_h=", bar_h,
                    "touch_h=", self._scrubber_touch_height,
                    "in_zone=", in_zone, "dragging=", self._scrubber_dragging)
                if in_zone then
                    self:_updateScrubberPreview(ges.pos.x)
                    self._scrubber_dragging = true
                    return true
                end
            else
                logger.warn("ABP pan/hold_pan NO progress_bar.dimen")
            end
        end

        -- Pan release / hold release on progress bar: perform seek
        if (ges.ges == "pan_release" or ges.ges == "hold_release")
            and self._scrubber_dragging then
            self._scrubber_dragging = false
            if self._scrubber_drag_pct and self.on_seek then
                self:onSeek(self._scrubber_drag_pct)
                self._scrubber_drag_pct = nil
            end
            return true
        end

        -- Tap handling
        if ges.ges == "tap" and ges.pos then
            -- If we were dragging and got a tap instead of pan_release, complete the seek
            -- only if the tap is on or near the progress bar.  Otherwise cancel the drag.
            if self._scrubber_dragging then
                local on_bar = false
                if self.progress_bar and self.progress_bar.dimen then
                    local bar_y = self.progress_bar.dimen.y
                    local bar_h = self.progress_bar.dimen.h
                    on_bar = ges.pos.y >= bar_y - self._scrubber_touch_height
                        and ges.pos.y <= bar_y + bar_h + self._scrubber_touch_height
                end
                if on_bar then
                    self._scrubber_dragging = false
                    local pct = self:_xToPercentage(ges.pos.x)
                    if pct and self.on_seek then
                        self:onSeek(pct)
                        self._scrubber_drag_pct = nil
                    end
                    return true
                else
                    -- Cancel the stale drag
                    self._scrubber_dragging = false
                    self._scrubber_drag_pct = nil
                end
            end

            -- Check if tap is inside any button
            local buttons = {
                self.play_pause_button, self.skip_back_button, self.skip_forward_button,
                self.prev_chapter_button, self.next_chapter_button,
                self.speed_button, self.close_button, self.minimize_button,
                self.chapter_list_button, self.sleep_timer_button,
                self.vol_minus_button, self.vol_plus_button,
            }
            if self.show_shuffle and self.shuffle_button then
                table.insert(buttons, self.shuffle_button)
            end
            if self.show_loop and self.loop_button then
                table.insert(buttons, self.loop_button)
            end
            for _, btn in ipairs(buttons) do
                if self:_isTapOnWidget(ges.pos, btn) then
                    return InputContainer.handleEvent(self, event)
                end
            end

            -- Check time widget tap (toggle book/chapter time display)
            if self.time_widget and self.time_widget.dimen then
                if self:_isTapOnWidget(ges.pos, self.time_widget) then
                    self._time_display_mode = (self._time_display_mode == "book")
                        and "chapter" or "book"
                    -- Force a time refresh on next poller tick by clearing cached string
                    self.current_time_str = nil
                    return true
                end
            end

            -- Check progress bar area (tap to seek)
            if self.progress_bar and self.progress_bar.dimen then
                local bar_y = self.progress_bar.dimen.y
                local bar_h = self.progress_bar.dimen.h
                if ges.pos.y >= bar_y - self._scrubber_touch_height / 2
                    and ges.pos.y <= bar_y + bar_h + self._scrubber_touch_height / 2 then
                    local pct = self:_xToPercentage(ges.pos.x)
                    if pct then
                        self:onSeek(pct)
                        return true
                    end
                end
            end

            -- Tap outside any control: do nothing (only X closes)
            return true
        end
    end

    return InputContainer.handleEvent(self, event)
end

function AudiobookPlayer:_isTapOnWidget(pos, widget)
    if not widget or not widget.dimen then return false end
    local d = widget.dimen
    return pos.x >= d.x and pos.x <= d.x + d.w
        and pos.y >= d.y and pos.y <= d.y + d.h
end

function AudiobookPlayer:_doRebuild(new_w, new_h)
    -- Preserve state across the rebuild
    local was_minimized = self._minimized
    local was_playing = self.is_playing
    local title = self.title
    local chapter = self.chapter_title
    local output = self.output_name
    local progress = self.progress
    local time_str = self.current_time_str
    local speed = self.playback_speed
    local cover_path = self.cover_image_path
    -- Re-derive dimensions from the (potentially rotated) screen
    self.width = new_w
    self.height = new_h
    self._rotation_mode = Screen:getRotationMode()
    -- Rebuild the UI tree with new dimensions
    self:setupUI()
    -- Restore state into the fresh widgets
    self.is_playing = was_playing
    self.title = title
    self.chapter_title = chapter
    self.output_name = output
    self.progress = progress
    self.current_time_str = time_str
    self.playback_speed = speed
    self.cover_image_path = cover_path
    self.play_pause_button:setText(was_playing and "⏸" or "▶", self.play_pause_button.width)
    if chapter and chapter ~= "" then self.chapter_widget:setText(chapter) end
    if output and output ~= "" then self.output_widget = self:_buildOutputWidget(output) end
    self.time_widget:setText(time_str or "0:00 / 0:00")
    self.progress_bar:setPercentage((progress or 0) / 100)
    self.speed_button:setText(self:_speedText(), self.speed_button.width)
    self:_updateMiniWidgets()
    -- Position at the correct coordinates for the new dimensions
    self.visible = true
    if was_minimized then
        self:_applyMinimizedGeometry()
    else
        self._minimized = false
        self.covers_fullscreen = true
        self.covers_footer = true
        self.dimen.h = self.height
        self.dimen.y = 0
    end
end

-- Handle rotation mode change.  On Kobo the framebuffer size is fixed
-- (1264x1680) and the hardware rotates the display; we must rebuild
-- with the SAME dimensions so the framebuffer content is rotated
-- Handle screen dimension changes (e.g. after device rotation).
-- We close and re-show the widget so UIManager registers the new
-- x, y coordinates, matching how PlaybackBar handles rotation.
function AudiobookPlayer:onSetDimensions(size, rotation_mode)
    if not self.visible then return end
    -- Kobo framebuffer is fixed at 1264x1680.  Standalone widgets never see
    -- updated Screen dimensions after rotation, so we derive logical size
    -- from the rotation mode passed in (or from the event that triggered us).
    local rot = rotation_mode or Screen:getRotationMode()
    local new_w, new_h
    if size and size.w and size.h then
        new_w = size.w
        new_h = size.h
    elseif rot == 1 or rot == 3 then
        new_w = 1680
        new_h = 1264
    else
        new_w = 1264
        new_h = 1680
    end
    logger.warn("AudiobookPlayer: onSetDimensions, size=",
        size and (size.w .. "x" .. size.h) or "nil",
        "rot=", rot, "using=", new_w, "x", new_h,
        "screen=", Screen:getWidth(), "x", Screen:getHeight())
    -- Remove from UIManager so old coordinates are discarded
    UIManager:close(self)
    self:_doRebuild(new_w, new_h)
    -- Re-show at the correct position — this registers the new x,y with
    -- UIManager so paintTo receives the right coordinates.
    UIManager:show(self, "ui")
    UIManager:setDirty(self, "ui")
    return true
end

function AudiobookPlayer:onCloseWidget()
    -- Cleanup hook
end

--- Extra window-stack widgets (menus/dialogs) besides this chrome.
function AudiobookPlayer:_isOverlayActive()
    local stack = UIManager._window_stack
    if not stack then return false end
    local non_toast = 0
    for i = 1, #stack do
        local w = stack[i].widget
        if w ~= self and not w.toast and not w._plugin_chrome then
            non_toast = non_toast + 1
            if non_toast > 1 then
                return true
            end
        end
    end
    return false
end

function AudiobookPlayer:paintTo(bb, x, y)
    if not self.visible then return end
    if self._minimized then
        -- Draw only the mini player bar at bottom (optionally above status bar).
        -- UIManager's window.y for this widget is always 0 (set when first shown),
        -- so we must add the bottom offset ourselves.
        if self._mini_bar and self._mini_bar.paintTo then
            self._mini_bar:paintTo(bb, x or 0, (y or 0) + self:_miniBarY())
        end
        return
    end
    if self[1] and self[1].paintTo then
        self[1]:paintTo(bb, x or 0, y or 0)
    end
end

return AudiobookPlayer
