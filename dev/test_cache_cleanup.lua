#!/usr/bin/env luajit
-- Smoke test for the self-cleaning overlay cache (epubmediaoverlay.lua).
-- Run from the repo root: luajit dev/test_cache_cleanup.lua
--
-- Uses a virtual filesystem for lfs so the rules can be pinned without
-- touching a real card: EPUB-gone, age, total-size and free-space deletion,
-- keep_path protection, dry run, truthful freed accounting when rm fails,
-- and the usage numbers the Diagnostics menu shows.

package.preload["logger"] = function()
    local t = {}
    for _, name in ipairs({ "warn", "dbg", "err", "info" }) do
        t[name] = function() end
    end
    return t
end
package.preload["audiobook_gettext"] = function()
    return function(s) return s end
end

local here = (arg and arg[0]):gsub("[^/]+$", "")
local EpubMediaOverlay = dofile(here .. "../epubmediaoverlay.lua")

local attrs, dirs, epub_paths = {}, {}, {}
local failed_rm = {}

local function mkdir(p)
    dirs[p] = {}
    attrs[p] = { mode = "directory", modification = 1000 }
end
local function mkfile(p, size, mtime)
    attrs[p] = { mode = "file", size = size, modification = mtime or 1000 }
end

local real_open = io.open
io.open = function(path, mode)
    if mode == "r" and epub_paths[path] ~= nil then
        return {
            read = function() return epub_paths[path] end,
            close = function() end,
        }
    end
    return real_open(path, mode)
end

local lfs = {}
function lfs.attributes(path, field)
    local a = attrs[path]
    if not a then return nil end
    return field and a[field] or a
end
function lfs.dir(path)
    local names = dirs[path]
    if not names then error("not a directory: " .. tostring(path)) end
    local i = 0
    return function()
        i = i + 1
        if names[i] then return names[i] end
    end
end
package.preload["libs/libkoreader-lfs"] = function() return lfs end

local df_line = "overlay 4000000 2000000 2000000 50% /"
io.popen = function()
    return {
        read = function() return df_line end,
        close = function() end,
    }
end

local executed = {}
local function vfs_remove(path)
    for _, name in ipairs(dirs[path] or {}) do
        local child = path .. "/" .. name
        if dirs[child] then vfs_remove(child) end
        attrs[child] = nil
    end
    dirs[path] = nil
    attrs[path] = nil
end
os.execute = function(cmd)
    executed[#executed + 1] = cmd
    local path = cmd:match("^rm %-rf '(.*)'$")
    if path and dirs[path] and not failed_rm[path] then
        vfs_remove(path)
    end
    return 0
end

local now = os.time()
local ROOT = "/plugin/cache/overlays"

local function reset()
    attrs, dirs, epub_paths, executed = {}, {}, {}, {}
    failed_rm = {}
    mkdir(ROOT)
end

local function add_book(opts)
    opts = opts or {}
    local hash = EpubMediaOverlay:_simpleHash(opts.epub)
    local dir = ROOT .. "/" .. hash
    mkdir(dir)
    table.insert(dirs[ROOT], hash)
    table.insert(dirs[dir], ".epub_fingerprint")
    table.insert(dirs[dir], ".epub_path")
    table.insert(dirs[dir], "chapter1.mp3")
    mkfile(dir .. "/.epub_fingerprint", 20, opts.used or now)
    mkfile(dir .. "/chapter1.mp3", (opts.mb or 1) * 1048576, 1000)
    epub_paths[dir .. "/.epub_path"] = opts.epub
    if opts.epub_exists ~= false then mkfile(opts.epub, 1000, 1000) end
    return hash, dir
end

local function deleted(hash)
    for _, cmd in ipairs(executed) do
        if cmd:find(hash, 1, true) then return true end
    end
    return false
end

local fails, checks = 0, 0
local function ok(c, label)
    checks = checks + 1
    if not c then fails = fails + 1; print("FAIL " .. label) else print("ok   " .. label) end
end

-- 1. EPUB referenced by .epub_path no longer exists.
reset()
local gone = add_book({ epub = "/books/gone.epub", epub_exists = false })
local live = add_book({ epub = "/books/live.epub" })
local summary = EpubMediaOverlay.cleanupCaches("/plugin", { keep_path = "/books/live.epub" })
ok(#summary.deleted == 1 and summary.deleted[1].hash == gone, "EPUB-gone cache selected")
ok(deleted(gone) and not deleted(live), "only the EPUB-gone cache was removed")

-- 2. Age rule.
reset()
local old = add_book({ epub = "/books/old.epub", used = now - 61 * 86400 })
add_book({ epub = "/books/new.epub", used = now - 86400 })
summary = EpubMediaOverlay.cleanupCaches("/plugin", { max_age_days = 60 })
ok(#summary.deleted == 1 and summary.deleted[1].hash == old, "aged cache selected")
ok(deleted(old), "aged cache removed")

-- 3. Size cap: least recently opened first.
reset()
local oldest = add_book({ epub = "/books/a.epub", used = now - 300, mb = 100 })
add_book({ epub = "/books/b.epub", used = now - 200, mb = 100 })
add_book({ epub = "/books/c.epub", used = now - 100, mb = 100 })
summary = EpubMediaOverlay.cleanupCaches("/plugin", {
    max_total_mb = 250, keep_path = "/books/c.epub",
})
ok(#summary.deleted == 1 and summary.deleted[1].hash == oldest, "oldest cache deleted")
ok(summary.total_mb == 200, "remaining total reported (got " .. tostring(summary.total_mb) .. ")")

-- 4. keep_path survives even when it is the oldest.
reset()
add_book({ epub = "/books/a.epub", used = now - 400, mb = 200 })
local keepb = add_book({ epub = "/books/b.epub", used = now - 300, mb = 200 })
summary = EpubMediaOverlay.cleanupCaches("/plugin", {
    max_total_mb = 100, keep_path = "/books/a.epub",
})
ok(#summary.deleted == 1 and summary.deleted[1].hash == keepb, "open book protected")

-- 5. Dry run reports but deletes nothing.
reset()
add_book({ epub = "/books/gone.epub", epub_exists = false })
summary = EpubMediaOverlay.cleanupCaches("/plugin", { dry_run = true })
ok(#summary.deleted == 1 and #executed == 0, "dry run reports without deleting")

-- 6. Failed rm is not counted as freed.
reset()
local stuck = add_book({ epub = "/books/stuck.epub", mb = 500 })
failed_rm[ROOT .. "/" .. stuck] = true
summary = EpubMediaOverlay.cleanupCaches("/plugin", {
    max_total_mb = 100, keep_path = "/books/other.epub",
})
ok(#summary.deleted == 0 and summary.freed_mb == 0, "failed delete is not counted")
ok(attrs[ROOT .. "/" .. stuck] ~= nil, "failed delete leaves the cache in place")

-- 7. Low free space deletes caches.
reset()
df_line = "overlay 4000000 3500000 500000 87% /"
add_book({ epub = "/books/a.epub", mb = 300 })
add_book({ epub = "/books/b.epub", mb = 300 })
summary = EpubMediaOverlay.cleanupCaches("/plugin", { min_free_mb = 1024 })
ok(#summary.deleted >= 1, "low free space deletes at least one cache")

-- 8. Usage numbers for the menu.
reset()
add_book({ epub = "/books/a.epub", mb = 100 })
add_book({ epub = "/books/b.epub", mb = 50 })
local usage = EpubMediaOverlay.cacheUsage("/plugin")
ok(usage and usage.books == 2, "usage counts books")
ok(usage and usage.bytes == 150 * 1048576 + 2 * 20, "usage sums bytes")

print(string.format("%d passed, %d failed", checks - fails, fails))
os.exit(fails == 0 and 0 or 1)