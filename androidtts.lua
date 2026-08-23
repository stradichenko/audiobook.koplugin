--[[--
Android TTS Module
Wraps the Android TextToSpeech Java API via JNI for use from Lua.
Requires a pre-compiled tts_helper.dex in the plugin's android/ directory.

The helper .dex provides a polling-friendly wrapper around TextToSpeech so
that Lua does not need to implement Java callback interfaces.

Build the .dex with: cd android && ./build-dex.sh

@module androidtts
--]]

local ffi = require("ffi")
local logger = require("logger")

local AndroidTts = {}

--- io.open can fail on Android for plugin paths; fall back to lfs.attributes.
--- Never shell out: a path with shell metacharacters must not reach sh.
local function fileExists(path)
    if not path or path == "" then return false end
    local f = io.open(path, "r")
    if f then f:close() return true end
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs then
        return lfs.attributes(path, "mode") ~= nil
    end
    return false
end

function AndroidTts:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self

    o._helper_ref = nil       -- JNI GlobalRef to TtsHelper instance
    o._helper_class_ref = nil -- JNI GlobalRef to TtsHelper class
    o._method = {}            -- cached jmethodID values
    o._initialized = false
    o._android = nil
    o._cache_dir = nil
    o.plugin_dir = (o.plugin_dir or "."):gsub("//+", "/"):gsub("/+$", "")

    return o
end

--[[--
Check for JNI exceptions after a call.  If an exception occurred, log it
to logcat (ExceptionDescribe) and clear it.
@param env  JNIEnv pointer
@return boolean  true if an exception was pending (and has been cleared)
--]]
local function checkException(env)
    if env[0].ExceptionCheck(env) ~= 0 then
        env[0].ExceptionDescribe(env)
        env[0].ExceptionClear(env)
        return true
    end
    return false
end

--- LuaJIT treats a NULL cdata pointer as truthy.  Convert failed GetMethodID
--- results to real nil so callers never Call*Method with a null jmethodID
--- (that hard-crashes the Android process).
local function getMethod(env, clazz, name, sig)
    local mid = env[0].GetMethodID(env, clazz, name, sig)
    if checkException(env) or mid == nil then
        return nil
    end
    -- Explicit NULL-pointer check for LuaJIT FFI jmethodID
    local ok, nullish = pcall(function()
        return tonumber(ffi.cast("intptr_t", mid)) == 0
    end)
    if ok and nullish then return nil end
    return mid
end

--[[--
Initialize the Android TTS engine.
Loads the helper .dex via DexClassLoader and creates a TtsHelper instance.
@return boolean  true on success
--]]
function AndroidTts:init()
    if self._initialized then return true end

    local Device = require("device")
    if not Device:isAndroid() then
        logger.err("AndroidTts: Not running on Android")
        return false
    end

    local ok, android = pcall(require, "android")
    if not ok then
        logger.err("AndroidTts: Cannot load android module:", android)
        return false
    end
    self._android = android

    -- Locate tts_helper.dex (plugin dir, then this file's dir).
    local dex_path = nil
    local plugin_dir = (self.plugin_dir or "."):gsub("//+", "/"):gsub("/+$", "")
    local candidates = {
        plugin_dir .. "/android/tts_helper.dex",
    }
    local fallback_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$")
    if fallback_dir then
        fallback_dir = fallback_dir:gsub("//+", "/"):gsub("/+$", "")
        table.insert(candidates, fallback_dir .. "/android/tts_helper.dex")
    end
    for _, candidate in ipairs(candidates) do
        if fileExists(candidate) then
            dex_path = candidate
            if candidate:find(plugin_dir, 1, true) == 1 then
                self.plugin_dir = plugin_dir
            elseif fallback_dir then
                self.plugin_dir = fallback_dir
            end
            break
        end
    end
    if not dex_path then
        logger.err("AndroidTts: tts_helper.dex not found. Checked:",
            table.concat(candidates, ", "))
        return false
    end

    -- Resolve the cache directory for DexClassLoader's optimized dex output
    -- and for WAV file storage.
    local cache_dir = self:_getCacheDir()
    if not cache_dir then
        logger.err("AndroidTts: Cannot determine cache directory")
        return false
    end
    self._cache_dir = cache_dir
    -- Ensure the audiobook cache subdirectory exists (lfs.mkdir, no shell:
    -- the path comes from the Android runtime and must not be interpolated).
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs then
        lfs.mkdir(cache_dir .. "/audiobook")
    end

    -- Load the .dex from the plugin folder (proven path on Boox).  cache_dir
    -- is only passed to DexClassLoader as the optimized-dex output dir.
    -- Do NOT io.open(..., "rb") here — KOReader Lua on Android can hard-crash.

    -- Load the helper via DexClassLoader inside a JNI context
    local load_ok = false
    android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env

        -- 1. Get the parent ClassLoader from the Activity context
        local ctx_class = env[0].GetObjectClass(env, android.app.activity.clazz)
        if checkException(env) or ctx_class == nil then
            logger.err("AndroidTts: GetObjectClass failed for activity")
            return
        end
        local get_cl_id = env[0].GetMethodID(env, ctx_class,
            "getClassLoader", "()Ljava/lang/ClassLoader;")
        env[0].DeleteLocalRef(env, ctx_class)
        if checkException(env) or get_cl_id == nil then
            logger.err("AndroidTts: getClassLoader methodID not found")
            return
        end
        local parent_cl = env[0].CallObjectMethod(env,
            android.app.activity.clazz, get_cl_id)
        if checkException(env) or parent_cl == nil then
            logger.err("AndroidTts: getClassLoader returned null")
            return
        end

        -- 2. Create a DexClassLoader to load our helper .dex
        local dcl_class = env[0].FindClass(env, "dalvik/system/DexClassLoader")
        if checkException(env) or dcl_class == nil then
            logger.err("AndroidTts: DexClassLoader class not found")
            env[0].DeleteLocalRef(env, parent_cl)
            return
        end
        local dcl_init = env[0].GetMethodID(env, dcl_class, "<init>",
            "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V")
        if checkException(env) or dcl_init == nil then
            logger.err("AndroidTts: DexClassLoader constructor not found")
            env[0].DeleteLocalRef(env, parent_cl)
            env[0].DeleteLocalRef(env, dcl_class)
            return
        end

        local j_dex_path = env[0].NewStringUTF(env, dex_path)
        local j_opt_dir = env[0].NewStringUTF(env, cache_dir)
        local dcl_obj = env[0].NewObject(env, dcl_class, dcl_init,
            j_dex_path, j_opt_dir, nil, parent_cl)
        env[0].DeleteLocalRef(env, j_dex_path)
        env[0].DeleteLocalRef(env, j_opt_dir)
        env[0].DeleteLocalRef(env, parent_cl)
        if checkException(env) or dcl_obj == nil then
            logger.err("AndroidTts: DexClassLoader creation failed")
            env[0].DeleteLocalRef(env, dcl_class)
            return
        end

        -- 3. Load the TtsHelper class from the .dex
        local load_class_id = env[0].GetMethodID(env, dcl_class,
            "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;")
        env[0].DeleteLocalRef(env, dcl_class)
        if checkException(env) or load_class_id == nil then
            logger.err("AndroidTts: loadClass methodID not found")
            env[0].DeleteLocalRef(env, dcl_obj)
            return
        end

        local j_class_name = env[0].NewStringUTF(env,
            "org.koreader.plugin.audiobook.TtsHelper")
        local helper_class = env[0].CallObjectMethod(env,
            dcl_obj, load_class_id, j_class_name)
        env[0].DeleteLocalRef(env, j_class_name)
        env[0].DeleteLocalRef(env, dcl_obj)
        if checkException(env) or helper_class == nil then
            logger.err("AndroidTts: TtsHelper class not found in .dex")
            return
        end

        -- 4. Get the TtsHelper constructor and create an instance
        local helper_init = env[0].GetMethodID(env, helper_class,
            "<init>", "(Landroid/content/Context;)V")
        if checkException(env) or helper_init == nil then
            logger.err("AndroidTts: TtsHelper constructor not found")
            env[0].DeleteLocalRef(env, helper_class)
            return
        end
        local helper_obj = env[0].NewObject(env, helper_class, helper_init,
            android.app.activity.clazz)
        if checkException(env) or helper_obj == nil then
            logger.err("AndroidTts: TtsHelper instantiation failed")
            env[0].DeleteLocalRef(env, helper_class)
            return
        end

        -- 5. Cache method IDs (valid as long as the class is loaded).
        -- Use getMethod() so missing methods become Lua nil (not NULL cdata).
        self._method.getInitStatus = getMethod(env, helper_class,
            "getInitStatus", "()I")
        self._method.synthesizeToFile = getMethod(env, helper_class,
            "synthesizeToFile", "(Ljava/lang/String;Ljava/lang/String;)I")
        self._method.getSynthStatus = getMethod(env, helper_class,
            "getSynthStatus", "()I")
        self._method.setRate = getMethod(env, helper_class,
            "setRate", "(F)V")
        self._method.setPitch = getMethod(env, helper_class,
            "setPitch", "(F)V")
        self._method.setLanguage = getMethod(env, helper_class,
            "setLanguage", "(Ljava/lang/String;)I")
        self._method.shutdown = getMethod(env, helper_class,
            "shutdown", "()V")
        self._method.playFile = getMethod(env, helper_class,
            "playFile", "(Ljava/lang/String;)I")
        self._method.isPlaying = getMethod(env, helper_class,
            "isPlaying", "()Z")
        self._method.isPlaybackDone = getMethod(env, helper_class,
            "isPlaybackDone", "()Z")
        self._method.stopPlayback = getMethod(env, helper_class,
            "stopPlayback", "()V")
        self._method.pausePlayback = getMethod(env, helper_class,
            "pausePlayback", "()V")
        self._method.resumePlayback = getMethod(env, helper_class,
            "resumePlayback", "()V")
        -- Pipeline methods (synth-then-play with audio focus)
        self._method.synthesizeAndPlay = getMethod(env, helper_class,
            "synthesizeAndPlay", "(Ljava/lang/String;Ljava/lang/String;)I")
        self._method.getPipelineStatus = getMethod(env, helper_class,
            "getPipelineStatus", "()I")
        self._method.getPipelineDurationMs = getMethod(env, helper_class,
            "getPipelineDurationMs", "()I")
        self._method.stopPipeline = getMethod(env, helper_class,
            "stopPipeline", "()V")
        self._method.getDefaultEngine = getMethod(env, helper_class,
            "getDefaultEngine", "()Ljava/lang/String;")
        -- Optional methods (newer tts_helper.dex).  Nil when absent — never
        -- leave a NULL jmethodID in the table (LuaJIT NULL is truthy).
        self._method.listVoices = getMethod(env, helper_class,
            "listVoices", "()Ljava/lang/String;")
        self._method.setVoice = getMethod(env, helper_class,
            "setVoice", "(Ljava/lang/String;)I")
        self._method.seekToMs = getMethod(env, helper_class,
            "seekToMs", "(I)V")
        self._method.playMediaFile = getMethod(env, helper_class,
            "playMediaFile", "(Ljava/lang/String;)I")
        self._method.setPcmMode = getMethod(env, helper_class,
            "setPcmMode", "(Z)V")

        if not self._method.getInitStatus
            or not self._method.playFile
            or not self._method.isPlaying then
            logger.err("AndroidTts: Failed to resolve required method IDs")
            env[0].DeleteLocalRef(env, helper_obj)
            env[0].DeleteLocalRef(env, helper_class)
            return
        end

        -- 6. Promote to GlobalRefs so they survive beyond this JNI context
        self._helper_ref = env[0].NewGlobalRef(env, helper_obj)
        self._helper_class_ref = env[0].NewGlobalRef(env, helper_class)
        env[0].DeleteLocalRef(env, helper_obj)
        env[0].DeleteLocalRef(env, helper_class)

        load_ok = true
        logger.dbg("AndroidTts: Helper loaded, waiting for TTS engine init")
    end)

    if not load_ok then
        return false
    end

    self._initialized = true
    return true
end

--[[--
Get the app's cache directory from the Android Context.
@return string|nil  Absolute path to cache dir
--]]
function AndroidTts:_getCacheDir()
    if self._cache_dir then return self._cache_dir end
    local android = self._android
    if not android then return nil end

    return android.jni:context(android.app.activity.vm, function(jni)
        local cache_file = jni:callObjectMethod(
            android.app.activity.clazz,
            "getCacheDir",
            "()Ljava/io/File;"
        )
        if cache_file == nil then return nil end
        local abs_path = jni:callObjectMethod(
            cache_file, "getAbsolutePath", "()Ljava/lang/String;"
        )
        jni.env[0].DeleteLocalRef(jni.env, cache_file)
        if abs_path == nil then return nil end
        local result = jni:to_string(abs_path)
        jni.env[0].DeleteLocalRef(jni.env, abs_path)
        return result
    end)
end

--[[--
Return the temp directory to use for WAV files.
On Android this is the app cache; on other platforms /tmp.
@return string
--]]
function AndroidTts:getTempDir()
    if self._cache_dir then
        return self._cache_dir .. "/audiobook"
    end
    return "/tmp"
end

--[[--
Poll the TTS engine initialization status.
@return number  -1 pending, 0 success, >0 error
--]]
function AndroidTts:getInitStatus()
    if not self._initialized or not self._helper_ref then return -1 end
    local android = self._android
    return android.jni:context(android.app.activity.vm, function(jni)
        return jni.env[0].CallIntMethod(jni.env,
            self._helper_ref, self._method.getInitStatus)
    end)
end

--[[--
Wait for TTS init to complete, polling with a timeout.
@param timeout_ms number  Maximum wait time in ms (default 5000)
@return boolean  true if engine initialized successfully
--]]
function AndroidTts:waitForInit(timeout_ms)
    timeout_ms = timeout_ms or 5000
    -- Bound the loop by iteration count, not os.clock(): on Android
    -- os.clock() is CPU time, so when the TTS service is wedged each
    -- blocking JNI status read barely advances the clock and the wait
    -- becomes effectively unbounded.  That spins the UI thread into an
    -- ANR (observed on Bigme HiBreak, issue #44).
    local max_polls = math.ceil(timeout_ms / 50)
    for _ = 1, max_polls do
        local status = self:getInitStatus()
        if status == 0 then
            logger.dbg("AndroidTts: Engine initialized OK")
            return true
        elseif status > 0 then
            logger.err("AndroidTts: Engine init failed, status:", status)
            return false
        end
        -- Still pending, brief sleep
        os.execute("usleep 50000")  -- 50ms
    end
    logger.err("AndroidTts: Engine init timed out after", timeout_ms, "ms")
    return false
end

--[[--
Start synthesis to a WAV file (async).
@param text string  Text to synthesize
@param output_path string  Full path for the output WAV file
@return number  0 on successful dispatch, -1 if not ready, >0 on error
--]]
function AndroidTts:synthesizeToFile(text, output_path)
    if not self._initialized or not self._helper_ref then return -1 end
    local android = self._android
    return android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local j_text = env[0].NewStringUTF(env, text)
        local j_path = env[0].NewStringUTF(env, output_path)
        local result = env[0].CallIntMethod(env,
            self._helper_ref, self._method.synthesizeToFile, j_text, j_path)
        env[0].DeleteLocalRef(env, j_text)
        env[0].DeleteLocalRef(env, j_path)
        if checkException(env) then
            logger.err("AndroidTts: synthesizeToFile threw exception")
            return -1
        end
        return result
    end)
end

--[[--
Poll the synthesis completion status.
@return number  -1 idle, 0 in-progress, 1 done, 2 error
--]]
function AndroidTts:getSynthStatus()
    if not self._initialized or not self._helper_ref then return -1 end
    local android = self._android
    return android.jni:context(android.app.activity.vm, function(jni)
        local result = jni.env[0].CallIntMethod(jni.env,
            self._helper_ref, self._method.getSynthStatus)
        if checkException(jni.env) then
            logger.err("AndroidTts: getSynthStatus threw exception")
            return 2  -- treat as error
        end
        return result
    end)
end

--[[--
Set speech rate.
@param rate number  1.0 = normal speed
--]]
function AndroidTts:setRate(rate)
    if not self._initialized or not self._helper_ref then return end
    local android = self._android
    android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local args = ffi.new("jvalue[1]")
        args[0].f = rate
        env[0].CallVoidMethodA(env,
            self._helper_ref, self._method.setRate, args)
    end)
end

--[[--
Set pitch.
@param pitch number  1.0 = normal pitch
--]]
function AndroidTts:setPitch(pitch)
    if not self._initialized or not self._helper_ref then return end
    local android = self._android
    android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local args = ffi.new("jvalue[1]")
        args[0].f = pitch
        env[0].CallVoidMethodA(env,
            self._helper_ref, self._method.setPitch, args)
    end)
end

--[[--
Set language by BCP-47 tag (e.g. "en-US").
@param lang string
@return number  TextToSpeech result code
--]]
function AndroidTts:setLanguage(lang)
    if not self._initialized or not self._helper_ref then return -1 end
    local android = self._android
    return android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local j_lang = env[0].NewStringUTF(env, lang)
        local result = env[0].CallIntMethod(env,
            self._helper_ref, self._method.setLanguage, j_lang)
        env[0].DeleteLocalRef(env, j_lang)
        return result
    end)
end

--- True when the loaded dex exposes playMediaFile (newer builds).
function AndroidTts:hasPlayMediaFile()
    return self._method.playMediaFile ~= nil
end

--- True when the loaded dex exposes seekToMs (newer builds).
function AndroidTts:hasSeekToMs()
    return self._method.seekToMs ~= nil
end

--[[--
Play a WAV file through Android's MediaPlayer.
@param path string  WAV file path
@return number  Duration in ms, or -1 on error
--]]
function AndroidTts:playFile(path)
    if not self._initialized or not self._helper_ref then return -1 end
    local android = self._android
    return android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local j_path = env[0].NewStringUTF(env, path)
        local result = env[0].CallIntMethod(env,
            self._helper_ref, self._method.playFile, j_path)
        env[0].DeleteLocalRef(env, j_path)
        if checkException(env) then
            logger.err("AndroidTts: playFile threw exception")
            return -1
        end
        return result
    end)
end

--- Play a pre-recorded audiobook file (mp3/m4b) via the media audio stream.
function AndroidTts:playMediaFile(path)
    if not self._initialized or not self._helper_ref then return -1 end
    if not self._method.playMediaFile then
        return self:playFile(path)
    end
    local android = self._android
    return android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local j_path = env[0].NewStringUTF(env, path)
        local result = env[0].CallIntMethod(env,
            self._helper_ref, self._method.playMediaFile, j_path)
        env[0].DeleteLocalRef(env, j_path)
        if checkException(env) then
            logger.err("AndroidTts: playMediaFile threw exception")
            return -1
        end
        return result
    end)
end

--[[--
Check if audio is still playing.
@return boolean
--]]
function AndroidTts:isPlaying()
    if not self._initialized or not self._helper_ref then return false end
    local android = self._android
    return android.jni:context(android.app.activity.vm, function(jni)
        return jni.env[0].CallBooleanMethod(jni.env,
            self._helper_ref, self._method.isPlaying) ~= 0
    end)
end

--[[--
Check if playback finished (completed or error).
@return boolean
--]]
function AndroidTts:isPlaybackDone()
    if not self._initialized or not self._helper_ref then return true end
    local android = self._android
    return android.jni:context(android.app.activity.vm, function(jni)
        local result = jni.env[0].CallBooleanMethod(jni.env,
            self._helper_ref, self._method.isPlaybackDone)
        if checkException(jni.env) then
            logger.err("AndroidTts: isPlaybackDone threw exception")
            return true  -- treat as done so the chain doesn't stall
        end
        return result ~= 0
    end)
end

--[[--
Stop audio playback.
--]]
function AndroidTts:stopPlayback()
    if not self._initialized or not self._helper_ref then return end
    local android = self._android
    android.jni:context(android.app.activity.vm, function(jni)
        jni.env[0].CallVoidMethod(jni.env,
            self._helper_ref, self._method.stopPlayback)
    end)
end

--[[--
Pause audio playback.
--]]
function AndroidTts:pausePlayback()
    if not self._initialized or not self._helper_ref then return end
    local android = self._android
    android.jni:context(android.app.activity.vm, function(jni)
        jni.env[0].CallVoidMethod(jni.env,
            self._helper_ref, self._method.pausePlayback)
    end)
end

--[[--
Resume audio playback.
--]]
function AndroidTts:resumePlayback()
    if not self._initialized or not self._helper_ref then return end
    local android = self._android
    android.jni:context(android.app.activity.vm, function(jni)
        jni.env[0].CallVoidMethod(jni.env,
            self._helper_ref, self._method.resumePlayback)
    end)
end

--- Seek active MediaPlayer playback (ms). Requires tts_helper.dex with seekToMs.
function AndroidTts:seekToMs(msec)
    if not self._initialized or not self._helper_ref then return end
    if not self._method.seekToMs then return end
    msec = math.floor(tonumber(msec) or 0)
    local android = self._android
    android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local args = ffi.new("jvalue[1]")
        args[0].i = msec
        env[0].CallVoidMethodA(env,
            self._helper_ref, self._method.seekToMs, args)
    end)
end

--[[--
Start a combined synthesize-then-play pipeline.
Synthesis runs asynchronously; when complete, playback starts
automatically on the Java side without needing a Lua poll round-trip.
@param text string  Text to synthesize
@param output_path string  Full path for the output WAV file
@return number  0 on successful dispatch, -1 if not ready, >0 on error
--]]
function AndroidTts:synthesizeAndPlay(text, output_path)
    if not self._initialized or not self._helper_ref then return -1 end
    local android = self._android
    return android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local j_text = env[0].NewStringUTF(env, text)
        local j_path = env[0].NewStringUTF(env, output_path)
        local result = env[0].CallIntMethod(env,
            self._helper_ref, self._method.synthesizeAndPlay, j_text, j_path)
        env[0].DeleteLocalRef(env, j_text)
        env[0].DeleteLocalRef(env, j_path)
        if checkException(env) then
            logger.err("AndroidTts: synthesizeAndPlay threw exception")
            return -1
        end
        return result
    end)
end

--[[--
Poll the combined pipeline status.
@return number  -1 idle, 0 synthesizing, 1 playing, 2 done OK, 3 error
--]]
function AndroidTts:getPipelineStatus()
    if not self._initialized or not self._helper_ref then return -1 end
    local android = self._android
    return android.jni:context(android.app.activity.vm, function(jni)
        local result = jni.env[0].CallIntMethod(jni.env,
            self._helper_ref, self._method.getPipelineStatus)
        if checkException(jni.env) then return 3 end
        return result
    end)
end

--[[--
Get playback duration from the pipeline (available once status = 1).
@return number  Duration in ms, or 0 if not yet available
--]]
function AndroidTts:getPipelineDurationMs()
    if not self._initialized or not self._helper_ref then return 0 end
    local android = self._android
    return android.jni:context(android.app.activity.vm, function(jni)
        local result = jni.env[0].CallIntMethod(jni.env,
            self._helper_ref, self._method.getPipelineDurationMs)
        if checkException(jni.env) then return 0 end
        return result
    end)
end

--[[--
Cancel the pipeline (synthesis and/or playback) and release audio focus.
--]]
function AndroidTts:stopPipeline()
    if not self._initialized or not self._helper_ref then return end
    local android = self._android
    android.jni:context(android.app.activity.vm, function(jni)
        jni.env[0].CallVoidMethod(jni.env,
            self._helper_ref, self._method.stopPipeline)
    end)
end

--[[--
Package name of the active system TTS engine (e.g. "com.google.android.tts").
Main-thread safe: the Java side returns a cached value.  "pending" until the
worker thread fills it after init, "not_ready" if the engine is not up.
@return string|nil  nil when the bridge is not initialized
--]]
function AndroidTts:getDefaultEngine()
    if not self._initialized or not self._helper_ref then return nil end
    local android = self._android
    return android.jni:context(android.app.activity.vm, function(jni)
        local j_str = jni.env[0].CallObjectMethod(jni.env,
            self._helper_ref, self._method.getDefaultEngine)
        if checkException(jni.env) or j_str == nil then
            logger.err("AndroidTts: getDefaultEngine threw exception")
            return nil
        end
        local result = jni:to_string(j_str)
        jni.env[0].DeleteLocalRef(jni.env, j_str)
        return result
    end)
end

--[[--
Installed Android TTS voices.
Each entry: { name, locale, quality, network }.
Empty table when the dex has no listVoices() or the engine is not ready.
@return table
--]]
function AndroidTts:listVoices()
    if not self._initialized or not self._helper_ref then return {} end
    if not self._method.listVoices then return {} end
    local android = self._android
    local raw = android.jni:context(android.app.activity.vm, function(jni)
        local j_str = jni.env[0].CallObjectMethod(jni.env,
            self._helper_ref, self._method.listVoices)
        if checkException(jni.env) or j_str == nil then
            logger.err("AndroidTts: listVoices threw exception")
            return ""
        end
        local result = jni:to_string(j_str)
        jni.env[0].DeleteLocalRef(jni.env, j_str)
        return result
    end)
    local voices = {}
    if type(raw) ~= "string" or raw == "" then return voices end
    for line in raw:gmatch("[^\n]+") do
        local name, locale, quality, network = line:match("^(.-)\t(.-)\t(.-)\t(.-)$")
        if name and name ~= "" then
            table.insert(voices, {
                name = name,
                locale = locale or "",
                quality = tonumber(quality) or 0,
                network = network == "1",
            })
        end
    end
    return voices
end

--[[--
Select a specific Android TTS voice by Voice.getName().
@param name string
@return number  TextToSpeech result code, or -1
--]]
function AndroidTts:setVoice(name)
    if not self._initialized or not self._helper_ref then return -1 end
    if not self._method.setVoice or not name or name == "" then return -1 end
    local android = self._android
    return android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local j_name = env[0].NewStringUTF(env, name)
        local result = env[0].CallIntMethod(env,
            self._helper_ref, self._method.setVoice, j_name)
        env[0].DeleteLocalRef(env, j_name)
        if checkException(env) then
            logger.err("AndroidTts: setVoice threw exception")
            return -1
        end
        return result
    end)
end

--[[--
Switch pipeline playback between per-sentence MediaPlayer (default) and the
persistent PCM streamer: one app-owned AudioTrack, continuously fed with
sentence PCM or silence by a dedicated writer thread.  Workaround for HALs
that tear down short MediaPlayer clips mid-sentence with no completion
(issue #44, Bigme HiBreak/MTK).  Session-only; not persisted Java-side.
@param enabled boolean
--]]
function AndroidTts:setPcmMode(enabled)
    if not self._initialized or not self._helper_ref then return end
    -- Optional method: absent on older tts_helper.dex builds. Calling a
    -- NULL jmethodID (truthy in LuaJIT) hard-crashes the process.
    if not self._method.setPcmMode then return end
    local android = self._android
    android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local args = ffi.new("jvalue[1]")
        args[0].z = enabled and 1 or 0
        env[0].CallVoidMethodA(env,
            self._helper_ref, self._method.setPcmMode, args)
    end)
end

--[[--
Release the TTS engine and clean up JNI references.
--]]
function AndroidTts:shutdown()
    if not self._initialized then return end
    local android = self._android
    if android and self._helper_ref then
        android.jni:context(android.app.activity.vm, function(jni)
            local env = jni.env
            -- Call TtsHelper.shutdown()
            env[0].CallVoidMethod(env,
                self._helper_ref, self._method.shutdown)
            -- Release global refs
            env[0].DeleteGlobalRef(env, self._helper_ref)
            if self._helper_class_ref then
                env[0].DeleteGlobalRef(env, self._helper_class_ref)
            end
        end)
    end
    self._helper_ref = nil
    self._helper_class_ref = nil
    self._method = {}
    self._initialized = false
    logger.dbg("AndroidTts: Shutdown complete")
end

return AndroidTts
