--[[--
Plugin metadata for KOReader.

@module _meta
--]]

local _ = require("gettext")

return {
    name = "audiobook",
    fullname = _("Audiobook Read-Along"),
    description = _([[Text-to-Speech with synchronized word highlighting.

Features:
• Word-by-word highlighting as text is read
• Sentence highlighting option
• Multiple TTS engine support (espeak, pico2wave, flite)
• Adjustable speech rate (0.5x to 2.0x)
• Auto-advance pages
• Multiple highlight styles (background, underline, box, invert)

Usage:
1. Long-press a word to open dictionary
2. Tap "🔊 Read aloud from here"
3. Or use Tools menu → Audiobook Read-Along]]),
}
