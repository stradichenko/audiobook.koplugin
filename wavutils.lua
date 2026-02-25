--[[--
WAV File Utilities
Provides functions for reading, writing, and manipulating WAV files.
Used by ttsengine and piperserver modules for audio file operations.

All functions assume standard PCM WAV format with a 44-byte header.
Piper and espeak-ng both produce this canonical layout.

@module wavutils
--]]

local logger = require("logger")

local WavUtils = {}

-- WAV header constants
WavUtils.HEADER_SIZE = 44
WavUtils.RIFF_SIZE_OFFSET = 4
WavUtils.BYTE_RATE_OFFSET = 28
WavUtils.BLOCK_ALIGN_OFFSET = 32
WavUtils.DATA_SIZE_OFFSET = 40

-- Default format (matches Piper / espeak-ng output)
WavUtils.DEFAULT_SAMPLE_RATE = 22050
WavUtils.DEFAULT_CHANNELS = 1
WavUtils.DEFAULT_BITS_PER_SAMPLE = 16

--- Encode a 32-bit integer in little-endian format.
-- @param n number  Integer to encode
-- @return string  4-byte LE string
function WavUtils.le32(n)
    return string.char(
        n % 256,
        math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 16777216) % 256
    )
end

--- Encode a 16-bit integer in little-endian format.
-- @param n number  Integer to encode
-- @return string  2-byte LE string
function WavUtils.le16(n)
    return string.char(n % 256, math.floor(n / 256) % 256)
end

--- Read a 32-bit LE integer from a raw 4-byte string.
-- @param raw string  4 bytes
-- @return number
function WavUtils.readLE32(raw)
    if not raw or #raw < 4 then return 0 end
    local b1, b2, b3, b4 = raw:byte(1, 4)
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

--- Read a 16-bit LE integer from a raw 2-byte string.
-- @param raw string  2 bytes
-- @return number
function WavUtils.readLE16(raw)
    if not raw or #raw < 2 then return 0 end
    local b1, b2 = raw:byte(1, 2)
    return b1 + b2 * 256
end

--- Read byte rate from a WAV file handle (file must be open).
-- @param f file  Open file handle
-- @return number  Byte rate (0 on error)
function WavUtils.readByteRate(f)
    f:seek("set", WavUtils.BYTE_RATE_OFFSET)
    local raw = f:read(4)
    return WavUtils.readLE32(raw)
end

--- Read block align from a WAV file handle.
-- @param f file  Open file handle
-- @return number  Block align (defaults to 2 on error)
function WavUtils.readBlockAlign(f)
    f:seek("set", WavUtils.BLOCK_ALIGN_OFFSET)
    local raw = f:read(2)
    local val = WavUtils.readLE16(raw)
    return val > 0 and val or 2
end

--- Update RIFF and data chunk headers for a WAV file.
-- Must be called after appending data to keep the file valid.
-- @param f file  Open file handle (r+b)
function WavUtils.updateHeaders(f)
    local file_size = f:seek("end")
    f:seek("set", WavUtils.RIFF_SIZE_OFFSET)
    f:write(WavUtils.le32(file_size - 8))
    f:seek("set", WavUtils.DATA_SIZE_OFFSET)
    f:write(WavUtils.le32(file_size - WavUtils.HEADER_SIZE))
end

--[[--
Get file size in bytes.
@param path string  File path
@return number|nil  Size in bytes, or nil on error
--]]
function WavUtils.getFileSize(path)
    local file = io.open(path, "rb")
    if file then
        local size = file:seek("end")
        file:close()
        return size
    end
    return nil
end

--[[--
Get WAV duration from a file path.
@param path string  WAV file path
@return number  Duration in ms, 0 on error
--]]
function WavUtils.getDurationMs(path)
    if not path then return 0 end
    local f = io.open(path, "rb")
    if not f then return 0 end
    local size = f:seek("end")
    local byte_rate = WavUtils.readByteRate(f)
    f:close()
    if byte_rate <= 0 then return 0 end
    local data_bytes = size - WavUtils.HEADER_SIZE
    if data_bytes <= 0 then return 0 end
    return math.floor((data_bytes / byte_rate) * 1000)
end

--[[--
Append silence (zero samples) to the end of an existing WAV file.
Reads byte rate and block align from the header for format-accurate padding.
Updates RIFF/data chunk sizes after appending.

@param path string  WAV file path
@param duration_ms number  Silence duration in milliseconds
@return boolean  true on success
--]]
function WavUtils.appendSilence(path, duration_ms)
    if not path or not duration_ms or duration_ms <= 0 then return false end

    local f = io.open(path, "r+b")
    if not f then return false end

    local byte_rate = WavUtils.readByteRate(f)
    if byte_rate <= 0 then f:close(); return false end

    local block_align = WavUtils.readBlockAlign(f)

    -- Calculate silence bytes (aligned to block_align)
    local silence_bytes = math.floor(byte_rate * (duration_ms / 1000))
    silence_bytes = silence_bytes - (silence_bytes % block_align)
    if silence_bytes <= 0 then f:close(); return false end

    -- Append zero bytes
    f:seek("end")
    local chunk_size = 8192
    local chunk = string.rep("\0", chunk_size)
    local written = 0
    while written < silence_bytes do
        local to_write = math.min(chunk_size, silence_bytes - written)
        if to_write < chunk_size then
            f:write(chunk:sub(1, to_write))
        else
            f:write(chunk)
        end
        written = written + to_write
    end

    WavUtils.updateHeaders(f)
    f:close()

    logger.dbg("WavUtils: Appended", duration_ms, "ms silence to", path,
        "(", silence_bytes, "bytes)")
    return true
end

--[[--
Apply a short linear fade-in at the start and fade-out at the end of a
WAV file.  This eliminates click/pop artifacts caused by PCM
discontinuities when the persistent pipeline switches between silence
and speech data.

The fade length is typically 10-20 ms — short enough to be
imperceptible as a volume change, long enough to smooth any DC-offset
jump at the boundary.

Operates in-place (reads, modifies, writes back the affected samples).
Assumes mono or interleaved 16-bit signed PCM after a 44-byte header.

@param path string  WAV file path
@param fade_ms number  Fade duration in milliseconds (applied to both ends)
@return boolean  true on success
--]]
function WavUtils.applyFade(path, fade_ms)
    if not path or not fade_ms or fade_ms <= 0 then return false end

    local f = io.open(path, "r+b")
    if not f then return false end

    local byte_rate = WavUtils.readByteRate(f)
    local block_align = WavUtils.readBlockAlign(f)
    if byte_rate <= 0 or block_align <= 0 then f:close(); return false end

    -- Read data size from header
    f:seek("set", WavUtils.DATA_SIZE_OFFSET)
    local raw = f:read(4)
    local data_size = WavUtils.readLE32(raw)
    if data_size <= 0 then f:close(); return false end

    -- Fade length in bytes, aligned to block_align
    local fade_bytes = math.floor(byte_rate * (fade_ms / 1000))
    fade_bytes = fade_bytes - (fade_bytes % block_align)
    -- Ensure we don't overlap (fade_in + fade_out must fit in data)
    if fade_bytes * 2 > data_size then
        fade_bytes = math.floor(data_size / 2)
        fade_bytes = fade_bytes - (fade_bytes % block_align)
    end
    if fade_bytes <= 0 then f:close(); return true end  -- nothing to do

    local num_samples = fade_bytes / 2  -- 16-bit = 2 bytes per sample

    -- ── Fade-in (first fade_bytes) ──────────────────────────────
    f:seek("set", WavUtils.HEADER_SIZE)
    local chunk = f:read(fade_bytes)
    if not chunk or #chunk < fade_bytes then f:close(); return false end

    local out = {}
    for i = 0, num_samples - 1 do
        local off = i * 2 + 1
        local b1, b2 = chunk:byte(off, off + 1)
        local sample = b1 + b2 * 256
        if sample >= 32768 then sample = sample - 65536 end
        sample = math.floor(sample * (i / num_samples))
        if sample < 0 then sample = sample + 65536 end
        out[i + 1] = string.char(sample % 256, math.floor(sample / 256) % 256)
    end
    f:seek("set", WavUtils.HEADER_SIZE)
    f:write(table.concat(out))

    -- ── Fade-out (last fade_bytes) ──────────────────────────────
    local fo_start = WavUtils.HEADER_SIZE + data_size - fade_bytes
    f:seek("set", fo_start)
    chunk = f:read(fade_bytes)
    if not chunk or #chunk < fade_bytes then f:close(); return false end

    out = {}
    for i = 0, num_samples - 1 do
        local off = i * 2 + 1
        local b1, b2 = chunk:byte(off, off + 1)
        local sample = b1 + b2 * 256
        if sample >= 32768 then sample = sample - 65536 end
        sample = math.floor(sample * (1.0 - i / num_samples))
        if sample < 0 then sample = sample + 65536 end
        out[i + 1] = string.char(sample % 256, math.floor(sample / 256) % 256)
    end
    f:seek("set", fo_start)
    f:write(table.concat(out))

    f:close()
    return true
end

--[[--
Merge multiple WAV files into a main file by appending raw PCM data.
All files must share the same sample format/rate/channels.
Updates the main file's RIFF/data headers after merging.

@param main_file string  Path to the destination WAV file
@param concat_files table  Array of {file=path, duration_ms=number}
@return boolean  true if data was appended
--]]
function WavUtils.mergeFiles(main_file, concat_files)
    if not main_file or not concat_files or #concat_files == 0 then
        return false
    end

    local f = io.open(main_file, "r+b")
    if not f then return false end

    local total_appended = 0
    for _, cf in ipairs(concat_files) do
        local src = io.open(cf.file, "rb")
        if src then
            src:seek("set", WavUtils.HEADER_SIZE)
            local data = src:read("*a")
            src:close()
            if data and #data > 0 then
                f:seek("end")
                f:write(data)
                total_appended = total_appended + #data
            end
        end
    end

    if total_appended > 0 then
        WavUtils.updateHeaders(f)
    end

    f:close()
    logger.warn("WavUtils: Merged", #concat_files, "files, appended",
        total_appended, "bytes")
    return total_appended > 0
end

--[[--
Generate a WAV file containing silence of the given duration.
Format: 22050 Hz, mono, 16-bit PCM (matches Piper/espeak-ng output).

@param path string  Output file path
@param duration_ms number  Duration in milliseconds
@return boolean  true on success
--]]
function WavUtils.generateSilence(path, duration_ms)
    if not path or not duration_ms or duration_ms <= 0 then return false end

    local sr = WavUtils.DEFAULT_SAMPLE_RATE
    local ch = WavUtils.DEFAULT_CHANNELS
    local bps = WavUtils.DEFAULT_BITS_PER_SAMPLE
    local num_samples = math.floor(sr * (duration_ms / 1000))
    local data_size = num_samples * ch * (bps / 8)
    local file_size = 36 + data_size
    local byte_rate = sr * ch * (bps / 8)
    local block_align = ch * (bps / 8)

    local header = "RIFF" .. WavUtils.le32(file_size) .. "WAVE"
                 .. "fmt " .. WavUtils.le32(16)
                 .. WavUtils.le16(1)           -- PCM
                 .. WavUtils.le16(ch)
                 .. WavUtils.le32(sr)
                 .. WavUtils.le32(byte_rate)
                 .. WavUtils.le16(block_align)
                 .. WavUtils.le16(bps)
                 .. "data" .. WavUtils.le32(data_size)

    local f = io.open(path, "wb")
    if not f then return false end
    f:write(header)

    local chunk = string.rep("\0", math.min(data_size, 8192))
    local written = 0
    while written < data_size do
        local to_write = math.min(#chunk, data_size - written)
        f:write(chunk:sub(1, to_write))
        written = written + to_write
    end
    f:close()
    return true
end

--[[--
Split a WAV file into multiple segments at estimated time boundaries.

Given a combined WAV file and estimated per-segment durations, splits
the PCM data at the proportional byte offsets and writes individual
WAV files.  The split is aligned to block_align boundaries to avoid
audio artifacts.

@param source_path string        Path to the combined WAV file
@param segment_durations table   Array of estimated durations in ms
                                 (one per segment, must sum to ~total duration)
@param output_paths table        Array of output file paths (same length)
@return boolean  true if all segments written successfully
--]]
function WavUtils.splitFile(source_path, segment_durations, output_paths)
    if #segment_durations ~= #output_paths then
        logger.err("WavUtils: splitFile: mismatched durations/paths count")
        return false
    end

    local f = io.open(source_path, "rb")
    if not f then
        logger.err("WavUtils: splitFile: cannot open", source_path)
        return false
    end

    local header = f:read(WavUtils.HEADER_SIZE)
    if not header or #header < WavUtils.HEADER_SIZE then
        f:close()
        return false
    end

    -- Read format from header
    local byte_rate = WavUtils.readLE32(header:sub(
        WavUtils.BYTE_RATE_OFFSET + 1, WavUtils.BYTE_RATE_OFFSET + 4))
    local block_align = WavUtils.readLE16(header:sub(
        WavUtils.BLOCK_ALIGN_OFFSET + 1, WavUtils.BLOCK_ALIGN_OFFSET + 2))
    local total_data_size = WavUtils.readLE32(header:sub(
        WavUtils.DATA_SIZE_OFFSET + 1, WavUtils.DATA_SIZE_OFFSET + 4))

    if byte_rate == 0 or block_align == 0 then
        f:close()
        logger.err("WavUtils: splitFile: invalid WAV header")
        return false
    end

    -- Calculate split byte offsets from durations
    local total_est_ms = 0
    for _, d in ipairs(segment_durations) do total_est_ms = total_est_ms + d end
    if total_est_ms == 0 then
        f:close()
        return false
    end

    local offsets = {}  -- byte offset for each segment start
    local cumulative_ms = 0
    for i, dur in ipairs(segment_durations) do
        local start_byte
        if i == 1 then
            start_byte = 0
        else
            -- Proportional position in the PCM data
            local byte_pos = math.floor(total_data_size * cumulative_ms / total_est_ms)
            -- Align to block boundary
            start_byte = byte_pos - (byte_pos % block_align)
        end
        table.insert(offsets, start_byte)
        cumulative_ms = cumulative_ms + dur
    end

    -- Write each segment
    local all_ok = true
    for i = 1, #output_paths do
        local seg_start = offsets[i]
        local seg_end = (i < #offsets) and offsets[i + 1] or total_data_size
        local seg_size = seg_end - seg_start

        if seg_size <= 0 then
            -- Degenerate segment — write minimal silence
            WavUtils.generateSilence(output_paths[i], 100)
        else
            local of = io.open(output_paths[i], "wb")
            if not of then
                logger.err("WavUtils: splitFile: cannot create", output_paths[i])
                all_ok = false
            else
                -- Write WAV header for this segment
                local seg_header = header:sub(1, WavUtils.RIFF_SIZE_OFFSET)
                    .. WavUtils.le32(seg_size + 36)
                    .. header:sub(WavUtils.RIFF_SIZE_OFFSET + 5, WavUtils.DATA_SIZE_OFFSET)
                    .. WavUtils.le32(seg_size)
                of:write(seg_header)

                -- Copy PCM data
                f:seek("set", WavUtils.HEADER_SIZE + seg_start)
                local chunk_sz = 8192
                local remaining = seg_size
                while remaining > 0 do
                    local to_read = math.min(chunk_sz, remaining)
                    local data = f:read(to_read)
                    if not data or #data == 0 then break end
                    of:write(data)
                    remaining = remaining - #data
                end
                of:close()
            end
        end
    end

    f:close()
    logger.warn("WavUtils: Split", source_path, "into", #output_paths, "segments")
    return all_ok
end

return WavUtils
