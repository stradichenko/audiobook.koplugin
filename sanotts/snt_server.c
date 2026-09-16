/* snt_server.c -- sanoTTS int8 engine server for audiobook.koplugin.
 * Piper-shaped line protocol on stdin: {"input": "text", "output": "path.wav"}
 * per line; synthesizes and prints {"wav": "path", "samples": N}.
 *
 * Phonemization: the bundled espeak-ng binary (per-sentence spawn) produces IPA,
 * then piper's phoneme_id_map (phoneme_id_map.h) with BOS/PAD/EOS framing,
 * matching piper.phoneme_ids.phonemes_to_ids exactly.
 *
 * Usage: snt_server --model <dir> --espeak-bin <espeak-ng-binary>
 *                   --espeak-data <dir> [--voice en-us] [--rate 22050]
 *                   [--loader <ld-linux>] [--loader-libdir <dir>]
 *                   [--comma-ms N] [--period-ms N]
 * The loader args exec the bundled armhf espeak-ng through the bundled
 * glibc loader on stock Kobo rootfs; the gap args size the silence
 * inserted after comma/period clauses (defaults 150/350 ms; colon 220,
 * semicolon 250).
 * Sources: sanoTTS mcu core (MIT), server written for the audiobook.koplugin spike. */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "snt_tts.h"
#include "phoneme_id_map.h"

#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/wait.h>

#define BOS_ID 1
#define EOS_ID 2
#define PAD_ID 0
#define MAX_IDS 1024

static void *xload2(const char *dir, const char *name) {
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

/* text -> piper phoneme ids: [BOS, PAD, (id, PAD)*, EOS] via espeak-ng IPA */
static int text_to_ids(const char *text, int32_t *ids) {
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
    if (n > MAX_IDS - 1) n = MAX_IDS - 1;
    ids[n++] = EOS_ID;
    return n;
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
    int rate = 22050;
    for (int i = 1; i < argc - 1; i++) {
        if (!strcmp(argv[i], "--model")) model = argv[i + 1];
        else if (!strcmp(argv[i], "--espeak-bin")) g_espeak_bin = argv[i + 1];
        else if (!strcmp(argv[i], "--espeak-data")) g_espeak_data = argv[i + 1];
        else if (!strcmp(argv[i], "--voice")) g_voice = argv[i + 1];
        else if (!strcmp(argv[i], "--loader")) g_loader = argv[i + 1];
        else if (!strcmp(argv[i], "--loader-libdir")) g_libdir = argv[i + 1];
        else if (!strcmp(argv[i], "--comma-ms")) g_comma_ms = atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "--period-ms")) g_period_ms = atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "--rate")) rate = atoi(argv[i + 1]);
    }
    if (!model || !g_espeak_bin || !g_espeak_data) {
        fprintf(stderr, "usage: %s --model <dir> --espeak-bin <bin> --espeak-data <dir> [--voice en-us] [--rate 22050]\n", argv[0]);
        return 2;
    }

    void *front = xload2(model, "front_q8.bin");
    void *dec = xload2(model, "model_q8.bin");

    static unsigned char arena[4 * 1024 * 1024] __attribute__((aligned(16)));
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
         * punctuation that ended it. */
        char clauses[64][4096];
        int clause_ms[64];
        int n_clauses = 0;
        {
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
            int n_ids = text_to_ids(clauses[ci], ids);
            if (n_ids <= 3) continue;
            snt_config cfg = {front, dec, arena, sizeof arena, NULL};
            snt_stats st;
            int rc = snt_synthesize(&cfg, ids, n_ids, wav_cb, &sink, &st);
            if (rc != 0) { rc_all = rc; break; }
            if (ci < n_clauses - 1 && clause_ms[ci] > 0) {
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
