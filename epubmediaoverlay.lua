--[[--
EPUB Media Overlay Parser -- Detect, parse, and extract timing data from EPUB 3 Media Overlays.
Uses `unzip` CLI to extract files from the EPUB ZIP archive.
Caches extracted audio to persistent storage (not /tmp, to avoid RAM exhaustion).

@module koplugin.audiobook.epubmediaoverlay
--]]

local logger = require("logger")
local _ = require("audiobook_gettext")

-- Lua patterns: `.` does not match newlines. Storyteller (and many OPF
-- producers) pretty-print SMIL/OPF with line breaks inside elements.
local RE_ANY_LAZY = "([%z\1-\255]-)"

local EpubMediaOverlay = {}

function EpubMediaOverlay:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o._cache_dir = nil
    o._epub_path = nil
    return o
end

-- ---------------------------------------------------------------------------
-- Utility
-- ---------------------------------------------------------------------------

function EpubMediaOverlay:_fileExists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

function EpubMediaOverlay:_runCommand(cmd)
    local h = io.popen(cmd .. " 2>&1")
    if not h then return nil end
    local out = h:read("*a") or ""
    h:close()
    return out
end

--- Info-ZIP unzip treats [], ?, * as wildcards in archive member names.
-- Storyteller titles often include bracketed series tags, e.g.
-- "Author-[Series-1]Title(1955).html". Without escaping, unzip -p returns
-- nothing even though unzip -l lists the SMIL files (which is why overlay
-- detection passes but timing extraction yields zero entries).
function EpubMediaOverlay:_escapeUnzipMember(path)
    if not path then return path end
    -- Info-ZIP: literal '[' is written as '[[]'. Do not escape ']' — doing so
    -- corrupts the '[[]' token (']' inside it would become '[]]').
    return path:gsub("%[", "[[]")
end

--- Calibre / Readest rewrite OPF hrefs as percent-encoded URLs
-- (`MediaOverlays/005%20-%20PROLOGUE.smil`) while the zip members keep
-- literal spaces.  unzip then misses every SMIL and we report "no
-- built-in audiobook" even though Readest still plays the same file.
function EpubMediaOverlay:_urlDecode(path)
    -- plain find: "%" is one percent. "%%" would look for two percents
    -- and skip every real %20 / %2C href (Readest/Calibre).
    if not path or not path:find("%", 1, true) then
        return path
    end
    return (path:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

--- Zip member names to try: as written, then percent-decoded.
function EpubMediaOverlay:_zipMemberCandidates(path)
    local list = { path }
    local decoded = self:_urlDecode(path)
    if decoded and decoded ~= path then
        list[#list + 1] = decoded
    end
    return list
end

--- Quote an argument for POSIX sh: single quotes make the whole string
-- literal, with the standard '\'' escape for embedded quotes. Never build
-- a shell command with double-quote-and-escape: $(), backticks and friends
-- stay live inside double quotes, and archive member paths come straight
-- from book content.
function EpubMediaOverlay:_quoteShell(arg)
    return "'" .. tostring(arg or ""):gsub("'", "'\\''") .. "'"
end

--- Archive member paths reach shell commands (unzip -p/-o) as arguments.
-- A malicious EPUB could otherwise smuggle shell metacharacters or ".."
-- traversal into the SMIL audio/text src values, and on Kindle KOReader
-- runs as root. Reject anything that is not a plain relative path.
function EpubMediaOverlay:_validateZipMember(path)
    if not path or path == "" then return false end
    if path:sub(1, 1) == "/" then return false end
    -- No control characters at all (covers newlines, $() separators, etc.)
    if path:find("%c") then return false end
    -- No "." or ".." path segments
    for segment in path:gmatch("[^/]+") do
        if segment == "." or segment == ".." then return false end
    end
    return true
end

--- Pretty-printed XML puts newlines inside elements; collapse tag boundaries
-- so legacy `(.-)` patterns still work if RE_ANY_LAZY ever fails on-device.
function EpubMediaOverlay:_compactXml(xml)
    if not xml or xml == "" then return xml end
    return xml:gsub(">%s+<", "><")
end

--- Fingerprint an EPUB so we invalidate extracted audio when the file is
-- replaced in-place (same path, new Storyteller export). Path-only cache
-- keys reused stale MP3/MP4 against fresh SMIL timings — highlights then
-- tracked the new alignment while the old audio played (Readest was fine
-- because it streams from the EPUB directly).
function EpubMediaOverlay:_epubFingerprint(epub_path)
    if not epub_path then return nil end
    -- LuaFileSystem may be unavailable; fall back to shell stat.
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs and lfs.attributes then
        local attr = lfs.attributes(epub_path)
        if attr and attr.size and attr.modification then
            return string.format("%d:%d", attr.size, attr.modification)
        end
    end
    local out = self:_runCommand(string.format(
        'stat -c "%%s:%%Y" %s 2>/dev/null || stat -f "%%z:%%m" %s 2>/dev/null',
        self:_quoteShell(epub_path), self:_quoteShell(epub_path)))
    if out then
        local fp = out:match("(%d+:%d+)")
        if fp then return fp end
    end
    return nil
end

function EpubMediaOverlay:_ensureCacheDir(plugin_dir, epub_path)
    -- Use a hash of the epub path to create a stable cache directory
    local hash = self:_simpleHash(epub_path)
    local cache = plugin_dir .. "/cache/overlays/" .. hash
    os.execute("mkdir -p '" .. cache:gsub("'", "'\\''") .. "'")

    local fp = self:_epubFingerprint(epub_path)
    local meta_path = cache .. "/.epub_fingerprint"
    local cached_fp
    local f = io.open(meta_path, "r")
    if f then
        cached_fp = (f:read("*l") or ""):gsub("%s+$", "")
        f:close()
    end
    if fp and cached_fp and cached_fp ~= "" and cached_fp ~= fp then
        logger.warn("EpubMediaOverlay: EPUB changed (", cached_fp, "->", fp,
            ") — wiping stale overlay cache", cache)
        os.execute("rm -rf '" .. cache:gsub("'", "'\\''") .. "'")
        os.execute("mkdir -p '" .. cache:gsub("'", "'\\''") .. "'")
    end
    if fp then
        local wf = io.open(meta_path, "w")
        if wf then
            wf:write(fp)
            wf:close()
        end
    end
    return cache
end

function EpubMediaOverlay:_simpleHash(str)
    -- DJB2 hash -> hex string.
    -- hash * 33 == (hash << 5) + hash, written arithmetically because
    -- LuaJIT is Lua 5.1: the 5.3 bitwise operators do not parse and a
    -- bare `<<` makes this whole module fail to load ("Failed to load
    -- EPUB Media Overlay parser").  Doubles stay exact here: hash is
    -- kept below 2^32, so hash*33 + byte < 2^38, well under 2^53.
    local hash = 5381
    for i = 1, #str do
        hash = (hash * 33 + str:byte(i)) % 4294967296
    end
    return string.format("%08x", hash)
end

function EpubMediaOverlay:_parseTimeToSeconds(time_str)
    -- SMIL clock values: "hh:mm:ss.ms", "mm:ss.ms", "ss.ms", or timecounts
    -- with a metric suffix: "25.180s", "300ms", "2.5min", "1.5h"
    -- (Storyteller emits the "...s" form for clipBegin/clipEnd).
    if not time_str then return 0 end
    time_str = time_str:gsub("^%s*", ""):gsub("%s*$", "")

    -- Timecount with metric suffix
    local num, suffix = time_str:match("^([%d%.]+)(m?s?i?n?h?)$")
    if num and suffix and suffix ~= "" then
        local n = tonumber(num)
        if n then
            if suffix == "s" then return n end
            if suffix == "ms" then return n / 1000 end
            if suffix == "min" then return n * 60 end
            if suffix == "h" then return n * 3600 end
        end
    end

    -- ss.ms format
    local secs = tonumber(time_str:match("^([%d%.]+)$"))
    if secs then return secs end

    -- mm:ss.ms format
    local mm, ss = time_str:match("^(%d+):([%d%.]+)$")
    if mm and ss then
        return tonumber(mm) * 60 + tonumber(ss)
    end

    -- hh:mm:ss.ms format
    local hh, mm2, ss2 = time_str:match("^(%d+):(%d+):([%d%.]+)$")
    if hh and mm2 and ss2 then
        return tonumber(hh) * 3600 + tonumber(mm2) * 60 + tonumber(ss2)
    end

    logger.warn("EpubMediaOverlay: could not parse time:", time_str)
    return 0
end

-- ---------------------------------------------------------------------------
-- EPUB container / OPF parsing
-- ---------------------------------------------------------------------------

function EpubMediaOverlay:_extractFromZip(epub_path, internal_path)
    -- Extract a single file from the EPUB using unzip
    local last_unsafe
    for _, path in ipairs(self:_zipMemberCandidates(internal_path)) do
        if not self:_validateZipMember(path) then
            last_unsafe = path
        else
            local zip_member = self:_escapeUnzipMember(path)
            local cmd = string.format(
                'unzip -p %s %s',
                self:_quoteShell(epub_path),
                self:_quoteShell(zip_member)
            )
            local out = self:_runCommand(cmd)
            if out and out ~= ""
                and not out:find("filename not matched", 1, true) then
                return out
            end
        end
    end
    if last_unsafe then
        logger.warn("EpubMediaOverlay: refusing unsafe archive member path",
            tostring(last_unsafe))
    end
    return nil
end

function EpubMediaOverlay:_findOpfPath(epub_path)
    -- Read META-INF/container.xml to find the OPF path
    local container_xml = self:_extractFromZip(epub_path, "META-INF/container.xml")
    if not container_xml or container_xml == "" then
        logger.warn("EpubMediaOverlay: could not read container.xml")
        return nil
    end

    -- Parse container.xml for full-path attribute
    local opf_path = container_xml:match('full%-path%s*=%s*"([^"]+)"')
    if not opf_path then
        -- Try without escaping the hyphen
        opf_path = container_xml:match('full%-path%s*=%s*"([^"]+)"')
    end
    if not opf_path then
        -- Fallback: look for any .opf reference
        opf_path = container_xml:match('href%s*=%s*"([^"]-%.opf)"')
    end

    return opf_path
end

function EpubMediaOverlay:_parseOpfManifest(opf_xml)
    opf_xml = self:_compactXml(opf_xml)
    -- Extract manifest items from OPF.
    -- We need: items with media-overlay attributes, and the smil files they reference.
    local manifest = {}
    local manifest_items = {}

    -- Find the manifest section
    local manifest_block = opf_xml:match("<manifest[^>]*>" .. RE_ANY_LAZY .. "</manifest>")
    if not manifest_block then
        logger.warn("EpubMediaOverlay: no manifest found in OPF")
        return nil
    end

    -- Parse each item in the manifest.
    -- The character class must allow '/' inside the capture: hrefs are
    -- paths ("text/part0007.html", "MediaOverlays/part0007.smil"), and a
    -- class of [^/>] silently dropped every such item, leaving the
    -- overlay map empty ("no media overlays found") on real books.
    for item_str in manifest_block:gmatch("<item([^>]-)/>") do
        local id = item_str:match('id%s*=%s*"([^"]+)"')
        local href = item_str:match('href%s*=%s*"([^"]+)"')
        local media_type = item_str:match('media%-type%s*=%s*"([^"]+)"')
        local media_overlay = item_str:match('media%-overlay%s*=%s*"([^"]+)"')

        if id and href then
            manifest_items[id] = {
                id = id,
                href = self:_urlDecode(href) or href,
                media_type = media_type,
                media_overlay = media_overlay,
            }
        end
    end

    -- Build overlay mapping: content file -> smil file
    for id, item in pairs(manifest_items) do
        if item.media_overlay then
            local overlay_item = manifest_items[item.media_overlay]
            if overlay_item then
                manifest[id] = {
                    content_id = id,
                    content_href = item.href,
                    smil_href = overlay_item.href,
                }
            end
        end
    end

    return manifest, manifest_items
end

-- ---------------------------------------------------------------------------
-- SMIL parsing
-- ---------------------------------------------------------------------------

function EpubMediaOverlay:_parseSmil(smil_xml, smil_base_path)
    smil_xml = self:_compactXml(smil_xml)
    -- Parse a SMIL file and return timing_data entries.
    -- SMIL structure:
    --   <smil>
    --     <body>
    --       <seq epub:textref="chapter.xhtml">
    --         <par>
    --           <text src="chapter.xhtml#id1"/>
    --           <audio src="audio.mp3" clipBegin="0:00:00.000" clipEnd="0:00:05.234"/>
    --         </par>
    --       </seq>
    --     </body>
    --   </smil>
    local timing_data = {}
    -- smil_base_path is already the SMIL file's directory (the caller
    -- strips the filename); taking another dirname here emptied the base
    -- and broke every relative audio src.
    local audio_base = smil_base_path or ""

    -- Find all <par> elements.  gmatch with two captures yields two loop
    -- values; the old single-variable loop bound only the attribute
    -- capture and threw away the body that holds <text>/<audio>.
    for _par_attrs, par_block in smil_xml:gmatch("<par([^>]*)>" .. RE_ANY_LAZY .. "</par>") do
        -- Extract text src (match the <text> element specifically; a bare
        -- src= match would also hit <audio src=...>)
        local text_src = par_block:match('<text[^>]-src%s*=%s*"([^"]+)"')
            or par_block:match('src%s*=%s*"([^"]+)"')
        -- Extract audio attributes ('/' must stay allowed in the capture:
        -- src paths contain slashes)
        local audio_block = par_block:match("<audio([^>]-)/>")
        if not audio_block then
            audio_block = par_block:match("<audio" .. RE_ANY_LAZY .. "</audio>")
        end

        if audio_block then
            local audio_src = audio_block:match('src%s*=%s*"([^"]+)"')
            local clip_begin = audio_block:match('clipBegin%s*=%s*"([^"]+)"')
            local clip_end = audio_block:match('clipEnd%s*=%s*"([^"]+)"')

            if audio_src then
                audio_src = self:_urlDecode(audio_src) or audio_src
                if text_src then
                    text_src = self:_urlDecode(text_src) or text_src
                end
                -- Resolve relative paths
                local resolved_audio = audio_src
                if audio_src:sub(1, 1) ~= "/" and audio_base ~= "" then
                    resolved_audio = audio_base .. "/" .. audio_src
                end
                -- Collapse "dir/../" segments: SMIL audio srcs are written
                -- relative to the SMIL dir ("../Audio/x.mp3"), but zip
                -- member names ("Audio/x.mp3") contain no dot-dots, so
                -- unzip would find nothing.
                local prev
                repeat
                    prev = resolved_audio
                    resolved_audio = resolved_audio:gsub("[^/]+/%.%./", "", 1)
                until resolved_audio == prev
                resolved_audio = resolved_audio:gsub("^%./", "")

                local start_time = self:_parseTimeToSeconds(clip_begin)
                local end_time = self:_parseTimeToSeconds(clip_end)

                table.insert(timing_data, {
                    text = text_src or "",
                    text_ref = text_src,
                    audio_src = resolved_audio,
                    start_time = start_time,
                    end_time = end_time,
                })
            end
        end
    end

    return timing_data
end

--- Extract sentence texts from a content document.
-- Storyteller (and other overlay producers) wrap each narrated sentence in
-- an element carrying the SMIL fragment id, e.g. <span id="id12-s0">…</span>.
-- Returns a map fragment_id -> plain text, which gives timing entries real
-- sentence text so HighlightManager can find them on screen (it matches by
-- text, not by DOM position).
function EpubMediaOverlay:_extractSentenceTexts(epub_path, html_zip_path)
    local html = self:_extractFromZip(epub_path, html_zip_path)
    if not html or html == "" then return nil end
    -- Stack-based scan so nested <span> (Storyteller wraps text in
    -- <span id=sN><i><span lang=FR>…</span></i></span>) does not truncate
    -- at the first inner </span>.
    local map = {}
    local stack = {} -- { id=string|nil, parts={} }
    local i = 1
    local n = #html
    while i <= n do
        local s, e, attrs = html:find("<span([^>]*)>", i)
        local cs, ce = html:find("</span>", i)
        if s and (not cs or s < cs) then
            if s > i and #stack > 0 then
                table.insert(stack[#stack].parts, html:sub(i, s - 1))
            end
            local id = attrs and attrs:match('id%s*=%s*"([^"]+)"')
            table.insert(stack, { id = id, parts = {} })
            i = e + 1
        elseif cs then
            if cs > i and #stack > 0 then
                table.insert(stack[#stack].parts, html:sub(i, cs - 1))
            end
            local finished = table.remove(stack)
            i = ce + 1
            if finished then
                local body = table.concat(finished.parts)
                -- Pass inner HTML up so parents keep nested text.
                if #stack > 0 then
                    table.insert(stack[#stack].parts, body)
                end
                if finished.id and not map[finished.id] then
                    local txt = body:gsub("<[^>]->", "")
                        :gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
                        :gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&apos;", "'")
                        :gsub("&nbsp;", " "):gsub("&#160;", " ")
                        :gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
                    if txt ~= "" then map[finished.id] = txt end
                end
            end
        else
            if #stack > 0 and i <= n then
                table.insert(stack[#stack].parts, html:sub(i))
            end
            break
        end
    end
    return map
end

--- Load chapter titles from the NCX table of contents.
-- Returns a map of content-document basename -> title.
function EpubMediaOverlay:_loadChapterTitles(epub_path, opf_xml, opf_base)
    local ncx_href = opf_xml:match('<item[^>]-href="([^"]-)"[^>]-media%-type="application/x%-dtbncx%+xml"')
        or opf_xml:match('<item[^>]-media%-type="application/x%-dtbncx%+xml"[^>]-href="([^"]-)"')
        or "toc.ncx"
    local p = ncx_href
    if p:sub(1, 1) ~= "/" and opf_base ~= "" then
        p = opf_base .. "/" .. p
    end
    local ncx = self:_extractFromZip(epub_path, p)
    if not ncx or ncx == "" then return {} end
    local titles = {}
    -- Flat scan is fine for the common non-nested navMap; with nesting the
    -- first label per target document still wins, which is what we want.
    for block in ncx:gmatch("<navPoint[%z\1-\255]-</navPoint>") do
        local label = block:match("<text>" .. RE_ANY_LAZY .. "</text>")
        local src = block:match('src="([^"#]+)')
        if label and src then
            local base = src:match("([^/]+)$")
            if base and not titles[base] then
                titles[base] = label
            end
        end
    end
    return titles
end

-- ---------------------------------------------------------------------------
-- Audio extraction
-- ---------------------------------------------------------------------------

function EpubMediaOverlay:_extractAudioFile(epub_path, internal_path, cache_dir)
    -- unzip -d preserves directory structure, so the extracted file lives
    -- at cache_dir/internal_path.  Check THAT path first: this function is
    -- called once per SMIL par entry (thousands of times per book, with a
    -- handful of distinct audio files), and the old check against only the
    -- flattened name made every single entry re-extract its multi-MB audio
    -- file from the zip.
    internal_path = self:_urlDecode(internal_path) or internal_path
    if not self:_validateZipMember(internal_path) then
        logger.warn("EpubMediaOverlay: refusing unsafe audio path",
            tostring(internal_path))
        return nil
    end
    local extracted = cache_dir .. "/" .. internal_path
    if self:_fileExists(extracted) then
        return extracted
    end

    local cache_path = cache_dir .. "/" .. internal_path:gsub("/", "_")
    if self:_fileExists(cache_path) then
        return cache_path
    end

    -- Extract the file
    local zip_member = self:_escapeUnzipMember(internal_path)
    local cmd = string.format(
        'unzip -o %s %s -d %s >/dev/null 2>&1',
        self:_quoteShell(epub_path),
        self:_quoteShell(zip_member),
        self:_quoteShell(cache_dir)
    )
    os.execute(cmd)

    -- The extracted file will be at cache_dir/internal_path
    -- But unzip preserves the directory structure, so we need to find it
    local extracted = cache_dir .. "/" .. internal_path
    if self:_fileExists(extracted) then
        return extracted
    end

    -- Fallback: try flat cache path
    if self:_fileExists(cache_path) then
        return cache_path
    end

    logger.warn("EpubMediaOverlay: failed to extract", internal_path)
    return nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function EpubMediaOverlay:loadFromEpub(epub_path, plugin_dir, progress_callback)
    if not epub_path or not plugin_dir then
        return nil, "missing path or plugin_dir"
    end

    local function report(phase, current, total, detail)
        if progress_callback then
            pcall(progress_callback, {
                phase = phase,
                current = current,
                total = total,
                detail = detail,
            })
        end
    end

    self._epub_path = epub_path
    self._cache_dir = self:_ensureCacheDir(plugin_dir, epub_path)

    -- Step 1: Find OPF path
    local opf_path = self:_findOpfPath(epub_path)
    if not opf_path then
        return nil, "could not find OPF"
    end
    logger.dbg("EpubMediaOverlay: OPF path =", opf_path)

    -- Step 2: Parse OPF manifest
    local opf_xml = self:_extractFromZip(epub_path, opf_path)
    if not opf_xml or opf_xml == "" then
        return nil, "could not read OPF"
    end

    local overlay_manifest, manifest_items = self:_parseOpfManifest(opf_xml)
    if not overlay_manifest or not next(overlay_manifest) then
        return nil, "no media overlays found"
    end

    logger.dbg("EpubMediaOverlay: found", self:_tableCount(overlay_manifest), "overlay entries")

    local all_timing_data = {}
    local opf_base = opf_path:match("^(.*)/") or ""
    self._chapter_titles = self:_loadChapterTitles(epub_path, opf_xml, opf_base)
    -- Spine order: crengine numbers DocFragments in spine order, so this
    -- maps the reader's current position to a content document (used to
    -- start narration from the page the user is on). Also drives SMIL
    -- parse order — string-sorting SMIL hrefs breaks when filenames are
    -- not zero-padded the same way as the spine.
    self._spine_hrefs = {}
    local spine_block = opf_xml:match("<spine[^>]*>" .. RE_ANY_LAZY .. "</spine>") or ""
    for idref in spine_block:gmatch('<itemref[^>]-idref="([^"]+)"') do
        local it = manifest_items[idref]
        if it and it.href then
            table.insert(self._spine_hrefs, it.href:match("([^/]+)$") or it.href)
        end
    end

    -- Step 3: Parse SMIL files in spine order (fallback: SMIL href sort).
    local by_content = {}
    for content_href, info in pairs(overlay_manifest) do
        local base = (info.content_href or content_href):match("([^/]+)$")
            or info.content_href or content_href
        by_content[base] = info
    end
    local ordered_overlays = {}
    local seen = {}
    for _, base in ipairs(self._spine_hrefs) do
        local info = by_content[base]
        if info and not seen[info] then
            table.insert(ordered_overlays, info)
            seen[info] = true
        end
    end
    for _, info in pairs(overlay_manifest) do
        if not seen[info] then
            table.insert(ordered_overlays, info)
        end
    end
    if #ordered_overlays > 1 and #self._spine_hrefs == 0 then
        table.sort(ordered_overlays, function(a, b)
            return (a.smil_href or "") < (b.smil_href or "")
        end)
    end

    local html_text_cache = {}
    local audio_path_cache = {}
    local total_smils = #ordered_overlays

    for smil_idx, overlay_info in ipairs(ordered_overlays) do
        report("smil", smil_idx, total_smils, overlay_info.smil_href)
        local smil_href = overlay_info.smil_href
        if not smil_href then goto continue end

        -- Resolve SMIL path relative to OPF
        local smil_path = smil_href
        if smil_href:sub(1, 1) ~= "/" and opf_base ~= "" then
            smil_path = opf_base .. "/" .. smil_href
        end

        local smil_xml = self:_extractFromZip(epub_path, smil_path)
        if not smil_xml or smil_xml == "" then
            logger.warn("EpubMediaOverlay: could not read SMIL", smil_path)
            goto continue
        end

        local smil_base = smil_path:match("^(.*)/") or ""
        local timing_data = self:_parseSmil(smil_xml, smil_base)

        -- Resolve audio paths once per distinct audio_src (Storyteller books
        -- reference the same MP4 from thousands of <par> entries).
        for _, entry in ipairs(timing_data) do
            if entry.audio_src then
                local ap = audio_path_cache[entry.audio_src]
                if not ap then
                    ap = self:_extractAudioFile(epub_path, entry.audio_src, self._cache_dir)
                    audio_path_cache[entry.audio_src] = ap or false
                elseif ap == false then
                    ap = nil
                end
                if ap then
                    entry.audio_path = ap
                end
            end
            -- "../text/part0007.html#id12-s0" -> content doc + fragment id,
            -- then real sentence text from the doc's sentence spans.
            local tref = entry.text_ref or ""
            local doc_part, frag = tref:match("^([^#]+)#(.+)$")
            if doc_part and frag then
                local doc_path = doc_part
                if doc_path:sub(1, 1) ~= "/" and smil_base ~= "" then
                    doc_path = smil_base .. "/" .. doc_path
                end
                local prev
                repeat
                    prev = doc_path
                    doc_path = doc_path:gsub("[^/]+/%.%./", "", 1)
                until doc_path == prev
                doc_path = doc_path:gsub("^%./", "")
                entry.fragment_id = frag
                entry.text_doc = doc_path
                local map = html_text_cache[doc_path]
                if map == nil then
                    map = self:_extractSentenceTexts(epub_path, doc_path) or false
                    html_text_cache[doc_path] = map
                end
                local txt = map and map[frag]
                if txt then entry.text = txt end
            end
            table.insert(all_timing_data, entry)
        end

        ::continue::
    end

    if #all_timing_data == 0 then
        return nil, "no timing data extracted"
    end

    -- NOTE: entries are deliberately NOT globally sorted by start_time:
    -- clip times restart at zero for every audio file, so a global sort
    -- interleaves chapters.  Order here is narrative (SMIL) order; the
    -- caller groups by audio file and each group is internally monotonic.

    local unique_audio = 0
    for _ in pairs(audio_path_cache) do unique_audio = unique_audio + 1 end
    report("done", #all_timing_data, total_smils,
        string.format("%d timing, %d audio", #all_timing_data, unique_audio))

    logger.warn("EpubMediaOverlay: loaded", #all_timing_data, "timing entries,",
        unique_audio, "audio files")
    return all_timing_data
end

function EpubMediaOverlay:getCacheDir()
    return self._cache_dir
end

function EpubMediaOverlay:cleanupOldCaches(plugin_dir, max_age_days)
    max_age_days = tonumber(max_age_days) or 7
    local cache_root = plugin_dir .. "/cache/overlays"
    -- Find directories older than max_age_days and remove them
    local cmd = string.format(
        'find %s -maxdepth 1 -type d -mtime +%d -exec rm -rf {} + 2>/dev/null',
        self:_quoteShell(cache_root),
        max_age_days
    )
    os.execute(cmd)
end

function EpubMediaOverlay:_tableCount(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

return EpubMediaOverlay
