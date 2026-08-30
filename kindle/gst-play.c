/*
 * kindle-gst-play -- Minimal WAV player for Kindle via GStreamer + mixersink
 *
 * Kindle e-readers have GStreamer 0.10 with Amazon's custom 'mixersink' that
 * routes audio through audiomgrd to Bluetooth headphones.  Most Kindles lack
 * 'wavparse', so this helper reads the WAV header in C, strips it, and feeds
 * raw PCM into a GStreamer pipeline:
 *
 *   filesrc location=<raw_pcm_file> ! audio/x-raw-int,<format> ! mixersink
 *
 * Uses dlopen/dlsym -- no GStreamer headers or libraries needed at build time.
 *
 * Cross-compile:
 *   arm-linux-gnueabihf-gcc -O2 -Wall -o gst-play gst-play.c -ldl
 *   (or use: nix-build cross-build-kindle-gst-play.nix)
 *
 * Usage:
 *   gst-play <file.wav>           Play WAV through GStreamer mixersink
 *   gst-play --probe              Check available GStreamer elements
 *   gst-play --version            Print version and exit
 *
 * Exit codes:
 *   0  Success (played to completion)
 *   1  Usage error
 *   2  WAV file error (bad header, unsupported format, I/O)
 *   3  GStreamer error (library not found, init failed, element missing)
 *   4  Playback error (pipeline failed, caps rejected by sink)
 *   5  Interrupted (SIGTERM / SIGINT)
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <signal.h>
#include <dlfcn.h>
#include <errno.h>

/*
 * KGP_NATIVE_GLIBC selects the build variant:
 *
 *  - Default (undefined): the "compat" binary, cross-built against a modern
 *    glibc and run on Kindle THROUGH our bundled ld-linux (glibc 2.42).  That
 *    bundled glibc must load the device's old-glibc libgstmixersink.so, so the
 *    two GLIBC_PRIVATE shims below are required.  This is the proven path on
 *    PW5/Colorsoft and stays byte-for-byte identical.
 *
 *  - Defined: the "native" binary, built with koxtoolchain against the Kindle's
 *    OWN (old) glibc and run under the SYSTEM /lib/ld-linux-armhf.so.3, exactly
 *    like KinAMP.  There is no glibc mixing, so the system glibc/libresolv
 *    already provide these symbols and the shims must NOT be re-exported
 *    (re-exporting h_errno@GLIBC_PRIVATE with -Wl,-E can shadow/conflict).
 *    The native build also omits -Wl,--version-script entirely.
 *
 * This single source therefore produces both binaries; only this block and the
 * build flags differ.  See .github/workflows/build-gst-play.yml.
 */
#ifndef KGP_NATIVE_GLIBC
/*
 * glibc 2.42 removed the h_errno@GLIBC_PRIVATE symbol that older system
 * libraries (e.g. Kindle's libresolv.so.2 built against glibc 2.20) still
 * reference.  Because gst-play runs through our bundled ld-linux (glibc 2.42),
 * the dynamic linker sees Kindle's old libresolv requesting h_errno@GLIBC_PRIVATE
 * and fails with "undefined symbol".
 *
 * Fix: define a compatibility symbol inside this binary and export it with
 * the GLIBC_PRIVATE version tag via a linker version-script.  The .symver
 * directive makes the linker emit h_errno_compat as h_errno@GLIBC_PRIVATE
 * in the dynamic symbol table, satisfying the old library at runtime.
 */
int h_errno_compat = 0;
__asm__(".symver h_errno_compat, h_errno@GLIBC_PRIVATE");

/*
 * Same issue for __res_maybe_init: Kindle's libgstmixersink.so loads
 * libresolv.so.2 which calls __res_maybe_init@GLIBC_PRIVATE to lazily
 * initialize the resolver state.  Stub returns 0 (success).
 */
int __res_maybe_init_compat(void *statp, int preinit) {
    (void)statp; (void)preinit;
    return 0;
}
__asm__(".symver __res_maybe_init_compat, __res_maybe_init@GLIBC_PRIVATE");
#endif /* !KGP_NATIVE_GLIBC */

#ifdef KGP_NATIVE_GLIBC
#define VERSION "0.6.0-native"
#define BUILD_VARIANT "native"
#else
#define VERSION "0.6.0-compat"
#define BUILD_VARIANT "compat"
#endif

/* ---- GStreamer constants (stable across 0.10 and 1.0) ---- */
#define GST_STATE_NULL    1
#define GST_STATE_PLAYING 4
#define GST_MESSAGE_EOS   (1 << 0)   /* 0.10 and 1.0 */
#define GST_MESSAGE_ERROR (1 << 1)

/* ---- Function pointer types (opaque void* for all GStreamer objects) ---- */
typedef void  (*fn_gst_init)(int *, char ***);
typedef void* (*fn_gst_parse_launch)(const char *, void **);
typedef int   (*fn_gst_element_set_state)(void *, int);
typedef void* (*fn_gst_element_get_bus)(void *);
typedef void* (*fn_gst_bus_poll)(void *, int, int64_t);
typedef void  (*fn_gst_message_parse_error)(void *, void **, char **);
typedef void  (*fn_gst_object_unref)(void *);
typedef void* (*fn_gst_element_factory_find)(const char *);
typedef void* (*fn_gst_element_factory_make)(const char *, const char *);

/* ---- Loaded symbols ---- */
static fn_gst_init                  gst_init_;
static fn_gst_parse_launch          gst_parse_launch_;
static fn_gst_element_set_state     gst_element_set_state_;
static fn_gst_element_get_bus       gst_element_get_bus_;
static fn_gst_bus_poll              gst_bus_poll_;
static fn_gst_message_parse_error   gst_message_parse_error_;
static fn_gst_object_unref          gst_object_unref_;
static fn_gst_element_factory_find  gst_element_factory_find_;
static fn_gst_element_factory_make  gst_element_factory_make_;

/* ---- Signal handling ---- */
static volatile sig_atomic_t got_signal = 0;
static void *pipeline_g = NULL;

static void on_signal(int sig)
{
    (void)sig;
    got_signal = 1;
    /* Best-effort stop -- gst_element_set_state is not strictly
       async-signal-safe but on a simple embedded pipeline it works
       in practice and prevents audio continuing after kill.       */
    if (pipeline_g && gst_element_set_state_)
        gst_element_set_state_(pipeline_g, GST_STATE_NULL);
}

/* ---- Helpers ---- */
static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t le32(const uint8_t *p) { return p[0] | (p[1]<<8) | (p[2]<<16) | ((uint32_t)p[3]<<24); }

/*
 * Load GStreamer via dlopen.  Tries 0.10 first (all observed Kindles),
 * then 1.0 as a future-proof fallback.  Returns 0 on success.
 */
static int gst_version_minor = 0;   /* 10 for 0.10, 0 for 1.0 */

static int load_gstreamer(void)
{
    /*
     * Try multiple library names and paths.  Bare names rely on the
     * dynamic linker's search path (--library-path, LD_LIBRARY_PATH,
     * ldconfig cache, /usr/lib).  Absolute paths bypass the search
     * entirely, which helps when the bundled ld-linux's search path
     * doesn't include /usr/lib or the ldconfig cache is incompatible.
     *
     * Indices 0-3: 0.10 names, 4+: 1.0 names.
     */
    const char *names[] = {
        "libgstreamer-0.10.so",
        "libgstreamer-0.10.so.0",
        "/usr/lib/libgstreamer-0.10.so",
        "/usr/lib/libgstreamer-0.10.so.0",
        "libgstreamer-1.0.so",
        "libgstreamer-1.0.so.0",
        "/usr/lib/libgstreamer-1.0.so",
        "/usr/lib/libgstreamer-1.0.so.0",
        NULL
    };
    void *lib = NULL;
    for (int i = 0; names[i]; i++) {
        lib = dlopen(names[i], RTLD_LAZY);
        if (lib) {
            gst_version_minor = (i < 4) ? 10 : 0;
            fprintf(stderr, "gst-play: loaded %s (0.%d)\n",
                    names[i], gst_version_minor);
            break;
        }
    }
    if (!lib) {
        fprintf(stderr, "gst-play: cannot load libgstreamer: %s\n", dlerror());
        /* Print per-name diagnostics so the bug report shows WHY each failed */
        for (int i = 0; names[i]; i++) {
            dlopen(names[i], RTLD_LAZY);
            fprintf(stderr, "  tried %s: %s\n", names[i], dlerror());
        }
        return -1;
    }

    gst_init_                 = dlsym(lib, "gst_init");
    gst_parse_launch_         = dlsym(lib, "gst_parse_launch");
    gst_element_set_state_    = dlsym(lib, "gst_element_set_state");
    gst_element_get_bus_      = dlsym(lib, "gst_element_get_bus");
    gst_bus_poll_             = dlsym(lib, "gst_bus_poll");
    gst_message_parse_error_  = dlsym(lib, "gst_message_parse_error");
    gst_object_unref_         = dlsym(lib, "gst_object_unref");
    gst_element_factory_find_ = dlsym(lib, "gst_element_factory_find");
    gst_element_factory_make_ = dlsym(lib, "gst_element_factory_make");

    if (!gst_init_ || !gst_parse_launch_ || !gst_element_set_state_ ||
        !gst_element_get_bus_) {
        fprintf(stderr, "gst-play: missing core GStreamer symbols\n");
        return -1;
    }
    if (!gst_bus_poll_) {
        fprintf(stderr, "gst-play: gst_bus_poll not found (GStreamer too old?)\n");
        return -1;
    }
    return 0;
}

/* Pre-load Kindle Ivona TTS libraries so GStreamer's ttssrc plugin can
 * find them even when the bundled ld-linux's search path does not match
 * the system ld.so.cache (issue #11).  RTLD_GLOBAL makes the symbols
 * visible to plugins loaded afterwards.
 */
static void preload_ivona_libs(void)
{
    static const char *libs[] = {
        "/usr/lib/tts/libIvonaEInkAPI.so.1.0",
        "/usr/lib/tts/libIvonaEInkCommon.so.1.0",
        NULL
    };
    for (int i = 0; libs[i]; i++) {
        void *h = dlopen(libs[i], RTLD_LAZY | RTLD_GLOBAL);
        if (h) {
            fprintf(stderr, "gst-play: preloaded %s\n", libs[i]);
        } else {
            fprintf(stderr, "gst-play: cannot preload %s: %s\n",
                    libs[i], dlerror());
        }
    }
}

/* ---- ttssrc property introspection (probe only) ----
 *
 * Firmware 5.19.x (KT6, PW6 Gen12) removed the "content-texts" property
 * from ttssrc: the pipeline still builds, but gst_tts_src_start() aborts
 * with "No content texts specified for TTS" because the text never
 * arrives.  Report the property's presence plus the full property-name
 * list so ttsengine.lua can retire the native fallback on those
 * firmwares and so bug reports carry the replacement API names.
 *
 * No gobject headers needed: every GObject starts with a GTypeInstance
 * whose single member is the class pointer, and GParamSpec's second
 * member is the property name, so both are plain pointer reads.  The
 * only symbols needed from libgobject are g_object_class_find_property
 * and g_object_class_list_properties.
 */
static void probe_ttssrc_properties(void *ttssrc_inst)
{
    void *gobj = dlopen("libgobject-2.0.so.0", RTLD_LAZY);
    if (!gobj)
        gobj = dlopen("/usr/lib/libgobject-2.0.so.0", RTLD_LAZY);
    if (!gobj || !ttssrc_inst) {
        printf("ttssrc_content_texts=unknown\n");
        return;
    }
    void *(*find_prop)(void *, const char *) =
        (void *(*)(void *, const char *))dlsym(gobj, "g_object_class_find_property");
    /* GTypeInstance.g_class is the first member of every GObject. */
    void *klass = find_prop ? *(void **)ttssrc_inst : NULL;
    if (!find_prop || !klass) {
        printf("ttssrc_content_texts=unknown\n");
        return;
    }
    void *pspec = find_prop(klass, "content-texts");
    printf("ttssrc_content_texts=%s\n", pspec ? "yes" : "no");

    /* Dump every property name (comma-separated, one line).  GParamSpec
       places `name` right after the GTypeInstance header, i.e. at one
       pointer offset on both 32-bit and 64-bit glib.  Best-effort: a
       NULL name prints as "?". */
    void *(*list_props)(void *, unsigned int *) =
        (void *(*)(void *, unsigned int *))dlsym(gobj, "g_object_class_list_properties");
    if (!list_props)
        return;
    unsigned int n = 0;
    void **props = list_props(klass, &n);
    printf("ttssrc_properties=");
    for (unsigned int i = 0; props && i < n; i++) {
        const char *name = props[i]
            ? *(const char **)((char *)props[i] + sizeof(void *))
            : NULL;
        printf("%s%s", i ? "," : "", name ? name : "?");
    }
    printf("\n");
}

/* ---- Probe mode ---- */
static int do_probe(void)
{
    /* Identify which binary produced this report (native vs compat). */
    printf("build=%s\n", BUILD_VARIANT);

    /* Report system glibc version (helps diagnose GLIBC_2.34 load failures) */
    const char *(*gnu_get_libc_version_fn)(void) = NULL;
    void *libc_handle = dlopen("libc.so.6", RTLD_LAZY);
    if (libc_handle) {
        gnu_get_libc_version_fn = dlsym(libc_handle, "gnu_get_libc_version");
        if (gnu_get_libc_version_fn)
            printf("glibc=%s\n", gnu_get_libc_version_fn());
        else
            printf("glibc=unknown\n");
    } else {
        printf("glibc=not_found\n");
    }

    /* Make Ivona symbols available before GStreamer tries to load ttssrc. */
    preload_ivona_libs();

    if (load_gstreamer() != 0) {
        printf("gstreamer=not_found\n");
        return 3;
    }

    int argc = 0;
    gst_init_(&argc, NULL);
    printf("gstreamer=loaded\n");
    printf("gstreamer_abi=0.%d\n", gst_version_minor);

    if (!gst_element_factory_find_) {
        printf("factory_find=unavailable\n");
        return 0;
    }

    const char *elems[] = {
        "filesrc", "capsfilter", "fdsrc", "fakesrc", "fakesink",
        "mixersink", "ttssrc", "wavparse", "audioconvert", "audioresample",
        NULL
    };
    for (int i = 0; elems[i]; i++) {
        void *f = gst_element_factory_find_(elems[i]);
        if (!f) {
            printf("%s=not_found\n", elems[i]);
            continue;
        }
        /* Factory exists, but the plugin .so may fail to load at runtime
           due to missing dependencies (e.g. libIvonaEInkAPI.so.1.0 for
           ttssrc on Colorsoft).  Try to actually instantiate the element. */
        int can_make = 0;
        if (gst_element_factory_make_) {
            void *inst = gst_element_factory_make_(elems[i], "probe_test");
            if (inst) {
                can_make = 1;
                if (strcmp(elems[i], "ttssrc") == 0)
                    probe_ttssrc_properties(inst);
                gst_object_unref_(inst);
            }
        }
        /* If make is unavailable, fall back to a minimal pipeline parse
           for the elements we care most about (ttssrc, mixersink). */
        if (!can_make && gst_parse_launch_ &&
            (strcmp(elems[i], "ttssrc") == 0 || strcmp(elems[i], "mixersink") == 0)) {
            char test_desc[128];
            if (strcmp(elems[i], "ttssrc") == 0)
                snprintf(test_desc, sizeof(test_desc), "ttssrc ! fakesink");
            else
                snprintf(test_desc, sizeof(test_desc), "fakesrc ! mixersink");
            void *err = NULL;
            void *test_pipe = gst_parse_launch_(test_desc, &err);
            if (test_pipe) {
                can_make = 1;
                gst_object_unref_(test_pipe);
            }
        }
        if (can_make) {
            printf("%s=found\n", elems[i]);
        } else {
            printf("%s=broken\n", elems[i]);
        }
    }
    return 0;
}

/* ---- Play mode ---- */
static int do_play(const char *wav_path)
{
    /* -- Read and validate the 44-byte WAV header -- */
    FILE *wf = fopen(wav_path, "rb");
    if (!wf) {
        fprintf(stderr, "gst-play: %s: %s\n", wav_path, strerror(errno));
        return 2;
    }

    uint8_t hdr[44];
    if (fread(hdr, 1, 44, wf) != 44) {
        fprintf(stderr, "gst-play: short WAV header\n");
        fclose(wf);
        return 2;
    }
    if (memcmp(hdr, "RIFF", 4) != 0 || memcmp(hdr + 8, "WAVE", 4) != 0) {
        fprintf(stderr, "gst-play: not a WAV file\n");
        fclose(wf);
        return 2;
    }

    uint16_t fmt      = le16(hdr + 20);
    uint16_t channels = le16(hdr + 22);
    uint32_t rate     = le32(hdr + 24);
    uint16_t bits     = le16(hdr + 34);

    if (fmt != 1) {
        fprintf(stderr, "gst-play: not PCM (fmt=%u)\n", fmt);
        fclose(wf);
        return 2;
    }
    if (channels == 0 || channels > 2 || rate == 0 ||
        (bits != 8 && bits != 16)) {
        fprintf(stderr, "gst-play: unsupported: %uch %uHz %ubit\n",
                channels, rate, bits);
        fclose(wf);
        return 2;
    }

    /* -- Copy raw PCM (bytes 44+) to a temp file -- */
    char raw_path[64];
    snprintf(raw_path, sizeof(raw_path), "/tmp/.abgst_%d.pcm", (int)getpid());

    FILE *rf = fopen(raw_path, "wb");
    if (!rf) {
        fprintf(stderr, "gst-play: temp file: %s\n", strerror(errno));
        fclose(wf);
        return 2;
    }

    char buf[4096];
    size_t total = 0, n;
    while ((n = fread(buf, 1, sizeof(buf), wf)) > 0) {
        if (fwrite(buf, 1, n, rf) != n) {
            fprintf(stderr, "gst-play: write: %s\n", strerror(errno));
            fclose(wf);
            fclose(rf);
            unlink(raw_path);
            return 2;
        }
        total += n;
    }
    fclose(wf);

    /* Append 1 second of silence: at EOS the pipeline tears down while
     * audiomgrd's shared-memory ring (~0.9 s deep) and the BT A2DP chain
     * still hold the tail of the audio, which would be cut off. */
    {
        uint32_t pad = rate * channels * (bits / 8);
        char zeros[4096];
        memset(zeros, 0, sizeof(zeros));
        while (pad > 0) {
            size_t chunk = pad < sizeof(zeros) ? pad : sizeof(zeros);
            if (fwrite(zeros, 1, chunk, rf) != chunk)
                break;
            pad -= chunk;
        }
    }
    fclose(rf);

    if (total == 0) {
        fprintf(stderr, "gst-play: empty audio data\n");
        unlink(raw_path);
        return 2;
    }

    /* -- Initialize GStreamer -- */
    if (load_gstreamer() != 0) {
        unlink(raw_path);
        return 3;
    }

    int argc = 0;
    gst_init_(&argc, NULL);

    /* -- Build pipeline description --
     *
     * mixersink needs stream-type=Music (the only playback stream type
     * audiomgrd accepts; without it the mixer stream never opens) and
     * sync=true (with the element's default sync=false the commit vfunc
     * receives mismatched in/out sample counts, rejects every buffer with
     * "MixerSink:Commit:in != out" in syslog, and the pipeline hangs
     * silently).  audiomgrd must also hold focus on 'Music'; the caller
     * (ttsengine.lua/mediaengine.lua) runs
     *   lipc-set-prop com.lab126.audiomgrd setFocus Music
     * before launching us.  Verified on PW5 firmware 5.x (2025-04).
     */
    char desc[512];
    if (gst_version_minor == 10) {
        /* GStreamer 0.10: audio/x-raw-int with explicit field types */
        snprintf(desc, sizeof(desc),
            "filesrc location=%s ! "
            "audio/x-raw-int,"
            "rate=(int)%u,"
            "channels=(int)%u,"
            "width=(int)%u,"
            "depth=(int)%u,"
            "signed=(boolean)%s,"
            "endianness=(int)1234"
            " ! mixersink stream-type=Music sync=true",
            raw_path, rate, channels, bits, bits,
            bits == 16 ? "true" : "false");
    } else {
        /* GStreamer 1.0: audio/x-raw with format string */
        const char *format = (bits == 16) ? "S16LE" : "U8";
        snprintf(desc, sizeof(desc),
            "filesrc location=%s ! "
            "audio/x-raw,"
            "format=(string)%s,"
            "rate=(int)%u,"
            "channels=(int)%u,"
            "layout=(string)interleaved"
            " ! mixersink stream-type=Music sync=true",
            raw_path, format, rate, channels);
    }

    void *error = NULL;
    void *pipeline = gst_parse_launch_(desc, &error);
    if (!pipeline) {
        fprintf(stderr, "gst-play: pipeline creation failed: %s\n", desc);
        unlink(raw_path);
        return 3;
    }
    fprintf(stderr, "gst-play: pipeline: %s\n", desc);

    pipeline_g = pipeline;

    /* -- Install signal handlers -- */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    /* -- Start playback -- */
    gst_element_set_state_(pipeline, GST_STATE_PLAYING);

    int ret = 0;

    void *bus = gst_element_get_bus_(pipeline);
    if (bus) {
        /* Wait for EOS or ERROR.  gst_bus_poll is available since 0.10.0.
           Negative timeout = wait forever. */
        void *msg = gst_bus_poll_(bus, GST_MESSAGE_EOS | GST_MESSAGE_ERROR,
                                  (int64_t)(-1));
        if (msg) {
            /* Distinguish EOS from ERROR without reading struct fields:
               gst_message_parse_error() uses g_return_if_fail internally --
               if the message is EOS the assertion fails harmlessly and
               the error output pointer stays NULL. */
            if (gst_message_parse_error_) {
                void *err = NULL;
                char *debug_info = NULL;
                gst_message_parse_error_(msg, &err, &debug_info);
                if (err != NULL) {
                    /* GError struct: domain (4/4) + code (4/4) + message pointer.
                       Offset 8 is stable on both 32-bit and 64-bit glib. */
                    char **err_msg_ptr = (char **)((char *)err + 8);
                    fprintf(stderr, "gst-play: GStreamer error: %s\n",
                            *err_msg_ptr ? *err_msg_ptr : "(unknown)");
                    if (debug_info && *debug_info)
                        fprintf(stderr, "gst-play: debug: %s\n", debug_info);
                    ret = 4;
                }
                /* err/debug leaked intentionally -- process exits shortly */
            }
            /* msg leaked intentionally */
        }
        /* bus leaked intentionally */
    } else {
        /* No bus -- fall back to duration-based sleep */
        uint32_t byte_rate = rate * channels * (bits / 8);
        unsigned int secs = (byte_rate > 0) ? (unsigned)(total / byte_rate) + 2 : 10;
        while (secs > 0 && !got_signal) {
            sleep(1);
            secs--;
        }
    }

    if (got_signal)
        ret = 5;

    /* -- Cleanup -- */
    gst_element_set_state_(pipeline, GST_STATE_NULL);
    /* pipeline leaked intentionally -- OS reclaims on exit */
    unlink(raw_path);

    return ret;
}

/* ---- TTS src mode (experimental) ----
 * Try to play text via the Kindle's ttssrc GStreamer element.
 * ttssrc connects to the TTS orchestrator (Ivona SDK) and produces
 * raw audio that flows to mixersink → audiomgrd → BT headphones.
 * This bypasses playermgr entirely, which is needed on Colorsoft
 * firmware where playermgr Open/PlayParameter does not trigger TTS.
 */

/* Escape a user-supplied sentence so it can safely appear inside a
 * GStreamer string property value (between double quotes).  We only
 * need to escape backslash and the quote itself; everything else is
 * passed through as UTF-8. */
static char *escape_gst_string(const char *text)
{
    size_t len = strlen(text);
    char *out = malloc(len * 2 + 1);
    if (!out)
        return NULL;

    size_t j = 0;
    for (size_t i = 0; i < len; i++) {
        if (text[i] == '\\' || text[i] == '"')
            out[j++] = '\\';
        out[j++] = text[i];
    }
    out[j] = '\0';
    return out;
}

static int do_ttssrc(const char *text)
{
    /* Make Ivona symbols available before GStreamer tries to load ttssrc. */
    preload_ivona_libs();

    if (load_gstreamer() != 0)
        return 3;

    int argc = 0;
    gst_init_(&argc, NULL);

    /* Check that ttssrc exists before building the pipeline */
    if (gst_element_factory_find_) {
        void *f = gst_element_factory_find_("ttssrc");
        if (!f) {
            fprintf(stderr, "gst-play: ttssrc element not found\n");
            return 3;
        }
    }

    char *escaped = escape_gst_string(text);
    if (!escaped) {
        fprintf(stderr, "gst-play: out of memory escaping TTS text\n");
        return 3;
    }

    /* Build a simple ttssrc pipeline.
     * The Colorsoft ttssrc element expects its input in the
     * "content-texts" property (plural), not the generic "text"
     * property.  Older firmware only understands "text", so if the
     * "content-texts" pipeline fails to parse we fall back to "text".
     *
     * Caps match the ttssrc pad template exactly:
     *   audio/x-raw-int,rate=24000,channels=1,width=16,depth=16,signed=true
     * and mixersink needs stream-type=Music + sync=true, just like the
     * WAV playback path, or audiomgrd rejects the stream.
     */
    char desc[2048];
    const char *prop_name = "content-texts";
    if (gst_version_minor == 10) {
        snprintf(desc, sizeof(desc),
            "ttssrc %s=\"%s\" ! "
            "audio/x-raw-int,"
            "endianness=(int)1234,"
            "signed=(boolean)true,"
            "width=(int)16,"
            "depth=(int)16,"
            "rate=(int)24000,"
            "channels=(int)1"
            " ! mixersink stream-type=Music sync=true",
            prop_name, escaped);
    } else {
        snprintf(desc, sizeof(desc),
            "ttssrc %s=\"%s\" ! "
            "audio/x-raw,"
            "format=(string)S16LE,"
            "rate=(int)24000,"
            "channels=(int)1,"
            "layout=(string)interleaved"
            " ! mixersink stream-type=Music sync=true",
            prop_name, escaped);
    }

    fprintf(stderr, "gst-play: ttssrc pipeline: %s\n", desc);

    void *error = NULL;
    void *pipeline = gst_parse_launch_(desc, &error);
    if (!pipeline) {
        /* "content-texts" may not exist on older firmware.  Try the
         * legacy "text" property as a last resort. */
        fprintf(stderr, "gst-play: content-texts pipeline failed, trying text property\n");
        if (gst_version_minor == 10) {
            snprintf(desc, sizeof(desc),
                "ttssrc text=\"%s\" ! "
                "audio/x-raw-int,"
                "endianness=(int)1234,"
                "signed=(boolean)true,"
                "width=(int)16,"
                "depth=(int)16,"
                "rate=(int)24000,"
                "channels=(int)1"
                " ! mixersink stream-type=Music sync=true",
                escaped);
        } else {
            snprintf(desc, sizeof(desc),
                "ttssrc text=\"%s\" ! "
                "audio/x-raw,"
                "format=(string)S16LE,"
                "rate=(int)24000,"
                "channels=(int)1,"
                "layout=(string)interleaved"
                " ! mixersink stream-type=Music sync=true",
                escaped);
        }
        fprintf(stderr, "gst-play: ttssrc fallback pipeline: %s\n", desc);
        pipeline = gst_parse_launch_(desc, &error);
        if (!pipeline) {
            fprintf(stderr, "gst-play: ttssrc pipeline creation failed\n");
            free(escaped);
            return 3;
        }
    }
    free(escaped);
    pipeline_g = pipeline;

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    gst_element_set_state_(pipeline, GST_STATE_PLAYING);

    int ret = 0;
    void *bus = gst_element_get_bus_(pipeline);
    if (bus) {
        void *msg = gst_bus_poll_(bus, GST_MESSAGE_EOS | GST_MESSAGE_ERROR,
                                  (int64_t)(-1));
        if (msg) {
            if (gst_message_parse_error_) {
                void *err = NULL;
                char *debug_info = NULL;
                gst_message_parse_error_(msg, &err, &debug_info);
                if (err != NULL) {
                    char **err_msg_ptr = (char **)((char *)err + 8);
                    fprintf(stderr, "gst-play: GStreamer error: %s\n",
                            *err_msg_ptr ? *err_msg_ptr : "(unknown)");
                    if (debug_info && *debug_info)
                        fprintf(stderr, "gst-play: debug: %s\n", debug_info);
                    ret = 4;
                }
            }
        }
    } else {
        /* No bus -- wait up to 30s for TTS to complete */
        int secs = 30;
        while (secs > 0 && !got_signal) {
            sleep(1);
            secs--;
        }
    }

    if (got_signal)
        ret = 5;

    gst_element_set_state_(pipeline, GST_STATE_NULL);
    return ret;
}

/* ---- Entry point ---- */
int main(int argc, char *argv[])
{
    if (argc < 2) {
        fprintf(stderr, "Usage: %s [--probe | --version | --ttssrc <text>] <file.wav>\n",
                argv[0]);
        return 1;
    }

    /* Help GStreamer find plugins when running through the bundled ld-linux.
       The 0 flag means "don't overwrite if already set". */
    setenv("GST_PLUGIN_PATH",
           "/usr/lib/gstreamer-0.10:/usr/lib/gstreamer-1.0", 0);

    if (strcmp(argv[1], "--version") == 0) {
        printf("kindle-gst-play %s (%s)\n", VERSION, BUILD_VARIANT);
        return 0;
    }
    if (strcmp(argv[1], "--probe") == 0)
        return do_probe();
    if (strcmp(argv[1], "--ttssrc") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Usage: %s --ttssrc <text>\n", argv[0]);
            return 1;
        }
        return do_ttssrc(argv[2]);
    }

    return do_play(argv[1]);
}
