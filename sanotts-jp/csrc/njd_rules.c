/* K-4b: chaining 前の独自ルール。詳細は njd_rules.h。
 *
 * `pyopenjtalk-plus 0.4.1.post9` の `openjtalk.pyx:1961`
 * `apply_original_rule_before_chaining()` をそのまま写した。
 *
 * ⚠️ Python 版は `njd_features[:-1]` を回す = **最後のノードは i にならない**
 *    （i+1 として触られることはある）。ここも同じにしてある。
 * ⚠️ Python 版は list を in-place で書き換えるので、**後の i は前の i の
 *    書き換えを見る**。連結リストを前から 1 回舐めるのは同じ意味になる。
 *
 * ⚠️ **`njd_rules_hits` は「発火した回数」であって「効いた回数」ではない。**
 *    実測で規則 1（分数 フン/プン→ブン）は 620 文中 4 回発火するが、
 *    書いた結果は後段の `njd_set_digit` に**丸ごと上書きされて消える**。
 *    出力を "ズズズ" に変えても G14a は 620 / 620 のまま通った。
 *    覆えているかの判定には `njd_rules_mask` で抜いて落ちるかを見ること。
 */
#include "njd_rules.h"

#include <string.h>

#define BUF 1024

unsigned njd_rules_hits[NJD_RULES_N];
unsigned njd_rules_mask = ~0u;

const char *const njd_rules_name[NJD_RULES_N] = {
    "不足→ブソク", "分数 フン/プン→ブン", "分数 ブ→ブン", "数+分+の+数→ブン",
    "〇〇→マル", "球→ダマ", "サ変スルを 1 句に", "お/御/ご 接頭",
    "動詞+動詞", "連用形の核を 1 つ戻す", "れる/られる+た", "形容詞+なる/する",
};

/* 条件が真になった時点で数え、マスクが立っているときだけ本体へ進む。
 * ⚠️ **必ず条件の一番最後に置く**（&& の短絡で、条件が真のときだけ数える）。 */
#define FIRE(k) (njd_rules_hits[k]++, (njd_rules_mask >> (k)) & 1u)

/* ------------------------------------------------------------------ UTF-8 */

static int u8len(unsigned char c) {
    if (c < 0x80) return 1;
    if ((c & 0xE0) == 0xC0) return 2;
    if ((c & 0xF0) == 0xE0) return 3;
    return 4;
}

static unsigned u8cp(const char *p) {
    unsigned char c = (unsigned char)*p;
    if (c < 0x80) return c;
    if ((c & 0xE0) == 0xC0) return ((unsigned)(c & 0x1F) << 6)
                                 | (unsigned)(p[1] & 0x3F);
    if ((c & 0xF0) == 0xE0) return ((unsigned)(c & 0x0F) << 12)
                                 | ((unsigned)(p[1] & 0x3F) << 6)
                                 | (unsigned)(p[2] & 0x3F);
    return ((unsigned)(c & 0x07) << 18) | ((unsigned)(p[1] & 0x3F) << 12)
         | ((unsigned)(p[2] & 0x3F) << 6) | (unsigned)(p[3] & 0x3F);
}

static int has_cp_in(const char *s, unsigned lo, unsigned hi) {
    for (size_t i = 0; s[i]; i += (size_t)u8len((unsigned char)s[i])) {
        unsigned c = u8cp(s + i);
        if (c >= lo && c <= hi) return 1;
    }
    return 0;
}

static int ends_with(const char *s, const char *suf) {
    size_t a = strlen(s), b = strlen(suf);
    return a >= b && memcmp(s + a - b, suf, b) == 0;
}

/* s から末尾 n 文字を落として out に入れ、tail を足す。
 * ⚠️ Python の `s[:-n]` は **文字**単位。バイト単位で切ると壊れる。 */
static void chop_add(char *out, const char *s, int n, const char *tail) {
    size_t cut = strlen(s);
    for (int k = 0; k < n; k++) {
        size_t last = 0;
        for (size_t i = 0; i < cut; i += (size_t)u8len((unsigned char)s[i])) last = i;
        cut = last;
    }
    if (cut >= BUF) cut = BUF - 1;
    memcpy(out, s, cut);
    out[cut] = 0;
    strncat(out, tail, BUF - 1 - cut);
}

static int in_list(const char *s, const char *const *list, int n) {
    for (int i = 0; i < n; i++)
        if (strcmp(s, list[i]) == 0) return 1;
    return 0;
}

/* ------------------------------------------------------------------ 本体 */

static const char *const RENYOU[] = {
    "連用形", "連用タ接続", "連用ゴザイ接続", "連用テ接続" };
static const char *const SAHEN_PREV[] = { "サ変接続", "格助詞", "接続助詞" };
static const char *const RARERU[] = { "れる", "られる", "せる", "させる", "ちゃう" };
static const char *const O_PREFIX[] = { "お", "御", "ご" };
static const char *const NARU_SURU[] = { "なる", "する" };

#define N_OF(a) ((int)(sizeof(a) / sizeof(*(a))))

void njd_rules_before_chaining(NJD *njd) {
    NJDNode *prev = NULL, *cur = njd ? njd->head : NULL;
    char buf[BUF];

    for (; cur && cur->next; prev = cur, cur = cur->next) {
        NJDNode *nx = cur->next;
        NJDNode *nx2 = nx->next;

        /* 名詞の後ろで新しい語を作る「不足」は連濁したブソクと読む */
        if (strcmp(NJDNode_get_pos(cur), "名詞") == 0
            && strcmp(NJDNode_get_string(nx), "不足") == 0
            && strcmp(NJDNode_get_pron(nx), "フソク") == 0
            && FIRE(0)) {
            NJDNode_set_read(nx, "ブソク");
            NJDNode_set_pron(nx, "ブソク");
        }

        /* 分母を表す「数値 + 分 + の + 数値」だけブンと読む */
        int is_denom = (nx2 != NULL
                        && strcmp(NJDNode_get_string(nx), "の") == 0
                        && strcmp(NJDNode_get_pos_group1(nx2), "数") == 0);
        if (is_denom && ends_with(NJDNode_get_string(cur), "分")) {
            const char *pr = NJDNode_get_pron(cur);
            if ((ends_with(pr, "フン") || ends_with(pr, "プン")) && FIRE(1)) {
                chop_add(buf, NJDNode_get_read(cur), 2, "ブン");
                NJDNode_set_read(cur, buf);
                chop_add(buf, NJDNode_get_pron(cur), 2, "ブン");
                NJDNode_set_pron(cur, buf);
            } else if (ends_with(pr, "ブ") && FIRE(2)) {
                chop_add(buf, NJDNode_get_read(cur), 0, "ン");
                NJDNode_set_read(cur, buf);
                chop_add(buf, NJDNode_get_pron(cur), 0, "ン");
                NJDNode_set_pron(cur, buf);
            }
        }

        /* 算用数字が別形態素になった分数の「分」 */
        if (prev != NULL && nx2 != NULL
            && strcmp(NJDNode_get_string(cur), "分") == 0
            && strcmp(NJDNode_get_pos_group1(prev), "数") == 0
            && strcmp(NJDNode_get_string(nx), "の") == 0
            && strcmp(NJDNode_get_pos_group1(nx2), "数") == 0
            && FIRE(3)) {
            NJDNode_set_read(cur, "ブン");
            NJDNode_set_pron(cur, "ブン");
        }

        /* 2 文字以上連続する「〇」は伏字なのでマルと読む */
        if (strcmp(NJDNode_get_string(cur), "〇") == 0
            && strcmp(NJDNode_get_string(nx), "〇") == 0
            && FIRE(4)) {
            NJDNode *pair[2] = { cur, nx };
            for (int k = 0; k < 2; k++) {
                NJDNode_set_pos_group1(pair[k], "一般");
                NJDNode_set_read(pair[k], "マル");
                NJDNode_set_pron(pair[k], "マル");
                NJDNode_set_acc(pair[k], 1);
                NJDNode_set_mora_size(pair[k], 2);
            }
        }

        /* 接尾辞「球」は漢字＋ひらがなの和語だけ連濁させる */
        if (strcmp(NJDNode_get_string(nx), "球") == 0
            && strcmp(NJDNode_get_pos(nx), "名詞") == 0
            && strcmp(NJDNode_get_pos_group1(nx), "接尾") == 0
            && strcmp(NJDNode_get_pron(nx), "キュー") == 0
            && has_cp_in(NJDNode_get_string(cur), 0x4E00, 0x9FFF)
            && has_cp_in(NJDNode_get_string(cur), 0x3041, 0x3096)
            && FIRE(5)) {
            NJDNode_set_read(nx, "ダマ");
            NJDNode_set_pron(nx, "ダマ");
            NJDNode_set_acc(nx, 1);
            NJDNode_set_mora_size(nx, 2);
            NJDNode_set_chain_rule(nx, "C4");
        }

        /* サ変動詞(スル)の前が サ変接続 / 名詞,一般 / 副詞 なら 1 アクセント句に纏める */
        if ((in_list(NJDNode_get_pos_group1(cur), SAHEN_PREV, N_OF(SAHEN_PREV))
             || (strcmp(NJDNode_get_pos(cur), "名詞") == 0
                 && strcmp(NJDNode_get_pos_group1(cur), "一般") == 0)
             || strcmp(NJDNode_get_pos(cur), "副詞") == 0)
            && strcmp(NJDNode_get_ctype(nx), "サ変・スル") == 0
            && FIRE(6)) {
            NJDNode_set_chain_flag(nx, 1);
        }

        /* 「お / 御 / ご」の接頭語がつくと後続の結合則が変わる */
        if (in_list(NJDNode_get_string(cur), O_PREFIX, N_OF(O_PREFIX))
            && strcmp(NJDNode_get_chain_rule(cur), "P1") == 0
            && FIRE(7)) {
            if (NJDNode_get_acc(nx) == 0
                || NJDNode_get_acc(nx) == NJDNode_get_mora_size(nx)) {
                NJDNode_set_chain_rule(nx, "C4");
                NJDNode_set_acc(nx, 0);
            } else {
                NJDNode_set_chain_rule(nx, "C1");
            }
        }

        /* 動詞(自立)が連続する場合、後ろの動詞の核が採用される */
        if (strcmp(NJDNode_get_pos(cur), "動詞") == 0
            && strcmp(NJDNode_get_pos(nx), "動詞") == 0
            && FIRE(8)) {
            NJDNode_set_chain_rule(nx, NJDNode_get_acc(nx) != 0 ? "C1" : "C4");
        }

        /* 連用形のアクセント核の登録を修正する */
        if (in_list(NJDNode_get_cform(cur), RENYOU, N_OF(RENYOU))
            && NJDNode_get_acc(cur) == NJDNode_get_mora_size(cur)
            && NJDNode_get_mora_size(cur) > 1
            && FIRE(9)) {
            NJDNode_set_acc(cur, NJDNode_get_acc(cur) - 1);
        }

        /* 「れる / られる…」＋「た」で「た」の F2@0 を上書きする */
        if (in_list(NJDNode_get_orig(cur), RARERU, N_OF(RARERU))
            && strcmp(NJDNode_get_string(nx), "た") == 0
            && FIRE(10)) {
            NJDNode_set_chain_rule(nx, "F2@1");
        }

        /* 形容詞＋「なる / する」は 1 アクセント句に纏める */
        if (strcmp(NJDNode_get_pos(cur), "形容詞") == 0
            && in_list(NJDNode_get_orig(nx), NARU_SURU, N_OF(NARU_SURU))
            && FIRE(11)) {
            NJDNode_set_chain_flag(nx, 1);
        }
    }
}
