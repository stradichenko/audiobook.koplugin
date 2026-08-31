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
local _ = require("audiobook_gettext")
local T = require("ffi/util").template

local Updater = {}

-- Files that must exist after extraction; if any are missing, the plugin
-- will be left in a broken state (menus grayed out, media playback unavailable).
local CRITICAL_FILES = {
    "_meta.lua",
    "main.lua",
    "mediaengine.lua",
    "mediasync.lua",
    "transcoder.lua",
    "abssync.lua",
    "abscache.lua",
    "audiobookplayer.lua",
    "downloader.lua",
    "mediaaligner.lua",
    "ttsengine.lua",
    "synccontroller.lua",
    "menubuilder.lua",
    "bugreport.lua",
}

--- Verify that all critical plugin files are present.
-- @treturn bool success
-- @treturn string|nil first missing file
local function verifyPluginDir(plugin_dir)
    for _, file in ipairs(CRITICAL_FILES) do
        local f = io.open(plugin_dir .. "/" .. file, "r")
        if not f then
            return false, file
        end
        f:close()
    end
    return true
end

local REPO = "stradichenko/audiobook.koplugin"
local API_URL = "https://api.github.com/repos/" .. REPO .. "/releases/latest"

-- Resolve the plugin directory from this file's location.
-- Collapse repeated slashes: if the loader path already ended with one,
-- the chunk path contains "//" and a naive parent-directory match fails.
local _dir = (debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"):gsub("//+", "/")

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
    local zip_url, zip_size
    if data.assets then
        for _, asset in ipairs(data.assets) do
            if asset.browser_download_url
                and asset.browser_download_url:match("audiobook%-koplugin.*%.zip$") then
                zip_url = asset.browser_download_url
                zip_size = tonumber(asset.size)
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

    return { tag = tag, version = version, zip_url = zip_url, zip_size = zip_size }
end

--- Free space in kB on the filesystem holding path (via busybox df).
-- @tparam string path
-- @treturn number|nil free kB, or nil when undeterminable
local function freeSpaceKb(path)
    local h = io.popen('df -k "' .. path .. '" 2>/dev/null | tail -1')
    if not h then return nil end
    local line = h:read("*a") or ""
    h:close()
    -- df -k columns: Filesystem  1K-blocks  Used  Available  Use%  Mounted
    local avail = line:match("%s(%d+)%s+%d+%%")
    return tonumber(avail)
end

--- Download a URL to a local file path, with resume support.
-- Downloads can be large (the release zip includes ffmpeg/Piper binaries),
-- so we use HTTP Range requests to resume after a network drop or timeout.
-- A partial file is kept on failure so the next attempt resumes where this
-- one stopped; a sidecar marker guards against resuming into a DIFFERENT
-- release's bytes (same fixed dest path, new zip on the server).
-- @tparam string url
-- @tparam string dest path
-- @tparam number|nil expected_size expected file size in bytes
-- @treturn bool success
-- @treturn string|nil error message
local function downloadFile(url, dest, expected_size)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local lfs = require("libs/libkoreader-lfs")

    local max_retries = 5
    local retry_count = 0
    -- Hard cap on total attempts so a connection that creeps forward one
    -- byte at a time cannot loop forever (progress resets retry_count).
    local max_total_attempts = 25
    local total_attempts = 0

    -- Stale-partial guard: only resume a previous partial when it was
    -- downloaded against the same expected size.
    local marker = dest .. ".expected"
    if expected_size then
        local mf = io.open(marker, "r")
        local marker_val = mf and mf:read("*a")
        if mf then mf:close() end
        if marker_val ~= tostring(expected_size) then
            if lfs.attributes(dest) then
                logger.warn("Updater: discarding stale partial download",
                    "(marker:", tostring(marker_val), "expected:", expected_size, ")")
                os.remove(dest)
            end
            local wf = io.open(marker, "w")
            if wf then
                wf:write(tostring(expected_size))
                wf:close()
            end
        end
    end

    while true do
        local attr = lfs.attributes(dest)
        local existing_size = (attr and attr.size) or 0
        if existing_size > 0 and expected_size and existing_size >= expected_size then
            os.remove(marker)
            return true
        end

        local mode = (existing_size > 0) and "a+b" or "wb"
        local fh, err = io.open(dest, mode)
        if not fh then
            return false, T(_("Cannot create %1: %2"), dest, err or "unknown")
        end

        -- Scale the total timeout with the remaining bytes so slow Wi-Fi or
        -- large zips do not abort prematurely. Base 10 minutes plus one minute
        -- per 20 MB remaining, capped at 30 minutes.
        local remaining = expected_size and math.max(expected_size - existing_size, 0) or 0
        local total_timeout = 600
        if remaining > 0 then
            total_timeout = math.min(total_timeout + math.ceil(remaining / (20 * 1024 * 1024)) * 60, 1800)
        end
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, total_timeout)

        local headers = {
            ["User-Agent"] = "audiobook.koplugin-updater",
        }
        if existing_size > 0 then
            headers["Range"] = string.format("bytes=%d-", existing_size)
        end

        local bytes_before = existing_size
        local code, res_headers, status = require("socket").skip(1, http.request{
            url = url,
            method = "GET",
            headers = headers,
            sink = ltn12.sink.file(fh),  -- closes fh on completion
        })
        socketutil:reset_timeout()

        local attr2 = lfs.attributes(dest)
        local bytes_after = attr2 and attr2.size or bytes_before

        if code == 200 or code == 206 then
            if code == 200 and existing_size > 0 then
                -- Server ignored the Range header and sent the full file,
                -- so the existing partial data is now duplicated at the start.
                logger.warn("Updater: server ignored Range request, restarting download")
                os.remove(dest)
                retry_count = retry_count + 1
                if retry_count > max_retries then
                    return false, _("Server does not support resume")
                end
            elseif not expected_size then
                os.remove(marker)
                return true
            elseif bytes_after >= expected_size then
                os.remove(marker)
                return true
            elseif bytes_after == bytes_before then
                logger.warn("Updater: no download progress, retrying", bytes_after)
                retry_count = retry_count + 1
                if retry_count > max_retries then
                    -- Keep the partial file: the next attempt resumes here.
                    return false, T(_("Download stalled at %1 bytes.\nTrying again will resume from that point."),
                        tostring(bytes_after))
                end
            else
                retry_count = 0
            end
        else
            local err_str = tostring(code or status or "")
            -- ENOSPC is terminal: no amount of retrying frees storage.
            -- Seen in the wild as repeated ~59 MB stalls on a full Kindle
            -- (issue #46), misreported as a network stall.
            if err_str:lower():find("no space") then
                logger.err("Updater: download failed, disk full at", bytes_after, "bytes")
                return false, T(_("Storage is full: the download stopped at %1 MB because the device has no free space left.\n\nFree up space (e.g. delete books or files via USB, or clean KOReader's cache), then try again. The download will resume where it stopped."),
                    tostring(math.floor(bytes_after / 1048576)))
            end
            logger.warn("Updater: download request failed:", tostring(code or status), "size:", bytes_after)
            if bytes_after > bytes_before then
                -- The attempt stalled mid-read (LuaSec "wantread", seen on
                -- Kindle Wi-Fi at ~47-57 MB into the zip, issue #46) but it
                -- DID advance the partial file, so resume is making real
                -- progress.  Do not burn a retry on forward motion: only
                -- consecutive no-progress attempts count toward the abort
                -- limit, otherwise a connection that stalls every ~10 MB
                -- exhausts all retries while advancing every time.
                logger.warn("Updater: request failed but made progress (",
                    bytes_before, "->", bytes_after, "), resuming")
                retry_count = 0
            else
                retry_count = retry_count + 1
            end
            total_attempts = total_attempts + 1
            if retry_count > max_retries or total_attempts > max_total_attempts then
                -- Keep the partial file: the next attempt resumes here.
                return false, T(_("Download failed (%1) at %2 bytes.\nTrying again will resume from that point."),
                    tostring(code or status or "no response"), tostring(bytes_after))
            end
        end

        -- Back off briefly on failures so a transiently congested link can
        -- recover; progress resets retry_count, so this stays short.
        require("socket").sleep(math.min(retry_count * 2, 10))
    end
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
    -- On Kobo /tmp is a small tmpfs (~470 MB) that fills up quickly.
    -- Use the plugin directory's parent for temp files so backups and
    -- downloads live on the internal SD card and cross-filesystem moves
    -- are avoided (issue #23).
    if Device:isKobo() then
        local parent = _dir:gsub("/+$", ""):match("^(.+)/[^/]+$")
        if parent then
            tmp_dir = parent
        end
    end
    -- On Kindle /tmp is a 64 MB tmpfs under /var/tmp, far too small for
    -- release zips that include ffmpeg/Piper binaries (issue #38 update
    -- failure). Put temp files on user storage next to the plugin dir.
    if Device:isKindle() then
        local parent = _dir:gsub("/+$", ""):match("^(.+)/[^/]+$")
        if parent then
            tmp_dir = parent
        end
    end
    -- Android has no /tmp in the app sandbox; writing there fails with
    -- "No such file or directory". Use user storage next to the plugin dir.
    if Device:isAndroid() then
        local parent = _dir:gsub("/+$", ""):match("^(.+)/[^/]+$")
        if parent then
            tmp_dir = parent
        end
    end
    -- Verify the chosen temp directory is actually writable.
    local test_file = tmp_dir .. "/.audiobook_update_test"
    local test_fh = io.open(test_file, "w")
    if not test_fh then
        tmp_dir = _dir:gsub("/+$", "")
        logger.warn("Updater: temp dir not writable, falling back to", tmp_dir)
    else
        test_fh:close()
        os.remove(test_file)
    end
    local zip_path = tmp_dir .. "/audiobook-koplugin-update.zip"
    logger.info("Updater: using temp dir", tmp_dir)

    -- Pre-flight space check (issue #46): the update needs the zip, a
    -- backup copy of the plugin, and the extracted files side by side.
    -- On nearly-full devices the download used to die mid-way and was
    -- misreported as a network stall.
    if release.zip_size then
        -- Rough margin over the zip: backup of the existing plugin dir
        -- plus extraction workspace (the plugin with binaries is ~165 MB).
        local need_kb = math.ceil(release.zip_size / 1024) + 350 * 1024
        local free_kb = freeSpaceKb(tmp_dir)
        if free_kb and free_kb < need_kb then
            logger.err("Updater: not enough space in", tmp_dir,
                "free:", free_kb, "kB, need:", need_kb, "kB")
            UIManager:show(InfoMessage:new{
                text = T(_("Not enough free storage for the update.\n\nNeeded: about %1 MB (update package plus installation workspace)\nAvailable: %2 MB\n\nFree up space (e.g. delete books or files via USB, or clean KOReader's cache), then try again."),
                    tostring(math.ceil(need_kb / 1024)),
                    tostring(math.floor(free_kb / 1024))),
                timeout = 12,
            })
            return
        end
    end

    local ok, err = downloadFile(release.zip_url, zip_path, release.zip_size)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Download failed: %1"), err or _("unknown")),
        })
        return
    end

    -- Verify the downloaded zip is complete (GitHub asset size) and intact.
    local lfs = require("libs/libkoreader-lfs")
    if release.zip_size then
        local attr = lfs.attributes(zip_path)
        local actual_size = attr and attr.size or 0
        if actual_size ~= release.zip_size then
            logger.warn("Updater: downloaded zip size mismatch: expected", release.zip_size, "got", actual_size)
            -- Delete: a completed-but-wrong file cannot be trusted and would
            -- otherwise satisfy the resume check forever (actual >= expected).
            os.remove(zip_path)
            os.remove(zip_path .. ".expected")
            UIManager:show(InfoMessage:new{
                text = T(_("Download incomplete: expected %1 bytes, got %2.\n\nPlease try again, or install manually: download the release zip from GitHub and copy audiobook.koplugin to your plugins folder."),
                         tostring(release.zip_size), tostring(actual_size)),
                timeout = 10,
            })
            return
        end
    end
    -- Probe the downloaded archive before touching the installed plugin
    -- directory.  Info-ZIP's `unzip -t` CRC-checks every entry, but the
    -- BusyBox unzip shipped on Kobo and PocketBook firmwares has no -t
    -- option at all and rejects EVERY archive with a usage error
    -- ("unzip: invalid option -- 't'" on Kobo fw 4.45, busybox 1.31.1),
    -- which made every fully downloaded zip look corrupt and got it
    -- deleted.  When -t fails, retry with `unzip -l`: both flavors
    -- support it and it validates the central directory, so truncated
    -- or garbage downloads still fail there.  Deep CRC damage is not
    -- detectable through BusyBox, but the byte count was just verified
    -- against the GitHub asset over TLS, extraction below is CRC-checked
    -- by libarchive, and the backup/restore plus critical-file sweep
    -- guard the installed plugin.  If unzip is missing entirely, skip
    -- the probe for the same reason.
    local test_ok
    local have_unzip = os.execute('command -v unzip >/dev/null 2>&1')
    if have_unzip == 0 or have_unzip == true then
        test_ok = os.execute('unzip -t "' .. zip_path .. '" >/dev/null 2>&1')
        if test_ok ~= 0 and test_ok ~= true then
            -- BusyBox unzip: -t unsupported.  -l is the lowest common
            -- denominator structural check on both flavors.
            test_ok = os.execute('unzip -l "' .. zip_path .. '" >/dev/null 2>&1')
        end
    else
        logger.warn("Updater: no unzip binary found, skipping archive probe")
        test_ok = true
    end
    if test_ok ~= 0 and test_ok ~= true then
        logger.warn("Updater: zip integrity test failed for", zip_path)
        os.remove(zip_path)
        UIManager:show(InfoMessage:new{
            text = _("Downloaded update archive is corrupt. Please try again."),
        })
        return
    end

    -- Determine install target: the directory containing this plugin
    local plugin_dir = _dir:gsub("/+$", "")  -- e.g. ".../plugins/audiobook.koplugin"

    logger.warn("Updater: extracting", zip_path, "to", plugin_dir)

    -- Backup the existing plugin directory so we can restore it if
    -- extraction fails part-way through (issue #22: archive_read_extract2
    -- can abort mid-extraction on FAT32 Kindles, leaving the plugin
    -- directory corrupted with missing .lua files).
    local backup_dir = tmp_dir .. "/audiobook.koplugin.backup"
    os.execute('rm -rf "' .. backup_dir .. '" 2>/dev/null')
    local backup_ok = os.execute('cp -rf "' .. plugin_dir .. '" "' .. backup_dir .. '" 2>/dev/null')
    if backup_ok == 0 or backup_ok == true then
        logger.warn("Updater: backed up plugin to", backup_dir)
    else
        logger.warn("Updater: plugin backup failed (non-fatal)")
        backup_dir = nil
    end

    -- Use KOReader's Device:unpackArchive which handles stripping the
    -- top-level directory from the zip (GitHub release zips contain
    -- "audiobook.koplugin/...").
    local extract_ok, extract_err
    if Device.unpackArchive then
        extract_ok, extract_err = Device:unpackArchive(zip_path, plugin_dir, true)
        if not extract_ok then
            logger.warn("Updater: Device:unpackArchive failed:",
                tostring(extract_err), "-- falling back to system unzip")
        end
    end
    if not extract_ok then
        -- Fallback: use system unzip (PocketBook PB740 ships an
        -- unpackArchive that rejects the .zip extension; the bundled
        -- BusyBox unzip handles it correctly).
        --
        -- Issue #15 (v0.1.5.79 regression): on PB740 unzip exits with
        -- status 1 ("warning, but extracted successfully") which os.execute
        -- reports as 256.  We used to fail the update on that.  Now we
        -- ignore the exit code entirely and verify success by checking
        -- whether the destination directory was actually populated.
        local unzip_dir = tmp_dir .. "/audiobook-update-tmp"
        os.execute('rm -rf "' .. unzip_dir .. '" 2>/dev/null')
        os.execute('mkdir -p "' .. unzip_dir .. '" 2>/dev/null')
        local ret = os.execute(
            'unzip -o "' .. zip_path .. '" -d "' .. unzip_dir .. '" 2>&1')
        local copied = false
        local copy_src
        if lfs.attributes(unzip_dir, "mode") == "directory" then
            for entry in lfs.dir(unzip_dir) do
                if entry ~= "." and entry ~= ".." then
                    copy_src = unzip_dir .. "/" .. entry
                    break
                end
            end
        end
        if copy_src then
            -- Some zips have a top-level dir, others extract files directly.
            local src_mode = lfs.attributes(copy_src, "mode")
            if src_mode == "directory" then
                os.execute('cp -rf "' .. copy_src .. '"/* "' .. plugin_dir .. '/" 2>/dev/null')
            else
                os.execute('cp -rf "' .. unzip_dir .. '"/* "' .. plugin_dir .. '/" 2>/dev/null')
            end
            copied = true
        end
        if copied then
            extract_ok = true
        else
            extract_ok = false
            extract_err = (extract_err and (tostring(extract_err) .. "; ") or "")
                .. "unzip returned " .. tostring(ret)
                .. " and produced no files"
        end
        os.execute('rm -rf "' .. unzip_dir .. '" 2>/dev/null')
    end

    -- Verify extraction produced a complete plugin directory.  Partial
    -- extraction (e.g. corrupt zip, unzip "short read") can leave critical
    -- .lua files missing and gray out the menu items.
    if extract_ok then
        local verify_ok, missing_file = verifyPluginDir(plugin_dir)
        if not verify_ok then
            logger.warn("Updater: critical file missing after extraction:", missing_file)
            extract_ok = false
            extract_err = T(_("Critical file missing after extraction: %1"), missing_file)
        end
    end

    -- Clean up the downloaded zip and, on PocketBook, the tmp directory if
    -- we created it (it is normally absent and the plugin should not leave
    -- it behind after an update).
    os.remove(zip_path)
    os.remove(zip_path .. ".expected")
    if created_ext_tmp then
        os.execute('rmdir "' .. tmp_dir .. '" 2>/dev/null')
    end

    if not extract_ok then
        -- Restore from backup so the plugin isn't left in a broken state
        -- with missing .lua files (issue #22).
        if backup_dir then
            logger.warn("Updater: restoring plugin from backup", backup_dir)
            os.execute('rm -rf "' .. plugin_dir .. '" 2>/dev/null')
            os.execute('mv "' .. backup_dir .. '" "' .. plugin_dir .. '" 2>/dev/null')
        end
        UIManager:show(InfoMessage:new{
            text = T(_("Extraction failed: %1"), extract_err or _("unknown")),
        })
        return
    end
    -- Extraction succeeded -- remove the backup to save space.
    if backup_dir then
        os.execute('rm -rf "' .. backup_dir .. '" 2>/dev/null')
    end

    logger.warn("Updater: successfully installed v" .. release.version)

    -- Ensure _meta.lua reports the installed release version, in case the
    -- release zip shipped with a stale version string.  Without this, the
    -- next "check for updates" comparison would keep offering the same
    -- release because the on-disk _meta.lua still reports the older version.
    local meta_path = plugin_dir .. "/_meta.lua"
    local rf = io.open(meta_path, "r")
    if rf then
        local content = rf:read("*a") or ""
        rf:close()
        local new_content, n = content:gsub('version%s*=%s*"[^"]*"',
            'version = "' .. release.version .. '"', 1)
        if n > 0 and new_content ~= content then
            local wf = io.open(meta_path, "w")
            if wf then
                wf:write(new_content)
                wf:close()
                logger.warn("Updater: pinned _meta.lua version to", release.version)
            else
                logger.warn("Updater: could not rewrite _meta.lua (open for write failed)")
            end
        end
    else
        logger.warn("Updater: _meta.lua not found at", meta_path)
    end

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
