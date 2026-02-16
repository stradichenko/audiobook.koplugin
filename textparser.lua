--[[--
Text Parser Module
Splits text into words and sentences with position tracking.

@module textparser
--]]

local logger = require("logger")

local TextParser = {
    -- Sentence ending punctuation
    SENTENCE_ENDINGS = "[%.%?!]",
    -- Word separators
    WORD_SEPARATORS = "[%s%p]",
}

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
    
    local result = {
        text = text,
        sentences = self:parseSentences(text),
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
    -- Collapse multiple blank lines into one newline
    text = text:gsub("\n%s*\n+", "\n")
    -- Replace runs of spaces/tabs (but NOT newlines) with single space
    text = text:gsub("[ \t]+", " ")
    -- Trim leading/trailing whitespace
    text = text:match("^%s*(.-)%s*$")
    return text
end

--[[--
Parse text into sentences.
@param text string Input text
@return table Array of sentence objects
--]]
function TextParser:parseSentences(text)
    local sentences = {}
    local sentence_index = 1

    -- First split on newlines (paragraph boundaries), then split each
    -- paragraph on sentence-ending punctuation (.?!) followed by a space.
    for paragraph in (text .. "\n"):gmatch("([^\n]+)\n") do
        paragraph = paragraph:match("^%s*(.-)%s*$") -- trim
        if paragraph and paragraph ~= "" then
            -- Split paragraph into sentences on .?! followed by whitespace
            -- We use gmatch to grab chunks ending with punctuation + space,
            -- then pick up any trailing remainder.
            local seg_start = 1
            -- Find positions where a sentence-ending punctuation is followed by a space
            while seg_start <= #paragraph do
                -- Match: any chars, then .?! optionally repeated, then a space
                local seg_end = nil
                local search_from = seg_start
                while true do
                    local p = paragraph:find("[%.%?!][%.%?!]*%s", search_from)
                    if p then
                        -- Skip past the punctuation run to find where the space is
                        local after_punct = paragraph:find("%s", p)
                        if after_punct then
                            seg_end = after_punct - 1  -- include last punct, not the space
                            break
                        end
                    end
                    break
                end

                local chunk
                if seg_end then
                    chunk = paragraph:sub(seg_start, seg_end)
                    seg_start = seg_end + 1
                    -- Skip whitespace between sentences
                    while seg_start <= #paragraph and paragraph:sub(seg_start, seg_start):match("%s") do
                        seg_start = seg_start + 1
                    end
                else
                    -- No more punctuation — rest of paragraph is one sentence
                    chunk = paragraph:sub(seg_start)
                    seg_start = #paragraph + 1
                end

                chunk = chunk:match("^%s*(.-)%s*$") -- trim
                if chunk and chunk ~= "" then
                    table.insert(sentences, {
                        index = sentence_index,
                        text = chunk,
                        start_pos = 0,  -- recalculated below
                        end_pos = 0,
                        words = {},
                    })
                    sentence_index = sentence_index + 1
                end
            end
        end
    end

    -- Recalculate start/end positions relative to original text
    local search_from = 1
    for _, sentence in ipairs(sentences) do
        -- Find this sentence's text in the original, starting from where we left off
        local pat = sentence.text:sub(1, math.min(30, #sentence.text))
        pat = pat:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
        local found = text:find(pat, search_from, false)
        if found then
            sentence.start_pos = found
            sentence.end_pos = found + #sentence.text - 1
            search_from = sentence.end_pos + 1
        end
    end

    return sentences
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
@param word string The word to analyze
@return number Estimated syllable count
--]]
function TextParser:countSyllables(word)
    if not word or word == "" then
        return 1
    end
    
    word = word:lower()
    local count = 0
    local prev_vowel = false
    local vowels = "aeiouy"
    
    for i = 1, #word do
        local char = word:sub(i, i)
        local is_vowel = vowels:find(char, 1, true) ~= nil
        
        if is_vowel and not prev_vowel then
            count = count + 1
        end
        prev_vowel = is_vowel
    end
    
    -- Handle silent e
    if word:sub(-1) == "e" and count > 1 then
        count = count - 1
    end
    
    -- Minimum 1 syllable
    return math.max(count, 1)
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
