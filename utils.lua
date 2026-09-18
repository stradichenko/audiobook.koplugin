--[[--
Shared Utility Functions
Common helpers used across the audiobook plugin modules.
Eliminates duplication of commandExists, ws, countSyllables.

@module utils
--]]

local Utils = {}

--- Check if a command exists on the system PATH.
-- @param cmd string  Command name (e.g. "piper", "espeak-ng")
-- @return boolean
function Utils.commandExists(cmd)
    local handle = io.popen("which " .. cmd .. " 2>/dev/null")
    if handle then
        local result = handle:read("*a")
        handle:close()
        return result and result ~= ""
    end
    return false
end

--- Normalise whitespace: collapse runs to single space, trim edges.
-- @param s string
-- @return string
function Utils.ws(s)
    if not s then return "" end
    return s:gsub("%s+", " "):match("^%s*(.-)%s*$")
end

--- Normalize text for matching against crengine-rendered text.
-- SMIL/source text and rendered text differ systematically: curly quotes,
-- dashes, non-breaking spaces, zero-width chars, and (in some production
-- pipelines) runs of straight apostrophes used as an escaping convention,
-- e.g. "June'''s" for "June's".  Matching only, never for display.
-- @param s string
-- @return string
function Utils.normalizeForMatching(s)
    if not s then return "" end
    return s
        :gsub("[\n\r]+", " ")
        :gsub("%s+", " ")
        :gsub("\226\128[\152-\155]", "'")    -- curly quotes U+2018-U+201B → straight '
        :gsub("\226\128[\156-\159]", '"')    -- curly double quotes U+201C-U+201F → straight "
        :gsub("\194\171", '"')               -- « guillemet → straight "
        :gsub("\194\187", '"')               -- » guillemet → straight "
        :gsub("\226\128[\147-\148]", "-")    -- en/em-dash → hyphen
        :gsub("\226\128\166", "...")         -- ellipsis
        :gsub("\194\160", " ")               -- non-breaking space → space
        :gsub("\194\173", "")                -- soft hyphen removed
        :gsub("\226\128[\139\169]", "")      -- zero-width chars removed
        :gsub("\239\187\191", "")            -- BOM removed
        :gsub("''+", "'")                    -- apostrophe-run artifact
        :gsub("^%s+", ""):gsub("%s+$", "")
end

--- Count the number of syllables in an English word (heuristic).
-- @param word string
-- @return number  Syllable count (minimum 1)
function Utils.countSyllables(word)
    if not word or word == "" then return 1 end

    word = word:lower()
    local count = 0
    local prev_vowel = false

    for i = 1, #word do
        local char = word:sub(i, i)
        local is_vowel = char:match("[aeiouy]")
        if is_vowel and not prev_vowel then
            count = count + 1
        end
        prev_vowel = is_vowel
    end

    -- Silent-e rule
    if word:sub(-1) == "e" and count > 1 then
        count = count - 1
    end

    return math.max(count, 1)
end

--- Normalize a directory path: collapse double slashes, strip trailing slashes.
-- @param path string|nil
-- @return string  Normalized path without trailing slash
function Utils.normalizeDirPath(path)
    if not path then return "." end
    path = path:gsub("//+", "/")
    path = path:gsub("/+$", "")
    if path == "" then return "." end
    return path
end

-- Kindle generations with a built-in speaker on a real ALSA codec and no
-- Bluetooth at all (2007-2011).  KOReader flavors: the first three run the
-- kindle-legacy build, the last three the "kindle" (kindle5 toolchain,
-- Cortex-A8 softfp) build.  PW2 (model "KindlePaperWhite2") is the first
-- speakerless generation, so everything from there on must NOT match.
Utils.LEGACY_KINDLE_MODELS = {
    Kindle2 = true,
    KindleDXG = true,
    Kindle3 = true,
    Kindle4 = true,
    KindleTouch = true,
    KindlePaperWhite = true,
}

local _legacy_kindle_model = nil

--- True when the current Kindle is a 2007-2011 speaker model.  Nil or
--- "unknown" model values conservatively return false; the bug report
--- captures Device.model so a misdetection can be closed later.
-- @return boolean
function Utils.isLegacyKindleModel()
    if _legacy_kindle_model ~= nil then return _legacy_kindle_model end
    _legacy_kindle_model = false
    local ok, Device = pcall(require, "device")
    if ok and Device and Device.model then
        _legacy_kindle_model = Utils.LEGACY_KINDLE_MODELS[Device.model] or false
    end
    return _legacy_kindle_model
end

local _kindle_alsa_card = nil
local _kindle_alsa_probed = false

--- Probe once for a usable ALSA playback device (old Kindles expose their
--- speaker codec directly; PW2+ report "no soundcards").  Cached for the
--- session so the probe runs at most once.
-- @return string|false  ALSA device argument (e.g. "plughw:0,0") or false
function Utils.probeKindleAlsaCard()
    if _kindle_alsa_probed then return _kindle_alsa_card end
    _kindle_alsa_probed = true
    _kindle_alsa_card = false
    local h = io.popen("aplay -l 2>/dev/null")
    if h then
        local out = h:read("*a") or ""
        h:close()
        if not out:find("no soundcards", 1, true) then
            local card, dev = out:match("card (%d+):.+device (%d+):")
            if card and dev then
                _kindle_alsa_card = "plughw:" .. card .. "," .. dev
            end
        end
    end
    return _kindle_alsa_card
end

--- Fold a token for alignment: lowercase, drop apostrophes/punctuation, strip
--- a trailing hyphen (CRe line-break hyphenation). Matching only.
function Utils.foldWord(w)
    if not w or w == "" then return "" end
    w = w:lower()
    w = w:gsub("\195\137", "\195\169") -- É → é
    w = w:gsub("\195\136", "\195\168") -- È → è
    w = w:gsub("\195\138", "\195\170") -- Ê → ê
    w = w:gsub("\195\128", "\195\160") -- À → à
    w = w:gsub("\195\135", "\195\167") -- Ç → ç
    w = w:gsub("'", ""):gsub("\226\128\153", "")
    w = w:gsub("^%p+", ""):gsub("%p+$", "")
    w = w:gsub("%-$", "")
    return w
end

--- Tokens of `s` with original character spans. Merges a hyphenated line-break
--- ("exem-" + "ple") and a French elision ("L'" + "homme").
function Utils.tokenizeForAlign(s)
    local toks = {}
    if not s or s == "" then return toks end
    local pos = 1
    while true do
        local a, b = s:find("%S+", pos)
        if not a then break end
        local raw = s:sub(a, b)
        pos = b + 1
        if raw:sub(-1) == "-" then
            local a2, b2 = s:find("%S+", pos)
            if a2 then
                raw = raw:sub(1, -2) .. s:sub(a2, b2)
                b = b2
                pos = b2 + 1
            end
        -- Elision markers ("L'", "d'", "qu'") always end WITH the
        -- apostrophe as the last character. The old check
        -- (raw:find("'") and #raw <= 4) also matched ordinary short
        -- contractions ("it's", "I'm", "he's", "I'll") — merging them
        -- with the next word and inflating the compared word count,
        -- causing highlight overshoot past the sentence end.    
        elseif raw:sub(-1) == "'" then
            local a2, b2 = s:find("%S+", pos)
            if a2 then
                raw = raw .. s:sub(a2, b2)
                b = b2
                pos = b2 + 1
            end
        end
        local fold = Utils.foldWord(raw)
        if fold ~= "" then
            toks[#toks + 1] = { fold = fold, a = a, b = b }
        end
    end
    return toks
end

--- Align `words` (SMIL) onto `page` (rendered). Returns
--- first_word, last_word, char_start, char_end in `page`, or nil.
--- Bookends the first and last matching words so a hyphenation hole in the
--- middle does not drop the start or end of the phrase.
function Utils.alignSentenceOnPage(words, page)
    if not words or #words == 0 or not page or page == "" then return nil end
    local toks = Utils.tokenizeForAlign(page)
    if #toks == 0 then return nil end
    local sent = {}
    for i = 1, #words do
        sent[i] = Utils.foldWord(words[i])
    end

    local function findFrom(i, min_p, max_p)
        local f = sent[i]
        if not f or f == "" then return nil end
        local hi = max_p or #toks
        for p = min_p, hi do
            local tf = toks[p].fold
            if tf == f then return p end
            if #tf >= 3 and #f >= 3 then
                if f:sub(1, #tf) == tf or tf:sub(1, #f) == f then return p end
            end
        end
        return nil
    end

    local first_w, first_p
    for i = 1, #words do
        local p = findFrom(i, 1, #toks)
        if p then
            first_w, first_p = i, p
            break
        end
    end
    if not first_w then return nil end

    local last_w, last_p = first_w, first_p
    local p_cur = first_p
    for i = first_w + 1, #words do
        if sent[i] ~= "" then
            local gap = (#sent[i] <= 3) and 5 or 12
            if i >= #words - 1 then gap = 20 end
            local p = findFrom(i, p_cur + 1, math.min(#toks, p_cur + gap))
            if p then
                last_w, last_p = i, p
                p_cur = p
            end
        end
    end
    if last_p < first_p then
        last_p = first_p
        last_w = first_w
    end
    local span = last_w - first_w + 1
    if span <= 2 and #words > 6 and first_w > 3 and last_w < #words - 2 then
        return nil
    end
    return first_w, last_w, toks[first_p].a, toks[last_p].b
end

--- Split on whitespace. UTF-8 safe (does not slice codepoints).
function Utils.splitWords(s)
    local words = {}
    if not s or s == "" then return words end
    for w in s:gmatch("%S+") do
        words[#words + 1] = w
    end
    return words
end

--- Longest prefix of `words` that appears as a contiguous phrase in `page`.
function Utils.wordPrefixCount(words, page)
    if not words or #words == 0 or not page or page == "" then return 0 end
    local lo, hi = 0, #words
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        local prefix = table.concat(words, " ", 1, mid)
        if page:find(prefix, 1, true) then
            lo = mid
        else
            hi = mid - 1
        end
    end
    return lo
end

--- Index of the first word that contains a letter/digit (skip leading punctuation).
function Utils.contentWordStart(words)
    if not words then return 1 end
    for i = 1, #words do
        if not words[i]:match("^%p+$") then return i end
    end
    return 1
end

--- Longest prefix of `words` on `page`, ignoring a leading punctuation token.
function Utils.sentencePrefixOnPage(words, page)
    if not words or #words == 0 or not page or page == "" then return 0 end
    local start = Utils.contentWordStart(words)
    if start == 1 then
        return Utils.wordPrefixCount(words, page)
    end
    local rest = {}
    for i = start, #words do
        rest[#rest + 1] = words[i]
    end
    local n = Utils.wordPrefixCount(rest, page)
    if n <= 0 then return 0 end
    return n + start - 1
end

--- Longest suffix of `words` that appears as a contiguous phrase in `page`.
-- Used after a mid-sentence page turn: only the tail is on screen.
function Utils.sentenceSuffixOnPage(words, page)
    if not words or #words == 0 or not page or page == "" then return 0 end
    for n = #words, 1, -1 do
        local suffix = table.concat(words, " ", #words - n + 1, #words)
        if page:find(suffix, 1, true) then
            return n
        end
    end
    return 0
end

--- First and last sentence-word indices of the longest contiguous run of
--- `words` that appears in `page`. nil when nothing matches.
--- Prefers the longest *span* (not the match that ends furthest): a later
--- one-word coincidence like "de" must not replace a 12-word prefix.
function Utils.visibleSentenceWordRange(words, page)
    if not words or #words == 0 or not page or page == "" then return nil end
    local best_i, best_j = nil, nil
    local function consider(i, j)
        if not i or not j or j < i then return end
        local span = j - i + 1
        local best_span = (best_i and (best_j - best_i + 1)) or 0
        if span > best_span or (span == best_span and i < best_i) then
            best_i, best_j = i, j
        end
    end
    local prefix = Utils.sentencePrefixOnPage(words, page)
    if prefix > 0 then
        consider(1, prefix)
        if prefix >= #words then return 1, #words end
    end
    for i = (prefix > 0 and prefix + 1 or 1), #words do
        local lo, hi = 0, #words - i + 1
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            local slice = table.concat(words, " ", i, i + mid - 1)
            if page:find(slice, 1, true) then
                lo = mid
            else
                hi = mid - 1
            end
        end
        if lo > 0 then
            consider(i, i + lo - 1)
        end
    end
    if not best_i then return nil end
    return best_i, best_j
end

--- Detect the number of CPU cores (same logic as piperqueue.lua).
-- @return number  Core count (1 when undetectable)
function Utils.getCpuCores()
    local f = io.open("/sys/devices/system/cpu/possible", "r")
    if f then
        -- Format: "0-N" → N+1 cores, or "0" → 1 core
        local s = f:read("*l") or "0"
        f:close()
        local hi = s:match("%-(%d+)")
        if hi then return tonumber(hi) + 1 end
        return 1
    end
    return 1  -- conservative fallback
end

--- Read total system memory in kB from /proc/meminfo.
-- @return number|nil  MemTotal in kB, or nil when unreadable
function Utils.getMemTotalKb()
    local f = io.open("/proc/meminfo", "r")
    if not f then return nil end
    for line in f:lines() do
        local kb = line:match("MemTotal:%s+(%d+)%s+kB")
        if kb then
            f:close()
            return tonumber(kb)
        end
    end
    f:close()
    return nil
end

return Utils
