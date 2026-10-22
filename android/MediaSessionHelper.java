package org.koreader.plugin.audiobook;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.media.MediaMetadata;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;

/**
 * Active MediaSession so Bluetooth headsets (AirPods stem, AVRCP) deliver
 * play/pause/next/prev to KOReader on Android.  Lua polls getPendingCommand()
 * — no JNI callbacks required.
 */
public class MediaSessionHelper {
    public static final int CMD_NONE = 0;
    public static final int CMD_PLAY_PAUSE = 1;
    public static final int CMD_PLAY = 2;
    public static final int CMD_PAUSE = 3;
    public static final int CMD_STOP = 4;
    public static final int CMD_NEXT = 5;
    public static final int CMD_PREV = 6;
    /** Interruption (phone call, other app took audio focus): pause. */
    public static final int CMD_INTERRUPT_PAUSE = 7;
    /** Interruption is over and we paused for it: resume. */
    public static final int CMD_INTERRUPT_RESUME = 8;

    // How often to poll AudioManager.getMode() as a fallback call detector
    // (some VoIP / OEM dialers do not take audio focus).
    private static final long MODE_POLL_MS = 1000;

    private final Context context;
    private final HandlerThread workerThread;
    private final Handler worker;
    private final Object lock = new Object();

    private MediaSession session;
    private AudioManager audioManager;
    private Object audioFocusRequest; // AudioFocusRequest on API 26+
    private volatile int pendingCommand = CMD_NONE;
    // Interruption commands bypass the button debounce: a short focus loss
    // followed by a quick regain must deliver both pause and resume.
    private volatile int pendingInterrupt = CMD_NONE;
    // True while we are paused because of a call / focus loss and should
    // resume automatically once it ends.
    private volatile boolean pausedByInterrupt;
    private volatile boolean focusLost;
    private volatile boolean inCall;
    private AudioManager.OnAudioFocusChangeListener focusListener;
    private volatile boolean active;
    private volatile boolean hasAudioFocus;
    private volatile long suppressCommandUntilMs;
    private volatile int playbackState = PlaybackState.STATE_NONE;
    private volatile long positionMs;
    private volatile String title = "Audiobook";
    private volatile String artist = "";

    public MediaSessionHelper(Context context) {
        this.context = context.getApplicationContext();
        workerThread = new HandlerThread("abk-mediasession");
        workerThread.start();
        worker = new Handler(workerThread.getLooper());
        audioManager = (AudioManager) this.context.getSystemService(Context.AUDIO_SERVICE);
    }

    /** Activate the session (call when overlay/audiobook playback starts). */
    public void start(final String trackTitle, final String trackArtist) {
        if (trackTitle != null && trackTitle.length() > 0) title = trackTitle;
        if (trackArtist != null) artist = trackArtist;
        worker.post(new Runnable() {
            @Override
            public void run() {
                ensureSessionLocked();
                // Only request focus once.  Re-requesting on every
                // pause→play status update can briefly lose focus and was
                // auto-pausing AirPods resume after ~0.5s.
                if (!hasAudioFocus) requestFocus();
                setStateInternal(PlaybackState.STATE_PLAYING, positionMs);
                active = true;
                scheduleModePoll();
            }
        });
    }

    public void stop() {
        worker.post(new Runnable() {
            @Override
            public void run() {
                active = false;
                pausedByInterrupt = false;
                worker.removeCallbacks(modePoll);
                setStateInternal(PlaybackState.STATE_STOPPED, positionMs);
                abandonFocus();
                releaseSessionLocked();
            }
        });
    }

    public void setPlaying(final boolean playing, final long posMs) {
        positionMs = Math.max(0, posMs);
        worker.post(new Runnable() {
            @Override
            public void run() {
                if (!active && session == null) return;
                ensureSessionLocked();
                if (playing) {
                    // User (or we) resumed: any pending auto-resume is moot.
                    pausedByInterrupt = false;
                    if (!hasAudioFocus) requestFocus();
                }
                setStateInternal(playing ? PlaybackState.STATE_PLAYING
                                         : PlaybackState.STATE_PAUSED, positionMs);
            }
        });
    }

    public void setMetadata(final String trackTitle, final String trackArtist) {
        if (trackTitle != null && trackTitle.length() > 0) title = trackTitle;
        if (trackArtist != null) artist = trackArtist;
        worker.post(new Runnable() {
            @Override
            public void run() {
                if (session == null) return;
                applyMetadataLocked();
            }
        });
    }

    /**
     * Atomically read-and-clear the next pending media-button command.
     * @return CMD_* constant
     */
    public int getPendingCommand() {
        synchronized (lock) {
            int c = pendingInterrupt;
            if (c != CMD_NONE) {
                pendingInterrupt = CMD_NONE;
                return c;
            }
            c = pendingCommand;
            pendingCommand = CMD_NONE;
            return c;
        }
    }

    public void shutdown() {
        stop();
        worker.post(new Runnable() {
            @Override
            public void run() {
                releaseSessionLocked();
                try { workerThread.quitSafely(); } catch (Exception ignored) {}
            }
        });
    }

    private void enqueue(int cmd) {
        long now = System.currentTimeMillis();
        synchronized (lock) {
            // AirPods / AVRCP often deliver both Callback.onPlay/onPause AND a
            // media-button event for one stem press.  Keep the first command
            // and suppress duplicates for a short window so resume is not
            // immediately toggled back to pause (~0.5s play bug).
            if (now < suppressCommandUntilMs) {
                return;
            }
            pendingCommand = cmd;
            suppressCommandUntilMs = now + 700;
        }
    }

    private void enqueueInterrupt(int cmd) {
        synchronized (lock) {
            pendingInterrupt = cmd;
        }
    }

    /** Something (call, other player) interrupted us: pause if playing. */
    private void interruptBegin() {
        if (playbackState == PlaybackState.STATE_PLAYING) {
            pausedByInterrupt = true;
            // Reflect the pause immediately so a second interruption source
            // (focus + mode) does not enqueue another pause.
            setStateInternal(PlaybackState.STATE_PAUSED, positionMs);
            enqueueInterrupt(CMD_INTERRUPT_PAUSE);
        }
    }

    /** All interruptions are over: resume if we were the ones who paused. */
    private void interruptEnd() {
        if (focusLost || inCall) return;
        if (pausedByInterrupt) {
            pausedByInterrupt = false;
            enqueueInterrupt(CMD_INTERRUPT_RESUME);
        }
    }

    private static boolean isCallMode(int mode) {
        return mode == AudioManager.MODE_IN_CALL
            || mode == AudioManager.MODE_IN_COMMUNICATION
            || mode == AudioManager.MODE_RINGTONE
            || (Build.VERSION.SDK_INT >= 30 && mode == 4 /* MODE_CALL_SCREENING */)
            || (Build.VERSION.SDK_INT >= 33 && mode == 5 /* MODE_CALL_REDIRECT */)
            || (Build.VERSION.SDK_INT >= 33 && mode == 6 /* MODE_COMMUNICATION_REDIRECT */);
    }

    private final Runnable modePoll = new Runnable() {
        @Override
        public void run() {
            if (!active || audioManager == null) return;
            boolean call = false;
            try { call = isCallMode(audioManager.getMode()); } catch (Exception ignored) {}
            if (call && !inCall) {
                inCall = true;
                interruptBegin();
            } else if (!call && inCall) {
                inCall = false;
                interruptEnd();
            }
            worker.postDelayed(this, MODE_POLL_MS);
        }
    };

    private void scheduleModePoll() {
        worker.removeCallbacks(modePoll);
        worker.postDelayed(modePoll, MODE_POLL_MS);
    }

    private void ensureSessionLocked() {
        if (session != null) return;
        session = new MediaSession(context, "audiobook.koplugin");
        session.setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS
                | MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS);
        session.setCallback(new MediaSession.Callback() {
            @Override
            public void onPlay() { enqueue(CMD_PLAY); }

            @Override
            public void onPause() { enqueue(CMD_PAUSE); }

            @Override
            public void onStop() { enqueue(CMD_STOP); }

            @Override
            public void onSkipToNext() { enqueue(CMD_NEXT); }

            @Override
            public void onSkipToPrevious() { enqueue(CMD_PREV); }

            @Override
            public boolean onMediaButtonEvent(Intent intent) {
                // Let the default implementation map keys → onPlay/onPause
                // once based on PlaybackState.  Handling keys ourselves AND
                // receiving transport callbacks caused duplicate commands.
                return super.onMediaButtonEvent(intent);
            }
        }, worker);

        // Media button receiver intent so the system can wake us.
        try {
            Intent mb = new Intent(Intent.ACTION_MEDIA_BUTTON);
            mb.setPackage(context.getPackageName());
            int flags = PendingIntent.FLAG_UPDATE_CURRENT;
            if (Build.VERSION.SDK_INT >= 23) {
                flags |= PendingIntent.FLAG_IMMUTABLE;
            }
            PendingIntent pi = PendingIntent.getBroadcast(context, 0, mb, flags);
            session.setMediaButtonReceiver(pi);
        } catch (Exception ignored) {}

        applyMetadataLocked();
        session.setActive(true);
    }

    private void applyMetadataLocked() {
        if (session == null) return;
        MediaMetadata.Builder b = new MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST,
                (artist != null && artist.length() > 0) ? artist : "Audiobook Read-Along")
            .putString(MediaMetadata.METADATA_KEY_ALBUM, "KOReader");
        session.setMetadata(b.build());
    }

    private void setStateInternal(int state, long posMs) {
        playbackState = state;
        if (session == null) return;
        long actions = PlaybackState.ACTION_PLAY
                | PlaybackState.ACTION_PAUSE
                | PlaybackState.ACTION_PLAY_PAUSE
                | PlaybackState.ACTION_STOP
                | PlaybackState.ACTION_SKIP_TO_NEXT
                | PlaybackState.ACTION_SKIP_TO_PREVIOUS
                | PlaybackState.ACTION_SEEK_TO;
        PlaybackState.Builder b = new PlaybackState.Builder()
            .setActions(actions)
            .setState(state, Math.max(0, posMs),
                state == PlaybackState.STATE_PLAYING ? 1.0f : 0.0f);
        session.setPlaybackState(b.build());
        if (!session.isActive()) session.setActive(true);
    }

    private void releaseSessionLocked() {
        if (session != null) {
            try { session.setActive(false); } catch (Exception ignored) {}
            try { session.release(); } catch (Exception ignored) {}
            session = null;
        }
    }

    private void requestFocus() {
        if (audioManager == null) return;
        try {
            if (focusListener == null) {
                focusListener = new AudioManager.OnAudioFocusChangeListener() {
                    @Override
                    public void onAudioFocusChange(int focusChange) {
                        switch (focusChange) {
                            case AudioManager.AUDIOFOCUS_GAIN:
                            case AudioManager.AUDIOFOCUS_GAIN_TRANSIENT:
                            case AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK:
                                hasAudioFocus = true;
                                focusLost = false;
                                interruptEnd();
                                break;
                            case AudioManager.AUDIOFOCUS_LOSS_TRANSIENT:
                                // Phone call, navigation prompt, voice assistant:
                                // pause now, resume when focus comes back.
                                focusLost = true;
                                interruptBegin();
                                break;
                            case AudioManager.AUDIOFOCUS_LOSS:
                                // Another player took over for good: pause and
                                // do not auto-resume.
                                hasAudioFocus = false;
                                focusLost = false;
                                if (playbackState == PlaybackState.STATE_PLAYING) {
                                    pausedByInterrupt = false;
                                    setStateInternal(PlaybackState.STATE_PAUSED, positionMs);
                                    enqueueInterrupt(CMD_INTERRUPT_PAUSE);
                                }
                                break;
                            default:
                                // LOSS_TRANSIENT_CAN_DUCK: the system ducks us.
                                break;
                        }
                    }
                };
            }
            if (Build.VERSION.SDK_INT >= 26) {
                AudioAttributes attrs = new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build();
                // Full GAIN like any audiobook/podcast player, so the system
                // delivers LOSS_TRANSIENT on incoming calls.  Spoken word
                // should pause rather than be ducked under a notification.
                AudioFocusRequest req = new AudioFocusRequest.Builder(
                        AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(attrs)
                    .setWillPauseWhenDucked(false)
                    .setAcceptsDelayedFocusGain(false)
                    .setOnAudioFocusChangeListener(focusListener, worker)
                    .build();
                audioFocusRequest = req;
                int r = audioManager.requestAudioFocus(req);
                hasAudioFocus = (r == AudioManager.AUDIOFOCUS_REQUEST_GRANTED);
            } else {
                int r = audioManager.requestAudioFocus(
                    focusListener,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN);
                hasAudioFocus = (r == AudioManager.AUDIOFOCUS_REQUEST_GRANTED);
            }
        } catch (Exception ignored) {}
    }

    private void abandonFocus() {
        if (audioManager == null) return;
        try {
            if (Build.VERSION.SDK_INT >= 26 && audioFocusRequest != null) {
                audioManager.abandonAudioFocusRequest((AudioFocusRequest) audioFocusRequest);
                audioFocusRequest = null;
            } else if (focusListener != null) {
                audioManager.abandonAudioFocus(focusListener);
            }
            hasAudioFocus = false;
            focusLost = false;
        } catch (Exception ignored) {}
    }
}
