/* K-1 辞書バイナリの読み出しと K-2 の Viterbi。詳細は jdict.h。
 *
 * ⚠️ 実装で必ず踏む落とし穴（K-1 §9-3 / §9-4。全部実際に踏んだ）:
 *   - 遷移コストの索引は flat[rc_prev + lsize*lc_cur]。
 *     MeCab 本家の式 (lcAttr + lsize*rcAttr) では**この辞書に合わない**（一致 0.91%）
 *   - LOUDS の子ノード番号は rank1(p)。rank1(p+1) にすると落ちずに
 *     **全部 1 文字に分割される**
 *   - 位置ごとに 1 本だけ最良経路を残すのは Viterbi ではない。
 *     同じ位置で終わるノードでも rc が違えば後続コストが変わるので、
 *     **ノードごと**に最良の前任を持つ
 */
#include "jdict.h"
#include <stdio.h>
#include <string.h>

#define SUPER_BITS   256u
#define BLOCK_BITS    64u
#define SELECT_STEP  512u
#define CHECKPOINT    32u
#define TERM_CHECKPOINT 512u
#define REC_SIZE       9u
#define REC5_SIZE      5u        /* `rec5`（M-107 §4a）*/
#define BOS_RC         0u
#define EOS_LC         0u
#define COST_INF   0x3FFFFFFF

static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16)
           | ((uint32_t)p[3] << 24);
}
static uint16_t rd16(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

/* レコード 1 件を展開する。**`records`(9 B) と `rec5`(5 B) の唯一の差はここ**（M-107 §4a）。
 * ⚠️ **読み口ごとに展開を書かない。** char の 916 行を直し忘れて未知語生成を殺した
 *    のと同じ形になる（M-107 §1）。**必ずこの 1 関数を通す。**
 * NULL を渡した出力は書かない。 */
static void rec_unpack(const jdict_t *d, uint32_t entry,
                       uint16_t *cid, int16_t *wcost, uint8_t *pl, uint8_t *el) {
    const uint8_t *r;
    if (d->rec5) {
        r = d->records + (size_t)entry * REC5_SIZE;
        uint16_t packed = rd16(r + 2);
        if (cid)   *cid   = (uint16_t)(packed & 0x0FFFu);
        if (wcost) *wcost = (int16_t)rd16(r);
        if (pl)    *pl    = (uint8_t)(((packed >> 12) & 0x0Fu) | ((r[4] & 1u) << 4));
        if (el)    *el    = (uint8_t)((r[4] >> 1) & 0x3Fu);
    } else {
        r = d->records + (size_t)entry * REC_SIZE;
        if (cid)   *cid   = rd16(r);
        if (wcost) *wcost = (int16_t)rd16(r + 2);
        if (pl)    *pl    = r[7];
        if (el)    *el    = r[8];
    }
}

/* chain ID と flags。`rec5` では classes 表の末尾 2 B に入っている。 */
static void rec_chain_flags(const jdict_t *d, uint32_t entry, uint16_t cid,
                            uint16_t *chid, uint8_t *flags) {
    if (d->rec5) {
        const uint8_t *c = d->classes + d->cls_stride * cid;
        *chid  = c[8];
        *flags = c[9];
    } else {
        const uint8_t *r = d->records + (size_t)entry * REC_SIZE;
        *chid  = rd16(r + 4);
        *flags = r[6];
    }
}

/* 入力検査（M-100）。⚠️ **JDICT_TEST_WEAK=1 で全部消える** —
 * `csrc/jdict_hard_test.c` の陽性対照が「検査を外すと壊れた blob が通る」ことを示すため。 */
#if defined(JDICT_TEST_WEAK) && JDICT_TEST_WEAK
#define JD_CHECK(cond, err)  ((void)0)
#else
#define JD_CHECK(cond, err)  do { if (!(cond)) return (err); } while (0)
#endif

/* ---------------------------------------------------------------- 区画 */

struct sec { const uint8_t *p; uint32_t len; };

static int find_sec(const uint8_t *blob, size_t n, const char *name, struct sec *out) {
    if (n < 8) return -1;
    uint16_t n_sec = rd16(blob + 6);
    for (uint16_t i = 0; i < n_sec; i++) {
        const uint8_t *e = blob + 8 + 16u * i;
        if ((size_t)(e - blob) + 16 > n) return -1;
        char nm[9]; memcpy(nm, e, 8); nm[8] = 0;
        if (strcmp(nm, name) == 0) {
            uint32_t off = rd32(e + 8), len = rd32(e + 12);
            /* ⚠️ **64 bit で足す。** ESP32 の size_t は 32 bit なので、
             *    off + len が巻き戻ると「blob の中」に見えてしまう。 */
            if ((uint64_t)off + len > (uint64_t)n) return -1;
            out->p = blob + off; out->len = len; return 0;
        }
    }
    return -1;
}

/* セクション表を**丸ごと**検査し、実 extent（= max(off+len)）を返す。
 *
 * ⚠️ **find_sec だけでは足りない。** あれは「引いたセクション」しか見ないので、
 *    引かないセクションが blob の外を指していても気づかない。
 * ⚠️ **`n` は上限であって長さではない**（端末はパーティション長を渡す）。
 *    ここで実 extent に絞り込むことで、焼き損ねた領域（0xFF）を読む窓を狭める。 */
#if !defined(JDICT_TEST_WEAK) || !JDICT_TEST_WEAK
static int scan_sectab(const uint8_t *blob, size_t n, size_t *end_out) {
    if (n < 8) return -1;
    uint16_t n_sec = rd16(blob + 6);
    if (n_sec == 0) return -1;
    uint64_t head = 8u + 16ull * n_sec;
    if (head > (uint64_t)n) return -1;
    uint64_t end = head;
    for (uint16_t i = 0; i < n_sec; i++) {
        const uint8_t *e = blob + 8 + 16u * i;
        uint32_t off = rd32(e + 8), len = rd32(e + 12);
        if ((uint64_t)off < head) return -1;            /* 表そのものに重なっている */
        if ((uint64_t)off + len > (uint64_t)n) return -1;
        if ((uint64_t)off + len > end) end = (uint64_t)off + len;
    }
    *end_out = (size_t)end;
    return 0;
}
#endif

int jdict_open(jdict_t *d, const uint8_t *blob, size_t n) {
    struct sec s;
    /* 相互検証に使うセクション長（フィールドを増やさずここで受ける）。 */
    uint32_t records_len = 0, surfck_len = 0, poolck_len = 0, termck_len = 0;
    memset(d, 0, sizeof *d);
    if (n < 8 || memcmp(blob, "K1D1", 4) != 0) return -1;
    /* version. ⚠️ 2 で poolck / termck が入った（K-6）。1 も読める。 */
    uint16_t ver = rd16(blob + 4);
    if (ver != 1 && ver != 2) return JDICT_ERR_VERSION;
    d->blob = blob;
    /* ⚠️ **セクション表を先に丸ごと検査する。** 通ったら blob_len は
     *    渡された n ではなく**実 extent**（M-100）。 */
    d->blob_len = n;
#if !defined(JDICT_TEST_WEAK) || !JDICT_TEST_WEAK
    {
        size_t end = 0;
        if (scan_sectab(blob, n, &end) != 0) return JDICT_ERR_SECTAB;
        d->blob_len = end;
    }
#endif

    if (find_sec(blob, d->blob_len, "louds", &s) != 0) return -3;
    /* ⚠️ **ヘッダを読む前に長さを見る。** かつては `s.len` を一度も参照せず、
     *    宣言長 4 のセクションから 20 B のヘッダを読んでいた（jdict_open は 0 を返す）。 */
    JD_CHECK(s.len >= 20u, -3);
    d->louds_bitlen = rd32(s.p);
    d->n_nodes      = rd32(s.p + 4);
    uint32_t n_sup  = rd32(s.p + 8), n_blk = rd32(s.p + 12), n_sel = rd32(s.p + 16);
    /* 導出した末尾がセクションに収まるか。64 bit で足す（各項は uint32 で、和が溢れうる）。 */
    JD_CHECK(20ull + ((uint64_t)d->louds_bitlen + 7) / 8 + d->n_nodes
             + ((uint64_t)d->n_nodes + 7) / 8 + n_sup + n_blk + n_sel <= (uint64_t)s.len, -3);
    const uint8_t *q = s.p + 20;
    d->louds_bits = q; q += (d->louds_bitlen + 7) / 8;
    d->labels     = q; q += d->n_nodes;
    d->term_bits  = q; q += (d->n_nodes + 7) / 8;
    d->rank_sup = q; q += n_sup;
    d->rank_blk = q; q += n_blk;
    d->sel0     = q; d->n_sel0 = n_sel / 4;

    if (find_sec(blob, d->blob_len, "counts", &s) != 0) return -4;
    d->counts = s.p; d->n_surfaces = s.len;
    if (find_sec(blob, d->blob_len, "surfck", &s) != 0) return -5;
    d->surfck = s.p; surfck_len = s.len;
    /* ⚠️ **`records`(9 B) と `rec5`(5 B) はどちらか一方。** 両方あれば拒む
     *    （matrix / matrixa / matrixc と同じ流儀。M-100 / M-107 §4a）。 */
    {
        struct sec s5;
        const int has9 = (find_sec(blob, d->blob_len, "records", &s) == 0);
        const int has5 = (find_sec(blob, d->blob_len, "rec5",    &s5) == 0);
        if (has9 == has5) return -6;                    /* 両方 / どちらも無い */
        d->rec5       = has5;
        d->cls_stride = has5 ? 10u : 8u;
        if (has5) s = s5;
    }
    d->records = s.p;
    d->n_entries = s.len / (d->rec5 ? REC5_SIZE : REC_SIZE);
    records_len = s.len;
    if (find_sec(blob, d->blob_len, "pool", &s) != 0) return -7;
    d->pool = s.p; d->pool_len = s.len;
    if (find_sec(blob, d->blob_len, "classes", &s) != 0) return -8;
    JD_CHECK(s.len >= 4u, -8);
    d->n_classes = rd32(s.p);
    /* ⚠️ **符号なし減算の underflow を先に止める。** かつては下限を見ておらず、
     *    n_classes が 1 bit 壊れるだけで pos6tab_len が 2 GB になり、
     *    strtab_find が 1 B ずつ 2 GB 走った（端末なら WDT）。jdict_open は 0 を返す。 */
    JD_CHECK(4ull + (uint64_t)d->cls_stride * d->n_classes <= (uint64_t)s.len, -8);
    d->classes = s.p + 4;
    /* classes セクションは [n u32][8 B × n][pos6 の NUL 区切り表] */
    d->pos6tab = s.p + 4 + d->cls_stride * d->n_classes;
    d->pos6tab_len = s.len - 4u - d->cls_stride * d->n_classes;
    if (find_sec(blob, d->blob_len, "keytab", &s) != 0) return -9;
    d->keytab = s.p; d->keytab_len = s.len;
    if (find_sec(blob, d->blob_len, "keyesc", &s) != 0) return -10;
    d->keyesc = s.p; d->keyesc_len = s.len;
    /* K-6 で要るもの。⚠️ 無くても K-2 / K-3 は動くので **任意**にしてある
     *    （古い blob をそのまま読めるように）。 */
    if (find_sec(blob, d->blob_len, "moratab", &s) == 0) { d->moratab = s.p; d->moratab_len = s.len; }
    if (find_sec(blob, d->blob_len, "chains", &s) == 0)  { d->chaintab = s.p; d->chaintab_len = s.len; }
    if (find_sec(blob, d->blob_len, "poolck", &s) == 0)  { d->poolck = s.p; poolck_len = s.len; }
    if (find_sec(blob, d->blob_len, "termck", &s) == 0)  { d->termck = s.p; d->n_termck = s.len / 4u; termck_len = s.len; }
    if (find_sec(blob, d->blob_len, "char", &s) == 0) {
        JD_CHECK(s.len >= 4u, -13);
        d->n_char_cats = rd32(s.p);
        /* ⚠️ char も同じ underflow を持っていた（n_codepoints が 1,073,741,823 になる）。 */
        JD_CHECK(4ull + 32ull * d->n_char_cats <= (uint64_t)s.len, -13);
        d->char_names  = s.p + 4;
        d->char_info   = s.p + 4 + 32u * d->n_char_cats;
        d->n_codepoints = (s.len - 4u - 32u * d->n_char_cats) / 4u;
    }
    if (find_sec(blob, d->blob_len, "charr", &s) == 0) {
        /* charr: ncat u32 / nrun u32 / 名前 32B×ncat / 値 u32×nval / run u32×nrun
         * ⚠️ **値表の長さは残りから逆算する**（形式に持たない）。M-106 §5 */
        JD_CHECK(s.len >= 8u, -13);
        uint32_t ncat = rd32(s.p), nrun = rd32(s.p + 4);
        JD_CHECK(nrun > 0u, -13);
        JD_CHECK(8ull + 32ull * ncat + 4ull * nrun <= (uint64_t)s.len, -13);
        d->n_char_cats = ncat;
        d->char_names  = s.p + 8;
        d->n_char_runs = nrun;
        d->char_vals   = s.p + 8 + 32u * ncat;
        d->char_runs   = s.p + s.len - 4u * nrun;
        d->n_char_vals = (uint32_t)((d->char_runs - d->char_vals) / 4);
        JD_CHECK(d->n_char_vals > 0u, -13);
        /* ⚠️ **値の添字が値表に収まるか、開始位置が昇順かを開き時に見る。**
         *    `char_raw` は範囲検査なしで引くので、1 bit 壊れると表の外を読む
         *    （matrixc の rmap / cmap と同じ形）。 */
        uint32_t prev_cp = 0;
        for (uint32_t i = 0; i < nrun; i++) {
            uint32_t r = rd32(d->char_runs + 4u * i);
            JD_CHECK((r & 0xFFFu) < d->n_char_vals, -13);
            JD_CHECK(i == 0 ? ((r >> 12) == 0u) : ((r >> 12) > prev_cp), -13);
            prev_cp = r >> 12;
        }
        d->n_codepoints = 65535u;
    }
    if (find_sec(blob, d->blob_len, "unk", &s) == 0) {
        /* ⚠️ 宣言長 0 だと unk_len が 0xFFFFFFFC になっていた。 */
        JD_CHECK(s.len >= 4u, -14);
        d->n_unk = rd32(s.p);
        d->unk = s.p + 4;
        d->unk_len = s.len - 4;
    }
    /* --- 層をまたぐ相互検証（M-100 §8 の 3）------------------------------
     *
     * ⚠️ **宣言長をそのまま長さに使うセクション**（counts / surfck / records /
     *    pool / poolck / termck）は、それ単体では「正しい長さ」を持たない。
     *    **他のセクションと突き合わせて初めて矛盾が見える。**
     *    式は `scripts/check_dict_blob.py` の self_check と同じもの（定義を 2 つ持たない）。
     *
     * ⚠️ **counts を全部足さない。** 355,768 B を起動時に舐めるコストが未測定なので、
     *    `surfck` の最後のチェックポイント + 端数（最大 32 件）で同じ数を出す。
     *    これは `jdict_entry_range` が使っているのと同じ復元式。 */
    JD_CHECK(d->n_surfaces > 0u, -4);
    JD_CHECK(d->n_entries * (d->rec5 ? REC5_SIZE : REC_SIZE) == records_len, -6);
    /* ⚠️ **9 の倍数か 5 の倍数か**。出荷 blob の 3,948,750 B は
     *    **9 でも 5 でも割り切れる**ので、この検査だけでは形式の取り違えを捕まえない。
     *    捕まえるのは上の排他検査と、下の counts / poolck との突き合わせ（M-107 §4a）。 */
    {
        /* surfck / poolck / termck の長さが、それぞれの件数から計算した値と合うか */
        uint32_t want_surfck = 4u * ((d->n_surfaces + CHECKPOINT - 1u) / CHECKPOINT);
        JD_CHECK(surfck_len == want_surfck, -5);
        if (d->poolck) {
            uint32_t want = 4u * ((d->n_entries + CHECKPOINT - 1u) / CHECKPOINT);
            JD_CHECK(poolck_len == want, -15);
        }
        if (d->termck) {
            uint32_t want = 4u * ((d->n_nodes + TERM_CHECKPOINT - 1u) / TERM_CHECKPOINT);
            JD_CHECK(termck_len == want, -15);
        }
        /* records の件数が counts の合計と一致するか（O(32) で復元する） */
        uint32_t base = (d->n_surfaces - 1u) / CHECKPOINT;
        uint32_t tot = rd32(d->surfck + 4u * base);
        for (uint32_t j = base * CHECKPOINT; j < d->n_surfaces; j++) tot += d->counts[j];
        JD_CHECK(tot == d->n_entries, -6);
    }

    /* ⚠️ **matrix は必須。** かつては任意扱いで、無いと jdict_trans が
     *    `if (!d->matrix) return 0;` により**全遷移コスト 0 の Viterbi**を
     *    落ちも警告も無しに走らせていた（M-100 §2 で実測: セクション名を 1 バイト
     *    変えただけで held-out 300 文中 170 文の分割が変わり、警告は 1 つも出なかった。
     *    ⚠️ 少数文では取り方で 3/10 〜 7/10 と揺れる）。
     * ⚠️ **長さを厳密に見る。** かつては一切見ておらず、別形式のデータを int16 と
     *    して読み進めても境界検査に当たらなかった（M-100 §1: 10/10 文が 1 文字ずつに
     *    刻まれ、それでも jdict_open は 0 を返した）。 */
#if !defined(JDICT_TEST_WEAK) || !JDICT_TEST_WEAK
    /* ⚠️ **`matrix` / `matrixa` / `matrixc` はどれか 1 つ。2 つ以上あれば拒む。**
     *    黙って片方を選ぶと、焼き損ねた blob が「動くが読みだけ違う」形になる
     *    （M-100 で見た欠陥そのもの）。 */
    {
        struct sec sa, sc;
        const int has_i16 = (find_sec(blob, d->blob_len, "matrix",  &s)  == 0);
        const int has_aff = (find_sec(blob, d->blob_len, "matrixa", &sa) == 0);
        const int has_clu = (find_sec(blob, d->blob_len, "matrixc", &sc) == 0);
        /* ⚠️ **3 つのうち、ちょうど 1 つ。** 2 つ以上あると「動くが読みだけ違う」
         *    blob になる（M-100 で見た欠陥そのもの）。0 個は全遷移コスト 0 の Viterbi。 */
        if (has_i16 + has_aff + has_clu != 1) return JDICT_ERR_MATRIX;
        if (has_i16) {
            /* ⚠️ **rd16 より前に長さを見る。** find_sec は len == 0 のセクションを
             *    正常に返すので、matrix が blob の末尾にあると 4 B 越境してから拒んでいた
             *    （ASan で再現。M-100 §8）。 */
            JD_CHECK(s.len >= 4u, JDICT_ERR_MATRIX);
            uint32_t L = rd16(s.p), R = rd16(s.p + 2);
            if (L == 0 || R == 0) return JDICT_ERR_MATRIX;
            /* 64 bit で組む（2*65535*65535 は uint32 に入らない）。 */
            if ((uint64_t)s.len != 4ull + 2ull * L * R) return JDICT_ERR_MATRIX;
            d->lsize = (uint16_t)L; d->rsize = (uint16_t)R;
            d->matrix = (const int16_t *)(const void *)(s.p + 4);
        } else if (has_aff) {
            /* matrixa: lsize u16 / rsize u16 / bits u16 / reserved u16
             *          / lo i16[rsize] / span u16[rsize] / q u8[lsize*rsize] */
            JD_CHECK(sa.len >= 8u, JDICT_ERR_MATRIX);
            uint32_t L = rd16(sa.p), R = rd16(sa.p + 2), bits = rd16(sa.p + 4);
            if (L == 0 || R == 0) return JDICT_ERR_MATRIX;
            if (bits != 8u) return JDICT_ERR_MATRIX;       /* 未知の量子化幅 */
            if ((uint64_t)sa.len != 8ull + 4ull * R + (uint64_t)L * R)
                return JDICT_ERR_MATRIX;
            d->lsize = (uint16_t)L; d->rsize = (uint16_t)R;
            d->matrix_lo   = (const int16_t  *)(const void *)(sa.p + 8);
            d->matrix_span = (const uint16_t *)(const void *)(sa.p + 8 + 2u * R);
            d->matrix_q    = sa.p + 8u + 4u * R;
        } else {
            /* matrixc: lsize u16 / rsize u16 / bits u16 / kr u16 / kc u16 / reserved u16
             *          / lo i16[kr] / span u16[kr] / q u8[kr*kc]
             *          / rmap u16[rsize] / cmap u16[lsize]      （M-106 §2） */
            /* ⚠️ **rd16 より前に長さを見る。** matrixa と同じ理由（M-100 §8）。
             *    ⚠️ `if` で書く。`JD_CHECK` は WEAK ビルドで `((void)0)` になり、
             *    直後の宣言より前に文が来て C99 でコンパイルが通らない（1 回踏んだ）。 */
            if (sc.len < 12u) return JDICT_ERR_MATRIX;
            uint32_t L = rd16(sc.p), R = rd16(sc.p + 2), bits = rd16(sc.p + 4);
            uint32_t kr = rd16(sc.p + 6), kc = rd16(sc.p + 8);
            if (L == 0 || R == 0 || kr == 0 || kc == 0) return JDICT_ERR_MATRIX;
            if (bits != 8u) return JDICT_ERR_MATRIX;       /* 未知の量子化幅 */
            /* ⚠️ **クラスタ数が寸法を超えていないか。** 超えていると rmap / cmap が
             *    代表行列の外を指しうる（値だけでは気づけない）。 */
            if (kr > R || kc > L) return JDICT_ERR_MATRIX;
            if ((uint64_t)sc.len != 12ull + 4ull * kr + (uint64_t)kr * kc
                                    + 2ull * R + 2ull * L)
                return JDICT_ERR_MATRIX;
            d->lsize = (uint16_t)L; d->rsize = (uint16_t)R;
            d->matrix_kr = (uint16_t)kr; d->matrix_kc = (uint16_t)kc;
            d->matrix_lo   = (const int16_t  *)(const void *)(sc.p + 12);
            d->matrix_span = (const uint16_t *)(const void *)(sc.p + 12 + 2u * kr);
            d->matrix_q    = sc.p + 12u + 4u * kr;
            d->matrix_rmap = (const uint16_t *)(const void *)(sc.p + 12u + 4u * kr + kr * kc);
            d->matrix_cmap = (const uint16_t *)(const void *)
                             (sc.p + 12u + 4u * kr + kr * kc + 2u * R);
            /* ⚠️ **写像の値域を開き時に見る。** `jdict_trans` は範囲検査なしで引くので、
             *    1 bit 壊れると代表行列の外を読む（matrixa の classes 検査と同じ形）。 */
            for (uint32_t i = 0; i < R; i++)
                JD_CHECK(rd16((const uint8_t *)(const void *)(d->matrix_rmap + i)) < kr,
                         JDICT_ERR_MATRIX);
            for (uint32_t i = 0; i < L; i++)
                JD_CHECK(rd16((const uint8_t *)(const void *)(d->matrix_cmap + i)) < kc,
                         JDICT_ERR_MATRIX);
        }
    }
    /* M-100 §8 の 4: エントリの lc / rc が行列の寸法に収まるか。
     * ⚠️ **誰も見ていなかった。** `jdict_trans` は `matrix[rc_prev + lsize*lc_cur]` を
     *    範囲検査なしで引くので、classes が 1 bit 壊れると行列の外を読む。
     * ⚠️ **classes は 5,299 件**（438,750 entries の実辞書）なので開き時 1 周は安い。 */
    for (uint32_t ci = 0; ci < d->n_classes; ci++) {
        const uint8_t *c = d->classes + d->cls_stride * ci;
        JD_CHECK(rd16(c) < d->rsize && rd16(c + 2) < d->lsize, JDICT_ERR_MATRIX);
    }
#else
    if (find_sec(blob, n, "matrix", &s) == 0) {
        d->lsize = rd16(s.p); d->rsize = rd16(s.p + 2);
        d->matrix = (const int16_t *)(const void *)(s.p + 4);
    } else if (find_sec(blob, n, "matrixa", &s) == 0) {
        uint32_t R = rd16(s.p + 2);
        d->lsize = rd16(s.p); d->rsize = (uint16_t)R;
        d->matrix_lo   = (const int16_t  *)(const void *)(s.p + 8);
        d->matrix_span = (const uint16_t *)(const void *)(s.p + 8 + 2u * R);
        d->matrix_q    = s.p + 8u + 4u * R;
    } else if (find_sec(blob, n, "matrixc", &s) == 0) {
        uint32_t L = rd16(s.p), R = rd16(s.p + 2);
        uint32_t kr = rd16(s.p + 6), kc = rd16(s.p + 8);
        d->lsize = (uint16_t)L; d->rsize = (uint16_t)R;
        d->matrix_kr = (uint16_t)kr; d->matrix_kc = (uint16_t)kc;
        d->matrix_lo   = (const int16_t  *)(const void *)(s.p + 12);
        d->matrix_span = (const uint16_t *)(const void *)(s.p + 12 + 2u * kr);
        d->matrix_q    = s.p + 12u + 4u * kr;
        d->matrix_rmap = (const uint16_t *)(const void *)(s.p + 12u + 4u * kr + kr * kc);
        d->matrix_cmap = (const uint16_t *)(const void *)
                         (s.p + 12u + 4u * kr + kr * kc + 2u * R);
    }
#endif
    return 0;
}

/* ---------------------------------------------------------------- 鍵 */

/* NUL 区切りの表から idx 番目の項目を探す。見つからなければ -1。 */
static int strtab_find(const uint8_t *tab, uint32_t len,
                       const uint8_t *item, uint32_t item_len) {
    uint32_t i = 0; int idx = 0;
    while (i < len) {
        uint32_t j = i;
        while (j < len && tab[j]) j++;
        if (j - i == item_len && memcmp(tab + i, item, item_len) == 0) return idx;
        idx++; i = j + 1;
    }
    return -1;
}

static uint32_t utf8_len(uint8_t c) {
    if (c < 0x80) return 1;
    if ((c & 0xE0) == 0xC0) return 2;
    if ((c & 0xF0) == 0xE0) return 3;
    return 4;
}

static uint32_t utf8_cp(const uint8_t *p, uint32_t n) {
    if (n == 1) return p[0];
    if (n == 2) return (uint32_t)((p[0] & 0x1F) << 6) | (uint32_t)(p[1] & 0x3F);
    if (n == 3) return (uint32_t)((p[0] & 0x0F) << 12)
                     | (uint32_t)((p[1] & 0x3F) << 6) | (uint32_t)(p[2] & 0x3F);
    return (uint32_t)((p[0] & 0x07) << 18) | (uint32_t)((p[1] & 0x3F) << 12)
         | (uint32_t)((p[2] & 0x3F) << 6) | (uint32_t)(p[3] & 0x3F);
}

int jdict_encode_key(const jdict_t *d, const uint8_t *u, size_t n,
                  uint8_t *out, size_t *out_n) {
    size_t o = 0, i = 0;
    while (i < n) {
        uint32_t cl = utf8_len(u[i]);
        if (i + cl > n) return -1;
        int id = strtab_find(d->keytab, d->keytab_len, u + i, cl);
        if (id >= 0) {
            if (o + 1 > *out_n) return -2;
            out[o++] = (uint8_t)id;
        } else {
            int e = strtab_find(d->keyesc, d->keyesc_len, u + i, cl);
            if (e >= 0) {
                if (o + 3 > *out_n) return -2;
                out[o++] = 0xFF;
                out[o++] = (uint8_t)((e >> 8) & 0xFF);
                out[o++] = (uint8_t)(e & 0xFF);
            } else {
                uint32_t cp = utf8_cp(u + i, cl);
                if (o + 4 > *out_n) return -2;
                out[o++] = 0xFE;
                out[o++] = (uint8_t)((cp >> 16) & 0xFF);
                out[o++] = (uint8_t)((cp >> 8) & 0xFF);
                out[o++] = (uint8_t)(cp & 0xFF);
            }
        }
        i += cl;
    }
    *out_n = o;
    return 0;
}

/* ---------------------------------------------------------------- LOUDS */

static uint32_t bit_at(const uint8_t *b, uint32_t i) {
    return (uint32_t)((b[i >> 3] >> (i & 7)) & 1);
}

static uint32_t popcnt8(uint8_t x) {
    static const uint8_t t[16] = {0,1,1,2,1,2,2,3,1,2,2,3,2,3,3,4};
    return (uint32_t)(t[x & 0xF] + t[x >> 4]);
}

static uint32_t rank1(const jdict_t *d, uint32_t i) {
    uint32_t r = rd32(d->rank_sup + 4u * (i / SUPER_BITS));
    r += d->rank_blk[i / BLOCK_BITS];
    uint32_t base = i - (i % BLOCK_BITS);
    uint32_t j = base;
    for (; j + 8 <= i; j += 8) r += popcnt8(d->louds_bits[j >> 3]);
    for (; j < i; j++) r += bit_at(d->louds_bits, j);
    return r;
}

static uint32_t select0(const jdict_t *d, uint32_t k) {
    uint32_t base = k / SELECT_STEP;
    uint32_t pos = rd32(d->sel0 + 4u * base);
    uint32_t need = k - base * SELECT_STEP;
    while (need) { if (!bit_at(d->louds_bits, pos)) need--; pos++; }
    while (bit_at(d->louds_bits, pos)) pos++;
    return pos;
}

/* node の子のうちラベルが ch のもの。無ければ -1。 */
static int32_t child_of(const jdict_t *d, uint32_t node, uint8_t ch) {
    uint32_t p = select0(d, node) + 1;
    while (p < d->louds_bitlen && bit_at(d->louds_bits, p)) {
        uint32_t c = rank1(d, p);            /* ⚠️ p より前の 1 の数 */
        if (c < d->n_nodes && d->labels[c] == ch) return (int32_t)c;
        p++;
    }
    return -1;
}

/* 前方宣言。実体は K-6 の節（索引を使う）。 */
static uint32_t term_rank_fast(const jdict_t *d, uint32_t node);
#define term_rank(d, node) term_rank_fast((d), (node))

int jdict_prefix_search(const jdict_t *d, const uint8_t *key, size_t key_n,
                            size_t start, jdict_hit_t *out, int max_out) {
    int n = 0;
    uint32_t node = 0;
    for (size_t k = start; k < key_n; k++) {
        int32_t nx = child_of(d, node, key[k]);
        if (nx < 0) break;
        node = (uint32_t)nx;
        if (bit_at(d->term_bits, node)) {
            if (n < max_out) {
                out[n].len = (uint32_t)(k - start + 1);
                out[n].rank = term_rank(d, node);
                n++;
            }
        }
    }
    return n;
}

/* ---------------------------------------------------------------- エントリ */

void jdict_entry_range(const jdict_t *d, uint32_t rank,
                    uint32_t *first, uint32_t *count) {
    uint32_t base = rank / CHECKPOINT;
    uint32_t off = rd32(d->surfck + 4u * base);
    for (uint32_t j = base * CHECKPOINT; j < rank; j++) off += d->counts[j];
    *first = off;
    *count = d->counts[rank];
}

void jdict_entry_conn(const jdict_t *d, uint32_t entry,
                   uint16_t *lc, uint16_t *rc, int16_t *wcost) {
    uint16_t cid;
    rec_unpack(d, entry, &cid, wcost, NULL, NULL);
    const uint8_t *c = d->classes + d->cls_stride * cid;
    *lc = rd16(c);
    *rc = rd16(c + 2);
}

/* ------------------------------------------------- K-6: 素性の復元 */

/* 前方宣言（実体は下の「未知語」節にある）。 */
static size_t cp_to_utf8(uint32_t cp, char *out);
static const uint8_t *strtab_at(const uint8_t *tab, uint32_t len, int idx,
                                uint32_t *out_len);
static uint32_t key_codepoint(const jdict_t *d, const uint8_t *key, size_t p,
                              uint32_t *sym_bytes);

#define REC_FLAG_ORIG_EQ_SURFACE 0x01u
#define REC_FLAG_READ_EQ_PRON    0x02u

/* node より前の終端の数。⚠️ **索引が無いと O(n) 走査**（K-6 以前の実装）。 */
static uint32_t term_rank_fast(const jdict_t *d, uint32_t node) {
    if (!d->termck) {
        uint32_t r = 0;
        for (uint32_t i = 0; i < node; i++) r += bit_at(d->term_bits, i);
        return r;
    }
    uint32_t base = node / TERM_CHECKPOINT;
    uint32_t r = rd32(d->termck + 4u * base);
    for (uint32_t i = base * TERM_CHECKPOINT; i < node; i++)
        r += bit_at(d->term_bits, i);
    return r;
}

/* 終端 rank のノード番号。無ければ 0xFFFFFFFF。 */
static uint32_t node_of_term_rank(const jdict_t *d, uint32_t rank) {
    if (!d->termck) return 0xFFFFFFFFu;
    /* 累積が rank 以下である最後のチェックポイントを二分探索 */
    uint32_t lo = 0, hi = d->n_termck;
    while (lo + 1 < hi) {
        uint32_t mid = (lo + hi) / 2;
        if (rd32(d->termck + 4u * mid) <= rank) lo = mid; else hi = mid;
    }
    uint32_t r = rd32(d->termck + 4u * lo);
    for (uint32_t i = lo * TERM_CHECKPOINT; i < d->n_nodes; i++) {
        if (bit_at(d->term_bits, i)) {
            if (r == rank) return i;
            r++;
        }
    }
    return 0xFFFFFFFFu;
}

/* node 番目の 1 のビット位置（LOUDS の select1）。 */
static uint32_t select1(const jdict_t *d, uint32_t node) {
    uint32_t lo = 0, hi = d->louds_bitlen;
    while (lo + 1 < hi) {                    /* rank1(x) <= node の最大 x */
        uint32_t mid = (lo + hi) / 2;
        if (rank1(d, mid) <= node) lo = mid; else hi = mid;
    }
    while (lo < d->louds_bitlen && !bit_at(d->louds_bits, lo)) lo++;
    return lo;
}

/* ビット位置 i より前の 0 の数。 */
static uint32_t rank0(const jdict_t *d, uint32_t i) { return i - rank1(d, i); }

int jdict_surface_of_rank(const jdict_t *d, uint32_t rank, char *out, size_t out_n) {
    uint32_t node = node_of_term_rank(d, rank);
    if (node == 0xFFFFFFFFu) return -1;
    /* 親へ遡って鍵バイトを逆順に集める */
    uint8_t key[256];
    int kn = 0;
    while (node != 0) {
        if (kn >= (int)sizeof key) return -2;
        key[kn++] = d->labels[node];
        uint32_t p = select1(d, node);
        uint32_t parent = rank0(d, p);
        if (parent == 0) break;              /* 根の子 */
        node = parent - 1;
    }
    /* 鍵は逆順。前から復号して UTF-8 にする */
    size_t o = 0;
    for (int i = kn - 1; i >= 0; ) {
        /* key_codepoint は前方向の並びを前提にするので、いったん整列する */
        uint8_t buf[8]; int bn = 0;
        buf[bn++] = key[i];
        if (key[i] == 0xFE && i >= 3) {      /* 直接コードポイント（4 B） */
            buf[bn++] = key[i-1]; buf[bn++] = key[i-2]; buf[bn++] = key[i-3];
            i -= 4;
        } else if (key[i] == 0xFF && i >= 2) {
            buf[bn++] = key[i-1]; buf[bn++] = key[i-2];
            i -= 3;
        } else {
            i -= 1;
        }
        uint32_t sym; (void)sym;
        uint32_t cp = key_codepoint(d, buf, 0, &sym);
        /* コードポイント → UTF-8 */
        if (o + 4 >= out_n) return -3;
        o += cp_to_utf8(cp, out + o);
    }
    out[o] = 0;
    return (int)o;
}

/* コードポイント → UTF-8。書いたバイト数を返す。 */
static size_t cp_to_utf8(uint32_t cp, char *out) {
    if (cp < 0x80) { out[0] = (char)cp; return 1; }
    if (cp < 0x800) {
        out[0] = (char)(0xC0 | (cp >> 6));
        out[1] = (char)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = (char)(0xE0 | (cp >> 12));
        out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[2] = (char)(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = (char)(0xF0 | (cp >> 18));
    out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    out[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
    out[3] = (char)(0x80 | (cp & 0x3F));
    return 4;
}

int jdict_key_to_utf8(const jdict_t *d, const uint8_t *key, size_t from, size_t to,
                   char *out, size_t out_n) {
    size_t o = 0;
    for (size_t p = from; p < to; ) {
        uint32_t sym = 0;
        uint32_t cp = key_codepoint(d, key, p, &sym);
        if (sym == 0) return -1;
        if (o + 4 >= out_n) return -2;
        o += cp_to_utf8(cp, out + o);
        p += sym;
    }
    out[o] = 0;
    return (int)o;
}

/* 値プール中の entry のオフセット。 */
static uint32_t pool_offset(const jdict_t *d, uint32_t entry) {
    uint32_t base = entry / CHECKPOINT;
    uint32_t off = d->poolck ? rd32(d->poolck + 4u * base) : 0;
    uint32_t from = d->poolck ? base * CHECKPOINT : 0;
    for (uint32_t j = from; j < entry; j++) {
        uint8_t pl, el;
        rec_unpack(d, j, NULL, NULL, &pl, &el);
        off += pl + el;                      /* pool_len + extra_len */
    }
    return off;
}

/* モーラ ID 列 → UTF-8。書いたバイト数を返す。 */
static size_t mora_decode(const jdict_t *d, const uint8_t *p, size_t n,
                          char *out, size_t out_n) {
    size_t o = 0;
    for (size_t i = 0; i < n; i++) {
        int idx = p[i];
        if (idx == 0xFF && i + 2 < n) {       /* エスケープ（副表） */
            idx = ((int)p[i+1] << 8) | p[i+2];
            i += 2;
        }
        uint32_t len; const uint8_t *s = strtab_at(d->moratab, d->moratab_len, idx, &len);
        if (!s || o + len >= out_n) break;
        memcpy(out + o, s, len); o += len;
    }
    out[o] = 0;
    return o;
}

static size_t put(char *out, size_t o, size_t out_n, const char *s) {
    size_t n = strlen(s);
    if (o + n >= out_n) return o;
    memcpy(out + o, s, n);
    return o + n;
}

int jdict_entry_feature(const jdict_t *d, uint32_t entry,
                     const char *surface, char *out, size_t out_n) {
    if (entry >= d->n_entries) return -1;
    uint16_t cid, chid;
    uint8_t flags, pl, el;
    rec_unpack(d, entry, &cid, NULL, &pl, &el);
    if (cid >= d->n_classes) return -2;
    rec_chain_flags(d, entry, cid, &chid, &flags);
    uint16_t p6 = rd16(d->classes + d->cls_stride * cid + 4);

    uint32_t off = pool_offset(d, entry);
    const uint8_t *pb = d->pool + off;
    const uint8_t *ex = pb + pl;

    char pron[256], read[256], orig[256];
    mora_decode(d, pb, pl, pron, sizeof pron);

    uint32_t j = 0;
    if (flags & REC_FLAG_ORIG_EQ_SURFACE) {
        snprintf(orig, sizeof orig, "%s", surface);
    } else if (ex[j] == 1) {
        uint32_t sid = (uint32_t)ex[j+1] | ((uint32_t)ex[j+2] << 8)
                     | ((uint32_t)ex[j+3] << 16);
        if (jdict_surface_of_rank(d, sid, orig, sizeof orig) < 0) return -3;
        j += 4;
    } else {
        uint32_t n = ex[j+1];
        if (n >= sizeof orig) return -4;
        memcpy(orig, ex + j + 2, n); orig[n] = 0;
        j += 2 + n;
    }
    if (flags & REC_FLAG_READ_EQ_PRON) {
        snprintf(read, sizeof read, "%s", pron);
    } else {
        uint32_t n = ex[j];
        mora_decode(d, ex + j + 1, n, read, sizeof read);
        j += 1 + n;
    }

    uint32_t p6len; const uint8_t *p6s = strtab_at(d->pos6tab, d->pos6tab_len,
                                                   p6, &p6len);
    uint32_t chlen; const uint8_t *chs = strtab_at(d->chaintab, d->chaintab_len,
                                                   chid, &chlen);
    if (!p6s || !chs) return -5;

    size_t o = 0;
    o = put(out, o, out_n, surface);
    if (o + 1 < out_n) out[o++] = ',';
    if (o + p6len < out_n) { memcpy(out + o, p6s, p6len); o += p6len; }
    if (o + 1 < out_n) out[o++] = ',';
    o = put(out, o, out_n, orig);
    if (o + 1 < out_n) out[o++] = ',';
    o = put(out, o, out_n, read);
    if (o + 1 < out_n) out[o++] = ',';
    o = put(out, o, out_n, pron);
    if (o + 1 < out_n) out[o++] = ',';
    /* アクセント: "acc/mora" を ':' で連結。255 は '*' */
    int first = 1;
    for (; j + 1 < el; j += 2) {
        char tmp[24];
        if (!first && o + 1 < out_n) out[o++] = ':';
        first = 0;
        /* ⚠️ **必ず "a/m" の形で書く。** 255 は "*"。
         *    Python の `_decode_acc` がそう書くので、`*` 単独にすると
         *    記号（読点など）で 251 / 300 文が食い違う。 */
        char a[8], m[8];
        if (ex[j] == 255) snprintf(a, sizeof a, "*"); else snprintf(a, sizeof a, "%u", ex[j]);
        if (ex[j+1] == 255) snprintf(m, sizeof m, "*"); else snprintf(m, sizeof m, "%u", ex[j+1]);
        snprintf(tmp, sizeof tmp, "%s/%s", a, m);
        o = put(out, o, out_n, tmp);
    }
    if (o + 1 < out_n) out[o++] = ',';
    if (o + chlen < out_n) { memcpy(out + o, chs, chlen); o += chlen; }
    if (o >= out_n) return -6;
    out[o] = 0;
    return (int)o;
}

int16_t jdict_trans(const jdict_t *d, uint16_t rc_prev, uint16_t lc_cur) {
    if (d->matrix) return d->matrix[(size_t)rc_prev + (size_t)d->lsize * lc_cur];
    if (!d->matrix_q) return 0;
    /* 行ごとアフィン uint8（`matrixa`）。⚠️ **整数だけで閉じる。**
     *    float スケールにするとホスト（float64）と C で値が食い違い、
     *    Viterbi の判断が変わりうる（M-99 §1 / C-060）。
     * ⚠️ span == 0 の行は lo をそのまま返す（ゼロ除算を踏まない）。
     *    実辞書では 0/1377 行だが、他の辞書では起きうる。 */
    /* matrixc（行・列クラスタ）なら、まず写像でクラスタ番号に落とす。
     * ⚠️ **代表行列の索引は kc 幅**（lsize ではない）。M-106 §2 */
    const size_t row = d->matrix_rmap ? (size_t)d->matrix_rmap[lc_cur] : (size_t)lc_cur;
    const size_t col = d->matrix_cmap ? (size_t)d->matrix_cmap[rc_prev] : (size_t)rc_prev;
    const size_t w   = d->matrix_rmap ? (size_t)d->matrix_kc : (size_t)d->lsize;
    const int32_t sp = (int32_t)d->matrix_span[row];
    const int32_t lo = (int32_t)d->matrix_lo[row];
    if (sp == 0) return (int16_t)lo;
    const int32_t q = (int32_t)d->matrix_q[col + w * row];
    /* 中間値は最大 255*17,342*2 = 8,844,420。int32 に収まる */
    return (int16_t)(lo + (q * sp * 2 + 255) / 510);
}

/* ---------------------------------------------------------------- 未知語 */

#define MAX_GROUPING 24u          /* MeCab の MAX_GROUPING_SIZE */

static uint32_t char_raw(const jdict_t *d, uint32_t cp);
uint32_t jdict_char_raw(const jdict_t *d, uint32_t cp) { return char_raw(d, cp); }

static uint32_t char_raw(const jdict_t *d, uint32_t cp) {
    if (cp >= d->n_codepoints) return 0;                    /* 表の外は DEFAULT */
    if (d->char_info) return rd32(d->char_info + 4u * cp);
    if (!d->char_runs) return 0;
    /* レンジ表（`charr`）: 開始位置 <= cp の最後の run を二分探索で引く。
     * ⚠️ run[0] の開始位置は 0 と検査済みなので、必ず 1 つは見つかる。 */
    uint32_t lo = 0, hi = d->n_char_runs;                   /* [lo, hi) */
    while (hi - lo > 1u) {
        uint32_t mid = lo + (hi - lo) / 2u;
        if ((rd32(d->char_runs + 4u * mid) >> 12) <= cp) lo = mid; else hi = mid;
    }
    return rd32(d->char_vals + 4u * (rd32(d->char_runs + 4u * lo) & 0xFFFu));
}
static uint32_t ci_type(uint32_t v)    { return v & 0x3FFFFu; }
static uint32_t ci_default(uint32_t v) { return (v >> 18) & 0xFFu; }
static uint32_t ci_length(uint32_t v)  { return (v >> 26) & 0xFu; }
static uint32_t ci_group(uint32_t v)   { return (v >> 30) & 1u; }
static uint32_t ci_invoke(uint32_t v)  { return (v >> 31) & 1u; }

/* NUL 区切り表の idx 番目を返す（長さも返す）。 */
static const uint8_t *strtab_at(const uint8_t *tab, uint32_t len, int idx,
                                uint32_t *out_len) {
    uint32_t i = 0; int k = 0;
    while (i < len) {
        uint32_t j = i;
        while (j < len && tab[j]) j++;
        if (k == idx) { *out_len = j - i; return tab + i; }
        k++; i = j + 1;
    }
    *out_len = 0; return NULL;
}

/* 鍵バイト列の位置 p にある記号のコードポイントと、記号のバイト長。 */
static uint32_t key_codepoint(const jdict_t *d, const uint8_t *key, size_t p,
                              uint32_t *sym_bytes) {
    uint8_t c = key[p];
    if (c == 0xFE) { *sym_bytes = 4;
        return ((uint32_t)key[p+1] << 16) | ((uint32_t)key[p+2] << 8) | key[p+3]; }
    if (c == 0xFF) {
        *sym_bytes = 3;
        int idx = ((int)key[p+1] << 8) | key[p+2];
        uint32_t n; const uint8_t *u = strtab_at(d->keyesc, d->keyesc_len, idx, &n);
        return u ? utf8_cp(u, n) : 0;
    }
    *sym_bytes = 1;
    uint32_t n; const uint8_t *u = strtab_at(d->keytab, d->keytab_len, c, &n);
    return u ? utf8_cp(u, n) : 0;
}

/* unk エントリ i の (lc, rc, wcost, カテゴリ名)。 */
static int unk_at(const jdict_t *d, uint32_t i, uint16_t *lc, uint16_t *rc,
                  int16_t *wcost, const uint8_t **cat, uint32_t *cat_len) {
    const uint8_t *p = d->unk;
    const uint8_t *e = d->unk + d->unk_len;
    for (uint32_t k = 0; k < d->n_unk; k++) {
        if (p + 6 > e) return -1;
        uint16_t l = rd16(p), r = rd16(p + 2); int16_t w = (int16_t)rd16(p + 4);
        p += 6;
        const uint8_t *c0 = p;
        while (p < e && *p) p++;
        uint32_t clen = (uint32_t)(p - c0); p++;          /* カテゴリ名 */
        while (p < e && *p) p++;
        p++;                                              /* feature */
        if (k == i) { *lc = l; *rc = r; *wcost = w; *cat = c0; *cat_len = clen; return 0; }
    }
    return -1;
}

/* カテゴリ番号 cat の unk エントリを列挙する。 */
static int unk_of_category(const jdict_t *d, uint32_t cat,
                           uint32_t *out, int max_out) {
    if (!d->unk || !d->char_names || cat >= d->n_char_cats) return 0;
    const uint8_t *want = d->char_names + 32u * cat;
    uint32_t wlen = 0;
    while (wlen < 32 && want[wlen]) wlen++;
    int n = 0;
    for (uint32_t i = 0; i < d->n_unk; i++) {
        uint16_t lc, rc; int16_t w; const uint8_t *c; uint32_t cl;
        if (unk_at(d, i, &lc, &rc, &w, &c, &cl) != 0) break;
        if (cl == wlen && memcmp(c, want, wlen) == 0 && n < max_out) out[n++] = i;
    }
    return n;
}

/* ---------------------------------------------------------------- Viterbi */

typedef struct {
    uint32_t begin, end, entry;
    uint16_t lc, rc;
    int32_t  cost;
    int32_t  prev;     /* -1 = BOS */
} vnode_t;

/* nodes[k] の前任を選び、終端リストに繋ぐ。既知語と未知語で共有する。 */
static int link_node(vnode_t *nodes, int32_t *ends_head, int32_t *next_at_end,
                     uint32_t k, size_t i, int16_t wcost, int use_cost,
                     const jdict_t *d) {
    vnode_t *v = &nodes[k];
    if (i == 0) {
        v->cost = (use_cost ? jdict_trans(d, BOS_RC, v->lc) : 0) + wcost;
        v->prev = -1;
    } else {
        int32_t best = COST_INF, bp = -2;
        for (int32_t pk = ends_head[i]; pk >= 0; pk = next_at_end[pk]) {
            if (nodes[pk].cost >= COST_INF) continue;
            int32_t c = nodes[pk].cost
                      + (use_cost ? jdict_trans(d, nodes[pk].rc, v->lc) : 0);
            /* ⚠️ 同点は辞書順で先勝ち（= ノード番号が小さい方）。K-2 で踏んだ。 */
            if (c < best || (c == best && (bp < 0 || pk < bp))) { best = c; bp = pk; }
        }
        if (bp == -2) return 0;
        v->cost = best + wcost;
        v->prev = bp;
    }
    next_at_end[k] = ends_head[v->end];
    ends_head[v->end] = (int32_t)k;
    return 1;
}

static int analyze_impl(const jdict_t *d, const uint8_t *key, size_t key_n,
                        void *arena, size_t arena_n, jdict_token_t *out, int max_out,
                        int use_cost) {
    size_t cap = arena_n / (sizeof(vnode_t) + sizeof(int32_t) * 2);
    if (cap < 8) return -1;
    vnode_t *nodes = (vnode_t *)arena;
    int32_t *ends_head = (int32_t *)(void *)(nodes + cap);      /* 位置 -> 先頭 */
    int32_t *next_at_end = ends_head + (key_n + 1);             /* 連結リスト */
    if ((size_t)(key_n + 1) * 2 > cap) return -1;

    for (size_t i = 0; i <= key_n; i++) ends_head[i] = -1;

    uint32_t n = 0;
    jdict_hit_t hits[64];
    for (size_t i = 0; i <= key_n; i++) {
        /* この位置に到達できるか（BOS または既存ノードの終端） */
        if (i > 0 && ends_head[i] < 0) continue;
        if (i == key_n) continue;
        int nh = jdict_prefix_search(d, key, key_n, i, hits, 64);

        /* --- 未知語ノード（K-3）--------------------------------------
         * MeCab の規則: 辞書に当たらなかったか、その文字カテゴリが invoke なら
         * 未知語ノードを作る。group なら同カテゴリの連なり（最大 24 文字）を
         * 1 ノードに、length があれば 1..length 文字のノードも作る。
         * ⚠️ wcost は unk.dic の値を**そのまま**使う（実測で確認。スケールしない）。 */
        uint32_t unk_len_list[MAX_GROUPING + 2];
        int n_unk_len = 0;
        /* ⚠️ **`char_info` だけを見てはいけない。** `charr`（レンジ表。M-106 §10）では
         *    `char_info` が NULL になり、**未知語ノード生成が丸ごと飛んでいた**。
         *    落ちも警告も出ず、経路なしの文が増えるだけなので、
         *    **ゲートがその文を分母から落として精度が良く見える**（M-107）。
         *    `char_raw()` は両方を扱うので、条件も両方を見ること。 */
        if (d->unk && (d->char_info || d->char_runs)) {
            uint32_t sb = 0;
            uint32_t cp0 = key_codepoint(d, key, i, &sb);
            uint32_t v0 = char_raw(d, cp0);
            if (nh == 0 || ci_invoke(v0)) {
                uint32_t cat = ci_default(v0);
                /* group: 同カテゴリの連なり */
                if (ci_group(v0)) {
                    size_t p2 = i + sb;
                    uint32_t nch = 1;
                    while (p2 < key_n && nch < MAX_GROUPING) {
                        uint32_t sb2 = 0;
                        uint32_t cpx = key_codepoint(d, key, p2, &sb2);
                        if (!(ci_type(char_raw(d, cpx)) & (1u << cat))) break;
                        p2 += sb2; nch++;
                    }
                    unk_len_list[n_unk_len++] = (uint32_t)(p2 - i);
                }
                /* length: 1..length 文字。
                 * ⚠️ **同カテゴリの文字しか伸ばせない。** これを入れないと
                 *    「たけーな」で `ー`(KATAKANA, length=2) が次の `な`(HIRAGANA) を
                 *    巻き込んで 2 文字ノードになり、MeCab と食い違う（実際に踏んだ）。 */
                for (uint32_t k2 = 1; k2 <= ci_length(v0); k2++) {
                    size_t p2 = i; uint32_t m2 = 0;
                    while (p2 < key_n && m2 < k2) {
                        uint32_t sb2 = 0;
                        uint32_t cpx = key_codepoint(d, key, p2, &sb2);
                        if (m2 > 0 && !(ci_type(char_raw(d, cpx)) & (1u << cat))) break;
                        p2 += sb2; m2++;
                    }
                    if (m2 != k2) break;
                    uint32_t bl = (uint32_t)(p2 - i);
                    int dup = 0;
                    for (int z = 0; z < n_unk_len; z++) if (unk_len_list[z] == bl) dup = 1;
                    if (!dup) unk_len_list[n_unk_len++] = bl;
                }
                uint32_t ids[32];
                int nid = unk_of_category(d, cat, ids, 32);
                for (int z = 0; z < n_unk_len; z++) {
                    for (int y = 0; y < nid; y++) {
                        if (n >= cap) return -1;
                        uint16_t lc, rc; int16_t w;
                        const uint8_t *cn; uint32_t cl;
                        if (unk_at(d, ids[y], &lc, &rc, &w, &cn, &cl) != 0) continue;
                        vnode_t *v = &nodes[n];
                        v->begin = (uint32_t)i;
                        v->end   = (uint32_t)(i + unk_len_list[z]);
                        v->entry = JDICT_UNKNOWN_FLAG | ids[y];
                        v->lc = lc; v->rc = rc;
                        v->cost = COST_INF; v->prev = -2;
                        if (link_node(nodes, ends_head, next_at_end, n, i, w, use_cost, d))
                            { }
                        n++;
                    }
                }
            }
        }

        for (int h = 0; h < nh; h++) {
            uint32_t first, cnt;
            jdict_entry_range(d, hits[h].rank, &first, &cnt);
            for (uint32_t e = 0; e < cnt; e++) {
                if (n >= cap) return -1;
                uint16_t lc, rc; int16_t w;
                jdict_entry_conn(d, first + e, &lc, &rc, &w);
                vnode_t *v = &nodes[n];
                v->begin = (uint32_t)i;
                v->end   = (uint32_t)(i + hits[h].len);
                v->entry = first + e;
                v->lc = lc; v->rc = rc;
                v->cost = COST_INF; v->prev = -2;
                /* ⚠️ 前任は位置ごとではなく **ノードごと**に持つ（link_node） */
                link_node(nodes, ends_head, next_at_end, n, i, w, use_cost, d);
                n++;
            }
        }
    }

    /* EOS */
    int32_t best = COST_INF, bk = -2;
    for (int32_t pk = ends_head[key_n]; pk >= 0; pk = next_at_end[pk]) {
        if (nodes[pk].cost >= COST_INF) continue;
        int32_t c = nodes[pk].cost + (use_cost ? jdict_trans(d, nodes[pk].rc, EOS_LC) : 0);
        if (c < best || (c == best && (bk < 0 || pk < bk))) { best = c; bk = pk; }
    }
    if (bk == -2) return -1;

    int cnt = 0;
    for (int32_t k = bk; k != -1; k = nodes[k].prev) cnt++;
    if (cnt > max_out) return -1;
    int w = cnt;
    for (int32_t k = bk; k != -1; k = nodes[k].prev) {
        w--;
        out[w].begin = nodes[k].begin;
        out[w].end   = nodes[k].end;
        out[w].entry = nodes[k].entry;
    }
    return cnt;
}

/* 未知語の feature。⚠️ **8 列しか無い**（読み/発音/acc/結合規則が無い）。
 * これが「未知語は無音で消える」の入口（B-0 / M-73）。 */
int jdict_unk_feature(const jdict_t *d, uint32_t entry,
                   const char *surface, char *out, size_t out_n) {
    if (!(entry & JDICT_UNKNOWN_FLAG)) return -1;
    uint32_t i = entry & ~JDICT_UNKNOWN_FLAG;
    const uint8_t *p = d->unk;
    const uint8_t *e = d->unk + d->unk_len;
    for (uint32_t k = 0; k < d->n_unk; k++) {
        if (p + 6 > e) return -2;
        p += 6;
        while (p < e && *p) p++;             /* カテゴリ名 */
        p++;
        const uint8_t *f0 = p;
        while (p < e && *p) p++;             /* feature 本体 */
        uint32_t flen = (uint32_t)(p - f0);
        p++;
        if (k == i) {
            size_t n = strlen(surface);
            if (n + 1 + flen >= out_n) return -3;
            memcpy(out, surface, n);
            out[n] = ',';
            memcpy(out + n + 1, f0, flen);
            out[n + 1 + flen] = 0;
            return (int)(n + 1 + flen);
        }
    }
    return -4;
}

/* ------------------------------------------- K-6b: 未知語の読みの推測 */

/* UTF-8 1 文字を読み、コードポイントとバイト長を返す。 */
static uint32_t next_cp(const char *s, int *len) {
    unsigned char c = (unsigned char)s[0];
    if (c < 0x80)            { *len = 1; return c; }
    if ((c & 0xE0) == 0xC0)  { *len = 2; return ((uint32_t)(c & 0x1F) << 6)
                                              | (uint32_t)(s[1] & 0x3F); }
    if ((c & 0xF0) == 0xE0)  { *len = 3; return ((uint32_t)(c & 0x0F) << 12)
                                              | ((uint32_t)(s[1] & 0x3F) << 6)
                                              | (uint32_t)(s[2] & 0x3F); }
    *len = 4;
    return ((uint32_t)(c & 0x07) << 18) | ((uint32_t)(s[1] & 0x3F) << 12)
         | ((uint32_t)(s[2] & 0x3F) << 6) | (uint32_t)(s[3] & 0x3F);
}

static int is_kana_cp(uint32_t cp) {
    return (cp >= 0x3041 && cp <= 0x3096)      /* ひらがな */
        || (cp >= 0x30A1 && cp <= 0x30FA)      /* カタカナ */
        || cp == 0x30FC                        /* ー */
        || cp == 0x30FB;                       /* ・ */
}

/* 小書きのかな（モーラを増やさない）。 */
static int is_small_kana(uint32_t cp) {
    switch (cp) {
    case 0x30A1: case 0x30A3: case 0x30A5: case 0x30A7: case 0x30A9:
    case 0x30E3: case 0x30E5: case 0x30E7: case 0x30EE:
    case 0x30F5: case 0x30F6: return 1;
    default: return 0;
    }
}

/* カタカナ列のモーラ数。 */
static int mora_count(const char *s) {
    int n = 0, l;
    for (const char *p = s; *p; p += l) {
        uint32_t cp = next_cp(p, &l);
        if (!is_small_kana(cp)) n++;
    }
    return n;
}

/* feature 文字列の idx 番目のフィールドを out に取り出す。0 で成功。 */
static int field_at(const char *feat, int idx, char *out, size_t out_n) {
    int k = 0; size_t o = 0;
    for (const char *p = feat; ; p++) {
        if (*p == ',' || *p == 0) {
            if (k == idx) { if (o >= out_n) return -1; out[o] = 0; return 0; }
            k++; o = 0;
            if (*p == 0) return -1;
            continue;
        }
        if (k == idx) { if (o + 1 >= out_n) return -1; out[o++] = *p; }
    }
}

int jdict_unk_guess(const jdict_t *d, uint32_t entry,
                 const char *surface, char *out, size_t out_n) {
    char base[512];
    if (jdict_unk_feature(d, entry, surface, base, sizeof base) < 0) return -1;

    char read[512];
    size_t ro = 0;
    int all_kana = 1, l;
    for (const char *p = surface; *p; p += l) {
        uint32_t cp = next_cp(p, &l);
        if (!is_kana_cp(cp)) { all_kana = 0; break; }
    }

    if (all_kana) {
        /* 表層そのものが読み。ひらがなはカタカナへ寄せる */
        for (const char *p = surface; *p; p += l) {
            uint32_t cp = next_cp(p, &l);
            if (cp >= 0x3041 && cp <= 0x3096) cp += 0x60;
            if (ro + 4 >= sizeof read) return -2;
            ro += cp_to_utf8(cp, read + ro);
        }
        read[ro] = 0;
    } else {
        /* 1 文字ずつ辞書を引く。1 文字でも引けなければ諦める */
        for (const char *p = surface; *p; p += l) {
            (void)next_cp(p, &l);
            char ch[8];
            memcpy(ch, p, (size_t)l); ch[l] = 0;
            uint8_t key[32]; size_t kn = sizeof key;
            if (jdict_encode_key(d, (const uint8_t *)ch, (size_t)l, key, &kn) != 0)
                return -3;
            jdict_hit_t hit[8];
            int nh = jdict_prefix_search(d, key, kn, 0, hit, 8);
            int best = -1; int16_t bw = 0;
            for (int i = 0; i < nh; i++) {
                if (hit[i].len != kn) continue;
                uint32_t first, cnt;
                jdict_entry_range(d, hit[i].rank, &first, &cnt);
                for (uint32_t e = 0; e < cnt; e++) {
                    uint16_t lc, rc; int16_t w;
                    jdict_entry_conn(d, first + e, &lc, &rc, &w);
                    if (best < 0 || w < bw) { best = (int)(first + e); bw = w; }
                }
            }
            if (best < 0) return -4;
            char f[512], pron[256];
            if (jdict_entry_feature(d, (uint32_t)best, ch, f, sizeof f) < 0) return -5;
            if (field_at(f, 9, pron, sizeof pron) != 0) return -6;
            size_t pn = strlen(pron);
            if (ro + pn >= sizeof read) return -7;
            memcpy(read + ro, pron, pn); ro += pn;
        }
        read[ro] = 0;
    }
    if (ro == 0) return -8;

    /* base の 8 列のうち先頭 7 列（表層 + 品詞 6 つ）を使い、
     * orig を表層に、読み/発音を推測値に、アクセントを **平板** にする。 */
    char fld[7][64];
    for (int i = 0; i < 7; i++)
        if (field_at(base, i, fld[i], sizeof fld[0]) != 0) return -9;

    int m = mora_count(read);
    int n = snprintf(out, out_n, "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,0/%d,*",
                     fld[0], fld[1], fld[2], fld[3], fld[4], fld[5], fld[6],
                     surface, read, read, m);
    if (n < 0 || (size_t)n >= out_n) return -10;
    return n;
}

int jdict_analyze(const jdict_t *d, const uint8_t *key, size_t key_n,
               void *arena, size_t arena_n, jdict_token_t *out, int max_out) {
    return analyze_impl(d, key, key_n, arena, arena_n, out, max_out, 1);
}

int jdict_analyze_nocost(const jdict_t *d, const uint8_t *key, size_t key_n,
                      void *arena, size_t arena_n, jdict_token_t *out, int max_out) {
    return analyze_impl(d, key, key_n, arena, arena_n, out, max_out, 0);
}
