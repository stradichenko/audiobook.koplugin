#!/usr/bin/env luajit
-- EpubMediaOverlay.sameFingerprint: "size:mtime" with the 2 s mtime slack of
-- FAT storage. Run from the repo root: luajit dev/test_fingerprint_slack.lua

local src = io.open("epubmediaoverlay.lua"):read("*a")
local body = assert(src:match("(function EpubMediaOverlay%.sameFingerprint%(a, b%).-\nend\n)"),
    "sameFingerprint not found")
local env = setmetatable({ EpubMediaOverlay = {} }, { __index = _G })
assert(load(body, "sameFingerprint", "t", env))()
local same = env.EpubMediaOverlay.sameFingerprint

local passed, failed = 0, 0
local function check(cond, label)
    if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. label) end
end

check(same("100:1700000000", "100:1700000000"), "identical")
check(same("100:1700000000", "100:1700000001"), "1 s apart (FAT rounding)")
check(same("100:1700000002", "100:1700000000"), "2 s apart")
check(not same("100:1700000000", "100:1700000003"), "3 s apart is a new file")
check(not same("100:1700000000", "101:1700000000"), "different size")
check(not same("100:1700000000", nil), "nil")
check(not same("garbage", "100:1700000000"), "malformed")

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
