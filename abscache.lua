--[[--
Audiobookshelf Cache Manager
Manages the local cache of downloaded ABS content.
Stores a JSON index and provides methods to add, retrieve, and delete items.

@module abscache
--]]

local logger = require("logger")
local _ = require("audiobook_gettext")

local ABSCache = {}

function ABSCache:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self

    o.plugin_dir = o.plugin_dir or "."
    o.cache_dir = o.plugin_dir .. "/abs_cache"
    o.index_path = o.cache_dir .. "/index.json"

    -- Ensure cache directory exists
    os.execute(string.format('mkdir -p "%s"', o.cache_dir))

    -- Load existing index
    o:_loadIndex()

    return o
end

-- ---------------------------------------------------------------------------
-- Internal: index persistence
-- ---------------------------------------------------------------------------

function ABSCache:_loadIndex()
    local f = io.open(self.index_path, "r")
    if f then
        local content = f:read("*a")
        f:close()
        if content and content ~= "" then
            local JSON = require("json")
            local ok, data = pcall(JSON.decode, content)
            if ok and type(data) == "table" and data.items then
                self.index = data
                logger.dbg("ABSCache: loaded index with", self:count(), "items")
                return
            end
        end
    end
    -- Start fresh
    self.index = { items = {} }
end

function ABSCache:_saveIndex()
    local JSON = require("json")
    local ok, json_str = pcall(JSON.encode, self.index)
    if not ok then
        logger.err("ABSCache: failed to encode index:", json_str)
        return false
    end

    local f = io.open(self.index_path, "w")
    if f then
        f:write(json_str)
        f:close()
        return true
    else
        logger.err("ABSCache: failed to write index to", self.index_path)
        return false
    end
end

-- ---------------------------------------------------------------------------
-- Item management
-- ---------------------------------------------------------------------------

--[[--
Add or update a cached item.
@param item table  ABS item metadata {id, title, author, library_id, duration, chapters, ...}
@param audio_files table  Array of local file paths
@param cover_path string|nil  Local path to cover image
@return boolean
--]]
function ABSCache:addItem(item, audio_files, cover_path, audio_durations)
    if not item or not item.id then
        logger.err("ABSCache: addItem called without valid item")
        return false
    end

    local entry = {
        id = item.id,
        title = item.title or item.media and item.media.metadata and item.media.metadata.title or _("Unknown Title"),
        author = item.author or item.media and item.media.metadata and item.media.metadata.authorName or "",
        narrator = item.narrator or item.media and item.media.metadata and item.media.metadata.narratorName or "",
        library_id = item.libraryId or "",
        duration = item.duration or item.media and item.media.duration or 0,
        chapters = item.chapters or item.media and item.media.chapters or {},
        audio_files = audio_files or {},
        -- Per-file durations in seconds, positionally aligned with
        -- audio_files (nil where the server did not report one).  Used to
        -- map a global book position onto the right part file.
        audio_durations = audio_durations or {},
        cover_path = cover_path,
        downloaded_at = os.time(),
    }

    self.index.items[item.id] = entry
    self:_saveIndex()
    logger.warn("ABSCache: added item", item.id, entry.title)
    return true
end

--[[--
Get a cached item by ID.
@param item_id string
@return table|nil
--]]
function ABSCache:getItem(item_id)
    return self.index.items[item_id]
end

--[[--
Get the local audio file path(s) for an item.
@param item_id string
@return table|nil  Array of file paths, or nil if not cached
--]]
function ABSCache:getAudioPaths(item_id)
    local item = self.index.items[item_id]
    if item and item.audio_files and #item.audio_files > 0 then
        return item.audio_files
    end
    return nil
end

--[[--
Get the first audio file path (convenience for single-file items).
@param item_id string
@return string|nil
--]]
function ABSCache:getFirstAudioPath(item_id)
    local paths = self:getAudioPaths(item_id)
    if paths then
        return paths[1]
    end
    return nil
end

--[[--
Get the local cover image path for an item.
@param item_id string
@return string|nil
--]]
function ABSCache:getCoverPath(item_id)
    local item = self.index.items[item_id]
    if item and item.cover_path then
        return item.cover_path
    end
    return nil
end

--[[--
List all cached items.
@return table  Array of item entries
--]]
function ABSCache:listCachedItems()
    local list = {}
    for _, item in pairs(self.index.items) do
        table.insert(list, item)
    end
    -- Sort by download time, newest first
    table.sort(list, function(a, b)
        return (a.downloaded_at or 0) > (b.downloaded_at or 0)
    end)
    return list
end

--[[--
Check if an item is fully downloaded.
@param item_id string
@return boolean
--]]
function ABSCache:isDownloaded(item_id)
    local item = self.index.items[item_id]
    if not item or not item.audio_files or #item.audio_files == 0 then
        return false
    end
    -- Verify files actually exist on disk
    for _, path in ipairs(item.audio_files) do
        local f = io.open(path, "r")
        if not f then
            return false
        end
        f:close()
    end
    return true
end

--[[--
Delete a cached item (audio files, cover, and index entry).
@param item_id string
@return boolean
--]]
function ABSCache:deleteItem(item_id)
    local item = self.index.items[item_id]
    if not item then
        return false
    end

    -- Delete audio files
    if item.audio_files then
        for _, path in ipairs(item.audio_files) do
            os.remove(path)
            logger.dbg("ABSCache: removed", path)
        end
    end

    -- Delete cover
    if item.cover_path then
        os.remove(item.cover_path)
        logger.dbg("ABSCache: removed cover", item.cover_path)
    end

    -- Delete item directory if empty
    local item_dir = self.cache_dir .. "/" .. item_id
    os.execute(string.format('rm -rf "%s"', item_dir))

    -- Remove from index
    self.index.items[item_id] = nil
    self:_saveIndex()
    logger.warn("ABSCache: deleted item", item_id)
    return true
end

--[[--
Get the item-specific cache directory.
@param item_id string
@return string
--]]
function ABSCache:getItemCacheDir(item_id)
    local dir = self.cache_dir .. "/" .. item_id
    os.execute(string.format('mkdir -p "%s"', dir))
    return dir
end

--[[--
Get the audio subdirectory for an item.
@param item_id string
@return string
--]]
function ABSCache:getItemAudioDir(item_id)
    local dir = self.cache_dir .. "/" .. item_id .. "/audio"
    os.execute(string.format('mkdir -p "%s"', dir))
    return dir
end

--[[--
Count cached items.
@return number
--]]
function ABSCache:count()
    local n = 0
    for _ in pairs(self.index.items) do
        n = n + 1
    end
    return n
end

--[[--
Get total cache size in bytes.
@return number
--]]
function ABSCache:getTotalSize()
    local total = 0
    for _, item in pairs(self.index.items) do
        if item.audio_files then
            for _, path in ipairs(item.audio_files) do
                local f = io.open(path, "rb")
                if f then
                    f:seek("end")
                    total = total + f:seek()
                    f:close()
                end
            end
        end
        if item.cover_path then
            local f = io.open(item.cover_path, "rb")
            if f then
                f:seek("end")
                total = total + f:seek()
                f:close()
            end
        end
    end
    return total
end

--[[--
Format bytes as human-readable string.
@param bytes number
@return string
--]]
function ABSCache:formatSize(bytes)
    if bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.1f KB", bytes / 1024)
    elseif bytes < 1024 * 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    else
        return string.format("%.1f GB", bytes / (1024 * 1024 * 1024))
    end
end

--[[--
Evict oldest items to stay under a size limit.
@param max_bytes number
@return number  Bytes freed
--]]
function ABSCache:evictToSize(max_bytes)
    local current = self:getTotalSize()
    if current <= max_bytes then
        return 0
    end

    local to_free = current - max_bytes
    local freed = 0

    -- Sort by download time, oldest first
    local items = self:listCachedItems()
    -- Reverse: oldest first
    for i = 1, math.floor(#items / 2) do
        items[i], items[#items - i + 1] = items[#items - i + 1], items[i]
    end

    for _, item in ipairs(items) do
        if freed >= to_free then
            break
        end
        local item_size = 0
        if item.audio_files then
            for _, path in ipairs(item.audio_files) do
                local f = io.open(path, "rb")
                if f then
                    f:seek("end")
                    item_size = item_size + f:seek()
                    f:close()
                end
            end
        end
        self:deleteItem(item.id)
        freed = freed + item_size
    end

    return freed
end

return ABSCache
