/* K-4b: NJD チェーンの「chaining 前」の独自ルール。
 *
 * pyopenjtalk-plus は素の Open JTalk に **Python 側の段を 1 つ挟んでいる**
 * （`openjtalk.pyx` の `apply_original_rule_before_chaining`）:
 *
 *   mecab2njd → njd_set_pronunciation → **ここ** → njd_set_digit
 *   → njd_set_accent_phrase → njd_set_accent_type
 *   → njd_set_unvoiced_vowel → njd_set_long_vowel
 *
 * ⚠️ **これを飛ばすと G14a は 302 / 600 までしか行かない。**
 * K-4 の 4 段（`accent.h`）は **chaining の後**なので別物。混同しないこと。
 *
 * ⚠️ **規則を「改善」しない。** 目的はホストと一致させることであって、
 * 日本語として正しくすることではない。
 */
#ifndef NJD_RULES_H
#define NJD_RULES_H

#include <stdio.h>          /* njd.h が FILE を使うので先に要る */

#include "openjtalk/njd.h"

#ifdef __cplusplus
extern "C" {
#endif

/* njd を in-place で書き換える。Python 版と同じく 1 パス。 */
void njd_rules_before_chaining(NJD *njd);

#define NJD_RULES_N 12

/* 規則ごとの発火回数（条件が真になった回数）。
 * ⚠️ **発火＝覆えている、ではない。** 規則 1 は 620 文で 4 回発火するが、
 * 書いた結果は `njd_set_digit` に上書きされて消えるので、
 * **出力を壊しても G14a は通ってしまう**。覆えているかは下の mask で測る。 */
extern unsigned njd_rules_hits[NJD_RULES_N];

/* bit k を落とすと規則 k を適用しない。既定は全部 1。
 * ゲートはこれで 1 つずつ抜いて、**落ちない規則＝検証できていない規則**を
 * 名指しする。 */
extern unsigned njd_rules_mask;

extern const char *const njd_rules_name[NJD_RULES_N];

#ifdef __cplusplus
}
#endif

#endif /* NJD_RULES_H */
