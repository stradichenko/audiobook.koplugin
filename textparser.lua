--[[--
Text Parser Module
Splits text into words and sentences with position tracking.

@module textparser
--]]

local logger = require("logger")

-- Shared utility modules (DRY: countSyllables)
local _utils_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local Utils = dofile(_utils_dir .. "utils.lua")

local TextParser = {
    -- Sentence ending punctuation
    SENTENCE_ENDINGS = "[%.%?!]",
    -- Word separators
    WORD_SEPARATORS = "[%s%p]",
}
-- Long-sentence splitting thresholds (see benchmark/RESULTS_LONG.md).
-- Piper on ARM OOMs above ~900 chars; 300 keeps us in the efficient window.
-- Chunks below 80 chars waste 90%+ of synthesis time on per-request overhead.
local MAX_CHUNK_CHARS = 300
local MIN_CHUNK_CHARS = 80

-- Aggressive splitting (setting B, "piper_aggressive_split"): smaller chunks
-- reach the synthesizer sooner and avoid onnxruntime failures on long inputs
-- in low-memory devices.  Used when max_chunk_fn() returns a lower cap.
local AGGRESSIVE_CHUNK_CHARS = 150

-- Exposed for the plugin's max_chunk_fn wiring (main.lua).
TextParser.AGGRESSIVE_CHUNK_CHARS = AGGRESSIVE_CHUNK_CHARS

function TextParser:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

--[[--
Parse text into structured data with words and sentences.
@param text string The input text to parse
@return table Parsed structure with sentences and words
--]]
function TextParser:parse(text)
    if not text or text == "" then
        return {
            sentences = {},
            words = {},
            text = "",
        }
    end
    
    -- Normalize whitespace
    text = self:normalizeText(text)

    -- Optional chunk-size override (aggressive Piper splitting).  The
    -- callback is installed by the plugin and evaluates current settings.
    local max_chunk = MAX_CHUNK_CHARS
    if self.max_chunk_fn then
        max_chunk = self.max_chunk_fn() or MAX_CHUNK_CHARS
    end

    local result = {
        text = text,
        sentences = self:parseSentences(text, max_chunk),
        words = self:parseWords(text),
    }
    
    -- Link words to their sentences
    self:linkWordsToSentences(result)
    
    logger.dbg("TextParser: Parsed", #result.sentences, "sentences,", #result.words, "words")
    
    return result
end

--[[--
Normalize text by cleaning up whitespace and special characters.
@param text string Input text
@return string Normalized text
--]]
function TextParser:normalizeText(text)
    -- Normalize line endings to \n
    text = text:gsub("\r\n", "\n")
    text = text:gsub("\r", "\n")

    -- Issue #15: PocketBook PDF/EPUB text extractors sometimes emit control
    -- characters (NUL, SOH, STX, etc.) between words or characters.  Left in
    -- place they can split words, create phantom paragraphs, or collide with
    -- the paragraph sentinel we use below.  Strip the whole C0 control range
    -- except the whitespace we actually need (\t, \n).
    text = text:gsub("[%z\x01-\x08\x0b\x0c\x0e-\x1f]", "")

    -- Issue #21: PDFs (and PDF-derived EPUBs) wrap each visual line with a
    -- literal newline.  parseSentences treats every newline as a paragraph
    -- break, which inserts a TTS pause at every line wrap and synthesises
    -- hyphen-split words ("re-" + "duce") as two utterances.
    --
    -- We preserve real paragraph breaks (blank lines) with a sentinel, turn
    -- remaining single newlines into spaces, then restore the sentinels.
    -- v0.1.5.80 used a single NUL byte ("\0") as the sentinel; v0.1.5.81
    -- stripped NULs from the input but PB632/PB700c still reported char-by-char
    -- reading, so we now use a multi-byte sentinel that can never collide.
    local PARA_SENTINEL = "\x01\x02\x03"
    text = text:gsub("\n[ \t]*\n+", PARA_SENTINEL)
    text = text:gsub("([^%s%p])%-\n([^%s%p])", "%1%2")
    text = text:gsub("\n", " ")
    text = text:gsub(PARA_SENTINEL, "\n")

    -- Replace runs of spaces/tabs (but NOT newlines) with single space
    text = text:gsub("[ \t]+", " ")
    -- Trim leading/trailing whitespace
    text = text:match("^%s*(.-)%s*$")

    -- Defensive guard: if the extractor emits paragraph breaks between every
    -- character or word, parseSentences will create one-sentence-per-character
    -- and TTS reads the page one letter at a time.  Detect an abnormally high
    -- proportion of very short lines and join them into a single paragraph.
    local line_count = 0
    local short_line_count = 0
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" then
            line_count = line_count + 1
            if #line <= 2 then
                short_line_count = short_line_count + 1
            end
        end
    end
    if line_count > 5 and short_line_count / line_count > 0.5 then
        text = text:gsub("\n", " ")
        text = text:gsub("[ \t]+", " ")
    end

    return text
end

--[[--
Parse text into sentences.
@param text string Input text
@param max_chunk number|nil  Long-sentence split cap (default MAX_CHUNK_CHARS)
@return table Array of sentence objects
--]]
function TextParser:parseSentences(text, max_chunk)
    max_chunk = max_chunk or MAX_CHUNK_CHARS
    local sentences = {}
    local sentence_index = 1

    -- Helper: add a sentence if non-empty
    -- @param s string  Trimmed sentence text
    -- @param end_type string  "paragraph" = last segment before a newline,
    --                         "sentence"  = split by .?!;: mid-line
    local function addSentence(s, end_type)
        s = s:match("^%s*(.-)%s*$")  -- trim
        if s and s ~= "" then
            table.insert(sentences, {
                index = sentence_index,
                text = s,
                start_pos = 0,
                end_pos = 0,
                words = {},
                end_type = end_type or "sentence",
            })
            sentence_index = sentence_index + 1
        end
    end

    -- Step 1: split on newlines (each line is at least one sentence)
    for line in (text .. "\n"):gmatch("([^\n]+)\n") do
        line = line:match("^%s*(.-)%s*$")
        if line and line ~= "" then
            -- Step 2: split each line on sentence-ending punctuation (.?!…)
            -- followed by a space or end-of-string.
            -- NOTE: semicolons (;) and colons (:) are NOT treated as sentence
            -- endings — they are mid-sentence punctuation that should not
            -- interrupt the reading flow.
            -- The Unicode ellipsis (…) must split too: otherwise "fin… La
            -- suite" is one utterance and some engines stop at the ellipsis.
            local ell = "\226\128\166" -- …
            local pos = 1
            local segments_in_line = {}
            while pos <= #line do
                -- Find the earliest .?!/… that is followed by a space (or is
                -- at end of line)
                local best_s, best_e
                local function consider(s, e)
                    if s and (not best_s or s < best_s) then
                        best_s, best_e = s, e
                    end
                end
                consider(line:find("[%.%?!]+%s", pos))
                consider(line:find("[%.%?!]+$", pos))
                consider(line:find(ell .. "%s", pos))
                consider(line:find(ell .. "$", pos))
                local pstart, pend = best_s, best_e
                if pstart then
                    -- Include the punctuation but not the trailing space
                    local seg_end = pend
                    -- If the match ended with a space, don't include the space
                    if line:sub(pend, pend):match("%s") then
                        seg_end = pend - 1
                    end
                    table.insert(segments_in_line, line:sub(pos, seg_end))
                    pos = seg_end + 1
                    -- Skip whitespace
                    while pos <= #line and line:sub(pos, pos):match("%s") do
                        pos = pos + 1
                    end
                else
                    -- No more sentence-ending punctuation: rest is one segment
                    table.insert(segments_in_line, line:sub(pos))
                    break
                end
            end
            -- Tag: last segment in line → "paragraph", others → "sentence"
            for i, seg in ipairs(segments_in_line) do
                local etype = (i == #segments_in_line) and "paragraph" or "sentence"
                addSentence(seg, etype)
            end
        end
    end

    -- Step 3: split long sentences for TTS safety.
    -- Piper on ARM OOMs above ~900 chars; split anything over max_chunk
    -- at clause boundaries, then cap at word boundaries if still too long.
    local expanded = {}
    local new_index = 1
    for _, sentence in ipairs(sentences) do
        if #sentence.text > max_chunk then
            local chunks = self:splitLongSentence(sentence.text, max_chunk)
            for j, chunk in ipairs(chunks) do
                local etype = (j == #chunks) and sentence.end_type or "sentence"
                table.insert(expanded, {
                    index = new_index,
                    text = chunk,
                    start_pos = 0,
                    end_pos = 0,
                    words = {},
                    end_type = etype,
                })
                new_index = new_index + 1
            end
        else
            sentence.index = new_index
            table.insert(expanded, sentence)
            new_index = new_index + 1
        end
    end
    sentences = expanded

    -- Recalculate start/end positions relative to original text
    local search_from = 1
    for _, sentence in ipairs(sentences) do
        local found = text:find(sentence.text, search_from, true)  -- plain search
        if found then
            sentence.start_pos = found
            sentence.end_pos = found + #sentence.text - 1
            search_from = sentence.end_pos + 1
        end
    end

    return sentences
end

--[[--
Split a long sentence into clause-aware chunks for Piper TTS.

Piper on ARM has a hard ceiling at ~900 chars (OOM above ~1000).  Even below
that, throughput is best with 100-300 char chunks.  This function:

1. Splits at natural clause boundaries (; : " - " and ", <conjunction>")
2. Merges tiny fragments (< MIN_CHUNK_CHARS) with their neighbours
3. Re-splits anything still over max_chars at word boundaries

See benchmark/RESULTS_LONG.md for the data behind these thresholds.

@param text string      The sentence text to split
@param max_chars number  Maximum chunk size (default MAX_CHUNK_CHARS)
@return table            Array of chunk strings
--]]
function TextParser:splitLongSentence(text, max_chars)
    max_chars = max_chars or MAX_CHUNK_CHARS
    if #text <= max_chars then
        return { text }
    end

    -- Step 1: split at clause boundaries
    local chunks = self:_splitAtClauses(text)

    -- Step 2: merge fragments smaller than MIN_CHUNK_CHARS
    chunks = self:_mergeSmallChunks(chunks, MIN_CHUNK_CHARS)

    -- Step 3: re-split anything still over max_chars at word boundaries
    local final = {}
    for _, chunk in ipairs(chunks) do
        if #chunk > max_chars then
            local subs = self:_splitAtWordBoundary(chunk, max_chars)
            for _, sub in ipairs(subs) do
                table.insert(final, sub)
            end
        else
            table.insert(final, chunk)
        end
    end

    return final
end

--[[--
Split text at clause boundaries.

Recognised boundaries (kept at the end of the preceding chunk):
  - semicolons:   "; "
  - colons:       ": "
  - dashes:       " - "
  - conjunctions: ", and/but/or/nor/for/yet/so/which/who/that/where/when/
                    while/although/because/since/unless/if/after/before"

@param text string
@return table Array of trimmed non-empty strings
--]]
function TextParser:_splitAtClauses(text)
    local conjunctions = {
        "and", "but", "or", "nor", "for", "yet", "so",
        "which", "who", "that", "where", "when", "while",
        "although", "because", "since", "unless", "if",
        "after", "before",
    }

    local chunks = {}
    local current = ""
    local pos = 1

    while pos <= #text do
        local ch = text:sub(pos, pos)

        -- "; " or ": " - split after the punctuation
        if (ch == ";" or ch == ":") and text:sub(pos + 1, pos + 1) == " " then
            current = current .. ch
            table.insert(chunks, current)
            current = ""
            pos = pos + 2  -- skip the trailing space

        -- " - " - split after the dash
        elseif text:sub(pos, pos + 2) == " - " then
            current = current .. " -"
            table.insert(chunks, current)
            current = ""
            pos = pos + 3

        -- ", <conjunction> " - split after the comma
        elseif ch == "," and text:sub(pos + 1, pos + 1) == " " then
            local rest = text:sub(pos + 2)
            local found_conj = false
            for _, conj in ipairs(conjunctions) do
                if rest:find("^" .. conj .. "%s") or rest:find("^" .. conj .. "$") then
                    current = current .. ","
                    table.insert(chunks, current)
                    current = ""
                    pos = pos + 2  -- skip ", "; conjunction starts the next chunk
                    found_conj = true
                    break
                end
            end
            if not found_conj then
                current = current .. ch
                pos = pos + 1
            end

        else
            current = current .. ch
            pos = pos + 1
        end
    end

    if current ~= "" then
        table.insert(chunks, current)
    end

    -- Trim and drop empties
    local result = {}
    for _, chunk in ipairs(chunks) do
        chunk = chunk:match("^%s*(.-)%s*$")
        if chunk and chunk ~= "" then
            table.insert(result, chunk)
        end
    end
    return result
end

--[[--
Merge chunks shorter than min_chars with a neighbour.

Prefers merging with the previous chunk (so we build up the leading chunk).
Falls back to merging forward when there is no previous chunk.

@param chunks table     Array of chunk strings
@param min_chars number  Minimum acceptable chunk length
@return table            Merged array
--]]
function TextParser:_mergeSmallChunks(chunks, min_chars)
    if #chunks <= 1 then return chunks end

    local merged = {}
    for _, chunk in ipairs(chunks) do
        if #chunk < min_chars and #merged > 0 then
            -- Merge with previous chunk
            merged[#merged] = merged[#merged] .. " " .. chunk
        elseif #chunk < min_chars then
            -- First chunk is tiny - just push, will merge on next iteration
            table.insert(merged, chunk)
        else
            table.insert(merged, chunk)
        end
    end

    -- Second pass: if the first chunk is still too small, merge it forward
    if #merged > 1 and #merged[1] < min_chars then
        merged[2] = merged[1] .. " " .. merged[2]
        table.remove(merged, 1)
    end

    return merged
end

--[[--
Split text at word boundaries so every chunk is <= max_chars.

Finds the last space at or before the limit and splits there.
Falls back to a hard cut when a single word exceeds max_chars.

@param text string
@param max_chars number
@return table Array of chunk strings
--]]
function TextParser:_splitAtWordBoundary(text, max_chars)
    local chunks = {}
    local remaining = text

    while #remaining > max_chars do
        local split_pos = max_chars
        -- Walk backwards to find a space
        while split_pos > 0 and remaining:sub(split_pos, split_pos) ~= " " do
            split_pos = split_pos - 1
        end
        if split_pos == 0 then
            -- No space found - hard cut (extremely unlikely with natural text)
            split_pos = max_chars
        end
        table.insert(chunks, remaining:sub(1, split_pos - 1))
        remaining = remaining:sub(split_pos + 1)  -- skip the space
    end

    if #remaining > 0 then
        -- If the trailing fragment is shorter than MIN_CHUNK_CHARS, merge it
        -- back into the previous chunk.  Slightly exceeding max_chars is far
        -- cheaper than the ~4-5 s fixed overhead of a tiny extra request.
        if #remaining < MIN_CHUNK_CHARS and #chunks > 0 then
            chunks[#chunks] = chunks[#chunks] .. " " .. remaining
        else
            table.insert(chunks, remaining)
        end
    end
    return chunks
end

--[[--
Parse text into words with positions.
@param text string Input text
@return table Array of word objects
--]]
function TextParser:parseWords(text)
    local words = {}
    local word_index = 1
    local pos = 1
    
    while pos <= #text do
        -- Skip whitespace
        while pos <= #text and text:sub(pos, pos):match("%s") do
            pos = pos + 1
        end
        
        if pos > #text then
            break
        end
        
        -- Find word start
        local word_start = pos
        
        -- Find word end (non-whitespace sequence)
        while pos <= #text and not text:sub(pos, pos):match("%s") do
            pos = pos + 1
        end
        
        local word_text = text:sub(word_start, pos - 1)
        
        -- Strip punctuation for clean word (but keep position of full token)
        local clean_word = word_text:gsub("^[%p]*", ""):gsub("[%p]*$", "")
        
        if clean_word ~= "" then
            table.insert(words, {
                index = word_index,
                text = word_text,        -- Original with punctuation
                clean_text = clean_word, -- Without punctuation
                start_pos = word_start,
                end_pos = pos - 1,
                sentence_index = nil,    -- Will be set later
                duration = nil,          -- Will be set by TTS timing
                start_time = nil,        -- Will be set by TTS timing
                end_time = nil,          -- Will be set by TTS timing
            })
            word_index = word_index + 1
        end
    end
    
    return words
end

--[[--
Link words to their containing sentences.
@param parsed_data table The parsed data structure
--]]
function TextParser:linkWordsToSentences(parsed_data)
    for _, word in ipairs(parsed_data.words) do
        for _, sentence in ipairs(parsed_data.sentences) do
            if word.start_pos >= sentence.start_pos and word.end_pos <= sentence.end_pos then
                word.sentence_index = sentence.index
                table.insert(sentence.words, word)
                break
            end
        end
    end
end

--[[--
Get word at specific character position.
@param parsed_data table The parsed data structure
@param position number Character position in text
@return table|nil Word object or nil
--]]
function TextParser:getWordAtPosition(parsed_data, position)
    for _, word in ipairs(parsed_data.words) do
        if position >= word.start_pos and position <= word.end_pos then
            return word
        end
    end
    return nil
end

--[[--
Get sentence at specific character position.
@param parsed_data table The parsed data structure
@param position number Character position in text
@return table|nil Sentence object or nil
--]]
function TextParser:getSentenceAtPosition(parsed_data, position)
    for _, sentence in ipairs(parsed_data.sentences) do
        if position >= sentence.start_pos and position <= sentence.end_pos then
            return sentence
        end
    end
    return nil
end

--[[--
Get word by index.
@param parsed_data table The parsed data structure
@param index number Word index (1-based)
@return table|nil Word object or nil
--]]
function TextParser:getWordByIndex(parsed_data, index)
    return parsed_data.words[index]
end

--[[--
Get sentence by index.
@param parsed_data table The parsed data structure
@param index number Sentence index (1-based)
@return table|nil Sentence object or nil
--]]
function TextParser:getSentenceByIndex(parsed_data, index)
    return parsed_data.sentences[index]
end

--[[--
Estimate word timing based on syllable count and speech rate.
@param word table Word object
@param rate number Speech rate multiplier
@return number Estimated duration in milliseconds
--]]
function TextParser:estimateWordDuration(word, rate)
    rate = rate or 1.0
    local syllables = self:countSyllables(word.clean_text)
    -- Average syllable duration is about 200ms at normal rate
    local base_duration = syllables * 200
    return math.floor(base_duration / rate)
end

--[[--
Count syllables in a word (simple heuristic).
Delegates to shared Utils module.
@param word string The word to analyze
@return number Estimated syllable count
--]]
function TextParser:countSyllables(word)
    return Utils.countSyllables(word)
end

--[[--
Apply timing information to parsed words.
@param parsed_data table The parsed data structure
@param timing_data table Array of timing info from TTS engine
--]]
function TextParser:applyTimingData(parsed_data, timing_data)
    if not timing_data or #timing_data == 0 then
        logger.dbg("TextParser: No timing data provided, using estimates")
        self:applyEstimatedTiming(parsed_data)
        return
    end
    
    -- Match timing data to words
    local timing_index = 1
    for _, word in ipairs(parsed_data.words) do
        if timing_index <= #timing_data then
            local timing = timing_data[timing_index]
            word.start_time = timing.start_time
            word.end_time = timing.end_time
            word.duration = timing.end_time - timing.start_time
            timing_index = timing_index + 1
        end
    end
    
    logger.dbg("TextParser: Applied timing data to", timing_index - 1, "words")
end

--[[--
Apply estimated timing when real timing is not available.
@param parsed_data table The parsed data structure
@param rate number Speech rate (default 1.0)
--]]
function TextParser:applyEstimatedTiming(parsed_data, rate)
    rate = rate or 1.0
    local current_time = 0
    
    for _, word in ipairs(parsed_data.words) do
        local duration = self:estimateWordDuration(word, rate)
        word.start_time = current_time
        word.end_time = current_time + duration
        word.duration = duration
        current_time = current_time + duration + 50 -- 50ms gap between words
    end
    
    logger.dbg("TextParser: Applied estimated timing, total duration:", current_time, "ms")
end

--[[--
Get the word that should be highlighted at a given time.
@param parsed_data table The parsed data structure
@param time_ms number Current playback time in milliseconds
@return table|nil Word object or nil
--]]
function TextParser:getWordAtTime(parsed_data, time_ms)
    for _, word in ipairs(parsed_data.words) do
        if word.start_time and word.end_time then
            if time_ms >= word.start_time and time_ms < word.end_time then
                return word
            end
        end
    end
    return nil
end

--[[--
Get the sentence that should be highlighted at a given time.
@param parsed_data table The parsed data structure
@param time_ms number Current playback time in milliseconds
@return table|nil Sentence object or nil
--]]
function TextParser:getSentenceAtTime(parsed_data, time_ms)
    local word = self:getWordAtTime(parsed_data, time_ms)
    if word and word.sentence_index then
        return self:getSentenceByIndex(parsed_data, word.sentence_index)
    end
    return nil
end

return TextParser
