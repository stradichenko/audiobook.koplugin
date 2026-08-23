--[[--
Android MediaSession bridge for headset / AirPods stem AVRCP buttons.

Loads android/media_session_helper.dex (MediaSessionHelper) and exposes a
poll-friendly API so Lua does not need Java callbacks.

@module androidmediasession
--]]

local ffi = require("ffi")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local time = require("ui/time")

local AndroidMediaSession = {}

AndroidMediaSession.CMD_NONE = 0
AndroidMediaSession.CMD_PLAY_PAUSE = 1
AndroidMediaSession.CMD_PLAY = 2
AndroidMediaSession.CMD_PAUSE = 3
AndroidMediaSession.CMD_STOP = 4
AndroidMediaSession.CMD_NEXT = 5
AndroidMediaSession.CMD_PREV = 6

local function checkException(env)
    if env[0].ExceptionCheck(env) ~= 0 then
        env[0].ExceptionDescribe(env)
        env[0].ExceptionClear(env)
        return true
    end
    return false
end

local function getMethod(env, clazz, name, sig)
    local mid = env[0].GetMethodID(env, clazz, name, sig)
    if checkException(env) or mid == nil then return nil end
    local ok, nullish = pcall(function()
        return tonumber(ffi.cast("intptr_t", mid)) == 0
    end)
    if ok and nullish then return nil end
    return mid
end

local function fileExists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    local rc = os.execute('test -f "' .. path:gsub('"', '\\"') .. '" 2>/dev/null')
    return rc == 0 or rc == true
end

function AndroidMediaSession:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o._android = nil
    o._helper_ref = nil
    o._helper_class = nil
    o._method = {}
    o._initialized = false
    o._poll_gen = 0
    o._plugin = nil
    return o
end

function AndroidMediaSession:init(plugin_dir)
    if self._initialized then return true end

    local Device = require("device")
    if not (Device.isAndroid and Device:isAndroid()) then
        return false
    end

    local ok, android = pcall(require, "android")
    if not ok or not android then
        logger.err("AndroidMediaSession: cannot load android module")
        return false
    end
    self._android = android

    plugin_dir = (plugin_dir or "."):gsub("//+", "/"):gsub("/+$", "")
    -- Prefer uniquely-named dex builds when present (MTP same-name overwrite is flaky).
    local dex_path = nil
    for _, name in ipairs({
        "media_session_helper.fix27.dex",
        "media_session_helper.fix25.dex",
        "media_session_helper.v25.dex",
        "media_session_helper.dex",
    }) do
        local candidate = plugin_dir .. "/android/" .. name
        if fileExists(candidate) then
            dex_path = candidate
            break
        end
    end
    if not dex_path then
        logger.warn("AndroidMediaSession: dex not found under", plugin_dir .. "/android/")
        return false
    end
    logger.warn("AndroidMediaSession: loading dex", dex_path)

    local cache_dir = nil
    pcall(function()
        cache_dir = android.getExternalDir("cache") or android.getExternalDir("files")
    end)
    if not cache_dir or cache_dir == "" then
        cache_dir = plugin_dir .. "/cache"
    end
    os.execute('mkdir -p "' .. cache_dir .. '/audiobook" 2>/dev/null')
    local opt_dir = cache_dir .. "/audiobook"

    local load_ok = false
    android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env

        local ctx_class = env[0].GetObjectClass(env, android.app.activity.clazz)
        if checkException(env) or ctx_class == nil then return end
        local get_cl = env[0].GetMethodID(env, ctx_class,
            "getClassLoader", "()Ljava/lang/ClassLoader;")
        env[0].DeleteLocalRef(env, ctx_class)
        if checkException(env) or get_cl == nil then return end
        local parent_cl = env[0].CallObjectMethod(env,
            android.app.activity.clazz, get_cl)
        if checkException(env) or parent_cl == nil then return end

        local dcl_class = env[0].FindClass(env, "dalvik/system/DexClassLoader")
        if checkException(env) or dcl_class == nil then
            env[0].DeleteLocalRef(env, parent_cl)
            return
        end
        local dcl_init = env[0].GetMethodID(env, dcl_class, "<init>",
            "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V")
        if checkException(env) or dcl_init == nil then
            env[0].DeleteLocalRef(env, parent_cl)
            env[0].DeleteLocalRef(env, dcl_class)
            return
        end

        local j_dex = env[0].NewStringUTF(env, dex_path)
        local j_opt = env[0].NewStringUTF(env, opt_dir)
        local dcl = env[0].NewObject(env, dcl_class, dcl_init,
            j_dex, j_opt, nil, parent_cl)
        env[0].DeleteLocalRef(env, j_dex)
        env[0].DeleteLocalRef(env, j_opt)
        env[0].DeleteLocalRef(env, parent_cl)
        env[0].DeleteLocalRef(env, dcl_class)
        if checkException(env) or dcl == nil then
            logger.err("AndroidMediaSession: DexClassLoader failed")
            return
        end

        local cl_class = env[0].GetObjectClass(env, dcl)
        local load_class = env[0].GetMethodID(env, cl_class,
            "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;")
        env[0].DeleteLocalRef(env, cl_class)
        if checkException(env) or load_class == nil then
            env[0].DeleteLocalRef(env, dcl)
            return
        end

        local j_name = env[0].NewStringUTF(env,
            "org.koreader.plugin.audiobook.MediaSessionHelper")
        local helper_class = env[0].CallObjectMethod(env, dcl, load_class, j_name)
        env[0].DeleteLocalRef(env, j_name)
        env[0].DeleteLocalRef(env, dcl)
        if checkException(env) or helper_class == nil then
            logger.err("AndroidMediaSession: loadClass failed")
            return
        end

        local init = getMethod(env, helper_class, "<init>",
            "(Landroid/content/Context;)V")
        self._method.start = getMethod(env, helper_class,
            "start", "(Ljava/lang/String;Ljava/lang/String;)V")
        self._method.stop = getMethod(env, helper_class, "stop", "()V")
        self._method.setPlaying = getMethod(env, helper_class,
            "setPlaying", "(ZJ)V")
        self._method.setMetadata = getMethod(env, helper_class,
            "setMetadata", "(Ljava/lang/String;Ljava/lang/String;)V")
        self._method.getPendingCommand = getMethod(env, helper_class,
            "getPendingCommand", "()I")
        self._method.shutdown = getMethod(env, helper_class, "shutdown", "()V")

        if not init or not self._method.start or not self._method.getPendingCommand then
            logger.err("AndroidMediaSession: required methods missing")
            env[0].DeleteLocalRef(env, helper_class)
            return
        end

        local helper = env[0].NewObject(env, helper_class, init,
            android.app.activity.clazz)
        if checkException(env) or helper == nil then
            logger.err("AndroidMediaSession: constructor failed")
            env[0].DeleteLocalRef(env, helper_class)
            return
        end

        self._helper_class = env[0].NewGlobalRef(env, helper_class)
        self._helper_ref = env[0].NewGlobalRef(env, helper)
        env[0].DeleteLocalRef(env, helper)
        env[0].DeleteLocalRef(env, helper_class)
        load_ok = true
    end)

    if not load_ok then return false end
    self._initialized = true
    logger.warn("AndroidMediaSession: ready")
    return true
end

function AndroidMediaSession:startSession(title, artist)
    if not self._initialized or not self._helper_ref then return end
    local android = self._android
    android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local j_title = env[0].NewStringUTF(env, title or "Audiobook")
        local j_artist = env[0].NewStringUTF(env, artist or "")
        env[0].CallVoidMethod(env, self._helper_ref, self._method.start,
            j_title, j_artist)
        checkException(env)
        env[0].DeleteLocalRef(env, j_title)
        env[0].DeleteLocalRef(env, j_artist)
    end)
end

function AndroidMediaSession:stopSession()
    if not self._initialized or not self._helper_ref or not self._method.stop then return end
    local android = self._android
    android.jni:context(android.app.activity.vm, function(jni)
        jni.env[0].CallVoidMethod(jni.env, self._helper_ref, self._method.stop)
        checkException(jni.env)
    end)
end

function AndroidMediaSession:setPlaying(playing, pos_ms)
    if not self._initialized or not self._helper_ref or not self._method.setPlaying then return end
    local android = self._android
    android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local args = ffi.new("jvalue[2]")
        args[0].z = playing and 1 or 0
        args[1].j = ffi.cast("jlong", math.floor(tonumber(pos_ms) or 0))
        env[0].CallVoidMethodA(env, self._helper_ref, self._method.setPlaying, args)
        checkException(env)
    end)
end

function AndroidMediaSession:pollCommand()
    if not self._initialized or not self._helper_ref then return self.CMD_NONE end
    local android = self._android
    local cmd = android.jni:context(android.app.activity.vm, function(jni)
        local c = jni.env[0].CallIntMethod(jni.env,
            self._helper_ref, self._method.getPendingCommand)
        if checkException(jni.env) then return 0 end
        return tonumber(c) or 0
    end)
    return cmd or self.CMD_NONE
end

function AndroidMediaSession:startPolling(plugin)
    self._plugin = plugin
    self._poll_gen = (self._poll_gen or 0) + 1
    local gen = self._poll_gen
    local function tick()
        if self._poll_gen ~= gen then return end
        local cmd = self:pollCommand()
        if cmd and cmd ~= self.CMD_NONE and self._plugin then
            -- Extra Lua debounce: AVRCP may still deliver a second command on
            -- the next poll tick after Java's 700ms window starts.
            local now = UIManager:getTime()
            local gap_ms = 0
            if self._last_dispatch_time then
                gap_ms = time.to_ms(now - self._last_dispatch_time) or 0
            end
            if self._last_dispatch_time and gap_ms < 750 then
                logger.warn("AndroidMediaSession: debounced command", cmd,
                    "gap_ms=", gap_ms)
            else
                self._last_dispatch_time = now
                logger.warn("AndroidMediaSession: command", cmd)
                local p = self._plugin
                -- Some headsets (AirPods Pro stem over AVRCP) repeat
                -- KEYCODE_MEDIA_PAUSE for both clicks and never send PLAY.
                -- Route every play/pause variant through the state-based
                -- toggle so the plugin's real state decides.
                if cmd == self.CMD_PLAY_PAUSE
                    or cmd == self.CMD_PLAY
                    or cmd == self.CMD_PAUSE then
                    pcall(function() p:onMediaPlayPause() end)
                elseif cmd == self.CMD_STOP then
                    pcall(function() p:onMediaStop() end)
                elseif cmd == self.CMD_NEXT then
                    pcall(function() p:onMediaNext() end)
                elseif cmd == self.CMD_PREV then
                    pcall(function() p:onMediaPrev() end)
                end
            end
        end
        UIManager:scheduleIn(0.2, tick)
    end
    UIManager:scheduleIn(0.2, tick)
end

function AndroidMediaSession:stopPolling()
    self._poll_gen = (self._poll_gen or 0) + 1
    self._plugin = nil
end

function AndroidMediaSession:shutdown()
    self:stopPolling()
    self:stopSession()
    if self._helper_ref and self._android and self._method.shutdown then
        pcall(function()
            self._android.jni:context(self._android.app.activity.vm, function(jni)
                jni.env[0].CallVoidMethod(jni.env,
                    self._helper_ref, self._method.shutdown)
                checkException(jni.env)
                jni.env[0].DeleteGlobalRef(jni.env, self._helper_ref)
            end)
        end)
        self._helper_ref = nil
    end
    if self._helper_class and self._android then
        pcall(function()
            self._android.jni:context(self._android.app.activity.vm, function(jni)
                jni.env[0].DeleteGlobalRef(jni.env, self._helper_class)
            end)
        end)
        self._helper_class = nil
    end
    self._initialized = false
end

return AndroidMediaSession
