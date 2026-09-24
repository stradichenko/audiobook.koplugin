--[[--
Download manager for voice/language packs.
Uses curl (preferred) or wget (fallback) for HTTP downloads,
and tar or unzip for extraction.

@module downloader
--]]

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local time = require("ui/time")
local _ = require("audiobook_gettext")

local Downloader = {}

-- Known Piper voices from the rhasspy/piper-voices HuggingFace repository.
-- Place custom .onnx files in plugins/audiobook.koplugin/piper/ to use voices
-- not listed here.
Downloader.PIPER_VOICES = {
    -- English (US)
    { id = "en_US-danny-low",      name = "Danny (US English, low)",       size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/danny/low/en_US-danny-low.onnx" },
    { id = "en_US-ryan-low",       name = "Ryan (US English, low)",        size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ryan/low/en_US-ryan-low.onnx" },
    { id = "en_US-ryan-medium",    name = "Ryan (US English, medium)",     size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ryan/medium/en_US-ryan-medium.onnx" },
    { id = "en_US-amy-low",        name = "Amy (US English, low)",         size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/low/en_US-amy-low.onnx" },
    { id = "en_US-amy-medium",     name = "Amy (US English, medium)",      size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx" },
    { id = "en_US-lessac-low",     name = "Lessac (US English, low)",      size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/low/en_US-lessac-low.onnx" },
    { id = "en_US-lessac-medium",  name = "Lessac (US English, medium)",   size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx" },
    { id = "en_US-ljspeech-medium",name = "LJSpeech (US English, medium)", size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ljspeech/medium/en_US-ljspeech-medium.onnx" },
    { id = "en_US-arctic-medium",  name = "Arctic (US English, medium)",   size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/arctic/medium/en_US-arctic-medium.onnx" },
    { id = "en_US-bryce-medium",   name = "Bryce (US English, medium)",    size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/bryce/medium/en_US-bryce-medium.onnx" },
    { id = "en_US-john-medium",    name = "John (US English, medium)",     size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/john/medium/en_US-john-medium.onnx" },
    { id = "en_US-kristin-medium", name = "Kristin (US English, medium)",  size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/kristin/medium/en_US-kristin-medium.onnx" },
    -- English (GB)
    { id = "en_GB-semaine-medium", name = "Semaine (GB English, medium)",  size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/semaine/medium/en_GB-semaine-medium.onnx" },
    { id = "en_GB-alan-low",       name = "Alan (GB English, low)",        size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/alan/low/en_GB-alan-low.onnx" },
    { id = "en_GB-alan-medium",    name = "Alan (GB English, medium)",     size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/alan/medium/en_GB-alan-medium.onnx" },
    { id = "en_GB-alba-medium",    name = "Alba (GB English, medium)",     size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/alba/medium/en_GB-alba-medium.onnx" },
    { id = "en_GB-southern_english_female-low", name = "Southern English Female (GB, low)", size_mb = 15, url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/southern_english_female/low/en_GB-southern_english_female-low.onnx" },
    -- Spanish
    { id = "es_ES-sharvard-medium",name = "Sharvard (Spanish, medium)",    size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/es/es_ES/sharvard/medium/es_ES-sharvard-medium.onnx" },
    { id = "es_ES-mls_10246-low",  name = "MLS 10246 (Spanish, low)",      size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/es/es_ES/mls_10246/low/es_ES-mls_10246-low.onnx" },
    { id = "es_ES-mls_9972-low",   name = "MLS 9972 (Spanish, low)",       size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/es/es_ES/mls_9972/low/es_ES-mls_9972-low.onnx" },
    -- German
    { id = "de_DE-thorsten-low",   name = "Thorsten (German, low)",        size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/de/de_DE/thorsten/low/de_DE-thorsten-low.onnx" },
    { id = "de_DE-thorsten-medium",name = "Thorsten (German, medium)",     size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/de/de_DE/thorsten/medium/de_DE-thorsten-medium.onnx" },
    { id = "de_DE-karlsson-low",   name = "Karlsson (German, low)",        size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/de/de_DE/karlsson/low/de_DE-karlsson-low.onnx" },
    { id = "de_DE-karlsson-medium",name = "Karlsson (German, medium)",     size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/de/de_DE/karlsson/medium/de_DE-karlsson-medium.onnx" },
    { id = "de_DE-pavoque-low",    name = "Pavoque (German, low)",         size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/de/de_DE/pavoque/low/de_DE-pavoque-low.onnx" },
    { id = "de_DE-ramona-low",     name = "Ramona (German, low)",          size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/de/de_DE/ramona/low/de_DE-ramona-low.onnx" },
    -- French
    { id = "fr_FR-siwis-low",      name = "Siwis (French, low)",           size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/fr/fr_FR/siwis/low/fr_FR-siwis-low.onnx" },
    { id = "fr_FR-siwis-medium",   name = "Siwis (French, medium)",        size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/fr/fr_FR/siwis/medium/fr_FR-siwis-medium.onnx" },
    { id = "fr_FR-gilles-low",     name = "Gilles (French, low)",          size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/fr/fr_FR/gilles/low/fr_FR-gilles-low.onnx" },
    { id = "fr_FR-mls_1840-low",   name = "MLS 1840 (French, low)",        size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/fr/fr_FR/mls_1840/low/fr_FR-mls_1840-low.onnx" },
    -- Portuguese (Brazil)
    { id = "pt_BR-faber-medium",   name = "Faber (Portuguese BR, medium)", size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/pt/pt_BR/faber/medium/pt_BR-faber-medium.onnx" },
    { id = "pt_BR-edresson-low",   name = "Edresson (Portuguese BR, low)", size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/pt/pt_BR/edresson/low/pt_BR-edresson-low.onnx" },
    -- Italian
    { id = "it_IT-paola-medium",   name = "Paola (Italian, medium)",       size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/it/it_IT/paola/medium/it_IT-paola-medium.onnx" },
    -- Dutch
    { id = "nl_NL-mls_5809-low",   name = "MLS 5809 (Dutch, low)",         size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/nl/nl_NL/mls_5809/low/nl_NL-mls_5809-low.onnx" },
    { id = "nl_NL-mls_7432-low",   name = "MLS 7432 (Dutch, low)",         size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/nl/nl_NL/mls_7432/low/nl_NL-mls_7432-low.onnx" },
    -- Polish
    { id = "pl_PL-darkman-medium", name = "Darkman (Polish, medium)",      size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/pl/pl_PL/darkman/medium/pl_PL-darkman-medium.onnx" },
    { id = "pl_PL-gosia-medium",   name = "Gosia (Polish, medium)",        size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/pl/pl_PL/gosia/medium/pl_PL-gosia-medium.onnx" },
    { id = "pl_PL-mc_speech-medium",name = "MC Speech (Polish, medium)",   size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/pl/pl_PL/mc_speech/medium/pl_PL-mc_speech-medium.onnx" },
    { id = "pl_PL-mls_6892-low",   name = "MLS 6892 (Polish, low)",        size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/pl/pl_PL/mls_6892/low/pl_PL-mls_6892-low.onnx" },
    -- Czech
    { id = "cs_CZ-jirka-low",      name = "Jirka (Czech, low)",            size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/cs/cs_CZ/jirka/low/cs_CZ-jirka-low.onnx" },
    { id = "cs_CZ-jirka-medium",   name = "Jirka (Czech, medium)",         size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/cs/cs_CZ/jirka/medium/cs_CZ-jirka-medium.onnx" },
    -- Ukrainian
    { id = "uk_UA-lada-x_low",     name = "Lada (Ukrainian, x_low)",      size_mb = 5,   url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/uk/uk_UA/lada/x_low/uk_UA-lada-x_low.onnx" },
    -- Hindi
    { id = "hi_IN-pratham-medium", name = "Pratham (Hindi, medium)",      size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/hi/hi_IN/pratham/medium/hi_IN-pratham-medium.onnx" },
    -- Arabic
    { id = "ar_JO-kareem-low",     name = "Kareem (Arabic, low)",          size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/ar/ar_JO/kareem/low/ar_JO-kareem-low.onnx" },
    { id = "ar_JO-kareem-medium",  name = "Kareem (Arabic, medium)",       size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/ar/ar_JO/kareem/medium/ar_JO-kareem-medium.onnx" },
    -- Catalan
    { id = "ca_ES-upc_ona-x_low",  name = "UPC Ona (Catalan, x_low)",     size_mb = 5,   url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/ca/ca_ES/upc_ona/x_low/ca_ES-upc_ona-x_low.onnx" },
    { id = "ca_ES-upc_ona-medium", name = "UPC Ona (Catalan, medium)",    size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/ca/ca_ES/upc_ona/medium/ca_ES-upc_ona-medium.onnx" },
    -- Chinese (Simplified)
    { id = "zh_CN-chaowen-medium", name = "Chaowen (Chinese, medium)",    size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/zh/zh_CN/chaowen/medium/zh_CN-chaowen-medium.onnx" },
    { id = "zh_CN-huayan-x_low",   name = "Huayan (Chinese, x_low)",      size_mb = 5,   url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/zh/zh_CN/huayan/x_low/zh_CN-huayan-x_low.onnx" },
    { id = "zh_CN-huayan-medium",  name = "Huayan (Chinese, medium)",     size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/zh/zh_CN/huayan/medium/zh_CN-huayan-medium.onnx" },
    { id = "zh_CN-xiao_ya-medium", name = "Xiao Ya (Chinese, medium)",    size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/zh/zh_CN/xiao_ya/medium/zh_CN-xiao_ya-medium.onnx" },
    -- Danish
    { id = "da_DK-talesyntese-medium", name = "Talesyntese (Danish, medium)", size_mb = 60, url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/da/da_DK/talesyntese/medium/da_DK-talesyntese-medium.onnx" },
    -- Finnish
    { id = "fi_FI-harri-low",      name = "Harri (Finnish, low)",          size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/fi/fi_FI/harri/low/fi_FI-harri-low.onnx" },
    { id = "fi_FI-harri-medium",   name = "Harri (Finnish, medium)",       size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/fi/fi_FI/harri/medium/fi_FI-harri-medium.onnx" },
    -- Russian
    { id = "ru_RU-irina-medium",   name = "Irina (Russian, medium)",       size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/ru/ru_RU/irina/medium/ru_RU-irina-medium.onnx" },
    -- Greek
    { id = "el_GR-rapunzelina-low",name = "Rapunzelina (Greek, low)",      size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/el/el_GR/rapunzelina/low/el_GR-rapunzelina-low.onnx" },
    -- Norwegian
    { id = "no_NO-talesyntese-medium", name = "Talesyntese (Norwegian, medium)", size_mb = 60, url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/no/no_NO/talesyntese/medium/no_NO-talesyntese-medium.onnx" },
    -- Swedish
    { id = "sv_SE-nst-medium",     name = "NST (Swedish, medium)",         size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/sv/sv_SE/nst/medium/sv_SE-nst-medium.onnx" },
    -- Turkish
    { id = "tr_TR-dfki-medium",    name = "DFKI (Turkish, medium)",        size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/tr/tr_TR/dfki/medium/tr_TR-dfki-medium.onnx" },
    -- Hungarian
    { id = "hu_HU-anna-medium",    name = "Anna (Hungarian, medium)",      size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/hu/hu_HU/anna/medium/hu_HU-anna-medium.onnx" },
    -- Romanian
    { id = "ro_RO-mihai-medium",   name = "Mihai (Romanian, medium)",      size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/ro/ro_RO/mihai/medium/ro_RO-mihai-medium.onnx" },
}

-- Known MBROLA voices from the numediart/MBROLA-voices repository.
-- Each voice is a single binary database file.
-- Bundled voices (included in release) are marked bundled = true.
Downloader.MBROLA_VOICES = {
    -- Bundled (included in release package)
    { id = "us1", name = "US English Male 1",     size_mb = 5.4,  bundled = true,  lang = "en" },
    { id = "us2", name = "US English Female 1",   size_mb = 5.4,  bundled = true,  lang = "en" },
    { id = "fr1", name = "French Male 1",         size_mb = 4.9,  bundled = true,  lang = "fr" },
    { id = "de1", name = "German Male 1",         size_mb = 10.9, bundled = true,  lang = "de" },
    { id = "es1", name = "Spanish Male 1",        size_mb = 2.7,  bundled = true,  lang = "es" },
    { id = "cn1", name = "Chinese (Mandarin) Female 1", size_mb = 4.2, bundled = true, lang = "zh" },
    { id = "pt1", name = "Portuguese Male 1",     size_mb = 5.4,  bundled = true,  lang = "pt" },
    -- Downloadable extras
    { id = "us3", name = "US English Female 2",   size_mb = 5.4,  bundled = false, lang = "en" },
    { id = "en1", name = "UK English Male 1",     size_mb = 5.4,  bundled = false, lang = "en" },
    { id = "fr2", name = "French Female 1",       size_mb = 5.0,  bundled = false, lang = "fr" },
    { id = "fr3", name = "French Male 2",         size_mb = 4.8,  bundled = false, lang = "fr" },
    { id = "fr4", name = "French Female 2",       size_mb = 5.0,  bundled = false, lang = "fr" },
    { id = "fr5", name = "French Male 3",         size_mb = 4.9,  bundled = false, lang = "fr" },
    { id = "fr6", name = "French Female 3",       size_mb = 4.8,  bundled = false, lang = "fr" },
    { id = "fr7", name = "French Male 4",         size_mb = 4.5,  bundled = false, lang = "fr" },
    { id = "de2", name = "German Male 2",         size_mb = 10.0, bundled = false, lang = "de" },
    { id = "de3", name = "German Male 3",         size_mb = 10.9, bundled = false, lang = "de" },
    { id = "de4", name = "German Male 4",         size_mb = 21.2, bundled = false, lang = "de" },
    { id = "de5", name = "German Male 5",         size_mb = 13.6, bundled = false, lang = "de" },
    { id = "de6", name = "German Male 6",         size_mb = 54.1, bundled = false, lang = "de" },
    { id = "de7", name = "German Female 1",       size_mb = 54.0, bundled = false, lang = "de" },
    { id = "es2", name = "Spanish Male 2",        size_mb = 3.0,  bundled = false, lang = "es" },
    { id = "es3", name = "Spanish Female 1",      size_mb = 2.2,  bundled = false, lang = "es" },
    { id = "es4", name = "Spanish Female 2",      size_mb = 3.4,  bundled = false, lang = "es" },
    { id = "it1", name = "Italian Male 1",        size_mb = 6.0,  bundled = false, lang = "it" },
    { id = "it2", name = "Italian Female 1",      size_mb = 5.8,  bundled = false, lang = "it" },
    { id = "it3", name = "Italian Male 2",        size_mb = 6.2,  bundled = false, lang = "it" },
    { id = "it4", name = "Italian Female 2",      size_mb = 5.9,  bundled = false, lang = "it" },
    { id = "br1", name = "Brazilian Portuguese Male 1",   size_mb = 5.4, bundled = false, lang = "pt" },
    { id = "br2", name = "Brazilian Portuguese Female 1", size_mb = 5.4, bundled = false, lang = "pt" },
    { id = "br3", name = "Brazilian Portuguese Male 2",   size_mb = 9.8, bundled = false, lang = "pt" },
    { id = "nl1", name = "Dutch Male 1",          size_mb = 5.4,  bundled = false, lang = "nl" },
    { id = "nl2", name = "Dutch Female 1",        size_mb = 5.4,  bundled = false, lang = "nl" },
    { id = "nl3", name = "Dutch Male 2",          size_mb = 5.5,  bundled = false, lang = "nl" },
    { id = "pl1", name = "Polish Male 1",         size_mb = 5.4,  bundled = false, lang = "pl" },
    { id = "pl2", name = "Polish Female 1",       size_mb = 5.4,  bundled = false, lang = "pl" },
    { id = "cz1", name = "Czech Male 1",          size_mb = 2.7,  bundled = false, lang = "cs" },
    { id = "cz2", name = "Czech Female 1",        size_mb = 9.3,  bundled = false, lang = "cs" },
    { id = "gr1", name = "Greek Male 1",          size_mb = 3.1,  bundled = false, lang = "el" },
    { id = "gr2", name = "Greek Female 1",        size_mb = 3.3,  bundled = false, lang = "el" },
    { id = "jp1", name = "Japanese Male 1",       size_mb = 1.9,  bundled = false, lang = "ja" },
    { id = "jp2", name = "Japanese Female 1",     size_mb = 2.9,  bundled = false, lang = "ja" },
    { id = "jp3", name = "Japanese Female 2",     size_mb = 1.9,  bundled = false, lang = "ja" },
    { id = "ru1", name = "Russian Male 1",        size_mb = 5.4,  bundled = false, lang = "ru" },
    { id = "ar1", name = "Arabic Male 1",         size_mb = 6.3,  bundled = false, lang = "ar" },
    { id = "ar2", name = "Arabic Female 1",       size_mb = 6.3,  bundled = false, lang = "ar" },
    { id = "sv1", name = "Swedish Male 1",        size_mb = 5.4,  bundled = false, lang = "sv" },
    { id = "sv2", name = "Swedish Female 1",      size_mb = 5.4,  bundled = false, lang = "sv" },
    { id = "tr1", name = "Turkish Male 1",        size_mb = 5.4,  bundled = false, lang = "tr" },
    { id = "tr2", name = "Turkish Female 1",      size_mb = 5.4,  bundled = false, lang = "tr" },
}

Downloader.MBROLA_BASE_URL = "https://raw.githubusercontent.com/numediart/MBROLA-voices/master/data"

--[[--
Detect which download tool is available.
@return string|nil  "curl", "wget", or nil
--]]
function Downloader:_detectTool()
    local h = io.popen("which curl 2>/dev/null")
    if h then
        local r = h:read("*a"):gsub("%s+", "")
        h:close()
        if r ~= "" then return "curl" end
    end
    h = io.popen("which wget 2>/dev/null")
    if h then
        local r = h:read("*a"):gsub("%s+", "")
        h:close()
        if r ~= "" then
            -- BusyBox wget doesn't support -L (redirect following).
            -- Detect by checking whether --help mentions "location".
            local h2 = io.popen('wget --help 2>&1 | grep -q "location" && echo yes || echo no')
            if h2 then
                local r2 = h2:read("*a"):gsub("%s+", "")
                h2:close()
                if r2 == "yes" then
                    return "wget"
                else
                    return "wget-noredirect"
                end
            end
            return "wget"
        end
    end
    return nil
end

--[[--
Build a shell command to download a URL to a destination file.
@param url string
@param dest string  Absolute destination file path
@param tool string  "curl" or "wget"
@return string
--]]
function Downloader:_buildCmd(url, dest, tool)
    if tool == "curl" then
        -- -L follows redirects, -f fails silently on HTTP errors,
        -- --progress-bar gives visual feedback when run in foreground
        return string.format('curl -Lf -o "%s" "%s" 2>&1', dest, url)
    elseif tool == "wget" then
        -- GNU wget: follow redirects, resume, quiet
        return string.format('wget -q -c -L -O "%s" "%s" 2>&1', dest, url)
    else
        -- BusyBox wget: no redirect support, handled by _downloadWithSocket
        return string.format('wget -q -c -O "%s" "%s" 2>&1', dest, url)
    end
end

--[[--
Download a file using socket.http with manual redirect following.
Used as a fallback when only BusyBox wget is available (no -L support).
@param url string
@param dest string
@param on_complete function(success, err_msg)
--]]
function Downloader:_downloadWithSocket(url, dest, on_complete)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local MAX_REDIRECTS = 5

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_BLOCK_TIMEOUT)

    local current_url = url
    for i = 1, MAX_REDIRECTS do
        local f, err = io.open(dest, "wb")
        if not f then
            socketutil:reset_timeout()
            if on_complete then on_complete(false, _("Cannot open file for writing: ") .. tostring(err)) end
            return
        end

        -- ltn12.sink.file closes the file automatically on stream end,
        -- so we must not call f:close() ourselves. If http.request throws,
        -- the file stays open and we close it in the error path.
        -- socket.http.request returns (1, code, headers) on success; the leading 1
        -- is an internal flag. We use socket.skip(1, ...) to discard it, matching
        -- the pattern used in refreshVoiceList().
        local ok, code, headers = pcall(function()
            return require("socket").skip(1, http.request{
                url = current_url,
                method = "GET",
                sink = ltn12.sink.file(f),
            })
        end)
        if not ok then
            pcall(function() f:close() end)
            socketutil:reset_timeout()
            logger.err("Downloader: request failed:", code)
            os.remove(dest)
            if on_complete then on_complete(false, _("Download failed (network error).")) end
            return
        end

        if code == 200 then
            socketutil:reset_timeout()
            -- Validate file size (>1 KB) to catch empty/error-page responses
            local sf = io.open(dest, "rb")
            local fsize = 0
            if sf then
                sf:seek("end")
                fsize = sf:seek()
                sf:close()
            end
            if fsize < 1024 then
                logger.err("Downloader: file too small (", fsize, "bytes), likely an error page")
                os.remove(dest)
                if on_complete then on_complete(false, _("Downloaded file is too small (server error).")) end
                return
            end
            logger.warn("Downloader: finished", dest, "(", fsize, "bytes)")
            if on_complete then on_complete(true, nil) end
            return
        elseif code and code >= 300 and code < 400 and headers and headers.location then
            current_url = headers.location
            -- Resolve relative URLs
            if current_url:sub(1, 1) == "/" then
                local base = url:match("^(https?://[^/]+)")
                current_url = base .. current_url
            elseif not current_url:match("^https?://") then
                local base = url:match("^(https?://.+/)")
                current_url = base .. current_url
            end
            logger.dbg("Downloader: following redirect to", current_url)
        else
            socketutil:reset_timeout()
            logger.err("Downloader: HTTP error", code, "for", url)
            os.remove(dest)
            if on_complete then on_complete(false, _("Download failed (HTTP ") .. tostring(code or "?") .. ").") end
            return
        end
    end

    socketutil:reset_timeout()
    os.remove(dest)
    if on_complete then on_complete(false, _("Download failed: too many redirects.")) end
end

--[[--
Download a file with optional progress reporting.
@param url string
@param dest string  Absolute destination path
@param on_progress function(done_bytes, total_bytes) — optional
@param on_complete function(success, err_msg) — required
--]]
function Downloader:download(url, dest, on_progress, on_complete)
    local tool = self:_detectTool()
    if not tool then
        if on_complete then
            on_complete(false, _("No download tool found.\nInstall curl or wget on your device."))
        end
        return
    end

    -- Ensure destination directory exists
    local dir = dest:match("^(.+)/[^/]+$")
    if dir then
        os.execute(string.format('mkdir -p "%s"', dir))
    end

    -- BusyBox wget can't follow redirects; fall back to socket.http.
    if tool == "wget-noredirect" then
        logger.warn("Downloader: using socket.http for", url)
        -- Defer slightly so the UI can render any "Downloading…" dialog first.
        UIManager:scheduleIn(0.1, function()
            self:_downloadWithSocket(url, dest, on_complete)
        end)
        return
    end

    local cmd = self:_buildCmd(url, dest, tool)
    logger.warn("Downloader: starting download via", tool, ":", url)

    -- Launch in background so UI stays responsive
    local bg_cmd = string.format('(%s; echo $? > "%s.exit") &', cmd, dest)
    os.execute(bg_cmd)

    local start_time = UIManager:getTime()
    local last_size = 0
    local poll_count = 0

    local function poll()
        poll_count = poll_count + 1
        -- Check for completion marker
        local ef = io.open(dest .. ".exit", "r")
        if ef then
            local code = ef:read("*a"):gsub("%s+", "")
            ef:close()
            os.remove(dest .. ".exit")
            if code == "0" then
                logger.warn("Downloader: finished", dest)
                if on_complete then on_complete(true, nil) end
            else
                logger.err("Downloader: failed, exit code", code)
                os.remove(dest)
                if on_complete then
                    on_complete(false, _("Download failed (server or network error)."))
                end
            end
            return
        end

        -- Report progress via file size
        if on_progress then
            local sf = io.open(dest, "r")
            if sf then
                sf:seek("end")
                local size = sf:seek()
                sf:close()
                if size > last_size then
                    last_size = size
                    on_progress(size, nil)
                end
            end
        end

        -- Timeout after 10 minutes
        if time.to_ms(UIManager:getTime() - start_time) > 600000 then
            logger.err("Downloader: timed out after 10 min")
            os.execute(string.format('rm -f "%s" "%s.exit"', dest, dest))
            if on_complete then on_complete(false, _("Download timed out after 10 minutes.")) end
            return
        end

        UIManager:scheduleIn(1.0, poll)
    end

    UIManager:scheduleIn(1.0, poll)
end

--[[--
Extract a .tar.gz or .zip file to a destination directory.
@param archive string  Path to archive
@param dest_dir string  Destination directory
@param on_complete function(success, err_msg)
--]]
function Downloader:extract(archive, dest_dir, on_complete)
    os.execute(string.format('mkdir -p "%s"', dest_dir))

    local cmd
    if archive:match("%.tar%.gz$") or archive:match("%.tgz$") then
        cmd = string.format('tar xzf "%s" -C "%s" 2>&1', archive, dest_dir)
    elseif archive:match("%.zip$") then
        cmd = string.format('unzip -o "%s" -d "%s" 2>&1', archive, dest_dir)
    else
        if on_complete then
            on_complete(false, _("Unknown archive format."))
        end
        return
    end

    logger.warn("Downloader: extracting", archive, "to", dest_dir)
    local h = io.popen(cmd .. "; echo $?")
    if h then
        local out = h:read("*a") or ""
        h:close()
        local code = out:match("(%d+)%s*$") or "1"
        if code == "0" then
            os.remove(archive)
            if on_complete then on_complete(true, nil) end
        else
            logger.err("Downloader: extract failed:", out:sub(1, 200))
            if on_complete then
                on_complete(false, _("Extraction failed."))
            end
        end
    else
        if on_complete then on_complete(false, _("Could not run extractor.")) end
    end
end

--[[--
Download a Piper voice model (.onnx + .json).
@param voice_id string  e.g. "en_US-danny-low"
@param plugin_dir string
@param on_progress function(done_bytes, total_bytes)
@param on_complete function(success, err_msg)
--]]
function Downloader:downloadPiperVoice(voice_id, plugin_dir, on_progress, on_complete)
    local voice = nil
    for _, v in ipairs(self:getPiperVoiceList(plugin_dir)) do
        if v.id == voice_id then
            voice = v
            break
        end
    end
    if not voice then
        if on_complete then on_complete(false, _("Unknown voice.")) end
        return
    end

    local piper_dir = plugin_dir .. "/piper"
    os.execute(string.format('mkdir -p "%s"', piper_dir))

    local onnx_url = voice.url
    local json_url = voice.url .. ".json"
    local onnx_dest = piper_dir .. "/" .. voice_id .. ".onnx"
    local json_dest = piper_dir .. "/" .. voice_id .. ".onnx.json"

    -- Download ONNX model
    self:download(onnx_url, onnx_dest, on_progress, function(ok, err)
        if not ok then
            if on_complete then on_complete(false, err) end
            return
        end
        -- Download JSON config (small, synchronous is fine)
        local tool = self:_detectTool()
        if tool == "wget-noredirect" then
            self:_downloadWithSocket(json_url, json_dest, function(ok, err)
                if not ok then logger.warn("Downloader: JSON config failed:", err) end
            end)
        elseif tool then
            local cmd = self:_buildCmd(json_url, json_dest, tool)
            os.execute(cmd)
        end
        logger.warn("Downloader: Piper voice", voice_id, "installed")
        if on_complete then on_complete(true, nil) end
    end)
end

--[[--
Check whether a Piper voice model is installed.
@param voice_id string
@param plugin_dir string
@return boolean
--]]
function Downloader:hasPiperVoice(voice_id, plugin_dir)
    local f = io.open(plugin_dir .. "/piper/" .. voice_id .. ".onnx", "r")
    if f then f:close(); return true end
    return false
end

-- ── sanoTTS-jp (Japanese, bring-your-own-weights) ────────────────────
-- Pinned to the upstream v1.0.0 release: the weights are v4 (no JSUT
-- share-alike exposure) and the attribution files are complete there.
-- The plugin bundles none of this data; downloading activates the backend.
Downloader.SNTJP_RELEASE_BASE = "https://github.com/ayutaz/sanoTTS-jp/releases/download/v1.0.0"
Downloader.SNTJP_RAW_BASE = "https://raw.githubusercontent.com/ayutaz/sanoTTS-jp/v1.0.0"
Downloader.SNTJP_FILES = {
    weights = { dest = "saanotts-jp-v4-int8.bin", size = 654032,
                url = Downloader.SNTJP_RELEASE_BASE .. "/saanotts-jp-v4-int8.bin" },
    dict    = { dest = "k1-dict-438750.bin", size = 13702320,
                url = Downloader.SNTJP_RELEASE_BASE .. "/k1-dict-438750.bin" },
    license = { dest = "LICENSE-MODEL.md", size = nil,
                url = Downloader.SNTJP_RAW_BASE .. "/LICENSE-MODEL.md" },
    notice  = { dest = "NOTICE.md", size = nil,
                url = Downloader.SNTJP_RAW_BASE .. "/NOTICE.md" },
}

function Downloader:getSntJpDir(plugin_dir)
    local dir = plugin_dir .. "/sanotts-jp"
    os.execute(string.format('mkdir -p "%s"', dir))
    return dir
end

--- Installed check: exists AND exact expected size where the catalog has
-- one.  Byte size plus the driver's runtime SAAN/K1D1 magic checks are the
-- integrity gate (no checksum infrastructure exists in this plugin).
function Downloader:hasSntJpFile(id, plugin_dir)
    local entry = self.SNTJP_FILES[id]
    if not entry or not plugin_dir then return false end
    local f = io.open(self:getSntJpDir(plugin_dir) .. "/" .. entry.dest, "r")
    if not f then return false end
    local ok = true
    if entry.size then
        ok = f:seek("end") == entry.size
    end
    f:close()
    return ok
end

--- Both data files present and size-verified: the Japanese backend becomes
-- selectable.
function Downloader:hasSntJpVoice(plugin_dir)
    return self:hasSntJpFile("weights", plugin_dir)
        and self:hasSntJpFile("dict", plugin_dir)
end

--[[--
Download one sanoTTS-jp file.
@param id string  "weights" | "dict" | "license" | "notice"
@param plugin_dir string
@param on_progress function(done_bytes, total_bytes)
@param on_complete function(success, err_msg)
--]]
function Downloader:downloadSntJpFile(id, plugin_dir, on_progress, on_complete)
    local entry = self.SNTJP_FILES[id]
    if not entry or not plugin_dir then
        if on_complete then on_complete(false, _("Unknown file.")) end
        return
    end
    local dest = self:getSntJpDir(plugin_dir) .. "/" .. entry.dest
    self:download(entry.url, dest, on_progress, function(ok, err)
        if not ok then
            if on_complete then on_complete(false, err) end
            return
        end
        if entry.size then
            local f = io.open(dest, "r")
            local got = f and f:seek("end") or 0
            if f then f:close() end
            if got ~= entry.size then
                os.remove(dest)
                if on_complete then
                    on_complete(false, _("Downloaded file has the wrong size. Please retry."))
                end
                return
            end
        end
        if on_complete then on_complete(true, nil) end
    end)
end

-- ── Hybrid voice list (cached + online refresh) ──────────────────────
-- URL of the voices.json on the master branch (raw GitHub content).
Downloader.VOICES_JSON_URL = "https://raw.githubusercontent.com/stradichenko/audiobook.koplugin/master/voices.json"

--[[--
Return the effective Piper voice list.
1. If a cached voices.json exists in plugin_dir/piper/voices_cache.json,
   parse and return it.
2. Otherwise fall back to the built-in PIPER_VOICES table.
@return table  Array of voice entries {id, name, size_mb, url}
--]]
function Downloader:getPiperVoiceList(plugin_dir)
    local cache_path = plugin_dir .. "/piper/voices_cache.json"
    local cf = io.open(cache_path, "r")
    if cf then
        local content = cf:read("*a")
        cf:close()
        if content and #content > 0 then
            local JSON = require("json")
            local ok, voices = pcall(JSON.decode, content)
            if ok and type(voices) == "table" and #voices > 0 then
                logger.dbg("Downloader: using cached voice list (", #voices, "voices)")
                return voices
            else
                logger.warn("Downloader: cached voice list invalid, using built-in")
            end
        end
    end
    logger.dbg("Downloader: using built-in voice list (", #self.PIPER_VOICES, "voices)")
    return self.PIPER_VOICES
end

--[[--
Fetch the latest voice list from the internet and cache it locally.
@param plugin_dir string
@param callback function(success, voices_or_err_msg)
--]]
function Downloader:refreshVoiceList(plugin_dir, callback)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local JSON = require("json")

    local sink = {}
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_BLOCK_TIMEOUT)
    -- Append cache-busting timestamp so GitHub raw content serves the latest file
    local fetch_url = self.VOICES_JSON_URL .. "?cb=" .. os.time()
    local code, headers, status = require("socket").skip(1, http.request{
        url = fetch_url,
        method = "GET",
        headers = {
            ["User-Agent"] = "audiobook.koplugin-downloader",
        },
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()

    if code ~= 200 then
        logger.warn("Downloader: voice list fetch failed, code=", code, "status=", status)
        if callback then callback(false, T(_("Failed to fetch voice list (HTTP %1)"), tostring(code or status or "no response"))) end
        return
    end

    local body = table.concat(sink)
    local ok, voices = pcall(JSON.decode, body)
    if not ok or type(voices) ~= "table" or #voices == 0 then
        logger.warn("Downloader: voice list JSON parse failed:", tostring(voices))
        if callback then callback(false, _("Failed to parse voice list.")) end
        return
    end

    -- Cache the fetched list
    local piper_dir = plugin_dir .. "/piper"
    os.execute(string.format('mkdir -p "%s"', piper_dir))
    local cache_path = piper_dir .. "/voices_cache.json"
    local cf = io.open(cache_path, "w")
    if cf then
        cf:write(body)
        cf:close()
        logger.warn("Downloader: cached", #voices, "voices to", cache_path)
    else
        logger.warn("Downloader: could not write voice cache to", cache_path)
    end

    if callback then callback(true, voices) end
end

--[[--
Return the MBROLA voice database directory for a given plugin dir.
@param plugin_dir string
@return string
--]]
function Downloader:_mbrolaDir(plugin_dir)
    return plugin_dir .. "/espeak-ng/share/mbrola"
end

--[[--
Return the full list of MBROLA voices (bundled + downloadable).
@param plugin_dir string
@return table  Array of voice entries {id, name, size_mb, bundled, lang, installed}
--]]
function Downloader:getMbrolaVoiceList(plugin_dir)
    local list = {}
    for _, v in ipairs(self.MBROLA_VOICES) do
        local entry = {}
        for k, val in pairs(v) do entry[k] = val end
        entry.installed = self:hasMbrolaVoice(v.id, plugin_dir)
        table.insert(list, entry)
    end
    return list
end

--[[--
Check whether a specific MBROLA voice database is installed.
@param voice_id string  e.g. "us1"
@param plugin_dir string
@return boolean
--]]
function Downloader:hasMbrolaVoice(voice_id, plugin_dir)
    local path = self:_mbrolaDir(plugin_dir) .. "/" .. voice_id .. "/" .. voice_id
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

--[[--
Download a single MBROLA voice database file.
@param voice_id string  e.g. "us1"
@param plugin_dir string
@param on_progress function(done_bytes, total_bytes)
@param on_complete function(success, err_msg)
--]]
function Downloader:downloadMbrolaVoice(voice_id, plugin_dir, on_progress, on_complete)
    local voice = nil
    for _, v in ipairs(self.MBROLA_VOICES) do
        if v.id == voice_id then
            voice = v
            break
        end
    end
    if not voice then
        if on_complete then on_complete(false, _("Unknown MBROLA voice.")) end
        return
    end

    local mbrola_dir = self:_mbrolaDir(plugin_dir)
    local voice_subdir = mbrola_dir .. "/" .. voice_id
    os.execute(string.format('mkdir -p "%s"', voice_subdir))

    local url = self.MBROLA_BASE_URL .. "/" .. voice_id .. "/" .. voice_id
    local dest = voice_subdir .. "/" .. voice_id

    self:download(url, dest, on_progress, function(ok, err)
        if ok then
            logger.warn("Downloader: MBROLA voice", voice_id, "installed")
        else
            logger.err("Downloader: MBROLA voice", voice_id, "failed:", err)
        end
        if on_complete then on_complete(ok, err) end
    end)
end

return Downloader
