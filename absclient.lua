--[[--
Audiobookshelf REST API Client
Wraps the ABS API using socket.http + ltn12.
Follows the HTTP patterns from downloader.lua and updater.lua.

@module absclient
--]]

local logger = require("logger")
local _ = require("audiobook_gettext")

local ABSClient = {}

function ABSClient:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self

    -- Normalize server URL: strip trailing slash
    if o.server_url then
        o.server_url = o.server_url:gsub("/+$", "")
    end

    o.token = o.token or ""
    o.user_id = o.user_id or ""

    return o
end

-- ---------------------------------------------------------------------------
-- Internal: generic authenticated request
-- ---------------------------------------------------------------------------

--[[--
Perform an HTTP request to the ABS server.
@param endpoint string  API endpoint (e.g. "/api/libraries")
@param method string    HTTP method (default "GET")
@param body table       Lua table to JSON-encode as request body (optional)
@return table|nil, string|nil  response_data, error_message
--]]
function ABSClient:_request(endpoint, method, body)
    method = method or "GET"

    if not self.server_url or self.server_url == "" then
        return nil, _("No Audiobookshelf server configured.")
    end

    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local JSON = require("json")

    local url = self.server_url .. endpoint
    local sink = {}
    local headers = {
        ["Content-Type"] = "application/json",
        ["User-Agent"] = "audiobook.koplugin-absclient",
    }

    -- Add Bearer token if available
    if self.token and self.token ~= "" then
        headers["Authorization"] = "Bearer " .. self.token
    end

    local request_body = nil
    if body then
        local ok, json_body = pcall(JSON.encode, body)
        if ok then
            request_body = json_body
            headers["Content-Length"] = tostring(#request_body)
        else
            return nil, _("Failed to encode request body.")
        end
    end

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_BLOCK_TIMEOUT)

    local code, response_headers, status = require("socket").skip(1, http.request{
        url = url,
        method = method,
        headers = headers,
        source = request_body and ltn12.source.string(request_body) or nil,
        sink = ltn12.sink.table(sink),
        redirect = false,  -- handle manually to preserve auth headers
    })

    socketutil:reset_timeout()

    -- If the request failed, code is a string error message (not a number).
    -- Guard here before any numeric comparisons.
    if code and type(code) ~= "number" then
        return nil, _("Network error: ") .. tostring(code)
    end

    -- Handle redirects manually (socket.http drops headers on redirect)
    if code and code >= 300 and code < 400 and response_headers and response_headers.location then
        local redirect_url = response_headers.location
        -- Resolve relative redirects
        if redirect_url:sub(1, 1) == "/" then
            local base = self.server_url:match("^(https?://[^/]+)")
            redirect_url = base .. redirect_url
        elseif not redirect_url:match("^https?://") then
            local base = self.server_url:match("^(https?://.+/)") or (self.server_url .. "/")
            redirect_url = base .. redirect_url
        end

        sink = {}
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_BLOCK_TIMEOUT)
        code, response_headers, status = require("socket").skip(1, http.request{
            url = redirect_url,
            method = method,
            headers = headers,
            source = request_body and ltn12.source.string(request_body) or nil,
            sink = ltn12.sink.table(sink),
        })
        socketutil:reset_timeout()
    end

    if not code then
        return nil, _("Network error: no response from server.")
    end

    if type(code) ~= "number" then
        return nil, _("Network error: ") .. tostring(code)
    end

    if code == 401 then
        return nil, _("Authentication failed. Please log in again.")
    end

    if code == 404 then
        return nil, _("Not found (HTTP 404).")
    end

    if code >= 400 then
        return nil, _("HTTP error: ") .. tostring(code) .. " " .. tostring(status or "")
    end

    if code ~= 200 then
        return nil, _("Unexpected HTTP response: ") .. tostring(code)
    end

    local response_body = table.concat(sink)
    if not response_body or response_body == "" then
        return {}, nil
    end

    -- Try JSON decode; fall back to raw body wrapper for plain-text responses
    -- like "OK" from /api/session/local.
    local ok, data = pcall(JSON.decode, response_body)
    if ok then
        return data, nil
    elseif response_body:match("^%s*[%[{]") then
        -- Looks like JSON but failed to parse → real error
        return nil, _("Failed to parse server response.")
    else
        -- Plain text response (e.g., "OK")
        return {raw = response_body}, nil
    end
end

-- ---------------------------------------------------------------------------
-- Authentication
-- ---------------------------------------------------------------------------

--[[--
Log in to the ABS server.
@param username string
@param password string
@return string|nil, table|nil, string|nil  token, user, error_message
--]]
function ABSClient:login(username, password)
    if not username or username == "" or not password or password == "" then
        return nil, nil, _("Username and password are required.")
    end

    local data, err = self:_request("/login", "POST", {
        username = username,
        password = password,
    })

    if not data then
        return nil, nil, err
    end

    if data.error then
        return nil, nil, data.error
    end

    local token = data.token or data.user and data.user.token
    if not token then
        return nil, nil, _("Login succeeded but no token was returned.")
    end

    self.token = token
    self.user_id = data.user and data.user.id or ""

    return token, data.user, nil
end

-- ---------------------------------------------------------------------------
-- Libraries
-- ---------------------------------------------------------------------------

--[[--
Get all accessible libraries.
@return table|nil, string|nil  libraries_array, error_message
--]]
function ABSClient:getLibraries()
    local data, err = self:_request("/api/libraries")
    if not data then
        return nil, err
    end
    if type(data.libraries) == "table" then
        return data.libraries, nil
    end
    -- Some ABS versions return the array directly
    if type(data) == "table" and #data > 0 then
        return data, nil
    end
    return {}, nil
end

-- ---------------------------------------------------------------------------
-- Items
-- ---------------------------------------------------------------------------

--[[--
Get items in a library.
@param library_id string
@param limit number  (default 20)
@param page number   (default 0)
@return table|nil, string|nil  {results, total}, error_message
--]]
function ABSClient:getLibraryItems(library_id, limit, page)
    limit = limit or 20
    page = page or 0
    local endpoint = string.format("/api/libraries/%s/items?limit=%d&page=%d&sort=media.metadata.title", library_id, limit, page)
    local data, err = self:_request(endpoint)
    if not data then
        return nil, err
    end
    return data, nil
end

--[[--
Fetch every item in a library in a single request (minified payloads).

Used for client-side search.  The server's GET /api/libraries/{id}/search
endpoint is a quick-search capped at 12 relevance-ordered matches with no
offset, which silently truncated large libraries (issue #65); the items
endpoint accepts an arbitrarily large limit and returns every title,
so the plugin fetches the whole list once and filters locally.

@param library_id string
@param max_items number  safety cap for enormous libraries (default 10000)
@return table|nil, string|nil  {results, total}, error_message
--]]
function ABSClient:getAllLibraryItems(library_id, max_items)
    max_items = max_items or 10000
    local endpoint = string.format(
        "/api/libraries/%s/items?limit=%d&page=0&sort=media.metadata.title&minified=1",
        library_id, max_items)
    local data, err = self:_request(endpoint)
    if not data then
        return nil, err
    end
    return data, nil
end

--[[--
Get detailed item information.
@param item_id string
@return table|nil, string|nil  item_details, error_message
--]]
function ABSClient:getItemDetails(item_id)
    local data, err = self:_request("/api/items/" .. item_id .. "?expanded=1")
    if not data then
        return nil, err
    end
    return data, nil
end

--[[--
Get the full URL for an item's cover image.
@param item_id string
@return string
--]]
function ABSClient:getCoverUrl(item_id)
    return self.server_url .. "/api/items/" .. item_id .. "/cover"
end

-- ---------------------------------------------------------------------------
-- Progress
-- ---------------------------------------------------------------------------

--[[--
Get playback progress for a specific item.
@param item_id string
@return table|nil, string|nil  progress, error_message
--]]
function ABSClient:getProgress(item_id)
    local data, err = self:_request("/api/me/progress/" .. item_id)
    if not data then
        return nil, err
    end
    return data, nil
end

--[[--
Update playback progress for an item.
Uses POST /api/session/local which is the correct endpoint for v2.35.1+.
@param item_id string
@param current_time number  Current position in seconds
@param duration number      Total duration in seconds
@param is_finished boolean  Whether playback is complete
@return boolean, string|nil  success, error_message
--]]
function ABSClient:updateProgress(item_id, current_time, duration, is_finished)
    current_time = current_time or 0
    duration = duration or 0

    local body = {
        libraryItemId = item_id,
        currentTime = current_time,
        duration = duration,
        isFinished = is_finished or false,
        timeListened = 0,  -- server calculates this from sessions
    }

    local data, err = self:_request("/api/session/local", "POST", body)
    if not data then
        return false, err
    end
    return true, nil
end

--[[--
Batch update progress for multiple items.
Uses POST /api/session/local-all for efficient bulk sync.
@param updates table  Array of {libraryItemId, currentTime, duration, isFinished}
@return boolean, string|nil  success, error_message
--]]
function ABSClient:batchSyncProgress(updates)
    if not updates or #updates == 0 then
        return true, nil
    end

    local sessions = {}
    for _, u in ipairs(updates) do
        table.insert(sessions, {
            libraryItemId = u.libraryItemId,
            currentTime = u.currentTime or 0,
            duration = u.duration or 0,
            isFinished = u.isFinished or false,
            timeListened = 0,
        })
    end

    local data, err = self:_request("/api/session/local-all", "POST", sessions)
    if not data then
        return false, err
    end
    return true, nil
end

-- ---------------------------------------------------------------------------
-- File download
-- ---------------------------------------------------------------------------

--[[--
Download a file from the ABS server to a local path.
Uses socket.http so no external curl/wget is required.
@param url string  Full URL (may be an API endpoint or content URL)
@param dest_path string  Local filesystem path to write
@return boolean, string|nil  success, error_message
--]]
function ABSClient:downloadFile(url, dest_path)
    if not url or url == "" then
        return false, _("No download URL provided.")
    end

    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")

    local headers = {
        ["User-Agent"] = "audiobook.koplugin-absclient",
    }
    if self.token and self.token ~= "" then
        headers["Authorization"] = "Bearer " .. self.token
    end

    -- Ensure parent directory exists
    local dir = dest_path:match("^(.*)/[^/]*$")
    if dir and dir ~= "" then
        os.execute(string.format('mkdir -p "%s"', dir))
    end

    local f, ferr = io.open(dest_path, "wb")
    if not f then
        return false, _("Cannot open destination file: ") .. tostring(ferr)
    end

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_BLOCK_TIMEOUT)

    local code, response_headers, status = require("socket").skip(1, http.request{
        url = url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.file(f),
        redirect = false,
    })

    -- Guard: if the request failed, code is a string error message.
    -- Check this before any numeric comparison to avoid crashing.
    if code and type(code) ~= "number" then
        socketutil:reset_timeout()
        return false, _("Network error: ") .. tostring(code)
    end

    -- Handle redirects manually (socket.http drops headers on redirect)
    if code and code >= 300 and code < 400 and response_headers and response_headers.location then
        local redirect_url = response_headers.location
        if redirect_url:sub(1, 1) == "/" then
            local base = self.server_url:match("^(https?://[^/]+)")
            redirect_url = base .. redirect_url
        elseif not redirect_url:match("^https?://") then
            local base = self.server_url:match("^(https?://.+/)") or (self.server_url .. "/")
            redirect_url = base .. redirect_url
        end
        f, ferr = io.open(dest_path, "wb")
        if not f then
            socketutil:reset_timeout()
            return false, _("Cannot reopen destination file: ") .. tostring(ferr)
        end
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_BLOCK_TIMEOUT)
        code, response_headers, status = require("socket").skip(1, http.request{
            url = redirect_url,
            method = "GET",
            headers = headers,
            sink = ltn12.sink.file(f),
        })
    end

    socketutil:reset_timeout()

    if not code then
        return false, _("Network error: no response from server.")
    end
    if type(code) ~= "number" then
        return false, _("Network error: ") .. tostring(code)
    end
    if code == 401 then
        return false, _("Authentication failed.")
    end
    if code >= 400 then
        return false, _("HTTP error: ") .. tostring(code)
    end
    if code ~= 200 then
        return false, _("Unexpected HTTP response: ") .. tostring(code)
    end

    return true, nil
end

-- ---------------------------------------------------------------------------
-- Server health / connectivity check
-- ---------------------------------------------------------------------------

--[[--
Check if the configured server is reachable.
@return boolean, string|nil  is_reachable, error_message
--]]
function ABSClient:ping()
    local data, err = self:_request("/api/libraries")
    if not data then
        return false, err
    end
    return true, nil
end

return ABSClient
