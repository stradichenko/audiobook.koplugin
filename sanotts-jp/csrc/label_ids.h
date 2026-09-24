/* K-7: フルコンテキストラベル列 → 生徒インデックス列。
 *
 * K-6 までで「漢字文 → ラベル」は通った。ここはその先で、
 * `piper_plus_g2p/japanese.py` の `_phonemize_core()` を写したもの。
 *
 *   ラベル列 → 音素 + アクセント記号（`[` `]` `#` `_`）→ `ん` の異音
 *   → 生徒インデックス（**トークン間に PAD を挟む**）
 *
 * ⚠️ **PAD の挟み方を canonical と同じにする。** 外すと発話が約 2.4 倍速に
 *    なるが例外は出ない（C-007）。規則は `csrc/g2p.c` の `emit()` と同一:
 *    「その音素自身が PAD なら後ろに挟まない」。
 *
 * ⚠️ **疑問符の種類は元テキストから決まる**（`?` `?!` `?.` `?~` の 4 種）。
 *    ラベルには入っていないので、テキストも渡す。
 */
#ifndef SAAN_K7_LABEL2IDS_H
#define SAAN_K7_LABEL2IDS_H

#include <stddef.h>
#include <stdint.h>

typedef enum {
    LABEL_IDS_OK = 0,
    LABEL_IDS_ERR_OVERFLOW = -1,   /* ids バッファが足りない */
    LABEL_IDS_ERR_TOKEN    = -2,   /* 語彙に無い音素が出た */
    LABEL_IDS_ERR_ARG      = -3
} label_ids_status;

/* --- トークン表の置き場（T10(a)）---------------------------------------------
 *
 * 既定（ホストのゲート）は .bss の静的配列。**ESP32 では
 * `-DLABEL_IDS_EXTERNAL_SCRATCH=1`** で呼び出し側が領域を渡す
 * （⚠️ **`K7_EXTERNAL_SCRATCH` と書いてあったのは誤り。そんなマクロは無い** = [C-104](../docs/decisions.md#c-104)）
 * （esp32/main/saan_kanji.c が合成用 arena から切り出す）。
 * .bss を `LABEL_IDS_SCRATCH_BYTES` = 10,240 B（既定値のとき）減らすため。
 *
 * ⚠️ **上限そのものは変わらない**（コンパイル時定数のまま）。渡すのは置き場だけ。
 * ⚠️ ホスト側のゲートは held-out の長文を通すので `-DLABEL_IDS_MAX_TOKENS=2048` で
 *    上書きできる。**その場合は .h と .c を同じ値でコンパイルすること**
 *    （`LABEL_IDS_SCRATCH_BYTES` がずれる）。 */
#ifndef LABEL_IDS_MAX_TOKENS
#define LABEL_IDS_MAX_TOKENS 640
#endif
#define LABEL_IDS_TOK_MAX 16
#define LABEL_IDS_SCRATCH_BYTES ((size_t)LABEL_IDS_MAX_TOKENS * (size_t)LABEL_IDS_TOK_MAX)

#if defined(LABEL_IDS_EXTERNAL_SCRATCH) && LABEL_IDS_EXTERNAL_SCRATCH
/* `nbytes` は LABEL_IDS_SCRATCH_BYTES 以上。足りなければ以後 LABEL_IDS_ERR_ARG を返す
 * （**黙って短いバッファを使わない**）。buf は 1 発話のあいだ生きていること。 */
void label_ids_set_scratch(void *buf, size_t nbytes);
#endif

/* labels[0..n_labels) と元テキストから ids を作る。
 * `n_ids` には必要な総数が返る（cap を超えても数える）。 */
label_ids_status label_ids_convert(const char *const *labels, int n_labels,
                       const char *text,
                       int32_t *ids, int32_t ids_cap, int32_t *n_ids);

/* 音素名 → 生徒インデックス。無ければ -1。 */
int32_t label_ids_token_id(const char *name);

const char *label_ids_strerror(label_ids_status s);

/* 語彙のトークン数（`token_table.h` の LABEL_IDS_N_TOKENS と同じ値）。 */
extern const int label_ids_n_tokens;

/* ⚠️ **ゲートの陰性対照専用。** 1 にすると上昇記号 `[` を出さなくなる。
 *    出荷経路では 0 のまま。これが無いと「一致した」を
 *    「検査が効いていない」と区別できない。 */
extern int label_ids_debug_drop_rise;

#endif /* SAAN_K7_LABEL2IDS_H */
