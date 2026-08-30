#!/usr/bin/env luajit
--[[--
Smoke test for Storyteller EPUB overlay parsing helpers.

Uses real fixtures extracted from a Storyteller read-aloud EPUB.
Run from repo root:
  luajit dev/test_epubmediaoverlay_multiline.lua [fixtures_dir]

Default fixtures_dir: ../scripts/_fixtures (when run from audiobook.koplugin clone
next to THE-BEAST scripts) or pass absolute path to scripts/_fixtures.
--]]

local RE_ANY_LAZY = "([%z\1-\255]-)"

local function escape_unzip_member(path)
    return path:gsub("%[", "[[]")
end

local function url_decode(path)
    if not path or not path:find("%", 1, true) then
        return path
    end
    return (path:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function compact_xml(xml)
    return xml:gsub(">%s+<", "><")
end

local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local data = f:read("*a")
    f:close()
    return data
end

local function count_par(smil, pattern)
    local n = 0
    for _a, _b in smil:gmatch(pattern) do
        n = n + 1
    end
    return n
end

local function count_manifest_overlays(opf_xml)
    opf_xml = compact_xml(opf_xml)
    local manifest_block = opf_xml:match("<manifest[^>]*>" .. RE_ANY_LAZY .. "</manifest>")
    if not manifest_block then return 0, 0 end
    local items = {}
    local overlays = 0
    for item_str in manifest_block:gmatch("<item([^>]-)/>") do
        local id = item_str:match('id%s*=%s*"([^"]+)"')
        local href = item_str:match('href%s*=%s*"([^"]+)"')
        local mo = item_str:match('media%-overlay%s*=%s*"([^"]+)"')
        if id and href then
            items[id] = { href = href, mo = mo }
        end
    end
    for id, item in pairs(items) do
        if item.mo and items[item.mo] then
            overlays = overlays + 1
        end
    end
    return overlays, #manifest_block
end

local fixtures = arg[1] or "scripts/_fixtures"
if not read_file(fixtures .. "/sample.smil") then
    fixtures = "../scripts/_fixtures"
end

local failures = {}

local smil, err = read_file(fixtures .. "/sample.smil")
if not smil then
    io.stderr:write("FAIL: missing fixture sample.smil: " .. tostring(err) .. "\n")
    os.exit(1)
end

local opf = read_file(fixtures .. "/content.opf")
if not opf then
    table.insert(failures, "missing fixture content.opf")
end

local encoded = "MediaOverlays/005%20-%20PROLOGUE.smil"
if url_decode(encoded) ~= "MediaOverlays/005 - PROLOGUE.smil" then
    table.insert(failures, "url_decode spaces: " .. tostring(url_decode(encoded)))
end
local encoded_comma = "MediaOverlays/011%20-%20V%20LE%20ROI%2C%20SES.smil"
if url_decode(encoded_comma) ~= "MediaOverlays/011 - V LE ROI, SES.smil" then
    table.insert(failures, "url_decode comma: " .. tostring(url_decode(encoded_comma)))
end
if url_decode("MediaOverlays/plain.smil") ~= "MediaOverlays/plain.smil" then
    table.insert(failures, "url_decode should leave plain paths alone")
end

local storyteller_member =
    "MediaOverlays/Author-[Series-1]Title_split_003.smil"
local escaped = escape_unzip_member(storyteller_member)
if escaped ~= "MediaOverlays/Author-[[]Series-1]Title_split_003.smil" then
    table.insert(failures, "unexpected unzip escape: " .. escaped)
end

local compact = compact_xml(smil)
local par_count = count_par(compact, "<par([^>]*)>" .. RE_ANY_LAZY .. "</par>")
if par_count ~= 23 then
    table.insert(failures, "expected 23 par blocks in Storyteller sample SMIL, got " .. par_count)
end

if opf then
    local overlays, manifest_len = count_manifest_overlays(opf)
    if overlays ~= 27 then
        table.insert(failures, "expected 27 overlay mappings in OPF, got " .. overlays)
    end
    if manifest_len < 1000 then
        table.insert(failures, "OPF manifest block too short: " .. manifest_len)
    end
end

if #failures > 0 then
    io.stderr:write("FAIL\n")
    for _, msg in ipairs(failures) do
        io.stderr:write("  - " .. msg .. "\n")
    end
    os.exit(1)
end

print(string.format(
    "ok: Storyteller fixtures parsed (%d par, unzip escape verified)",
    par_count
))
