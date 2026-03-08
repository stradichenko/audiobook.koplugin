--[[--
Bluetooth UI functions for the Audiobook plugin.
Handles BT device menus, connect/disconnect, scan, and
the disconnect alert watcher.

All functions take `plugin` (the Audiobook WidgetContainer instance)
as their first parameter to access settings, bt_manager, etc.

@module btui
--]]

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local BtUI = {}

--- Build the BT disconnect alert interval submenu.
function BtUI.buildBTDisconnectMenu(plugin)
    local options = {
        { label = _("Off"),  value = 0 },
        { label = _("15 s"), value = 15 },
        { label = _("30 s"), value = 30 },
        { label = _("60 s"), value = 60 },
    }
    local items = {}
    for _, opt in ipairs(options) do
        table.insert(items, {
            text = opt.label,
            checked_func = function()
                return plugin:getSetting("bt_disconnect_check", 30) == opt.value
            end,
            callback = function()
                plugin:setSetting("bt_disconnect_check", opt.value)
            end,
        })
    end
    return items
end

--- Top-level label for the Bluetooth menu entry.
-- Shows connected device name when available.
function BtUI.btMenuLabel(plugin)
    local bt = plugin.bt_manager
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
    local saved = plugin:getSetting("bt_device_name", nil)
    if saved then
        return T(_("BT: %1 (not connected)"), saved)
    end
    return _("Bluetooth (on)")
end

function BtUI.buildBluetoothMenu(plugin)
    local bt = plugin.bt_manager
    local powered = bt:isPowered()
    local menu = {}

    -- Power toggle
    table.insert(menu, {
        text = powered and _("Turn Bluetooth off") or _("Turn Bluetooth on"),
        callback = function()
            if powered then
                bt:powerOff()
                plugin:setSetting("bt_device_addr", nil)
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
            BtUI.btScanAndShow(plugin)
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
                BtUI.btQuickConnect(plugin, dev, touchmenu_instance)
            end,
            -- Hold = show more actions (forget, info)
            hold_callback = function(touchmenu_instance)
                BtUI.btDeviceHoldMenu(plugin, dev, touchmenu_instance)
            end,
            checked_func = function()
                return dev.connected
            end,
        })
    end

    return menu
end

--- Quick connect/disconnect: tap on a device row in the BT menu.
function BtUI.btQuickConnect(plugin, dev, touchmenu_instance)
    local bt = plugin.bt_manager
    local name = dev.name ~= "" and dev.name or dev.address

    if dev.connected then
        -- Already connected → disconnect
        bt:disconnect(dev.address)
        dev.connected = false  -- update captured state so checked_func refreshes
        plugin:setSetting("bt_device_addr", nil)
        plugin:setSetting("bt_device_name", nil)
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
            plugin:setSetting("bt_device_addr", dev.address)
            plugin:setSetting("bt_device_name", name)
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
function BtUI.btDeviceHoldMenu(plugin, dev, touchmenu_instance)
    local bt = plugin.bt_manager
    local name = dev.name ~= "" and dev.name or dev.address
    local ButtonDialog = require("ui/widget/buttondialog")

    local buttons = {}

    if dev.connected then
        table.insert(buttons, {{
            text = _("Disconnect"),
            callback = function()
                UIManager:close(plugin._bt_dialog)
                bt:disconnect(dev.address)
                plugin:setSetting("bt_device_addr", nil)
                plugin:setSetting("bt_device_name", nil)
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
                UIManager:close(plugin._bt_dialog)
                BtUI.btQuickConnect(plugin, dev)
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
                UIManager:close(plugin._bt_dialog)
                bt:remove(dev.address)
                if dev.address == plugin:getSetting("bt_device_addr", nil) then
                    plugin:setSetting("bt_device_addr", nil)
                    plugin:setSetting("bt_device_name", nil)
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
            UIManager:close(plugin._bt_dialog)
        end,
    }})

    plugin._bt_dialog = ButtonDialog:new{
        title = name,
        buttons = buttons,
    }
    UIManager:show(plugin._bt_dialog)
end

function BtUI.btScanAndShow(plugin)
    local bt = plugin.bt_manager

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

-- ── BT Disconnect Watcher ────────────────────────────────────────────

-- Start a low-frequency Bluetooth disconnect watcher while read-along
-- is active.  It checks, via D-Bus, whether any audio-related BT
-- device is still connected, and shows a notification if everything
-- disconnects.  Runs only while this plugin is in use to avoid
-- unnecessary battery drain.
function BtUI.startWatcher(plugin)
    local interval = plugin:getSetting("bt_disconnect_check", 30)
    if interval == 0 then
        return  -- user disabled the alert
    end
    if plugin._bt_disconnect_watching then
        return
    end
    plugin._bt_disconnect_watching = true
    plugin._bt_last_connected = nil
    BtUI._scheduleBTDisconnectCheck(plugin)
end

function BtUI.stopWatcher(plugin)
    plugin._bt_disconnect_watching = false
end

function BtUI._scheduleBTDisconnectCheck(plugin)
    if not plugin._bt_disconnect_watching then
        return
    end
    -- Check at a coarse interval to keep overhead and wakeups low.
    local interval = plugin:getSetting("bt_disconnect_check", 30)
    if interval == 0 then
        plugin._bt_disconnect_watching = false
        return
    end
    UIManager:scheduleIn(interval, function()
        if not plugin._bt_disconnect_watching then
            return
        end

        local any_connected = false
        local ok, devices = pcall(plugin.bt_manager.listAudioDevices, plugin.bt_manager)
        if ok and devices then
            for _, dev in ipairs(devices) do
                if dev.connected then
                    any_connected = true
                    break
                end
            end
        end

        if plugin._bt_last_connected == nil then
            plugin._bt_last_connected = any_connected
        elseif plugin._bt_last_connected and not any_connected then
            plugin._bt_last_connected = any_connected
            UIManager:show(InfoMessage:new{
                text = _("Bluetooth audio device disconnected."),
                timeout = 4,
            })
        else
            plugin._bt_last_connected = any_connected
        end

        -- Reschedule next check while watcher is active
        if plugin._bt_disconnect_watching then
            BtUI._scheduleBTDisconnectCheck(plugin)
        end
    end)
end

return BtUI
