# Audiobook Read-Along Plugin for KOReader

A Text-to-Speech plugin with synchronized word highlighting for KOReader e-readers.

## Features

- **Word Highlight Sync**: Each word is highlighted as it's spoken, moving through the text
- **Sentence Highlighting**: Optional sentence-level highlighting
- **Playback Control Bar**: Bottom control bar with:
  - ⏮ Rewind (previous paragraph/sentence)
  - ⏸/▶ Play/Pause toggle
  - ⏭ Forward (next paragraph/sentence)
  - ✕ Close/Stop reading
  - Progress bar showing reading position
  - Current word display
- **Multiple TTS Engines**: Support for espeak, pico2wave, flite, festival, and Android TTS
- **Adjustable Speech Rate**: 0.5x to 2.0x speed control
- **Multiple Highlight Styles**: Background, underline, box, or invert
- **Auto-Advance**: Automatically moves to the next page when reading completes

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


### Kobo (with USB-C headphones or Bluetooth)

**IMPORTANT:** Kobo devices do not come with a TTS (text-to-speech) engine. You need to install **espeak-ng** once before this plugin will work. No coding experience is needed — just follow the steps below carefully.

---

#### Step 1: Install the Plugin via USB

This is the easiest part. You don't need Wi-Fi or SSH for this.

1. **Connect your Kobo to your computer** using the USB cable.
2. Your Kobo will appear as a USB drive on your computer.
3. Navigate to the hidden `.adds/koreader/plugins/` folder.
   - **On Windows:** You may need to enable "Show hidden files" in File Explorer (View → Show → Hidden items).
   - **On Mac:** Press `Cmd + Shift + .` in Finder to show hidden folders.
   - **On Linux:** Press `Ctrl + H` in your file manager.
4. Copy the entire `audiobook.koplugin` folder into that `plugins/` folder.
5. Eject the Kobo safely and unplug it.

---

#### Step 2: Connect to Your Kobo (to install espeak-ng)

You have **two options** — pick whichever is easier for you:

##### Option A: Use KOReader's Built-in Terminal (easiest — no computer needed)

KOReader has a terminal emulator that lets you type commands directly on your Kobo.

1. Open KOReader on your Kobo.
2. Tap the top of the screen to open the menu bar.
3. Go to **☰ (hamburger menu) → More tools → Terminal emulator**.
4. A text input will appear where you can type commands.
5. Continue to **Step 3** below and type the commands there.

##### Option B: Connect via SSH from Your Computer

KOReader has a **built-in SSH server** — you do NOT need `devmodeon` or developer mode.

1. On your Kobo, open **KOReader**.
2. Make sure **Wi-Fi is on** and connected to your home network.
3. Tap the top of the screen → **☰ (hamburger menu) → Network → SSH server**.
4. Check **"Login without password (DANGEROUS)"** (you can disable this later).
5. Check **"SSH server"** to start it.
6. A popup will show your Kobo's **IP address** (e.g., `192.168.1.14`).

Now, on your computer:

- **Windows:** Download and open [PuTTY](https://www.putty.org/). Enter the IP address, set port to **2222**, and click Open.
- **Mac/Linux:** Open a terminal and type:

```bash
ssh root@192.168.1.14 -p 2222
```

> ⚠️ **The port is 2222, not 22!** This is the most common mistake.

The password is **root**. If asked about authenticity, type `yes` and press Enter.

---

#### Step 3: Check What's Already Installed

Once you're connected (via Terminal emulator or SSH), type these commands one at a time:

```bash
which espeak-ng
```

```bash
which aplay
```

- If either command shows a path (like `/usr/bin/espeak-ng`), that tool is already installed.
- If it says `not found` or shows nothing, you need to install it.

---

#### Step 4: Install espeak-ng

**Try the package manager first:**

```bash
opkg update
opkg install espeak-ng
```

If `opkg` is not found, try:

```bash
pkm install espeak-ng
```

If neither works, you'll need to download espeak-ng manually:

1. On your computer, visit: https://github.com/nickel-packages/packages
2. Download the espeak-ng `.ipk` file for your Kobo's architecture (usually ARM).
3. Connect your Kobo via USB and copy the `.ipk` file to the root of your Kobo's storage.
4. Then via SSH or Terminal emulator:

```bash
opkg install /mnt/onboard/espeak-ng*.ipk
```

---

#### Step 5: Test That It Works

Plug in your headphones, then type:

```bash
espeak-ng "hello" -w /tmp/test.wav
aplay /tmp/test.wav
```

- If you hear "hello" through your headphones — **you're all set!** 🎉
- If you hear nothing, see Troubleshooting below.

---

#### Troubleshooting

| Problem | Solution |
|---------|----------|
| `espeak-ng: command not found` | espeak-ng is not installed. Repeat Step 4. |
| `aplay: command not found` | Try: `opkg install alsa-utils` |
| No sound through headphones | Make sure headphones are plugged in **before** running the command. Try `aplay -l` to list audio devices. |
| `ssh: Connection refused` on port 22 | Use port **2222** instead: `ssh root@IP -p 2222` |
| SSH server not showing in menu | Make sure you are in **KOReader** (not Kobo's default reader). Go to ☰ → Network → SSH server. |
| Can't find `.adds` folder via USB | Enable "show hidden files" on your computer. The folder starts with a dot. |

**Need more help?**

- [KOReader SSH Wiki](https://github.com/koreader/koreader/wiki/SSH)
- [KOReader Community Forum](https://www.mobileread.com/forums/forumdisplay.php?f=276)

---

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
3. Tap **"🔊 Read aloud from here"** button (appears below Wikipedia/Search/Close)
4. Reading starts from that sentence with synchronized word highlighting
5. **Playback control bar** appears at the bottom of the screen

### Playback Controls
When reading is active, a control bar appears at the bottom:
- **⏮ Rewind**: Jump to previous sentence/paragraph (hold for 3x)
- **⏸ Pause / ▶ Play**: Toggle playback
- **⏭ Forward**: Jump to next sentence/paragraph (hold for 3x)
- **✕ Close**: Stop reading and close the control bar

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
- **Invert**: Inverts the word colors (best for e-ink)

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
├── highlightmanager.lua # Visual highlighting (moving word highlight)
├── playbackbar.lua      # Bottom playback control bar widget
├── synccontroller.lua   # Coordination, timing, and playback state
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

### Nothing happens after "Starting read-along..."
This usually means TTS synthesis failed:
1. **Check for error messages** - The plugin should show what's missing
2. **Verify TTS is installed**:
   ```bash
   which espeak-ng   # Should show a path
   espeak-ng "hello" -w /tmp/test.wav  # Should create file
   ls -la /tmp/test.wav  # Should show file size > 0
   ```
3. **Verify audio player**:
   ```bash
   which aplay   # Should show a path
   aplay /tmp/test.wav  # Should play audio
   ```

### "No TTS engine found" error
You need to install espeak-ng on your device. See Requirements section above.

### "No audio player found" error
The plugin needs `aplay`, `paplay`, or `mpv` to play audio files.
- On Kobo: `aplay` is usually available
- Make sure headphones are connected before starting

### No "Read aloud" button in dictionary popup
- Make sure you're long-pressing a word (not selecting text)
- The button appears below Wikipedia/Search/Close
- Restart KOReader after installing the plugin

### No audio with USB-C headphones
- Some USB-C audio adapters need special configuration
- Try playing audio with `aplay /tmp/test.wav` via SSH first
- Check ALSA device list: `aplay -l`

### Playback control bar doesn't appear
- The bar should appear at the bottom when reading starts
- If synthesis fails, the bar won't show
- Check KOReader logs for errors

### Highlights not visible
- E-ink screens may need a full refresh
- Try different highlight styles (Invert works best on e-ink)
- Check that "Highlight words" is enabled in settings

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
