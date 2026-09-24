/* K-4: アクセント規則 4 段。詳細は accent.h。
 *
 * pyopenjtalk-plus の Python 実装をそのまま写した。**規則を「改善」しない** —
 * 目的は既定経路と一致させることで、日本語として正しくすることではない。
 */
#include "accent.h"
#include <string.h>

/* ---------------------------------------------------------------- UTF-8 */

static int u8len(unsigned char c) {
    if (c < 0x80) return 1;
    if ((c & 0xE0) == 0xC0) return 2;
    if ((c & 0xF0) == 0xE0) return 3;
    return 4;
}

/* s の idx 番目の文字の先頭を返す。無ければ NULL。 */
static const char *u8at(const char *s, int idx) {
    int n = 0;
    for (size_t i = 0; s[i]; i += (size_t)u8len((unsigned char)s[i])) {
        if (n == idx) return s + i;
        n++;
    }
    return NULL;
}

/* p の 1 文字が lit と一致するか。 */
static int u8eq(const char *p, const char *lit) {
    if (!p) return 0;
    int n = u8len((unsigned char)*p);
    return (int)strlen(lit) == n && memcmp(p, lit, (size_t)n) == 0;
}

/* s の最後の 1 文字の先頭。空なら NULL。 */
static const char *u8last(const char *s) {
    const char *last = NULL;
    for (size_t i = 0; s[i]; i += (size_t)u8len((unsigned char)s[i])) last = s + i;
    return last;
}

/* ---------------------------------------------------------------- 1. filler */

static void modify_filler_accent(accent_node_t *nd, int n) {
    int after = 0;
    for (int i = 0; i < n; i++) {
        if (strcmp(nd[i].pos, "フィラー") == 0) {
            if (nd[i].acc > nd[i].mora_size) nd[i].acc = 0;
            after = 1;
        } else if (after) {
            if (strcmp(nd[i].pos, "名詞") == 0) nd[i].chain_flag = 0;
            after = 0;
        }
    }
}

/* ------------------------------------------------------- 2. suppress_u_long */

static char dan_of(const accent_dan_t *dan, int n_dan, const char *ch) {
    for (int i = 0; i < n_dan; i++)
        if (u8eq(ch, dan[i].kana)) return dan[i].dan;
    return 0;
}

static void suppress_u_long(accent_node_t *nd, int n,
                            const accent_dan_t *dan, int n_dan) {
    if (n < 2) return;
    for (int i = 0; i < n - 1; i++) {
        if (strcmp(nd[i + 1].pron, "ー") != 0) continue;
        if (strcmp(nd[i + 1].read, "ウ") != 0) continue;
        /* current_feature["pron"].rstrip("’") */
        char cur[ACCENT_PRON_MAX];
        size_t L = strlen(nd[i].pron);
        if (L >= sizeof cur) L = sizeof cur - 1;
        memcpy(cur, nd[i].pron, L); cur[L] = 0;
        for (;;) {
            const char *last = u8last(cur);
            if (!last || !u8eq(last, "’")) break;
            cur[last - cur] = 0;
        }
        if (cur[0] == 0) continue;
        char d = dan_of(dan, n_dan, u8last(cur));
        if (d == 'a' || d == 'i' || d == 'e')
            strcpy(nd[i + 1].pron, "ウ");
    }
}

/* ------------------------------------------------------- 3. retreat_acc_nuc */

static const char *const YOUON[] = { "ャ","ュ","ョ","ァ","ィ","ゥ","ェ","ォ" };
static const char *const BAD_NUC[] = { "ー","ッ","ン" };

static int is_youon(const char *p) {
    for (size_t k = 0; k < sizeof YOUON / sizeof *YOUON; k++)
        if (u8eq(p, YOUON[k])) return 1;
    return 0;
}

static void retreat_acc_nuc(accent_node_t *nd, int n) {
    if (n <= 0) return;
    int acc = 0;
    accent_node_t *head = &nd[0];
    for (int i = 0; i < n; i++) {
        accent_node_t *v = &nd[i];
        if (v->chain_flag == 0 || v->chain_flag == -1) {
            head = v;
            acc = v->acc;
        }
        /* 拗音を落とす。全部落ちたら元の pron を使う（Python と同じ） */
        char pron[ACCENT_PRON_MAX];
        size_t o = 0;
        for (size_t j = 0; v->pron[j]; ) {
            int cl = u8len((unsigned char)v->pron[j]);
            if (!is_youon(v->pron + j) && o + (size_t)cl < sizeof pron) {
                memcpy(pron + o, v->pron + j, (size_t)cl); o += (size_t)cl;
            }
            j += (size_t)cl;
        }
        pron[o] = 0;
        const char *use = (o == 0) ? v->pron : pron;

        if (acc > 0) {
            if (acc <= v->mora_size) {
                const char *nuc = u8at(use, acc - 1);
                if (!nuc) nuc = u8at(use, 0);          /* Python の IndexError 相当 */
                for (size_t k = 0; k < sizeof BAD_NUC / sizeof *BAD_NUC; k++)
                    if (u8eq(nuc, BAD_NUC[k])) { head->acc += -1; break; }
                acc = -1;
            } else {
                acc = acc - v->mora_size;
            }
        }
    }
}

/* -------------------------------------------------- 4. acc_after_chaining */

static int orig_is_chained(const char *s) {
    static const char *const L[] = { "れる","られる","すぎる","せる","させる" };
    for (size_t k = 0; k < sizeof L / sizeof *L; k++)
        if (strcmp(s, L[k]) == 0) return 1;
    return 0;
}

static void modify_acc_after_chaining(accent_node_t *nd, int n) {
    if (n <= 0) return;
    int acc = 0, after_nuc = 0, phase_len = 0;
    accent_node_t *head = &nd[0];
    for (int i = 0; i < n; i++) {
        accent_node_t *v = &nd[i];
        if (v->chain_flag == 0 || v->chain_flag == -1) {
            after_nuc = 0;
            head = v;
            acc = v->acc;
            phase_len = 0;
        }
        if (acc == 0) continue;
        if (after_nuc) {
            if (strcmp(v->ctype, "特殊・マス") == 0)
                head->acc = phase_len + (strcmp(v->cform, "未然形") != 0 ? 1 : 2);
            else if (strcmp(v->ctype, "特殊・ナイ") == 0)
                head->acc = phase_len;
            else if (orig_is_chained(v->orig))
                head->acc = phase_len + v->acc;
            else { after_nuc = 0; acc = 0; }
            phase_len += v->mora_size;
        } else {
            phase_len += v->mora_size;
            if (acc <= v->mora_size) after_nuc = 1;
            else acc = acc - v->mora_size;
        }
    }
}

/* ---------------------------------------------------------------- 適用 */

void accent_apply(accent_node_t *nodes, int n, unsigned mask,
              const accent_dan_t *dan, int n_dan) {
    /* 順序は Python の apply_postprocessing に合わせてある。
     * ⚠️ **ただし「入れ替えてはいけない」は検証できていない。**
     *    retreat と chaining を入れ替えても held-out 1,200 文で結果が
     *    1 文も変わらなかった（Python 側で実測）。ゲートもこの入れ替えを
     *    捕まえられない。**この corpus は段の順序を区別しない。** */
    if (mask & ACCENT_FILLER)     modify_filler_accent(nodes, n);
    if (mask & ACCENT_SUPPRESS_U) suppress_u_long(nodes, n, dan, n_dan);
    if (mask & ACCENT_RETREAT)    retreat_acc_nuc(nodes, n);
    if (mask & ACCENT_CHAINING)   modify_acc_after_chaining(nodes, n);
}
