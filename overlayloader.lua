--[[--
Background parse of an EPUB's media overlays.

The first play of a narrated book parses every SMIL file and content
document (one unzip each): 10 s to several minutes on a Kobo. Doing that in
KOReader's own process froze the reader behind a "Loading…" box. Here the
parse runs in a forked child, which writes the parse cache that
EpubMediaOverlay:loadFromEpub then reads in a fraction of a second. The
child reports progress over a pipe; the parent polls it from UIManager, so
pages keep turning while the book loads.

@module koplugin.audiobook.overlayloader
--]]

local logger = require("logger")
local UIManager = require("ui/uimanager")

local OverlayLoader = {}

local POLL_S = 0.5

local function ffiParts()
    local ok_u, ffiutil = pcall(require, "ffi/util")
    if not (ok_u and ffiutil and ffiutil.runInSubProcess
            and ffiutil.isSubProcessDone and ffiutil.getNonBlockingReadSize
            and ffiutil.readAllFromFD and ffiutil.writeToFD) then
        return nil
    end
    local ok_f, ffi = pcall(require, "ffi")
    if not ok_f then return nil end
    pcall(require, "ffi/posix_h")
    return ffiutil, ffi
end

--- True when this KOReader can run the parse in a child process.
function OverlayLoader.available()
    return ffiParts() ~= nil
end

--- Start parsing in a child process.
-- @param parser    EpubMediaOverlay instance (copied into the child by fork)
-- @param on_progress function(current, total), called on the UI loop
-- @param on_done   function(ok, err), called once on the UI loop
-- @return job table with :cancel(), or nil when a child cannot be started
function OverlayLoader.start(parser, epub_path, plugin_dir, on_progress, on_done)
    local ffiutil, ffi = ffiParts()
    if not ffiutil then return nil end

    local pid, fd = ffiutil.runInSubProcess(function(_pid, wfd)
        local function send(line)
            pcall(ffiutil.writeToFD, wfd, line .. "\n")
        end
        local ok, timing, err = pcall(parser.loadFromEpub, parser, epub_path,
            plugin_dir, function(p)
                if p and p.phase == "smil" and p.current and p.total then
                    send(string.format("p %d %d", p.current, p.total))
                end
            end)
        if ok and timing then
            send("ok " .. #timing)
        else
            send("err " .. tostring(ok and err or timing):gsub("\n", " "))
        end
    end, true)
    if not pid or not fd then
        logger.warn("OverlayLoader: could not start the background parse")
        return nil
    end

    local job = { pid = pid, done = false }
    local pending = ""
    local result_ok, result_err = false, "no result"

    local function handleLines(chunk)
        pending = pending .. chunk
        while true do
            local line, rest = pending:match("^([^\n]*)\n(.*)$")
            if not line then break end
            pending = rest
            local cur, total = line:match("^p (%d+) (%d+)$")
            if cur then
                if on_progress then
                    pcall(on_progress, tonumber(cur), tonumber(total))
                end
            elseif line:match("^ok ") then
                result_ok, result_err = true, nil
            elseif line:match("^err ") then
                result_ok, result_err = false, line:sub(5)
            end
        end
    end

    local function readAvailable()
        local n = ffiutil.getNonBlockingReadSize(fd)
        if not n or n <= 0 then return end
        local buf = ffi.new("char[?]", n)
        local got = ffi.C.read(fd, buf, n)
        if got and got > 0 then
            handleLines(ffi.string(buf, got))
        end
    end

    local function finish(ok, err)
        if job.done then return end
        job.done = true
        UIManager:unschedule(job._tick)
        if on_done then pcall(on_done, ok, err) end
    end

    job._tick = function()
        if job.done then return end
        pcall(readAvailable)
        if ffiutil.isSubProcessDone(pid) then
            -- The child has exited: the rest of the pipe is ready, read to EOF.
            local ok_r, rest = pcall(ffiutil.readAllFromFD, fd)
            fd = nil
            if ok_r and rest then handleLines(rest .. "\n") end
            finish(result_ok, result_err)
            return
        end
        UIManager:scheduleIn(POLL_S, job._tick)
    end

    function job:cancel()
        if self.done then return end
        self.done = true
        UIManager:unschedule(self._tick)
        pcall(ffiutil.terminateSubProcess, pid)
        if fd then
            pcall(function() ffi.C.close(fd) end)
            fd = nil
        end
        -- Reap the child once it has gone, so no zombie is left behind.
        local tries = 0
        local function reap()
            tries = tries + 1
            local ok_d, gone = pcall(ffiutil.isSubProcessDone, pid)
            if (ok_d and gone) or tries > 20 then return end
            UIManager:scheduleIn(1, reap)
        end
        UIManager:scheduleIn(1, reap)
    end

    UIManager:scheduleIn(POLL_S, job._tick)
    return job
end

return OverlayLoader
