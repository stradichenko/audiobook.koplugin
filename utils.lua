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

return Utils
