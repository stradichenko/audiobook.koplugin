--[[--
Self-updater for the Audiobook Read-Along plugin.

Checks the latest GitHub release, compares with the installed version,
downloads and extracts the update zip, then asks the user to restart.

Uses KOReader's built-in LuaSocket/LuaSec for HTTPS, libarchive for
zip extraction, and NetworkMgr for connectivity gating.

@module updater
--]]

local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Updater = {}

local REPO = "stradichenko/audiobook.koplugin"
local API_URL = "https://api.github.com/repos/" .. REPO .. "/releases/latest"

-- Resolve the plugin directory from this file's location.
local _dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"

--- Read the currently installed version from _meta.lua.
-- @treturn string version string (e.g. "0.1.5.55")
local function installedVersion()
    local meta = dofile(_dir .. "_meta.lua")
    return meta and meta.version or "0.0.0"
end

--- Fetch the latest release metadata from GitHub.
-- @treturn table|nil {tag, version, zip_url} on success, nil on failure
-- @treturn string|nil error message on failure
local function fetchLatestRelease()
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")

    local sink = {}
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, headers, status = require("socket").skip(1, http.request{
        url = API_URL,
        method = "GET",
        headers = {
            ["Accept"] = "application/vnd.github+json",
            ["User-Agent"] = "audiobook.koplugin-updater",
        },
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()

    if code ~= 200 then
        return nil, T(_("GitHub API returned %1"), tostring(code or status or "no response"))
    end

    local body = table.concat(sink)
    local JSON = require("json")
    local ok, data = pcall(JSON.decode, body)
    if not ok or type(data) ~= "table" then
        local preview = body and tostring(body):sub(1, 200) or "(empty)"
        logger.warn("Updater: JSON parse failed:", tostring(data), "body:", preview)
        return nil, _("Failed to parse GitHub response")
    end

    -- Find the zip asset matching our release naming convention
    local zip_url
    if data.assets then
        for _, asset in ipairs(data.assets) do
            if asset.browser_download_url
                and asset.browser_download_url:match("audiobook%-koplugin.*%.zip$") then
                zip_url = asset.browser_download_url
                break
            end
        end
    end

    if not zip_url then
        return nil, _("No plugin zip found in the latest release")
    end

    -- tag_name is typically "v0.1.5.55"; strip leading "v"
    local tag = data.tag_name or ""
    local version = tag:gsub("^v", "")

    return { tag = tag, version = version, zip_url = zip_url }
end

--- Download a URL to a local file path.
-- @tparam string url
-- @tparam string dest path
-- @treturn bool success
-- @treturn string|nil error message
local function downloadFile(url, dest)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")

    local fh, err = io.open(dest, "w")
    if not fh then
        return false, T(_("Cannot create %1: %2"), dest, err or "unknown")
    end

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, headers, status = require("socket").skip(1, http.request{
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = "audiobook.koplugin-updater",
        },
        sink = ltn12.sink.file(fh),  -- closes fh on completion
    })
    socketutil:reset_timeout()

    if code ~= 200 then
        os.remove(dest)
        return false, T(_("Download failed: %1"), tostring(code or status or "no response"))
    end
    return true
end

--- Compare two dotted version strings.
-- @treturn number -1 if a < b, 0 if equal, 1 if a > b
local function compareVersions(a, b)
    local function parts(v)
        local t = {}
        for n in v:gmatch("(%d+)") do t[#t + 1] = tonumber(n) end
        return t
    end
    local pa, pb = parts(a), parts(b)
    local len = math.max(#pa, #pb)
    for i = 1, len do
        local na, nb = pa[i] or 0, pb[i] or 0
        if na < nb then return -1 end
        if na > nb then return 1 end
    end
    return 0
end

--- Run the full check-and-update flow (called from the menu).
-- @tparam table plugin  the Audiobook WidgetContainer instance
function Updater.checkForUpdate(plugin)
    -- Gate on network connectivity; re-runs this function once online.
    if NetworkMgr.willRerunWhenOnline then
        if NetworkMgr:willRerunWhenOnline(function()
            Updater.checkForUpdate(plugin)
        end) then
            return
        end
    elseif not NetworkMgr:isConnected() then
        UIManager:show(InfoMessage:new{
            text = _("No network connection. Please connect to Wi-Fi first."),
        })
        return
    end

    UIManager:show(InfoMessage:new{
        text = _("Checking for updates..."),
        timeout = 2,
    })
    UIManager:forceRePaint()

    local release, err = fetchLatestRelease()
    if not release then
        UIManager:show(InfoMessage:new{
            text = T(_("Update check failed: %1"), err or _("unknown error")),
        })
        return
    end

    local current = installedVersion()
    if compareVersions(release.version, current) <= 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("Already up to date (v%1)."), current),
        })
        return
    end

    UIManager:show(ConfirmBox:new{
        text = T(_("Update available: v%1 (installed: v%2).\n\nDownload and install?"),
                 release.version, current),
        ok_text = _("Update"),
        ok_callback = function()
            Updater._performUpdate(plugin, release)
        end,
    })
end

--- Download, extract, and install the update.
-- @tparam table plugin
-- @tparam table release  {tag, version, zip_url}
function Updater._performUpdate(plugin, release)
    UIManager:show(InfoMessage:new{
        text = _("Downloading update..."),
        timeout = 60,
    })
    UIManager:forceRePaint()

    -- Use external storage on PocketBook: /tmp is a tiny tmpfs that
    -- fills up and destabilises the device when large zips are written.
    local tmp_dir = os.getenv("TMPDIR") or "/tmp"
    local created_ext_tmp = false
    local Device = require("device")
    if Device:isPocketBook() then
        local ext = "/mnt/ext1/tmp"
        local lfs = require("libs/libkoreader-lfs")
        local already_exists = lfs.attributes(ext, "mode") == "directory"
        os.execute('mkdir -p "' .. ext .. '" 2>/dev/null')
        if lfs.attributes(ext, "mode") == "directory" then
            tmp_dir = ext
            created_ext_tmp = not already_exists
        end
    end
    local zip_path = tmp_dir .. "/audiobook-koplugin-update.zip"

    local ok, err = downloadFile(release.zip_url, zip_path)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Download failed: %1"), err or _("unknown")),
        })
        return
    end

    -- Determine install target: the directory containing this plugin
    local plugin_dir = _dir:gsub("/$", "")  -- e.g. ".../plugins/audiobook.koplugin"

    logger.warn("Updater: extracting", zip_path, "to", plugin_dir)

    -- Use KOReader's Device:unpackArchive which handles stripping the
    -- top-level directory from the zip (GitHub release zips contain
    -- "audiobook.koplugin/...").
    local extract_ok, extract_err
    if Device.unpackArchive then
        extract_ok, extract_err = Device:unpackArchive(zip_path, plugin_dir, true)
    else
        -- Fallback: use system unzip
        local ret = os.execute(
            'unzip -o "' .. zip_path .. '" -d "' .. tmp_dir .. '/audiobook-update-tmp" 2>/dev/null')
        if ret == 0 then
            -- Find the extracted subdirectory and copy contents
            local lfs = require("libs/libkoreader-lfs")
            for entry in lfs.dir(tmp_dir .. "/audiobook-update-tmp") do
                if entry ~= "." and entry ~= ".." then
                    local src = tmp_dir .. "/audiobook-update-tmp/" .. entry
                    os.execute('cp -rf "' .. src .. '"/* "' .. plugin_dir .. '/" 2>/dev/null')
                    break
                end
            end
            extract_ok = true
        else
            extract_ok = false
            extract_err = "unzip returned " .. tostring(ret)
        end
        os.execute('rm -rf "' .. tmp_dir .. '/audiobook-update-tmp" 2>/dev/null')
    end

    -- Clean up the downloaded zip and, on PocketBook, the tmp directory if
    -- we created it (it is normally absent and the plugin should not leave
    -- it behind after an update).
    os.remove(zip_path)
    if created_ext_tmp then
        os.execute('rmdir "' .. tmp_dir .. '" 2>/dev/null')
    end

    if not extract_ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Extraction failed: %1"), extract_err or _("unknown")),
        })
        return
    end

    logger.warn("Updater: successfully installed v" .. release.version)
    
    -- Ensure latest release version is written in _meta.lua
    local meta_lua = _dir .. "_meta.lua"
    local f = io.open(meta_lua, "r")
    local content = f:read("*a")
    f:close()
    content = content:gsub('version%s*=%s*".-"', 'version = "' .. release.version .. '"')
    f = io.open(meta_lua, "w")
    f:write(content)
    f:close()

    UIManager:show(ConfirmBox:new{
        text = T(_("Updated to v%1.\n\nRestart KOReader to apply the update."), release.version),
        ok_text = _("Restart now"),
        ok_callback = function()
            UIManager:restartKOReader()
        end,
        cancel_text = _("Later"),
        dismissable = false,
    })
end

return Updater
