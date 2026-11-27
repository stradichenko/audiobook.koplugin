#!/usr/bin/env luajit
-- Smoke test for Audiobook:_entryOnCurrentPage (start on the page on screen).
-- Run from the repo root: luajit dev/test_page_entry.lua
--
-- Pins the page lookup used after a background load and for a plain play:
-- the first sentence on the current page, the sentence running onto it when
-- none starts there, the last entry past the end, the namespaced crengine id
-- probe, rejection of ids from another content document, no narration, and
-- the fallback when an id cannot be resolved.

package.path = (arg and arg[0]:gsub("[^/]+$", "")) .. "../?.lua;" .. package.path

package.preload["ui/widget/container/widgetcontainer"] = function()
    local WC = {}
    function WC:extend(o) o = o or {}; return setmetatable(o, { __index = self }) end
    return WC
end
package.preload["logger"] = function()
    local t = {}
    for _, n in ipairs({ "warn", "dbg", "err", "info" }) do t[n] = function() end end
    return t
end
package.preload["audiobook_gettext"] = function()
    return function(s) return s end
end

local here = (arg and arg[0]):gsub("[^/]+$", "")
local Audiobook = dofile(here .. "../main.lua")

local fails, checks = 0, 0
local function ok(c, label)
    checks = checks + 1
    if not c then fails = fails + 1; print("FAIL " .. label) else print("ok   " .. label) end
end

local function make_doc(opts)
    local d = {
        cur_page = opts.cur_page,
        pages = opts.pages or {},
        unresolved = opts.unresolved or {},
        wrong_doc = opts.wrong_doc or {},
        ns_only = opts.ns_only or {},
        xp = "/body/DocFragment[2]/body/p[3]/text().0",
    }
    function d:getXPointer() return self.xp end
    function d:getNormalizedXPointer(q)
        if q:sub(1, 1) ~= "#" then return false end
        local id = q:match("([%w_%-]+)$")
        if not id or self.unresolved[id] then return false end
        if self.ns_only[id] and not q:find("_doc_fragment_", 1, true) then return false end
        if self.wrong_doc[id] then
            return "/body/DocFragment[1]/body/p[" .. id .. "]/text().0"
        end
        return "/body/DocFragment[2]/body/p[" .. id .. "]/text().0"
    end
    function d:getPageFromXPointer(xp)
        if xp == self.xp then return self.cur_page end
        local id = xp and xp:match("%[([%w_%-]+)%]/text")
        return id and self.pages[id] or nil
    end
    return d
end

local parser = { _spine_hrefs = { "part1.xhtml", "part2.xhtml" } }
local function entry(id, doc)
    return { audio_path = "/a.mp3", fragment_id = id,
        text_doc = doc or "OEBPS/part2.xhtml", start_time = 0 }
end
local timing = {
    entry("s1", "OEBPS/part1.xhtml"),
    entry("s2"), entry("s3"), entry("s4"), entry("s5"),
}
local function app(doc)
    return setmetatable({ ui = { document = doc } }, { __index = Audiobook })
end

-- First sentence on the current page.
local d = make_doc({ cur_page = 7, pages = { s2 = 5, s3 = 7, s4 = 9, s5 = 11 } })
local e = app(d):_entryOnCurrentPage(parser, timing)
ok(e and e.fragment_id == "s3", "entry on the current page is chosen")

-- Nothing starts on this page: the sentence running onto it.
d = make_doc({ cur_page = 6, pages = { s2 = 5, s3 = 7, s4 = 9, s5 = 11 } })
e = app(d):_entryOnCurrentPage(parser, timing)
ok(e and e.fragment_id == "s2", "sentence running onto the page is chosen")

-- Page past the last sentence: last entry.
d = make_doc({ cur_page = 20, pages = { s2 = 5, s3 = 7, s4 = 9, s5 = 11 } })
e = app(d):_entryOnCurrentPage(parser, timing)
ok(e and e.fragment_id == "s5", "page past the end uses the last entry")

-- Namespaced id probe only.
d = make_doc({ cur_page = 9, pages = { s2 = 5, s3 = 7, s4 = 9, s5 = 11 },
    ns_only = { s4 = true } })
e = app(d):_entryOnCurrentPage(parser, timing)
ok(e and e.fragment_id == "s4", "namespaced id probe resolves")

-- An id that resolves into another DocFragment is rejected.
d = make_doc({ cur_page = 9, pages = { s2 = 5, s3 = 7, s4 = 9, s5 = 11 },
    wrong_doc = { s4 = true } })
e = app(d):_entryOnCurrentPage(parser, timing)
ok(e == nil, "id from another document is not trusted")

-- No narration in this content document.
d = make_doc({ cur_page = 3, pages = {} })
parser._spine_hrefs = { "part1.xhtml", "part9.xhtml" }
e = app(d):_entryOnCurrentPage(parser, timing)
ok(e == nil, "no narration in the document yields nil")
parser._spine_hrefs = { "part1.xhtml", "part2.xhtml" }

-- One unresolvable id in the middle aborts the lookup (falls back).
d = make_doc({ cur_page = 9, pages = { s2 = 5, s3 = 7, s4 = 9, s5 = 11 },
    unresolved = { s4 = true } })
e = app(d):_entryOnCurrentPage(parser, timing)
ok(e == nil, "unresolvable id falls back")

print(string.format("%d passed, %d failed", checks - fails, fails))
os.exit(fails == 0 and 0 or 1)