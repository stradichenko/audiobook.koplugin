/* K-1 辞書バイナリの読み出しと K-2 の Viterbi。
 *
 * 設計の決定は docs/decisions.md D-042〜D-044、実測は docs/measurements.md M-69〜M-77。
 * blob の形式は src/saanotts_jp/k1_dict.py が作るもの（magic "K1D1"）。
 *
 * 規約（csrc の他のコアと同じ）:
 *   - 依存は libc の一部だけ。malloc をコアで呼ばない。作業領域は arena で渡す
 *   - blob は mmap した領域をそのまま指す（コピーしない）
 */
#ifndef JDICT_H
#define JDICT_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    const uint8_t *blob;
    size_t         blob_len;

    const uint8_t *louds_bits;   /* LOUDS ビット列 */
    uint32_t       louds_bitlen;
    const uint8_t *labels;       /* ノードのラベル（1 B/node） */
    uint32_t       n_nodes;
    const uint8_t *term_bits;    /* 終端フラグ */
    const uint8_t *rank_sup;     /* rank1 の superblock（256 bit ごと u32） */
    const uint8_t *rank_blk;     /* 同 block（64 bit ごと u8） */
    const uint8_t *sel0;         /* select0 の標本（512 個ごと u32） */
    uint32_t       n_sel0;
    const uint8_t *surfck;       /* 見出し語 32 個ごとの累積エントリ数 u32 */

    const uint8_t *counts;       /* 見出し語ごとのエントリ数 */
    uint32_t       n_surfaces;

    const uint8_t *records;      /* `records` なら 9 B 固定 / `rec5` なら 5 B */
    uint32_t       n_entries;
    /* `rec5`（5 B レコード。M-107 §4a）なら 1。**`records` と排他。**
     * (class, chain, flags) を 12 bit の class2 に畳んである:
     *     b0..b1  wcost i16
     *     b2..b3  u16 = class2(bit 0-11) | pron長 下位 4bit(bit 12-15)
     *     b4      pron長 bit4(bit 0) | extra長(bit 1-6) | 予備(bit 7)
     * ⚠️ **classes のストライドも 8 → 10 B になる**（chain u8 / flags u8 が末尾に付く）。
     *    片方だけ直すと黙って別のエントリを読む。 */
    int            rec5;
    uint32_t       cls_stride;   /* 8（records） / 10（rec5） */
    const uint8_t *pool;
    uint32_t       pool_len;

    const uint8_t *classes;      /* 8 B: lc u16, rc u16, pos6 u16, posid u16 */
    uint32_t       n_classes;

    const int16_t *matrix;       /* 接続コスト（生 int16）。flat[rc_prev + lsize*lc_cur] */
    uint16_t       lsize, rsize;

    /* 接続コストを**行ごとアフィン uint8** で持つ形（セクション `matrixa`。D-051 の ①）。
     * ⚠️ **`matrix` と排他。** どちらか一方だけが非 NULL になる。
     *    2 つの形式を 1 つのセクション名に入れないのは、`matrix` の長さ検査
     *    `len == 4 + 2*L*R` を厳密なまま残すため（M-100）。
     * 逆量子化は**整数で閉じる**（float を使うとホストと C で値が食い違う。C-060）:
     *     v = span ? lo[lc] + (q*span[lc]*2 + 255) / 510 : lo[lc]
     * 中間値は最大 255*17,342*2 = 8,844,420 で int32 に収まる。 */
    const uint8_t  *matrix_q;    /* q[rc_prev + lsize*lc_cur]（matrixa）
                                  * / q[cmap[rc_prev] + kc*rmap[lc_cur]]（matrixc） */
    const int16_t  *matrix_lo;   /* lo[lc_cur]（matrixa） / lo[rmap[lc_cur]]（matrixc） */
    const uint16_t *matrix_span; /* span も同様に索引する */

    /* 接続コストを**行・列クラスタ + 代表行列**で持つ形（セクション `matrixc`。M-106 §2）。
     * ⚠️ **`matrix` / `matrixa` と排他。** 3 つのうち 1 つだけが有効になる。
     * `matrix_rmap` が非 NULL なら matrixc で、`matrix_lo` / `matrix_span` / `matrix_q` は
     * **クラスタ番号で索引する**（行数 = kr、1 行の長さ = kc）。
     * 逆量子化の式は matrixa と同一（整数で閉じる。C-060）。 */
    const uint16_t *matrix_rmap; /* lc_cur  → 行クラスタ。長さ rsize */
    const uint16_t *matrix_cmap; /* rc_prev → 列クラスタ。長さ lsize */
    uint16_t        matrix_kr, matrix_kc;

    const uint8_t *keytab;       /* NUL 区切りの文字表（1 B 符号） */
    uint32_t       keytab_len;
    const uint8_t *keyesc;       /* 同・副表 */
    uint32_t       keyesc_len;
    const uint8_t *moratab;      /* NUL 区切りのモーラ表（read / pron の復号） */
    uint32_t       moratab_len;
    const uint8_t *chaintab;     /* NUL 区切りのアクセント結合規則 */
    uint32_t       chaintab_len;
    const uint8_t *pos6tab;      /* NUL 区切りの "品詞,細分類1..3,活用型,活用形" */
    uint32_t       pos6tab_len;
    const uint8_t *poolck;       /* 32 エントリごとの値プール offset u32 */
    const uint8_t *termck;       /* 512 ノードごとの累積終端数 u32 */
    uint32_t       n_termck;

    /* K-3: 未知語 */
    const uint8_t *char_names;   /* 32 B ずつのカテゴリ名 */
    uint32_t       n_char_cats;
    const uint8_t *char_info;    /* 65,535 件の CharInfo (u32)。`charr` のときは NULL */
    uint32_t       n_codepoints;

    /* 文字カテゴリを**レンジ表**で持つ形（セクション `charr`。M-106 §5）。
     * ⚠️ **`char` と排他**。65,535 符号位置は 106 run しかないので 262,496 B → 832 B。
     * ⚠️ **完全に無損失**（run に畳むだけ。ホストの往復で bit 一致を確認済み）。
     *     run[i] は 上位 20 bit = 開始符号位置 / 下位 12 bit = 値表の添字。
     *     開始位置の昇順なので二分探索で引く。 */
    const uint8_t *char_runs;    /* u32 × n_char_runs */
    uint32_t       n_char_runs;
    const uint8_t *char_vals;    /* u32 × distinct な CharInfo */
    uint32_t       n_char_vals;
    const uint8_t *unk;          /* 未知語エントリ（可変長） */
    uint32_t       unk_len;
    uint32_t       n_unk;
} jdict_t;

typedef struct { uint32_t len; uint32_t rank; } jdict_hit_t;
/* entry の最上位ビットが立っていたら **未知語**で、下位は unk エントリの番号。 */
#define JDICT_UNKNOWN_FLAG 0x80000000u

typedef struct { uint32_t begin, end, entry; } jdict_token_t;

/* blob を開く。0 で成功、負でエラー。
 *
 * ⚠️ **`n` は「読んでよい上限」であって blob の長さではない。**
 *    端末は dict パーティション長を渡す（esp32/main/saan_dict.c）ので、
 *    実 blob より 125,776 B 大きい。成功したら `d->blob_len` に
 *    **セクション表から復元した実 extent** が入るので、そちらを使うこと。 */
int jdict_open(jdict_t *d, const uint8_t *blob, size_t n);

/* jdict_open の戻り値。⚠️ **-1 〜 -10 は既存の値**（変えると既存のログが別の意味になる）。 */
#define JDICT_ERR_MAGIC    (-1)
#define JDICT_ERR_VERSION  (-2)
/* -3 〜 -10 = 必須セクション（louds/counts/surfck/records/pool/classes/keytab/keyesc）が無い */
#define JDICT_ERR_MATRIX   (-11)  /* matrix / matrixa が無い / 長さが合わない / 寸法が 0 */
#define JDICT_ERR_SECTAB   (-12)  /* セクション表が壊れている（blob の外を指す等） */
#define JDICT_ERR_CHAR     (-13)  /* char セクションの長さが宣言と合わない */
#define JDICT_ERR_UNK      (-14)  /* unk セクションの長さが宣言と合わない */
#define JDICT_ERR_CKPT     (-15)  /* poolck / termck の長さが件数と合わない */

/* 文字列（UTF-8）を鍵バイト列に符号化する。out_n は入出力。0 で成功。 */
int jdict_encode_key(const jdict_t *d, const uint8_t *utf8, size_t n,
                  uint8_t *out, size_t *out_n);

/* key[start..] の接頭辞のうち見出し語になっているものを列挙。件数を返す。 */
int jdict_prefix_search(const jdict_t *d, const uint8_t *key, size_t key_n,
                            size_t start, jdict_hit_t *out, int max_out);

/* 見出し語 rank のエントリ範囲。 */
void jdict_entry_range(const jdict_t *d, uint32_t rank,
                    uint32_t *first, uint32_t *count);

/* エントリの接続情報。 */
void jdict_entry_conn(const jdict_t *d, uint32_t entry,
                   uint16_t *lc, uint16_t *rc, int16_t *wcost);

/* 遷移コスト。⚠️ 索引は flat[rc_prev + lsize*lc_cur]（K-1 §9-3）。 */
int16_t jdict_trans(const jdict_t *d, uint16_t rc_prev, uint16_t lc_cur);

/* 符号位置 cp の CharInfo（生の u32）。表の外は 0 = DEFAULT / group=0 / invoke=0。
 * ビット割り当て: type:18 / default_type:8 / length:4 / group:1 / invoke:1。
 * ⚠️ **`char` と `charr` のどちらでも同じ値を返す**（charr_test.c がこれで突き合わせる）。 */
uint32_t jdict_char_raw(const jdict_t *d, uint32_t cp);

/* 見出し語 rank の表層形を UTF-8 で書き出す。バイト数を返す（負でエラー）。
 * ⚠️ **LOUDS を親へ遡って組み立てる。** 見出し語の文字列表は blob に無い
 *    （鍵そのものが表層形なので冗長。K-1）。 */
int jdict_surface_of_rank(const jdict_t *d, uint32_t rank, char *out, size_t out_n);

/* 鍵バイト列の [from, to) を UTF-8 に戻す。バイト数を返す（負でエラー）。
 * ⚠️ **トークンの begin/end は「鍵」の上の位置**で、元テキストの位置ではない。
 *    表層形はここで作る。 */
int jdict_key_to_utf8(const jdict_t *d, const uint8_t *key, size_t from, size_t to,
                   char *out, size_t out_n);

/* エントリ entry の MeCab feature 文字列を組む（surface は呼び出し側が渡す）。
 *
 *   "表層,品詞,細分類1,細分類2,細分類3,活用型,活用形,原形,読み,発音,アクセント,結合規則"
 *
 * これを `mecab2njd()` にそのまま渡せる。バイト数を返す（負でエラー）。 */
int jdict_entry_feature(const jdict_t *d, uint32_t entry,
                     const char *surface, char *out, size_t out_n);

/* 未知語ノード（entry の最上位ビットが立っているもの）の feature 文字列。
 * ⚠️ **未知語は 8 列しか無い**（読み/発音/acc/結合規則が無い）。
 *    これがそのまま「無音で消える」の入口（B-0）。 */
int jdict_unk_feature(const jdict_t *d, uint32_t entry,
                   const char *surface, char *out, size_t out_n);

/* 未知語の読みを**推測して** 12 列の feature を作る。
 * 0 以上で成功（バイト数）、負なら推測できない（呼び出し側が
 * `jdict_unk_feature` に落ちる）。
 *
 * ⚠️ **これは正しさではなく「無音で消えない」ための措置。**
 *    未知語は読み/発音を持たないので `njd_set_pronunciation` が読点に
 *    置換し、**語が丸ごと音から消える**（B-0 / M-73）。
 *    推測が当たる保証はない — 落ちる漢字語はほぼ地名で、
 *    単漢字の組み合わせでは当たらない。
 *
 * 規則は 2 つだけ:
 *   - 表層が全部かなら、**それ自身が読み**（カタカナに寄せる）
 *   - そうでなければ、**1 文字ずつ辞書を引いて読みを繋ぐ**
 *     （同じ字に複数あれば単語コスト最小）
 * アクセントは **平板（0）**に逃げる。 */
int jdict_unk_guess(const jdict_t *d, uint32_t entry,
                 const char *surface, char *out, size_t out_n);

/* Viterbi。arena は作業領域。返り値はトークン数、負でエラー。 */
int jdict_analyze(const jdict_t *d, const uint8_t *key, size_t key_n,
               void *arena, size_t arena_n, jdict_token_t *out, int max_out);

/* 陰性対照用: 接続コストを全部 0 にして解析する（G7）。 */
int jdict_analyze_nocost(const jdict_t *d, const uint8_t *key, size_t key_n,
                      void *arena, size_t arena_n, jdict_token_t *out, int max_out);

#endif
