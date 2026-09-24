/* ゴールデンテスト: C99 コアが参照実装（PyTorch）と一致するか
 *
 * 受け入れ条件（計画書 §Phase D）: **fp 参照との Pearson 相関 0.98 以上**。
 * ここではそれに加えて各段の SNR も出す。**どの段でずれ始めたか**が分かるようにする。
 *
 *   cc -std=c99 -O2 -o golden_test golden_test.c saanotts.c -lm
 *   ./golden_test student.bin golden.bin
 */
#include "saanotts.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void *slurp(const char *path, size_t *size) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "開けない: %s\n", path); exit(1); }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    void *b = malloc((size_t)n);
    if (fread(b, 1, (size_t)n, f) != (size_t)n) { fprintf(stderr, "読めない\n"); exit(1); }
    fclose(f);
    *size = (size_t)n;
    return b;
}

typedef struct { double snr_db, pearson, max_abs; size_t n, n_bad; } cmp_t;

static cmp_t compare(const float *a, const float *b, size_t n) {
    double sa = 0, sb = 0;
    for (size_t i = 0; i < n; ++i) { sa += a[i]; sb += b[i]; }
    const double ma = sa / (double)n, mb = sb / (double)n;
    double num = 0, da = 0, db = 0, sig = 0, err = 0, mx = 0;
    size_t nbad = 0;
    for (size_t i = 0; i < n; ++i) {
        if (!isfinite(a[i]) || !isfinite(b[i])) ++nbad;
        const double xa = a[i] - ma, xb = b[i] - mb;
        num += xa * xb; da += xa * xa; db += xb * xb;
        sig += (double)b[i] * b[i];
        const double e = (double)a[i] - (double)b[i];
        err += e * e;
        if (fabs(e) > mx) mx = fabs(e);
    }
    cmp_t c;
    c.n = n;
    c.n_bad = nbad;
    /* ⚠️ **NaN を「完全一致」と読ませない。** 素直に書くと落とし穴がある:
     *   - `err` が NaN なら `err > 0` は **false** なので INFINITY 分岐に落ちる
     *   - `da` / `db` が NaN なら `da > 0 && db > 0` も false なので pearson = 1.0 になる
     * つまり **出力に NaN が 1 つでも混じると「Pearson 1.000000 / SNR inf」で PASS する**。
     * 実際に踏んだ: 重みを 4 バイト壊した blob で `SNR inf dB / max|Δ| 1.684e-03` が出て通った
     * （`fabs(NaN) > mx` も false なので max|Δ| は NaN 以外の最大値のまま残り、矛盾に見える）。
     * 非有限を数えて別に落とす。 */
    c.pearson = (da > 0 && db > 0) ? num / sqrt(da * db) : 1.0;
    c.snr_db = err > 0 ? 10.0 * log10(sig / err) : (err == 0 ? INFINITY : NAN);
    c.max_abs = mx;
    return c;
}

static const float *get(const saan_weights *g, const char *name, uint64_t *nb) {
    uint32_t dt;
    const void *p = saan_tensor(g, name, &dt, NULL, nb);
    if (!p) { fprintf(stderr, "golden に %s が無い\n", name); exit(1); }
    return (const float *)p;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s student.bin golden.bin\n", argv[0]); return 2; }
    size_t wsz, gsz;
    void *wbuf = slurp(argv[1], &wsz), *gbuf = slurp(argv[2], &gsz);

    saan_weights W, G;
    saan_status s = saan_weights_open(&W, wbuf, wsz);
    if (s != SAAN_OK) { fprintf(stderr, "重み: %s\n", saan_strerror(s)); return 1; }
    s = saan_weights_open(&G, gbuf, gsz);
    if (s != SAAN_OK) { fprintf(stderr, "golden: %s\n", saan_strerror(s)); return 1; }

    uint64_t nb;
    const float *ids_f = get(&G, "in.ids", &nb);
    const int n_ids = (int)(nb / sizeof(float));
    int32_t *ids = malloc(sizeof(int32_t) * (size_t)n_ids);
    for (int i = 0; i < n_ids; ++i) ids[i] = (int32_t)ids_f[i];

    const size_t need = saan_arena_needed(n_ids);
    void *abuf = malloc(need);
    saan_arena A;
    saan_arena_init(&A, abuf, need);
    printf("入力 %d ids / arena %.2f MB を確保\n", n_ids, (double)need / 1048576.0);

    saan_output out;
    s = saan_synthesize(&W, &A, ids, n_ids, SAAN_S_V, &out);
    if (s != SAAN_OK) { fprintf(stderr, "合成: %s\n", saan_strerror(s)); return 1; }
    printf("arena 実使用 %.2f MB / %d frames / %d sample (%.3f s)\n\n",
           (double)A.used / 1048576.0, out.n_frames, out.n_samples,
           (double)out.n_samples / SAAN_SR);

    int bad = 0;

    /* d̂ は整数なので完全一致を要求する（1 個ずれるとフレーム数が変わる） */
    const float *g_d = get(&G, "out.d_hat", &nb);
    int d_mismatch = 0;
    for (int i = 0; i < n_ids; ++i)
        if ((int32_t)g_d[i] != out.d_hat[i]) ++d_mismatch;
    printf("  %s d_hat 完全一致           %d/%d\n",
           d_mismatch ? "NG!" : "OK ", n_ids - d_mismatch, n_ids);
    bad += d_mismatch != 0;
    if (d_mismatch) {
        printf("      ⚠️ フレーム数が変わるので以降の比較は意味を持たない\n");
        for (int i = 0; i < n_ids && d_mismatch; ++i)
            if ((int32_t)g_d[i] != out.d_hat[i]) {
                printf("      最初のずれ: i=%d 参照 %d / C %d\n",
                       i, (int)g_d[i], out.d_hat[i]);
                break;
            }
    }

    /* ⚠️ Pearson だけで判定してはいけない。Pearson はスケールとオフセットに
     * 不変なので、層を 1 つ落としても 0.98 を超えることがある（検証で実証済み）。
     * SNR を必ず併せて見る。しきい値は「桁が違えば落ちる」水準に置く。 */
    struct { const char *name; const float *got; size_t n; double min_r; double min_snr; } chk[] = {
        {"out.log_d", out.log_d, (size_t)n_ids, 0.98, 40.0},
        {"out.c", out.c, (size_t)SAAN_CDIM * out.n_frames, 0.98, 40.0},
        {"out.pcm", out.pcm, (size_t)out.n_samples, 0.98, 40.0},
    };
    for (size_t i = 0; i < sizeof chk / sizeof chk[0]; ++i) {
        const float *ref = get(&G, chk[i].name, &nb);
        const size_t rn = nb / sizeof(float);
        if (rn != chk[i].n) {
            printf("  NG! %-24s 要素数が違う 参照 %zu / C %zu\n",
                   chk[i].name, rn, chk[i].n);
            ++bad;
            continue;
        }
        cmp_t c = compare(chk[i].got, ref, rn);
        const int ok_r = c.pearson >= chk[i].min_r;
        const int ok_s = c.snr_db >= chk[i].min_snr;   /* NaN >= x は false なのでここで落ちる */
        const int ok = ok_r && ok_s && c.n_bad == 0;
        bad += !ok;
        printf("  %s %-24s Pearson %.6f  SNR %7.2f dB  max|Δ| %.3e  n=%zu%s\n",
               ok ? "OK " : "NG!", chk[i].name, c.pearson, c.snr_db, c.max_abs, rn,
               ok ? "" : (c.n_bad ? "  ← 非有限（NaN / inf）を含む"
                                  : (!ok_r ? "  ← Pearson 不足" : "  ← SNR 不足")));
        if (c.n_bad)
            printf("      非有限 %zu / %zu 要素（**NaN は Pearson 1.0 / SNR inf に化ける**）\n",
                   c.n_bad, rn);
    }

    /* --- 陽性対照（毎回走る）------------------------------------------------
     * ⚠️ **この比較器は一度、NaN を「完全一致」と報告して通していた**（C-056）。
     * `err > 0` / `da > 0 && db > 0` という「正常なら真」の条件で分岐していたので、
     * NaN は全部 else 側（= 一致）に落ちていた。**同じ壊れ方に戻っていないか毎回見る。**
     * 実データを 1 要素だけ壊した複製を作り、比較器が**落とすこと**を確かめる。 */
    {
        const size_t n = (size_t)out.n_samples;
        float *probe = (float *)malloc(sizeof(float) * n);
        int pc_bad = 0;
        if (!probe) {
            printf("  NG! 陽性対照: 作業領域が取れない\n");
            ++bad;
        } else {
            const float *ref_pcm = get(&G, "out.pcm", &nb);
            memcpy(probe, out.pcm, sizeof(float) * n);
            probe[n / 2] = (float)NAN;              /* (1) NaN を 1 つ混ぜる */
            cmp_t cn = compare(probe, ref_pcm, n);
            const int caught_nan = !(cn.pearson >= 0.98 && cn.snr_db >= 40.0 && cn.n_bad == 0);
            memcpy(probe, out.pcm, sizeof(float) * n);
            for (size_t i = 0; i < n; ++i) probe[i] *= 0.5f;   /* (2) 半分に潰す */
            cmp_t ch = compare(probe, ref_pcm, n);
            /* ⚠️ Pearson はスケール不変なので 1.0 のまま。**SNR で落ちなければ空虚**。 */
            const int caught_half = !(ch.snr_db >= 40.0);
            pc_bad = !(caught_nan && caught_half);
            printf("  %s 陽性対照: NaN 1 個 → %s / 振幅 0.5 倍 → %s（C-056）\n",
                   pc_bad ? "NG!" : "OK ",
                   caught_nan ? "落ちる" : "**通ってしまう**",
                   caught_half ? "落ちる" : "**通ってしまう**");
            bad += pc_bad;
            free(probe);
        }
    }

    printf("\n%s\n", bad ? "一致しない項目がある"
                          : "参照実装と一致（Pearson >= 0.98 かつ SNR >= 40 dB）");
    free(wbuf); free(gbuf); free(abuf); free(ids);
    return bad ? 1 : 0;
}
