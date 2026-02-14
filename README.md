# Audiobook Read-Along Plugin for KOReader

A Text-to-Speech plugin with synchronized word highlighting for KOReader e-readers.

## Features

- **Word Highlight Sync**: Each word is highlighted as it's spoken
- **Sentence Highlighting**: Optional sentence-level highlighting
- **Multiple TTS Engines**: Support for espeak, pico2wave, flite, festival, and Android TTS
- **Adjustable Speech Rate**: 0.5x to 2.0x speed control
- **Multiple Highlight Styles**: Background, underline, box, or invert
- **Auto-Advance**: Automatically moves to the next page when reading completes
- **Playback Controls**: Play, pause, stop, skip sentences

## Installation

1. Copy the entire `audiobook.koplugin` folder to your KOReader plugins directory:
   - **Linux**: `~/.config/koreader/plugins/`
   - **Kindle**: `koreader/plugins/`
   - **Kobo**: `.adds/koreader/plugins/`
   - **Android**: `/sdcard/koreader/plugins/`
   - **PocketBook**: `applications/koreader/plugins/`

2. **Restart KOReader completely** (close and reopen)

3. Open any book/document

## Requirements

### Linux/Desktop
One of the following TTS engines must be installed:
- **espeak-ng** (recommended): `sudo apt install espeak-ng`
- **pico2wave**: `sudo apt install libttspico-utils`
- **flite**: `sudo apt install flite`
- **festival**: `sudo apt install festival`

An audio player is also required:
- **aplay** (ALSA): Usually pre-installed
- **paplay** (PulseAudio): `sudo apt install pulseaudio-utils`
- **mpv**: `sudo apt install mpv`

### Android
Uses the built-in Android TTS system. Make sure a TTS engine is installed in your Android settings.

## Usage

### Method 1: Long-press a Word (Recommended)
1. Open a document in KOReader
2. **Long-press on any word** to open the dictionary popup
3. Tap **"🔊 Read aloud from here"** button (appears below "Add to vocabulary builder")
4. Reading starts from that sentence with synchronized word highlighting

### Method 2: From Tools Menu
1. Open a document in KOReader
2. Tap the top of the screen to show the menu bar
3. Go to **☰ (hamburger menu) → Tools → Audiobook Read-Along**
4. Select **"Start reading from current page"**

### Keyboard/Gesture Shortcuts
You can configure shortcuts in **Settings → Gesture Manager** or **Settings → Keyboard shortcuts**:
- **Toggle Read-Along**: Play/pause reading
- **Stop Read-Along**: Stop completely

### Settings

#### TTS Engine
Choose which TTS engine to use for speech synthesis.

#### Speech Rate
Adjust how fast the text is read:
- 0.5x - Half speed
- 1.0x - Normal speed
- 2.0x - Double speed

#### Highlight Style
- **Background**: Fills word background with color
- **Underline**: Draws line under the word
- **Box**: Draws border around the word
- **Invert**: Inverts the word colors

#### Auto-Advance Pages
When enabled, automatically turns to the next page and continues reading.

#### Highlight Words/Sentences
Toggle word-level and sentence-level highlighting independently.

## Architecture

```
audiobook.koplugin/
├── _meta.lua            # Plugin metadata
├── main.lua             # Main plugin entry point  
├── textparser.lua       # Text parsing and tokenization
├── ttsengine.lua        # TTS synthesis and playback
├── highlightmanager.lua # Visual highlighting
├── synccontroller.lua   # Coordination and timing
└── README.md            # This file
```

### Module Descriptions

- **main.lua**: Plugin initialization, menu integration, dictionary button hook, settings
- **textparser.lua**: Splits text into words and sentences, tracks positions
- **ttsengine.lua**: Handles TTS synthesis, timing generation, audio playback
- **highlightmanager.lua**: Manages visual highlighting on screen
- **synccontroller.lua**: Coordinates timing between audio and highlights

## How It Works

1. **Text Parsing**: When read-along starts, the current page text is parsed into words and sentences with character position tracking.

2. **TTS Synthesis**: The text is sent to the TTS engine which generates audio and timing metadata (or estimates timing based on syllable count).

3. **Synchronization**: During playback, the sync controller tracks elapsed time and matches it to word timing data.

4. **Highlighting**: The highlight manager uses text positions to draw highlights at the corresponding screen locations.

5. **Auto-Advance**: When the page is complete, the plugin can automatically advance and continue.

## Timing Estimation

When TTS engines don't provide word timing metadata, the plugin estimates timing:
- Syllables are counted using vowel patterns
- Each syllable is estimated at ~200ms base duration
- Adjusted by speech rate multiplier
- 50ms gap added between words

## Troubleshooting

### Plugin not showing in menu
1. **Check folder name**: Must be exactly `audiobook.koplugin` (with `.koplugin` extension)
2. **Check location**: Must be in the correct `plugins/` folder for your device
3. **Restart properly**: Close KOReader completely (not just minimize), then reopen
4. **Check permissions**: All files should be readable
5. **Open a document**: The plugin only appears when a document is open (`is_doc_only = true`)

To verify installation, check if the folder exists:
```bash
# Linux example
ls ~/.config/koreader/plugins/audiobook.koplugin/
# Should show: main.lua, _meta.lua, textparser.lua, etc.
```

### No "Read aloud" button in dictionary popup
- Make sure you're long-pressing a word (not selecting text)
- The button appears below "Add to vocabulary builder"
- If vocabulary builder is disabled, the button should still appear

### No audio playing
- Check that a TTS engine is installed
- Check that an audio player is available
- Try running TTS manually: `espeak-ng "test"`

### Highlights not visible
- E-ink screens may need a full refresh
- Try different highlight styles
- Check that "Highlight words" is enabled

### Timing seems off
- Estimated timing may not match exact speech
- Try adjusting speech rate
- Some TTS engines provide better timing than others

## Contributing

Contributions are welcome! Areas for improvement:
- Real word timing from TTS engines (SSML/callbacks)
- Better position mapping for different document types
- More TTS engine support
- Accessibility improvements

## License

This plugin is part of the KOReader project and is licensed under the AGPL-3.0 license.
