/* snt_server.c -- sanoTTS engine server for audiobook.koplugin.
 * Piper-shaped line protocol on stdin: {"input": "text", "output": "path.wav"}
 * per line; synthesizes and prints {"wav": "path", "samples": N}.
 *
 * Three engines, selected with --engine:
 *   int8 (default)  kristin-class R7 voice, 22050 Hz. Phonemization: the
 *                   bundled espeak-ng binary (per-sentence spawn) produces IPA,
 *                   then piper's phoneme_id_map (phoneme_id_map.h) with
 *                   BOS/PAD/EOS framing, matching piper.phoneme_ids exactly.
 *   pq8             piperlite voice, fully int8 (snt_front_q8 +
 *                   snt_piperlite_q8), 22050 Hz. All dimensions come out of
 *                   the blobs, so one binary serves any exported voice; the
 *                   model dir holds front_meta_q8.bin, front_weights_q8.bin,
 *                   meta_q8.bin and weights_q8.bin. --length-scale warps the
 *                   durations (1.0 native speed). Phonemization as for int8.
 *   nano            heart-nano voice (294K params), 24000 Hz, snt_nano
 *                   runtime. Phonemization: the espeak-free lexicon G2P
 *                   (nano_lex_g2p.c, misaki dictionary data, Apache-2.0)
 *                   emits dense BOS/EOS-framed ids for the 62-symbol vocab;
 *                   no espeak spawn at all. Noise is seeded from the clause
 *                   text, or --seed forces one value.
 *
 * Usage: snt_server --model <dir> --engine int8|pq8|nano
 *                   [--espeak-bin <bin> --espeak-data <dir> --voice en-us]
 *                   [--rate 22050|24000] [--loader <ld-linux>]
 *                   [--loader-libdir <dir>] [--comma-ms N] [--period-ms N]
 *                   [--seed N] [--length-scale F]
 * The espeak/loader args apply to the int8/pq8 engines only (the loader execs
 * the bundled armhf espeak-ng through the bundled glibc loader on stock Kobo
 * rootfs); the gap args size the silence inserted after comma/period clauses
 * (defaults 150/350 ms; colon 220, semicolon 250).
 * Sources: sanoTTS mcu core and nano lexicon G2P (MIT/Apache-2.0), server
 * written for the audiobook.koplugin spike. */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "snt_tts.h"
#include "snt_nano.h"
#include "snt_front_q8.h"
#include "snt_piperlite_q8.h"
#include "phoneme_id_map.h"
#include "nano_lex_g2p.h"

#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/wait.h>

#define BOS_ID 1
#define EOS_ID 2
#define PAD_ID 0
#define MAX_IDS 1024

static void *xload2s(const char *dir, const char *name, size_t *out_bytes);

static void *xload2(const char *dir, const char *name) {
    return xload2s(dir, name, NULL);
}

static void *xload2s(const char *dir, const char *name, size_t *out_bytes) {
    char path[512];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *fh = fopen(path, "rb");
    if (!fh) { fprintf(stderr, "{\"error\": \"missing %s\"}\n", path); exit(1); }
    fseek(fh, 0, SEEK_END);
    long sz = ftell(fh);
    fseek(fh, 0, SEEK_SET);
    void *buf = malloc((size_t)sz);
    if (!buf || fread(buf, 1, (size_t)sz, fh) != (size_t)sz) { fprintf(stderr, "{\"error\": \"short read %s\"}\n", path); exit(1); }
    fclose(fh);
    if (out_bytes) *out_bytes = (size_t)sz;
    return buf;
}

static void put_u32(FILE *fh, uint32_t v) { fwrite(&v, 4, 1, fh); }
static void put_u16(FILE *fh, uint16_t v) { fwrite(&v, 2, 1, fh); }

typedef struct { FILE *fh; long n; } WavSink;

static int wav_cb(const float *pcm, int count, void *user) {
    WavSink *w = (WavSink *)user;
    for (int i = 0; i < count; i++) {
        float s = pcm[i];
        if (s > 1.0f) s = 1.0f;
        else if (s < -1.0f) s = -1.0f;
        int16_t v = (int16_t)(s * 32767.0f);
        if (fwrite(&v, sizeof v, 1, w->fh) != 1) return 1;
        w->n++;
    }
    return 0;
}

static void write_header(FILE *fh, uint32_t data_bytes, uint32_t rate) {
    uint32_t chunk = 36 + data_bytes, byte_rate = rate * 2;
    uint16_t fmt = 1, chan = 1, align = 2, bits = 16;
    fwrite("RIFF", 1, 4, fh); put_u32(fh, chunk); fwrite("WAVE", 1, 4, fh);
    fwrite("fmt ", 1, 4, fh); put_u32(fh, 16);
    put_u16(fh, fmt); put_u16(fh, chan); put_u32(fh, rate); put_u32(fh, byte_rate);
    put_u16(fh, align); put_u16(fh, bits);
    fwrite("data", 1, 4, fh); put_u32(fh, data_bytes);
}

static int map_id(const char *sym) {
    for (int i = 0; i < PHONEME_MAP_N; i++)
        if (!strcmp(PHONEME_MAP[i].sym, sym)) return PHONEME_MAP[i].id;
    return -1;
}

static int utf8_len(unsigned char b) {
    if (b < 0x80) return 1;
    if ((b & 0xE0) == 0xC0) return 2;
    if ((b & 0xF0) == 0xE0) return 3;
    if ((b & 0xF8) == 0xF0) return 4;
    return 0;
}

static const char *g_espeak_bin, *g_espeak_data, *g_voice = "en-us";
static const char *g_loader, *g_libdir;
static int g_comma_ms = 150, g_period_ms = 350, g_colon_ms = 220, g_semi_ms = 250;
static int g_engine_nano = 0;
static int g_engine_pq8 = 0;
static int g_native_punct = 0;
static float g_length_scale = 1.0f;
static float g_pause_scale = 1.0f;
static uint64_t g_seed;
static int g_seed_set = 0;

/* Run the bundled espeak-ng binary on a sentence, return its IPA output
 * (malloc'd). The binary reads stdin when no text argument is given. */
static char *phonemize_via_binary(const char *espeak_bin, const char *espeak_data, const char *voice, const char *text) {
    int in_pipe[2], out_pipe[2];
    if (pipe(in_pipe) || pipe(out_pipe)) return NULL;
    pid_t pid = fork();
    if (pid < 0) return NULL;
    if (pid == 0) {
        dup2(in_pipe[0], 0);
        dup2(out_pipe[1], 1);
        close(in_pipe[0]); close(in_pipe[1]);
        close(out_pipe[0]); close(out_pipe[1]);
        setenv("ESPEAK_DATA_PATH", espeak_data, 1);
        if (g_loader) {
            char lp[1024], dirbuf[512];
            snprintf(lp, sizeof lp, "%s:%s:/usr/lib:/lib", g_libdir ? g_libdir : "/usr/lib:/lib", g_libdir ? g_libdir : "");
            snprintf(dirbuf, sizeof dirbuf, "%s", g_libdir ? g_libdir : "");
            if (g_libdir && g_libdir[0])
                setenv("LD_LIBRARY_PATH", g_libdir, 1);
            execl(g_loader, g_loader, "--library-path", g_libdir ? g_libdir : "", espeak_bin, "-q", "--ipa", "-v", voice, (char *)NULL);
        } else {
            execl(espeak_bin, espeak_bin, "-q", "--ipa", "-v", voice, (char *)NULL);
        }
        _exit(127);
    }
    close(in_pipe[0]); close(out_pipe[1]);
    size_t cap = 4096, len = 0;
    char *ipa = malloc(cap);
    /* write sentence, then close so the child sees EOF */
    size_t tlen = strlen(text);
    if (write(in_pipe[1], text, tlen) != (ssize_t)tlen) { /* ignore short writes from EPIPE */ }
    close(in_pipe[1]);
    ssize_t r;
    while ((r = read(out_pipe[0], ipa + len, cap - len)) > 0) {
        len += (size_t)r;
        if (cap - len < 1024) { cap *= 2; ipa = realloc(ipa, cap); }
    }
    close(out_pipe[0]);
    waitpid(pid, NULL, 0);
    if (len == 0) { free(ipa); return NULL; }
    ipa[len] = 0;
    return ipa;
}

/* text -> piper phoneme ids: [BOS, PAD, (id, PAD)*, EOS] via espeak-ng IPA.
 * punct_id >= 0 appends the punctuation mark's own id before EOS so the
 * model renders its native terminal contour for the clause. */
static int text_to_ids(const char *text, int32_t *ids, int punct_id) {
    int n = 0;
    ids[n++] = BOS_ID;
    ids[n++] = PAD_ID;
    char *ipa = phonemize_via_binary(g_espeak_bin, g_espeak_data, g_voice, text);
    if (!ipa) return -1;
    for (const unsigned char *q = (const unsigned char *)ipa; *q; ) {
        int len = utf8_len(*q);
        if (len <= 0 || len > 7) { q++; continue; }
        char sym[8];
        memcpy(sym, q, (size_t)len);
        sym[len] = 0;
        int id = map_id(sym);
        if (id >= 0 && n < MAX_IDS - 2) {
            ids[n++] = id;
            ids[n++] = PAD_ID;
        }
        q += len;
    }
    free(ipa);
    if (punct_id >= 0 && n < MAX_IDS - 2) {
        ids[n++] = punct_id;
        ids[n++] = PAD_ID;
    }
    if (n > MAX_IDS - 1) n = MAX_IDS - 1;
    ids[n++] = EOS_ID;
    return n;
}

/* Append one IPA string's ids to the stream (helper for text_to_ids_native). */
static void append_ipa_ids(const char *ipa, int32_t *ids, int *n) {
    for (const unsigned char *q = (const unsigned char *)ipa; *q; ) {
        int len = utf8_len(*q);
        if (len <= 0 || len > 7) { q++; continue; }
        char sym[8];
        memcpy(sym, q, (size_t)len);
        sym[len] = 0;
        int id = map_id(sym);
        if (id >= 0 && *n < MAX_IDS - 2) {
            ids[(*n)++] = id;
            ids[(*n)++] = PAD_ID;
        }
        q += len;
    }
}

/* Piper-style punctuation awareness (piper.phonemize_espeak behavior): the
 * text is split at . , ? ! : ;, each piece is phonemized separately, and the
 * punctuation mark's own id is emitted between pieces so the model renders
 * its native pauses and terminal contours (rising for ?, falling for .).
 * espeak's IPA output drops punctuation entirely, so the ids have to be
 * interleaved at the text level. */
static int text_to_ids_native(const char *text, int32_t *ids) {
    int n = 0;
    ids[n++] = BOS_ID;
    ids[n++] = PAD_ID;
    const char *p = text;
    while (*p && n < MAX_IDS - 2) {
        char c = *p;
        if (c == '.' || c == ',' || c == '?' || c == '!' || c == ':' || c == ';') {
            char sym[2] = { c, 0 };
            int id = map_id(sym);
            if (id >= 0) {
                ids[n++] = id;
                ids[n++] = PAD_ID;
            }
            p++;
            continue;
        }
        size_t len = strcspn(p, ".,!?;:");
        if (len == 0) { p++; continue; }
        char piece[2048];
        if (len > sizeof piece - 1) len = sizeof piece - 1;
        memcpy(piece, p, len);
        piece[len] = 0;
        p += len;
        char *ipa = phonemize_via_binary(g_espeak_bin, g_espeak_data, g_voice, piece);
        if (ipa) {
            append_ipa_ids(ipa, ids, &n);
            free(ipa);
        }
    }
    if (n > MAX_IDS - 1) n = MAX_IDS - 1;
    ids[n++] = EOS_ID;
    return n;
}

/* Synthesize one clause on the nano engine: sub-split the clause at word
 * boundaries so no piece exceeds the G2P's 512-codepoint input limit, run
 * the lexicon G2P per piece, and feed snt_nano. Noise is seeded from the
 * piece text (deterministic) or the forced --seed. Returns 0 on success,
 * the first non-zero synth rc otherwise; samples emitted are added to
 * *emitted so the caller can skip the clause gap for silent clauses. */
static int synth_clause_nano(void *front, void *dec, void *arena, size_t arena_size,
                             const char *clause, WavSink *sink, long *emitted) {
    static int32_t ids[NANO_LEX_MAX_TOKENS];
    int off = 0, n = (int)strlen(clause);
    long before = sink->n;
    while (off < n) {
        int take = n - off;
        if (take > 480) {
            take = 480;
            int cut = off + take;
            while (cut > off + 64 && clause[cut] != ' ') cut--;
            take = cut - off;
        }
        while (off < n && clause[off] == ' ') off++; /* never lead with a space */
        if (off >= n) break;
        char chunk[512];
        memcpy(chunk, clause + off, (size_t)take);
        chunk[take] = 0;
        off += take;

        int n_ids = nano_lex_g2p_text_to_ids(chunk, ids, NANO_LEX_MAX_TOKENS);
        if (n_ids == NANO_LEX_E_CAP) n_ids = NANO_LEX_MAX_TOKENS; /* framed prefix, speakable */
        if (n_ids < 0) {
            fprintf(stderr, "{\"error\": \"g2p rc %d (%s)\"}\n", n_ids, nano_lex_g2p_strerror(n_ids));
            fflush(stderr);
            continue;
        }
        if (n_ids <= 2) continue; /* nothing survived the vocabulary */

        uint64_t seed = g_seed;
        if (!g_seed_set && snt_nano_sha256_seed(chunk, &seed) != 0) seed = (uint64_t)n * 2654435761u;
        snt_nano_config ncfg = {front, dec, arena, arena_size, NULL, seed};
        snt_nano_stats nst;
        int rc = snt_nano_synthesize(&ncfg, ids, n_ids, wav_cb, sink, &nst);
        if (rc != 0) return rc;
    }
    *emitted += sink->n - before;
    return 0;
}

/* Synthesize one clause on the pq8 engine (blob-parameterized piperlite,
 * fully int8): durations -> latent -> decoder -> PCM. Phoneme ids come from
 * the shared espeak path, so this takes the framed id array directly.
 * Returns 0 on success, the failing rc otherwise. */
static int synth_clause_pq8(snt_front_q8_model *fq, snt_piperlite_q8_model *dq,
                            void *arena, size_t arena_size,
                            const int32_t *ids, int n_ids,
                            WavSink *sink, long *emitted) {
    static int32_t durs[MAX_IDS];
    long before = sink->n;
    long frames = snt_front_q8_durations(fq, ids, n_ids, g_length_scale,
                                         durs, arena, arena_size);
    if (frames < 0) {
        fprintf(stderr, "{\"error\": \"pq8 durations rc %ld\"}\n", frames);
        fflush(stderr);
        return (int)frames;
    }
    /* --pause-scale stretches only the punctuation tokens' frame counts,
     * leaving every phone at its native duration: the pacing pauses get
     * longer without feeding the decoder stretched phones (which reads as
     * phasing/reverb). Frames must re-sum to the new total. */
    if (g_pause_scale != 1.0f) {
        long total = 0;
        for (int i = 0; i < n_ids; i++) {
            if (ids[i] == 4 || ids[i] == 8 || ids[i] == 10 ||
                ids[i] == 11 || ids[i] == 12 || ids[i] == 13) {
                long scaled = (long)(durs[i] * g_pause_scale + 0.5f);
                durs[i] = (int32_t)(scaled < 1 ? 1 : scaled);
            }
            total += durs[i];
        }
        frames = total;
    }
    size_t la = snt_front_q8_latent_arena_bytes(fq, n_ids, frames);
    size_t da = snt_piperlite_q8_arena_bytes(dq, (int)frames);
    /* The decoder arena scales with clause length (tens of KB per second of
     * audio), so long clauses fall back to a heap arena. The two stages run
     * sequentially and share whichever buffer wins. */
    size_t need = la > da ? la : da;
    void *ar = arena;
    int heap_arena = 0;
    if (need > arena_size) {
        ar = malloc(need);
        if (!ar) { fprintf(stderr, "{\"error\": \"pq8 arena malloc %zu\"}\n", need); fflush(stderr); return -1; }
        heap_arena = 1;
    }
    float *latent = malloc(sizeof(float) * (size_t)fq->a_out * (size_t)frames);
    float *audio = malloc(sizeof(float) * (size_t)frames * SNT_PIPERLITE_Q8_HOP);
    if (!latent || !audio) { free(latent); free(audio); if (heap_arena) free(ar); return -1; }
    int rc = snt_front_q8_latent(fq, ids, durs, n_ids, frames, latent, ar, la);
    if (rc == 0)
        rc = snt_piperlite_q8_synthesize(dq, latent, (int)frames, audio, ar, da);
    if (heap_arena) free(ar);
    if (rc == 0) {
        long n = (long)frames * SNT_PIPERLITE_Q8_HOP;
        for (long i = 0; i < n; i++) {
            float s = audio[i];
            if (s > 1.0f) s = 1.0f;
            else if (s < -1.0f) s = -1.0f;
            int16_t v = (int16_t)(s * 32767.0f);
            if (fwrite(&v, sizeof v, 1, sink->fh) != 1) { rc = -1; break; }
            sink->n++;
        }
    }
    free(latent);
    free(audio);
    if (rc != 0) {
        fprintf(stderr, "{\"error\": \"pq8 synth rc %d\"}\n", rc);
        fflush(stderr);
        return rc;
    }
    *emitted += sink->n - before;
    return 0;
}

/* extract "input" and "output" string values from a flat JSON object line;
 * unescapes the common escapes in place. */
static int json_fields(char *line, char **input, char **output) {
    *input = NULL; *output = NULL;
    char *cursor = line;
    while ((cursor = strchr(cursor, '"')) != NULL) {
        char *key = cursor + 1;
        char *kend = strchr(key, '"');
        if (!kend) break;
        *kend = 0;
        char *rest = kend + 1;
        while (*rest == ' ' || *rest == ':') rest++;
        if (*rest != '"') { cursor = rest; continue; }
        rest++;
        char *out = rest, *r = rest;
        while (*r && *r != '"') {
            if (*r == '\\' && r[1]) {
                r++;
                switch (*r) {
                case 'n': *out++ = '\n'; break;
                case 't': *out++ = '\t'; break;
                case 'r': *out++ = '\r'; break;
                default: *out++ = *r;
                }
                r++;
            } else *out++ = *r++;
        }
        if (*r != '"') { cursor = kend + 1; continue; }
        *out = 0;
        /* accept both piper json-input key names and generic ones */
        if ((!strcmp(key, "input") || !strcmp(key, "text")) && !*input) *input = rest;
        else if ((!strcmp(key, "output") || !strcmp(key, "output_file")) && !*output) *output = rest;
        cursor = r + 1;
        if (*input && *output) return 0;
    }
    return (*input && *output) ? 0 : -1;
}

int main(int argc, char **argv) {
    const char *model = NULL;
    const char *engine = "int8";
    int rate = 0; /* resolved after arg parse: 22050 int8, 24000 nano */
    for (int i = 1; i < argc - 1; i++) {
        if (!strcmp(argv[i], "--model")) model = argv[i + 1];
        else if (!strcmp(argv[i], "--engine")) engine = argv[i + 1];
        else if (!strcmp(argv[i], "--espeak-bin")) g_espeak_bin = argv[i + 1];
        else if (!strcmp(argv[i], "--espeak-data")) g_espeak_data = argv[i + 1];
        else if (!strcmp(argv[i], "--voice")) g_voice = argv[i + 1];
        else if (!strcmp(argv[i], "--loader")) g_loader = argv[i + 1];
        else if (!strcmp(argv[i], "--loader-libdir")) g_libdir = argv[i + 1];
        else if (!strcmp(argv[i], "--comma-ms")) g_comma_ms = atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "--period-ms")) g_period_ms = atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "--rate")) rate = atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "--seed")) { g_seed = strtoull(argv[i + 1], NULL, 0); g_seed_set = 1; }
        else if (!strcmp(argv[i], "--length-scale")) g_length_scale = (float)atof(argv[i + 1]);
        else if (!strcmp(argv[i], "--pause-scale")) g_pause_scale = (float)atof(argv[i + 1]);
        else if (!strcmp(argv[i], "--native-punct")) g_native_punct = 1;
    }
    if (!strcmp(engine, "nano")) g_engine_nano = 1;
    if (!strcmp(engine, "pq8")) g_engine_pq8 = 1;
    if (!rate) rate = g_engine_nano ? 24000 : 22050;
    if (!model || (!g_engine_nano && (!g_espeak_bin || !g_espeak_data))) {
        fprintf(stderr, "usage: %s --model <dir> --engine int8|pq8|nano [--espeak-bin <bin> --espeak-data <dir>] [--rate 22050|24000] [--seed N] [--length-scale F]\n", argv[0]);
        return 2;
    }

    void *front = NULL, *dec = NULL;
    snt_front_q8_model fq;
    snt_piperlite_q8_model dq;
    if (g_engine_pq8) {
        /* The metas must outlive the models (the fp32 pool is read in
         * place), so these allocations are simply never freed. */
        size_t fq_meta_nb, fq_w_nb, dq_meta_nb, dq_w_nb;
        void *fq_meta = xload2s(model, "front_meta_q8.bin", &fq_meta_nb);
        void *fq_w = xload2s(model, "front_weights_q8.bin", &fq_w_nb);
        void *dq_meta = xload2s(model, "meta_q8.bin", &dq_meta_nb);
        void *dq_w = xload2s(model, "weights_q8.bin", &dq_w_nb);
        int rc = snt_front_q8_init(&fq, fq_meta, fq_meta_nb, (const int8_t *)fq_w, fq_w_nb);
        if (rc == 0) rc = snt_piperlite_q8_init(&dq, dq_meta, dq_meta_nb, (const int8_t *)dq_w, dq_w_nb);
        if (rc != 0) { fprintf(stderr, "{\"error\": \"pq8 init rc %d\"}\n", rc); return 1; }
    } else {
        front = xload2(model, "front_q8.bin");
        dec = xload2(model, "model_q8.bin");
    }

    static unsigned char arena[16 * 1024 * 1024] __attribute__((aligned(16)));
    int32_t *ids = malloc((size_t)MAX_IDS * 4);
    WavSink sink;

    char line[16384];
    while (fgets(line, sizeof line, stdin)) {
        char *input = NULL, *output = NULL;
        if (json_fields(line, &input, &output) != 0) {
            fprintf(stderr, "{\"error\": \"bad line\"}\n");
            fflush(stderr);
            continue;
        }

        /* split into clauses at punctuation; each clause is phonemized and
         * synthesized separately, with a silence gap after it sized by the
         * punctuation that ended it. --native-punct skips the splitting:
         * the whole line is one synthesis and the punctuation mark ids
         * carry the pauses and contours themselves. */
        char clauses[64][4096];
        int clause_ms[64];
        char clause_punct[64];
        int n_clauses = 0;
        if (g_native_punct && !g_engine_nano) {
            snprintf(clauses[0], sizeof clauses[0], "%s", input);
            clauses[0][sizeof clauses[0] - 1] = 0;
            clause_ms[0] = 0;
            clause_punct[0] = 0; /* punctuation ids are already in the stream */
            n_clauses = 1;
        } else {
            char cur[4096]; int cur_n = 0;
            const char *p = input;
            while (*p && n_clauses < 64) {
                unsigned char c = (unsigned char)*p;
                if (c == '.' || c == ',' || c == '?' || c == '!' || c == ':' || c == ';') {
                    if (cur_n > 0) {
                        cur[cur_n] = 0;
                        memcpy(clauses[n_clauses], cur, (size_t)cur_n + 1);
                        clause_ms[n_clauses] =
                            c == ',' ? g_comma_ms :
                            c == ':' ? g_colon_ms :
                            c == ';' ? g_semi_ms : g_period_ms;
                        clause_punct[n_clauses] = (char)c;
                        n_clauses++;
                        cur_n = 0;
                    }
                    p++;
                    continue;
                }
                if (cur_n < 4090) cur[cur_n++] = (char)c;
                p++;
            }
            if (cur_n > 0 && n_clauses < 64) {
                cur[cur_n] = 0;
                memcpy(clauses[n_clauses], cur, (size_t)cur_n + 1);
                clause_ms[n_clauses] = 0; /* final clause: plugin adds its own gap */
                clause_punct[n_clauses] = 0;
                n_clauses++;
            }
        }
        if (n_clauses == 0) {
            fprintf(stderr, "{\"error\": \"empty input\"}\n");
            fflush(stderr);
            continue;
        }

        FILE *fh = fopen(output, "wb");
        if (!fh) { fprintf(stderr, "{\"error\": \"cannot write %s\"}\n", output); fflush(stderr); continue; }
        write_header(fh, 0, (uint32_t)rate);
        sink.fh = fh; sink.n = 0;

        long total_ms = 0;
        int rc_all = 0;
        for (int ci = 0; ci < n_clauses; ci++) {
            int rc = 0, spoke = 0;
            long emitted = 0;
            if (g_engine_nano) {
                rc = synth_clause_nano(front, dec, arena, sizeof arena, clauses[ci], &sink, &emitted);
                spoke = emitted > 0;
            } else {
                int n_ids;
                if (g_native_punct) {
                    n_ids = text_to_ids_native(clauses[ci], ids);
                } else {
                    int pid = -1;
                    if (clause_punct[ci]) {
                        char sym[2] = { clause_punct[ci], 0 };
                        pid = map_id(sym);
                    }
                    n_ids = text_to_ids(clauses[ci], ids, pid);
                }
                if (n_ids > 3) {
                    if (g_engine_pq8) {
                        rc = synth_clause_pq8(&fq, &dq, arena, sizeof arena, ids, n_ids, &sink, &emitted);
                        spoke = emitted > 0;
                    } else {
                        snt_config cfg = {front, dec, arena, sizeof arena, NULL};
                        snt_stats st;
                        rc = snt_synthesize(&cfg, ids, n_ids, wav_cb, &sink, &st);
                        spoke = 1;
                    }
                }
            }
            if (rc != 0) { rc_all = rc; break; }
            if (spoke && ci < n_clauses - 1 && clause_ms[ci] > 0) {
                int gap = rate * clause_ms[ci] / 1000;
                static const int16_t zero;
                for (int s = 0; s < gap; s++) fwrite(&zero, 2, 1, fh);
                sink.n += gap;
            }
        }

        long data_bytes = sink.n * 2;
        fseek(fh, 0, SEEK_SET);
        write_header(fh, (uint32_t)data_bytes, (uint32_t)rate);
        fclose(fh);

        printf("%s\n", output);
        fflush(stdout);
        if (rc_all != 0) { fprintf(stderr, "{\"error\": \"synth rc %d\"}\n", rc_all); fflush(stderr); }
        (void)total_ms;
    }
    return 0;
}
