/* K-4: pyopenjtalk-plus のアクセント規則 4 段を C に移植したもの。
 *
 * 根拠は docs/measurements.md M-69（NJD チェーンがホストと 635/635 一致）。
 * **この 4 段が C 実装のアクセント天井 76% の正体**で、外部資源は
 * `_DAN_MAP`（かな 76 件）しか要らない。SudachiDict 217 MB と nani ONNX の
 * 寄与は合計 0.13pt しかない。
 *
 * 規約: malloc を呼ばない。ノード列はその場で書き換える。
 */
#ifndef ACCENT_H
#define ACCENT_H

#include <stddef.h>

#define ACCENT_STR_MAX   64
#define ACCENT_PRON_MAX 128

/* NJD ノードのうち、4 段が読む/書くフィールドだけ。 */
typedef struct {
    char pos[ACCENT_STR_MAX];
    char ctype[ACCENT_STR_MAX];
    char cform[ACCENT_STR_MAX];
    char orig[ACCENT_STR_MAX];
    char pron[ACCENT_PRON_MAX];      /* suppress_u が書き換える */
    char read[ACCENT_PRON_MAX];
    int  acc;                    /* filler / retreat / chaining が書き換える */
    int  mora_size;
    int  chain_flag;             /* filler が書き換える */
} accent_node_t;

/* かな → 母音（'a','i','u','e','o'）。_DAN_MAP に対応。 */
typedef struct {
    const char *kana;            /* UTF-8 1 文字 */
    char        dan;
} accent_dan_t;

enum {
    ACCENT_FILLER      = 1u << 0,    /* modify_filler_accent */
    ACCENT_SUPPRESS_U  = 1u << 1,    /* suppress_unnatural_auxiliary_u_long_vowel */
    ACCENT_RETREAT     = 1u << 2,    /* retreat_acc_nuc */
    ACCENT_CHAINING    = 1u << 3,    /* modify_acc_after_chaining */
    ACCENT_ALL         = 0xF
};

/* stage_mask のビットが立っている段だけを、**この順で**適用する。 */
void accent_apply(accent_node_t *nodes, int n, unsigned stage_mask,
              const accent_dan_t *dan, int n_dan);

#endif
