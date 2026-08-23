package org.koreader.plugin.audiobook;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.media.MediaPlayer;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;
import android.speech.tts.Voice;

import java.io.File;
import java.io.FileInputStream;
import java.util.ArrayDeque;
import java.util.Arrays;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * Minimal TTS helper for the KOReader audiobook plugin.
 *
 * Provides a polling-friendly API so Lua (via JNI) does not need to
 * implement Java callback interfaces.  All callbacks update volatile
 * status fields that Lua reads via getInitStatus() / getSynthStatus().
 *
 * Threading: ALL TextToSpeech and MediaPlayer calls run on a single
 * dedicated HandlerThread.  Neither the Android main thread (Lua JNI
 * calls) nor the TTS utterance callback thread ever touches the engine
 * or the media server directly:
 *
 *   - Binder calls into the TTS service (synthesizeToFile, stop,
 *     setLanguage, ...) block the caller when the engine process is
 *     wedged; on the main thread that hard-freezes KOReader (issue #44).
 *   - MediaPlayer create/prepare/start/stop block on the media server;
 *     running them inside the TTS callback can deadlock against the
 *     engine's own audio output (the original #44 freeze).
 *
 * JNI-facing methods therefore only post work to the worker thread and
 * update volatile status fields synchronously, so Lua's polling semantics
 * do not change.  The single worker also serializes engine operations,
 * which keeps stop-before-next-synthesis ordering for free.
 *
 * The one bounded exception is setLanguage(): its result code drives a
 * user-facing warning, so it waits on a latch with a 3 s cap.  A wedged
 * engine turns that into a 3 s stall plus a warning, never a freeze.
 */
public class TtsHelper implements TextToSpeech.OnInitListener {

    private TextToSpeech tts;
    private AudioManager audioManager;
    private final HandlerThread workerThread;
    private final Handler worker;

    /** -1 = pending, 0 = SUCCESS, non-zero = error */
    private volatile int initStatus = -1;

    /** -1 = idle, 0 = in progress, 1 = done OK, 2 = error */
    private volatile int synthStatus = -1;

    // --- Synth-then-play pipeline state ---
    /** Pipeline status: -1=idle, 0=synthesizing, 1=playing, 2=done OK, 3=error */
    private volatile int pipelineStatus = -1;
    private volatile int pipelineDurationMs = 0;
    private volatile boolean pipelineActive = false;
    private volatile String pendingPlayFile = null;
    /** File of the currently active pipeline; stale posted starts compare
     *  against it so a stop or a newer pipeline cancels them. */
    private volatile String pipelineFile = null;
    /** Monotonic generation; posted work captured under an older
     *  generation is dropped (a stop or a newer pipeline superseded it). */
    private volatile int pipelineGeneration = 0;
    /** Result of the most recent setLanguage() (TextToSpeech result code). */
    private volatile int lastLangResult = 0;
    /** Package name of the active TTS engine (e.g. com.google.android.tts).
     *  Filled on the worker thread after init; never queried from the main
     *  thread because getDefaultEngine() is a binder call. */
    private volatile String defaultEnginePackage = null;
    /** Cached getVoices() snapshot: name\\tlocale\\tquality\\tnetwork per line.
     *  Filled on the worker thread; listVoices() never calls the TTS binder
     *  from JNI. */
    private volatile String voicesSnapshot = "";
    /** Result of the most recent setVoice() (TextToSpeech result code). */
    private volatile int lastVoiceResult = 0;

    /** When true, pipeline playback uses the persistent PCM streamer instead
     *  of a per-sentence MediaPlayer (workaround for HALs that tear down
     *  short MediaPlayer clips mid-sentence, issue #44 Bigme HiBreak/MTK).
     *  Flipped by Lua: menu setting or session-only stall auto-degrade. */
    private volatile boolean pcmMode = false;
    /** Lazily created on the worker thread by startPcmPlayback().  Read on
     *  the JNI calling thread only through volatile getters inside the
     *  streamer; all AudioTrack work happens on the streamer's own thread. */
    private volatile PcmStreamer pcm = null;

    public TtsHelper(Context context) {
        workerThread = new HandlerThread("audiobook-tts");
        workerThread.start();
        worker = new Handler(workerThread.getLooper());
        tts = new TextToSpeech(context, this);
        audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
    }

    @Override
    public void onInit(int status) {
        initStatus = status;
        if (status == TextToSpeech.SUCCESS) {
            tts.setLanguage(Locale.US);
            tts.setOnUtteranceProgressListener(new UtteranceProgressListener() {                @Override
                public void onStart(String utteranceId) {}

                @Override
                public void onDone(String utteranceId) {
                    synthStatus = 1;
                    // Pipeline mode: auto-start playback when synthesis finishes.
                    // This callback runs on a TTS engine thread; never do
                    // media work here, just hand the file to the worker.
                    if (pipelineActive && pendingPlayFile != null) {
                        final String path = pendingPlayFile;
                        pendingPlayFile = null;
                        worker.post(new Runnable() {
                            @Override
                            public void run() {
                                // A stopPipeline() or a newer pipeline may
                                // have been dispatched after this was posted.
                                if (!pipelineActive || !path.equals(pipelineFile)) {
                                    return;
                                }
                                int dur = pcmMode ? startPcmPlayback(path)
                                                  : startPlayback(path, speechAttributes());
                                if (dur >= 0) {
                                    pipelineDurationMs = dur;
                                    pipelineStatus = 1;  // playing
                                } else {
                                    pipelineStatus = 3;  // error
                                    pipelineActive = false;
                                }
                            }
                        });
                    }
                }

                @Override
                public void onError(String utteranceId) {
                    synthStatus = 2;
                    if (pipelineActive) {
                        pipelineStatus = 3;
                        pipelineActive = false;
                        pendingPlayFile = null;
                    }
                }
            });
            // Identify the active engine on the worker thread: getDefaultEngine()
            // is a binder call and must not run on the main thread.
            worker.post(new Runnable() {
                @Override
                public void run() {
                    try {
                        String pkg = tts.getDefaultEngine();
                        defaultEnginePackage = (pkg != null) ? pkg : "unknown";
                    } catch (Exception e) {
                        defaultEnginePackage = "unknown";
                    }
                    refreshVoicesLocked();
                }
            });
        }
    }

    /** Returns -1 while TTS engine is loading, 0 on success, >0 on error. */
    public int getInitStatus() {
        return initStatus;
    }

    /**
     * Package name of the active TTS engine (e.g. "com.google.android.tts").
     * Main-thread safe: returns a cached value, never calls into the TTS
     * service.  "pending" until the worker thread fills it after init,
     * "not_ready" if the engine never initialized.
     */
    public String getDefaultEngine() {
        if (defaultEnginePackage != null) {
            return defaultEnginePackage;
        }
        return (initStatus == TextToSpeech.SUCCESS) ? "pending" : "not_ready";
    }

    /**
     * Installed TTS voices as "name\\tlocale\\tquality\\tnetwork\\n" lines.
     * Refreshes on the worker thread (getVoices is a binder call) and waits
     * up to 3 s, matching setLanguage().  Empty string on timeout / error.
     */
    public String listVoices() {
        if (tts == null || initStatus != TextToSpeech.SUCCESS) {
            return voicesSnapshot != null ? voicesSnapshot : "";
        }
        final CountDownLatch latch = new CountDownLatch(1);
        worker.post(new Runnable() {
            @Override
            public void run() {
                refreshVoicesLocked();
                latch.countDown();
            }
        });
        try {
            latch.await(3, TimeUnit.SECONDS);
        } catch (InterruptedException ignored) {}
        return voicesSnapshot != null ? voicesSnapshot : "";
    }

    /**
     * Select a voice by Voice.getName().  Worker-thread binder call with a
     * 3 s cap.  Returns the TextToSpeech result code, or -1 on miss/timeout.
     */
    public int setVoice(final String name) {
        if (tts == null || initStatus != TextToSpeech.SUCCESS || name == null) {
            return -1;
        }
        final CountDownLatch latch = new CountDownLatch(1);
        worker.post(new Runnable() {
            @Override
            public void run() {
                int result = -1;
                try {
                    if (tts != null) {
                        Set<Voice> voices = tts.getVoices();
                        if (voices != null) {
                            for (Voice v : voices) {
                                if (v != null && name.equals(v.getName())) {
                                    result = tts.setVoice(v);
                                    break;
                                }
                            }
                        }
                    }
                } catch (Exception ignored) {}
                lastVoiceResult = result;
                latch.countDown();
            }
        });
        try {
            if (latch.await(3, TimeUnit.SECONDS)) {
                return lastVoiceResult;
            }
        } catch (InterruptedException ignored) {}
        return -1;
    }

    /** Must run on the worker thread. */
    private void refreshVoicesLocked() {
        if (tts == null) return;
        try {
            Set<Voice> voices = tts.getVoices();
            if (voices == null) {
                voicesSnapshot = "";
                return;
            }
            StringBuilder sb = new StringBuilder();
            for (Voice v : voices) {
                if (v == null) continue;
                String name = v.getName();
                if (name == null || name.length() == 0) continue;
                name = name.replace('\t', ' ').replace('\n', ' ');
                Locale loc = v.getLocale();
                String tag = (loc != null) ? loc.toLanguageTag() : "";
                int quality = v.getQuality();
                int network = v.isNetworkConnectionRequired() ? 1 : 0;
                sb.append(name).append('\t')
                  .append(tag).append('\t')
                  .append(quality).append('\t')
                  .append(network).append('\n');
            }
            voicesSnapshot = sb.toString();
        } catch (Exception e) {
            // Keep the previous snapshot if the binder call fails.
        }
    }

    /**
     * Start async synthesis to a WAV file.
     * The engine call happens on the worker thread; returns 0 when the
     * request was dispatched, -1 if TTS not ready.  Completion is reported
     * through getSynthStatus().
     */
    public int synthesizeToFile(final String text, final String filePath) {
        if (tts == null || initStatus != TextToSpeech.SUCCESS) {
            return -1;
        }
        synthStatus = 0;
        worker.post(new Runnable() {
            @Override
            public void run() {
                File file = new File(filePath);
                File parent = file.getParentFile();
                if (parent != null && !parent.exists()) {
                    parent.mkdirs();
                }
                try {
                    // Unique utterance ID per call so the engine treats each
                    // request as distinct (some engines ignore onDone for
                    // reused IDs).
                    String uttId = "audiobook_" + System.currentTimeMillis();
                    int result = tts.synthesizeToFile(text, new Bundle(), file, uttId);
                    if (result != TextToSpeech.SUCCESS) {
                        synthStatus = 2;
                    }
                } catch (Exception e) {
                    synthStatus = 2;
                }
            }
        });
        return 0;
    }

    /** Returns -1 idle, 0 in-progress, 1 done, 2 error. */
    public int getSynthStatus() {
        return synthStatus;
    }

    /** Set speech rate (1.0 = normal). */
    public void setRate(final float rate) {
        worker.post(new Runnable() {
            @Override
            public void run() {
                if (tts != null) {
                    try { tts.setSpeechRate(rate); } catch (Exception ignored) {}
                }
            }
        });
    }

    /** Set pitch (1.0 = normal). */
    public void setPitch(final float pitch) {
        worker.post(new Runnable() {
            @Override
            public void run() {
                if (tts != null) {
                    try { tts.setPitch(pitch); } catch (Exception ignored) {}
                }
            }
        });
    }

    /**
     * Set language by BCP-47 tag (e.g. "en-US").
     * Runs on the worker thread; the caller waits on a latch with a 3 s
     * cap because the result code drives a user-facing warning.  Returns
     * the TextToSpeech result code, or -1 on error/timeout.
     */
    public int setLanguage(String bcp47) {
        if (tts == null) return -1;
        final Locale locale = Locale.forLanguageTag(bcp47);
        final CountDownLatch latch = new CountDownLatch(1);
        worker.post(new Runnable() {
            @Override
            public void run() {
                int result = -1;
                try {
                    if (tts != null) {
                        result = tts.setLanguage(locale);
                    }
                } catch (Exception ignored) {}
                lastLangResult = result;
                latch.countDown();
            }
        });
        try {
            if (latch.await(3, TimeUnit.SECONDS)) {
                return lastLangResult;
            }
        } catch (InterruptedException ignored) {}
        return -1;
    }

    /** Release the TTS engine (posted; the caller never blocks). */
    public void shutdown() {
        stopPipeline();
        worker.post(new Runnable() {
            @Override
            public void run() {
                if (pcm != null) {
                    pcm.shutdown();
                    pcm = null;
                }
                if (tts != null) {
                    try { tts.stop(); } catch (Exception ignored) {}
                    try { tts.shutdown(); } catch (Exception ignored) {}
                    tts = null;
                }
                // Drain pending work, then stop the thread.
                workerThread.quitSafely();
            }
        });
    }

    /**
     * Switch pipeline playback between per-sentence MediaPlayer (default)
     * and the persistent PCM streamer.  JNI entry point: updates volatile
     * state only; the streamer is created lazily on the worker thread.
     * Turning the mode off tears the streamer down.
     */
    public void setPcmMode(final boolean enabled) {
        pcmMode = enabled;
        if (!enabled) {
            worker.post(new Runnable() {
                @Override
                public void run() {
                    if (pcm != null) {
                        pcm.shutdown();
                        pcm = null;
                    }
                }
            });
        }
    }

    // --- Audio focus ---

    /** Speech attributes for short TTS clips (synth-then-play pipeline). */
    private static AudioAttributes speechAttributes() {
        return new AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build();
    }

    /** Music/media attributes for pre-recorded audiobook chapters (EPUB overlay). */
    private static AudioAttributes mediaAttributes() {
        return new AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build();
    }

    /** Kept as Object so the class still loads on API < 26 where
     *  AudioFocusRequest does not exist. */
    private Object audioFocusRequest = null;

    @SuppressWarnings("deprecation")
    private void requestAudioFocus(AudioAttributes attrs) {
        if (audioManager == null) return;
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                AudioFocusRequest req = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(attrs != null ? attrs : speechAttributes())
                    .build();
                audioFocusRequest = req;
                audioManager.requestAudioFocus(req);
            } else {
                audioManager.requestAudioFocus(null,
                    AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN);
            }
        } catch (Exception ignored) {}
    }

    @SuppressWarnings("deprecation")
    private void abandonAudioFocus() {
        if (audioManager == null) return;
        try {
            if (Build.VERSION.SDK_INT >= 26 && audioFocusRequest != null) {
                audioManager.abandonAudioFocusRequest((AudioFocusRequest) audioFocusRequest);
                audioFocusRequest = null;
            } else {
                audioManager.abandonAudioFocus(null);
            }
        } catch (Exception ignored) {}
    }

    // --- Synth-then-play pipeline ---

    /**
     * Start a combined synthesize-then-play pipeline.
     * All engine work happens on the worker thread; this method only
     * updates volatile state and posts.  Returns 0 when dispatched, -1 if
     * TTS not ready.  Progress is reported through getPipelineStatus().
     */
    public int synthesizeAndPlay(final String text, final String filePath) {
        if (tts == null || initStatus != TextToSpeech.SUCCESS) return -1;

        // Cancel the current pipeline (state only; engine stop is posted).
        stopPipeline();

        final int gen = ++pipelineGeneration;
        pipelineActive = true;
        pipelineStatus = 0;  // synthesizing
        pipelineDurationMs = 0;
        pendingPlayFile = filePath;
        pipelineFile = filePath;
        synthStatus = 0;

        worker.post(new Runnable() {
            @Override
            public void run() {
                if (gen != pipelineGeneration) return;  // superseded by stop/newer
                // Engine-side stop of whatever the previous pipeline was
                // doing, then dispatch this synthesis.
                try { if (tts != null) tts.stop(); } catch (Exception ignored) {}

                File file = new File(filePath);
                File parent = file.getParentFile();
                if (parent != null && !parent.exists()) parent.mkdirs();

                try {
                    String uttId = "pipeline_" + System.currentTimeMillis();
                    int result = tts.synthesizeToFile(text, new Bundle(), file, uttId);
                    if (result != TextToSpeech.SUCCESS && gen == pipelineGeneration) {
                        pipelineStatus = 3;
                        pipelineActive = false;
                        pendingPlayFile = null;
                        pipelineFile = null;
                    }
                } catch (Exception e) {
                    if (gen == pipelineGeneration) {
                        pipelineStatus = 3;
                        pipelineActive = false;
                        pendingPlayFile = null;
                        pipelineFile = null;
                    }
                }
            }
        });
        return 0;
    }

    /** Pipeline status: -1=idle, 0=synthesizing, 1=playing, 2=done OK, 3=error. */
    public int getPipelineStatus() {
        return pipelineStatus;
    }

    /** Playback duration in ms (available once pipeline reaches status 1). */
    public int getPipelineDurationMs() {
        return pipelineDurationMs;
    }

    /** Cancel the pipeline (synthesis and/or playback) and release audio focus. */
    public void stopPipeline() {
        pipelineGeneration++;
        pendingPlayFile = null;
        pipelineFile = null;
        boolean wasSynthesizing = pipelineActive && pipelineStatus == 0;
        pipelineActive = false;
        pipelineStatus = -1;
        pipelineDurationMs = 0;
        if (wasSynthesizing && tts != null) {
            worker.post(new Runnable() {
                @Override
                public void run() {
                    try { if (tts != null) tts.stop(); } catch (Exception ignored) {}
                }
            });
        }
        stopPlayback();
    }

    // --- Audio playback via MediaPlayer ---

    private final Object mpLock = new Object();
    private MediaPlayer mediaPlayer;
    private volatile boolean playbackDone = false;
    /** Set after start() succeeds, cleared on completion/error/stop.  Read
     *  by isPlaying() on the JNI calling thread; keeps that path free of
     *  locks and binder calls (issue #44). */
    private volatile boolean playbackActive = false;

    /**
     * Play a WAV file through the speech audio output.
     * If a pipeline is active, it is cancelled first (direct playFile
     * implies the caller is bypassing the pipeline).
     * Returns 0 when dispatched, or -1 if playback is impossible.
     *
     * NOTE: legacy direct API, not used by the synth-then-play pipeline.
     * startPlayback() runs on the worker thread so the caller (Lua main
     * thread via JNI) never blocks in media-server binder calls (issue #44).
     */
    public int playFile(final String path) {
        return playFileWithAttributes(path, speechAttributes());
    }

    /**
     * Play a pre-recorded audiobook file (mp3/m4b/…) through the media stream.
     * Use this for EPUB Media Overlay chapters; short TTS clips use playFile().
     */
    public int playMediaFile(final String path) {
        return playFileWithAttributes(path, mediaAttributes());
    }

    private int playFileWithAttributes(final String path, final AudioAttributes attrs) {
        if (pipelineActive) {
            pipelineActive = false;
            pipelineStatus = -1;
            pipelineDurationMs = 0;
            pendingPlayFile = null;
        }
        worker.post(new Runnable() {
            @Override
            public void run() {
                startPlayback(path, attrs);
            }
        });
        return 0;
    }

    /**
     * Internal: start MediaPlayer on a file.  Runs on the worker thread.
     */
    private int startPlayback(String path, AudioAttributes attrs) {
        stopPlaybackInternal();
        playbackDone = false;
        playbackActive = false;
        if (attrs == null) attrs = speechAttributes();
        requestAudioFocus(attrs);
        synchronized (mpLock) {
            try {
                mediaPlayer = new MediaPlayer();
                mediaPlayer.setAudioAttributes(attrs);
                mediaPlayer.setDataSource(path);
                mediaPlayer.setOnCompletionListener(mp -> {
                    playbackDone = true;
                    playbackActive = false;
                    if (pipelineActive) {
                        pipelineStatus = 2;
                        pipelineActive = false;
                    }
                    abandonAudioFocus();
                });
                mediaPlayer.setOnErrorListener((mp, what, extra) -> {
                    playbackDone = true;
                    playbackActive = false;
                    if (pipelineActive) {
                        pipelineStatus = 3;
                        pipelineActive = false;
                    }
                    abandonAudioFocus();
                    return true;
                });
                mediaPlayer.prepare();
                mediaPlayer.start();
                playbackActive = true;
                return mediaPlayer.getDuration();
            } catch (Exception e) {
                playbackDone = true;
                playbackActive = false;
                if (pipelineActive) {
                    pipelineStatus = 3;
                    pipelineActive = false;
                }
                abandonAudioFocus();
                if (mediaPlayer != null) {
                    try { mediaPlayer.release(); } catch (Exception ignored) {}
                    mediaPlayer = null;
                }
                return -1;
            }
        }
    }

    /**
     * Check if audio is still playing.  Volatile flag only: never lock and
     * never call MediaPlayer.isPlaying() here -- this runs on the Lua main
     * thread via JNI, and both the lock (held by the worker across blocking
     * media-server calls in startPlayback) and the binder call itself can
     * freeze the whole app when the media server wedges (issue #44).
     */
    public boolean isPlaying() {
        if (pcmMode) {
            PcmStreamer s = pcm;
            return s != null && s.isSentencePlaying();
        }
        return playbackActive;
    }

    /** Check if playback finished (completed or error). */
    public boolean isPlaybackDone() {
        if (pcmMode) {
            PcmStreamer s = pcm;
            return s == null || s.isSentenceDone();
        }
        return playbackDone;
    }

    /**
     * Stop and release the MediaPlayer (JNI entry point).
     * Only posts to the worker thread; the main thread must never block
     * in MediaPlayer calls (issue #44).
     */
    public void stopPlayback() {
        worker.post(new Runnable() {
            @Override
            public void run() {
                stopPlaybackInternal();
            }
        });
    }

    /** Stop and release the MediaPlayer.  Runs on the worker thread. */
    private void stopPlaybackInternal() {
        PcmStreamer s = pcm;
        if (s != null) {
            // Cancel the in-flight sentence; the streamer keeps bridging a
            // few seconds of silence so the mixer never idles mid-session.
            s.stopSentence();
        }
        synchronized (mpLock) {
            if (mediaPlayer != null) {
                // Clear listeners BEFORE release to prevent callbacks from
                // firing on the internal thread after the native object is
                // destroyed (causes pthread_mutex_lock on destroyed mutex).
                mediaPlayer.setOnCompletionListener(null);
                mediaPlayer.setOnErrorListener(null);
                try {
                    if (mediaPlayer.isPlaying()) {
                        mediaPlayer.stop();
                    }
                } catch (IllegalStateException ignored) {}
                try {
                    mediaPlayer.release();
                } catch (Exception ignored) {}
                mediaPlayer = null;
            }
            playbackDone = false;
            playbackActive = false;
        }
        abandonAudioFocus();
    }

    /** Pause audio playback (JNI entry point: posted, never blocks). */
    public void pausePlayback() {
        worker.post(new Runnable() {
            @Override
            public void run() {
                PcmStreamer s = pcm;
                if (pcmMode && s != null) {
                    s.pause();
                    return;
                }
                synchronized (mpLock) {
                    try {
                        if (mediaPlayer != null && playbackActive) {
                            mediaPlayer.pause();
                            playbackActive = false;
                        }
                    } catch (IllegalStateException ignored) {}
                }
            }
        });
    }

    /** Resume audio playback after pause (JNI entry point: posted). */
    public void resumePlayback() {
        worker.post(new Runnable() {
            @Override
            public void run() {
                PcmStreamer s = pcm;
                if (pcmMode && s != null) {
                    s.resume();
                    return;
                }
                synchronized (mpLock) {
                    try {
                        if (mediaPlayer != null && !playbackActive) {
                            mediaPlayer.start();
                            playbackActive = true;
                        }
                    } catch (IllegalStateException ignored) {}
                }
            }
        });
    }

    /**
     * Seek the active MediaPlayer (JNI entry point: posted, never blocks).
     * Used by EPUB Media Overlay read-aloud on Android (Boox, etc.).
     */
    public void seekToMs(final int msec) {
        worker.post(new Runnable() {
            @Override
            public void run() {
                synchronized (mpLock) {
                    try {
                        if (mediaPlayer != null) {
                            mediaPlayer.seekTo(Math.max(0, msec));
                        }
                    } catch (Exception ignored) {}
                }
            }
        });
    }

    // --- PCM streamer playback (issue #44 workaround) ---

    /** Streamer events reach the helper here.  They run on the streamer's
     *  writer thread, so they only set volatile fields and post focus work
     *  to the worker; never any binder or AudioTrack calls inline. */
    private final PcmStreamer.Listener pcmListener = new PcmStreamer.Listener() {
        @Override
        public void onPcmSentenceDone() {
            playbackDone = true;
            if (pipelineActive) {
                pipelineStatus = 2;
                pipelineActive = false;
            }
        }

        @Override
        public void onPcmSentenceError() {
            playbackDone = true;
            if (pipelineActive) {
                pipelineStatus = 3;
                pipelineActive = false;
            }
        }

        @Override
        public void onPcmStreamIdle() {
            // The streamer released its track after the post-sentence
            // silence bridge lapsed: the session is quiet, drop focus.
            worker.post(new Runnable() {
                @Override
                public void run() {
                    abandonAudioFocus();
                }
            });
        }
    };

    /**
     * Play a WAV file through the persistent PCM streamer.
     * Runs on the worker thread.  Mirrors startPlayback()'s contract:
     * returns the clip duration in ms, or -1 on error.
     */
    private int startPcmPlayback(String path) {
        try {
            PcmStreamer s = pcm;
            if (s == null) {
                s = new PcmStreamer(pcmListener, speechAttributes());
                pcm = s;
            }
            s.stopSentence();  // cancel previous (mirrors startPlayback's top)
            WavData w = parseWav(path);
            if (w == null) {
                playbackDone = true;
                return -1;
            }
            requestAudioFocus(speechAttributes());
            playbackDone = false;
            s.startSentence(w);
            return w.durationMs;
        } catch (Exception e) {
            playbackDone = true;
            return -1;
        }
    }

    /** Parsed PCM payload of a 16-bit RIFF/WAVE file. */
    private static class WavData {
        int rate;
        int channels;
        int frameBytes;
        byte[] pcm;
        int durationMs;
    }

    private static int le16(byte[] b, int off) {
        return (b[off] & 0xff) | ((b[off + 1] & 0xff) << 8);
    }

    private static int le32(byte[] b, int off) {
        return (b[off] & 0xff) | ((b[off + 1] & 0xff) << 8)
            | ((b[off + 2] & 0xff) << 16) | ((b[off + 3] & 0xff) << 24);
    }

    private static boolean tagEq(byte[] b, int off, String tag) {
        return b[off] == tag.charAt(0) && b[off + 1] == tag.charAt(1)
            && b[off + 2] == tag.charAt(2) && b[off + 3] == tag.charAt(3);
    }

    /**
     * Parse a RIFF/WAVE file into interleaved 16-bit PCM.
     * Returns null for anything but uncompressed PCM, mono/stereo,
     * 8-48 kHz: TTS engines emit plain PCM WAVs, and refusing the exotic
     * cases loudly beats playing garbage.
     */
    private static WavData parseWav(String path) {
        byte[] b;
        try {
            File f = new File(path);
            b = new byte[(int) f.length()];
            FileInputStream in = new FileInputStream(f);
            int off = 0;
            while (off < b.length) {
                int r = in.read(b, off, b.length - off);
                if (r < 0) break;
                off += r;
            }
            in.close();
            if (off < b.length) return null;  // short read
        } catch (Exception e) {
            return null;
        }
        if (b.length < 44 || !tagEq(b, 0, "RIFF") || !tagEq(b, 8, "WAVE")) {
            return null;
        }
        int fmt = 0, channels = 0, rate = 0, bits = 0;
        int dataOff = -1, dataLen = 0;
        int pos = 12;
        while (pos + 8 <= b.length) {
            int size = le32(b, pos + 4);
            if (size < 0) return null;  // corrupt chunk length
            if (tagEq(b, pos, "fmt ") && size >= 16) {
                fmt = le16(b, pos + 8);
                channels = le16(b, pos + 10);
                rate = le32(b, pos + 12);
                bits = le16(b, pos + 22);
            } else if (tagEq(b, pos, "data")) {
                dataOff = pos + 8;
                dataLen = Math.min(size, b.length - dataOff);
                break;
            }
            pos += 8 + size + (size & 1);  // chunks are 2-byte aligned
        }
        if (fmt != 1 || bits != 16 || (channels != 1 && channels != 2)
                || rate < 8000 || rate > 48000 || dataOff < 0 || dataLen <= 0) {
            return null;
        }
        WavData w = new WavData();
        w.rate = rate;
        w.channels = channels;
        w.frameBytes = channels * 2;
        w.pcm = Arrays.copyOfRange(b, dataOff, dataOff + dataLen);
        w.durationMs = (int) ((long) dataLen * 1000 / ((long) rate * w.frameBytes));
        return w;
    }

    /**
     * Persistent PCM player for the synth-then-play pipeline.
     *
     * Why this exists: on some HALs (MTK e-ink, Bigme HiBreak, issue #44)
     * a per-sentence MediaPlayer clip is torn down ~130-550 ms in, with no
     * completion and no error: the mixer decides the track is idle and
     * sleeps, taking the track with it.  The platform speak() path works
     * on those devices because the engine streams PCM continuously into
     * one long-lived AudioTrack.  This class mirrors that: one app-owned
     * AudioTrack, fed by a dedicated writer thread with either sentence
     * PCM or silence, so the mixer never sees an idle moment mid-session.
     *
     * Threading: EVERY AudioTrack call happens on the writer thread.
     * Other threads (TtsHelper worker, JNI callers) only hand over queue
     * items under a lock and read volatile state.  All queue item types
     * are processed strictly in order by the single writer, which keeps
     * format changes, sentence boundaries, and teardown race-free.
     *
     * Track lifecycle: the track exists only while feeding.  After a
     * sentence ends (played out or cancelled), the writer keeps feeding
     * silence for LAPSE_MS so inter-sentence gaps (synthesis time, page
     * turns) never idle the mixer; past that it releases the track and
     * parks until the next sentence.  Pause releases the track too: a
     * paused track on these HALs is exactly what gets killed, and the
     * queue survives the release, so resume simply recreates and
     * continues where the PCM left off (up to ~0.5 s of already-buffered
     * tail is skipped on pause, accepted for a workaround mode).
     */
    private static class PcmStreamer {

        interface Listener {
            /** Sentence PCM fully played out (or completed early on
             *  pause/teardown with only the buffered tail lost). */
            void onPcmSentenceDone();
            /** The HAL killed the track mid-sentence; the sentence was
             *  abandoned so the pipeline can advance to the next one. */
            void onPcmSentenceError();
            /** Silence bridge lapsed and the track was released. */
            void onPcmStreamIdle();
        }

        /** Silence keep-alive after the last sentence before going idle. */
        private static final long LAPSE_MS = 8000;

        private final Listener listener;
        private final AudioAttributes attrs;
        private final Object lock = new Object();
        private final ArrayDeque<Object> queue = new ArrayDeque<>();
        private final Thread thread;

        private volatile boolean running = true;
        private volatile boolean userPaused = false;
        /** Set/cleared by the writer thread; read cross-thread via getters. */
        private volatile boolean sentenceActive = false;
        private volatile boolean sentenceDone = true;
        private volatile long sentenceEndFrames = 0;

        // Writer-thread state (single-threaded, no sync needed).
        private AudioTrack track = null;
        private int fmtRate = 0, fmtChannels = 0, fmtFrameBytes = 0;
        private long framesWritten = 0;
        private long headBase = 0, prevRawHead = 0, headTotal = 0;
        private long lapseAtMs = 0;
        private byte[] silence = null;
        /** Deferred listener event captured inside the lock, fired outside. */
        private Runnable pendingEvent = null;

        // Queue item types.
        private static class FmtTag {
            final int rate, channels, frameBytes;
            FmtTag(int rate, int channels, int frameBytes) {
                this.rate = rate;
                this.channels = channels;
                this.frameBytes = frameBytes;
            }
        }
        private static class PcmData {
            final byte[] bytes;
            PcmData(byte[] bytes) { this.bytes = bytes; }
        }
        private static class EndTag {}

        PcmStreamer(Listener listener, AudioAttributes attrs) {
            this.listener = listener;
            this.attrs = attrs;
            thread = new Thread(new Runnable() {
                @Override
                public void run() {
                    writerLoop();
                }
            }, "audiobook-pcm");
            thread.setDaemon(true);
            thread.start();
        }

        /** Queue one sentence for playback (worker thread). */
        void startSentence(WavData w) {
            synchronized (lock) {
                queue.add(new FmtTag(w.rate, w.channels, w.frameBytes));
                queue.add(new PcmData(w.pcm));
                queue.add(new EndTag());
                sentenceDone = false;
                lock.notify();
            }
        }

        /** Cancel the in-flight sentence; keep bridging silence briefly so
         *  the mixer stays awake until the next sentence arrives. */
        void stopSentence() {
            synchronized (lock) {
                queue.clear();
                sentenceActive = false;
                lapseAtMs = System.currentTimeMillis() + LAPSE_MS;
                lock.notify();
            }
        }

        void pause() {
            synchronized (lock) {
                userPaused = true;
                lock.notify();
            }
        }

        void resume() {
            synchronized (lock) {
                userPaused = false;
                lock.notify();
            }
        }

        void shutdown() {
            synchronized (lock) {
                running = false;
                userPaused = false;
                lock.notify();
            }
            try { thread.join(800); } catch (InterruptedException ignored) {}
        }

        boolean isSentencePlaying() {
            return sentenceActive && !userPaused;
        }

        boolean isSentenceDone() {
            return sentenceDone;
        }

        // --- Writer thread internals (only ever touched by `thread`) ---

        private void writerLoop() {
            while (true) {
                Object item;
                Runnable evt;
                synchronized (lock) {
                    while (running && (userPaused || !hasWorkLocked())) {
                        releaseTrackLocked();  // park releases the track
                        try { lock.wait(500); } catch (InterruptedException ignored) {}
                    }
                    if (!running) {
                        releaseTrackLocked();
                        evt = pendingEvent;
                        pendingEvent = null;
                        if (evt != null) evt.run();
                        return;
                    }
                    item = queue.poll();
                    evt = pendingEvent;
                    pendingEvent = null;
                }
                if (evt != null) evt.run();
                processItem(item);
                checkSentenceDone();
            }
        }

        /** Work exists when a queue item is pending, or the track is alive
         *  and still inside a sentence or the silence bridge window. */
        private boolean hasWorkLocked() {
            if (!queue.isEmpty()) return true;
            if (track == null) return false;
            return sentenceActive || System.currentTimeMillis() < lapseAtMs;
        }

        private void processItem(Object item) {
            if (item == null) {
                // Silence feed: only when the track is alive and bridging.
                if (track != null && silence != null) {
                    writeFully(silence);
                }
                return;
            }
            if (item instanceof FmtTag) {
                FmtTag f = (FmtTag) item;
                if (f.rate != fmtRate || f.channels != fmtChannels) {
                    releaseTrack();  // format change: recreate below
                    fmtRate = f.rate;
                    fmtChannels = f.channels;
                    fmtFrameBytes = f.frameBytes;
                }
                return;
            }
            if (item instanceof PcmData) {
                if (track == null && fmtRate > 0) {
                    if (!createTrack()) {
                        failSentence();
                        return;
                    }
                }
                writeFully(((PcmData) item).bytes);
                return;
            }
            if (item instanceof EndTag) {
                // All sentence PCM is written by queue order; the sentence
                // is done once the head passes what we have written.
                sentenceEndFrames = framesWritten;
                sentenceActive = true;
            }
        }

        private void writeFully(byte[] buf) {
            int off = 0;
            while (off < buf.length && running) {
                int w;
                try {
                    w = track.write(buf, off, buf.length - off);
                } catch (Exception e) {
                    w = -1;
                }
                if (w < 0) {
                    // DEAD_OBJECT etc: the HAL killed our track out from
                    // under us (the failure mode this class works around
                    // for MediaPlayer can still hit a raw track).
                    releaseTrack();
                    if (sentenceActive) {
                        failSentence();
                    } else if (fmtRate > 0) {
                        createTrack();  // silence feed: recreate and carry on
                    }
                    return;
                }
                off += w;
                framesWritten += w / fmtFrameBytes;
            }
        }

        private void checkSentenceDone() {
            if (track == null) return;
            long r;
            try {
                r = track.getPlaybackHeadPosition() & 0xffffffffL;
            } catch (Exception e) {
                return;
            }
            if (r < prevRawHead) headBase += 1L << 32;  // 32-bit head wrap
            prevRawHead = r;
            headTotal = headBase + r;
            if (sentenceActive && headTotal >= sentenceEndFrames) {
                sentenceActive = false;
                sentenceDone = true;
                lapseAtMs = System.currentTimeMillis() + LAPSE_MS;
                listener.onPcmSentenceDone();
            }
        }

        /** Abandon the in-flight sentence after a track failure so the
         *  pipeline advances instead of stalling. */
        private void failSentence() {
            synchronized (lock) {
                queue.clear();
            }
            sentenceActive = false;
            sentenceDone = true;
            listener.onPcmSentenceError();
        }

        private boolean createTrack() {
            int cfg = (fmtChannels == 2)
                ? AudioFormat.CHANNEL_OUT_STEREO : AudioFormat.CHANNEL_OUT_MONO;
            int minBuf = AudioTrack.getMinBufferSize(
                fmtRate, cfg, AudioFormat.ENCODING_PCM_16BIT);
            if (minBuf <= 0) return false;
            // ~0.5 s: enough slack to ride out e-ink refresh stalls, small
            // enough that the pause-time tail skip stays short.
            int bufSize = Math.max(minBuf, fmtRate * fmtFrameBytes / 2);
            try {
                if (Build.VERSION.SDK_INT >= 23) {
                    track = new AudioTrack.Builder()
                        .setAudioAttributes(attrs)
                        .setAudioFormat(new AudioFormat.Builder()
                            .setSampleRate(fmtRate)
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setChannelMask(cfg)
                            .build())
                        .setBufferSizeInBytes(bufSize)
                        .setTransferMode(AudioTrack.MODE_STREAM)
                        .build();
                } else {
                    track = new AudioTrack(AudioManager.STREAM_ACCESSIBILITY,
                        fmtRate, cfg, AudioFormat.ENCODING_PCM_16BIT,
                        bufSize, AudioTrack.MODE_STREAM);
                }
                if (track.getState() != AudioTrack.STATE_INITIALIZED) {
                    releaseTrack();
                    return false;
                }
                framesWritten = 0;
                headBase = 0;
                prevRawHead = 0;
                headTotal = 0;
                int silenceBytes = Math.max(fmtRate * fmtFrameBytes / 10,
                    fmtFrameBytes * 64);
                silence = new byte[silenceBytes];  // zero-filled
                track.play();
                return true;
            } catch (Exception e) {
                releaseTrack();
                return false;
            }
        }

        private void releaseTrack() {
            synchronized (lock) {
                releaseTrackLocked();
            }
            Runnable evt;
            synchronized (lock) {
                evt = pendingEvent;
                pendingEvent = null;
            }
            if (evt != null) evt.run();
        }

        /** Lock-held teardown.  If a sentence was mid-flight its target is
         *  now meaningless; complete it early so the pipeline advances
         *  (only the buffered tail is lost, e.g. on pause).  The event is
         *  deferred: listeners must not run inside the lock. */
        private void releaseTrackLocked() {
            if (track != null) {
                try { track.pause(); } catch (Exception ignored) {}
                try { track.flush(); } catch (Exception ignored) {}
                try { track.stop(); } catch (Exception ignored) {}
                try { track.release(); } catch (Exception ignored) {}
                track = null;
                silence = null;
                if (sentenceActive) {
                    sentenceActive = false;
                    sentenceDone = true;
                    pendingEvent = new Runnable() {
                        @Override
                        public void run() {
                            listener.onPcmSentenceDone();
                        }
                    };
                }
                // Going fully quiet (lapse or park) ends the focus session.
                if (System.currentTimeMillis() >= lapseAtMs) {
                    pendingEvent = chain(pendingEvent, new Runnable() {
                        @Override
                        public void run() {
                            listener.onPcmStreamIdle();
                        }
                    });
                }
            }
        }

        private Runnable chain(Runnable a, Runnable b) {
            if (a == null) return b;
            final Runnable first = a, second = b;
            return new Runnable() {
                @Override
                public void run() {
                    first.run();
                    second.run();
                }
            };
        }
    }
}
