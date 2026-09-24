/* ----------------------------------------------------------------- */
/*           The Japanese TTS System "Open JTalk"                    */
/*           developed by HTS Working Group                          */
/*           http://open-jtalk.sourceforge.net/                      */
/* ----------------------------------------------------------------- */
/*                                                                   */
/*  Copyright (c) 2008-2016  Nagoya Institute of Technology          */
/*                           Department of Computer Science          */
/*                                                                   */
/* All rights reserved.                                              */
/*                                                                   */
/* Redistribution and use in source and binary forms, with or        */
/* without modification, are permitted provided that the following   */
/* conditions are met:                                               */
/*                                                                   */
/* - Redistributions of source code must retain the above copyright  */
/*   notice, this list of conditions and the following disclaimer.   */
/* - Redistributions in binary form must reproduce the above         */
/*   copyright notice, this list of conditions and the following     */
/*   disclaimer in the documentation and/or other materials provided */
/*   with the distribution.                                          */
/* - Neither the name of the HTS working group nor the names of its  */
/*   contributors may be used to endorse or promote products derived */
/*   from this software without specific prior written permission.   */
/*                                                                   */
/* THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND            */
/* CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,       */
/* INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF          */
/* MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE          */
/* DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS */
/* BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,          */
/* EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED   */
/* TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,     */
/* DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON */
/* ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,   */
/* OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY    */
/* OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE           */
/* POSSIBILITY OF SUCH DAMAGE.                                       */
/* ----------------------------------------------------------------- */

#ifndef JPCOMMON_LABEL_C
#define JPCOMMON_LABEL_C

#ifdef __cplusplus
#define JPCOMMON_LABEL_C_START extern "C" {
#define JPCOMMON_LABEL_C_END   }
#else
#define JPCOMMON_LABEL_C_START
#define JPCOMMON_LABEL_C_END
#endif                          /* __CPLUSPLUS */

JPCOMMON_LABEL_C_START;

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#include "jpcommon.h"

#ifdef ASCII_HEADER
#if defined(CHARSET_EUC_JP)
#include "jpcommon_rule_ascii_for_euc_jp.h"
#elif defined(CHARSET_SHIFT_JIS)
#include "jpcommon_rule_ascii_for_shift_jis.h"
#elif defined(CHARSET_UTF_8)
#include "jpcommon_rule_ascii_for_utf_8.h"
#else
#error CHARSET is not specified
#endif
#else
#if defined(CHARSET_EUC_JP)
#include "jpcommon_rule_euc_jp.h"
#elif defined(CHARSET_SHIFT_JIS)
#include "jpcommon_rule_shift_jis.h"
#elif defined(CHARSET_UTF_8)
#include "jpcommon_rule_utf_8.h"
#else
#error CHARSET is not specified
#endif
#endif

#define MAXBUFLEN 256
#define MAX_S     19
#define MAX_M     49 // NOTE: おそらく Maximum_Medium
#define MAX_L     99
#define MAX_LL    199

static const char *nodata = "*";

// NOTE:
// string top compare の略 ?
// 以下の振る舞いをする：
// - pattern 全長が str の冒頭に一致する -> len(pattern)。例: `hello_world` / `hello`
// - str 全長が pattern の冒頭に一致する -> -1。          例: `hello` / `hello_world`
// - 不一致箇所が見つかる                -> -1。          例: `heo_world` / `hello`
static int strtopcmp(const char *str, const char *pattern)
{
   int i;

   for (i = 0;; i++) {
      if (pattern[i] == '\0')
         return i;
      if (str[i] == '\0')
         return -1;
      if (str[i] != pattern[i])
         return -1;
   }
}

static int limit(int in, int min, int max)
// NOTE: 最小値と最大値で値を clip する
{
   if (in <= min)
      return min;
   if (in >= max)
      return max;
   return in;
}

static int append_format(char *destination, size_t destination_size, const char *format, ...)
{
   size_t current_length;
   int write_result;
   va_list variable_arguments;

   if (destination == NULL || format == NULL || destination_size == 0) {
      return 0;
   }

   current_length = strlen(destination);
   if (current_length >= destination_size) {
      return 0;
   }

   va_start(variable_arguments, format);
   write_result =
      vsnprintf(destination + current_length, destination_size - current_length, format, variable_arguments);
   va_end(variable_arguments);

   if (write_result < 0) {
      return 0;
   }
   if ((size_t) write_result >= destination_size - current_length) {
      destination[destination_size - 1] = '\0';
      return 0;
   }

   return 1;
}

static char *duplicate_or_nodata(const char *source)
{
   char *copied;

   if (source == NULL) {
      source = nodata;
   }
   copied = strdup(source);
   if (copied == NULL) {
      return (char *) nodata;
   }
   return copied;
}

static void JPCommonLabelPhoneme_initialize(JPCommonLabelPhoneme * p, const char *phoneme,
                                            JPCommonLabelPhoneme * prev,
                                            JPCommonLabelPhoneme * next, JPCommonLabelMora * up)
{
   p->phoneme = duplicate_or_nodata(phoneme);
   p->prev = prev;
   p->next = next;
   p->up = up;
}

static void JPCommonLabelPhoneme_convert_unvoice(JPCommonLabelPhoneme * p)
{
   int i;

   for (i = 0; jpcommon_unvoice_list[i] != NULL; i += 2) {
      if (strcmp(jpcommon_unvoice_list[i], p->phoneme) == 0) {
         if (p->phoneme != nodata) {
            free(p->phoneme);
         }
         p->phoneme = duplicate_or_nodata(jpcommon_unvoice_list[i + 1]);
         return;
      }
   }

   fprintf(stderr,
           "WARNING: JPCommonLabelPhoneme_convert_unvoice() in jpcommon_label.c: %s cannot be unvoiced.\n",
           p->phoneme);
}

static void JPCommonLabelPhoneme_clear(JPCommonLabelPhoneme * p)
{
   if (p->phoneme != nodata) {
      free(p->phoneme);
   }
}

static void JPCommonLabelMora_initialize(JPCommonLabelMora * m, const char *mora,
                                         JPCommonLabelPhoneme * head, JPCommonLabelPhoneme * tail,
                                         JPCommonLabelMora * prev, JPCommonLabelMora * next,
                                         JPCommonLabelWord * up)
{
   m->mora = duplicate_or_nodata(mora);
   m->head = head;
   m->tail = tail;
   m->prev = prev;
   m->next = next;
   m->up = up;
}

static void JPCommonLabelMora_clear(JPCommonLabelMora * m)
{
   if (m->mora != nodata) {
      free(m->mora);
   }
}

// NOTE: ワード情報をフォーマット変換して JPCommonLabelWord を生成する。
static void JPCommonLabelWord_initialize(JPCommonLabelWord * w, const char *pron, const char *pos,
                                         const char *ctype, const char *cform,
                                         JPCommonLabelMora * head, JPCommonLabelMora * tail,
                                         JPCommonLabelWord * prev, JPCommonLabelWord * next)
{
   int i, find;

   // NOTE: 発音を設定する
   w->pron = duplicate_or_nodata(pron);

   // NOTE: 品詞 ID を設定する
   for (i = 0, find = 0; jpcommon_pos_list[i] != NULL; i += 2) {
      if (strcmp(jpcommon_pos_list[i], pos) == 0) {
         find = 1;
         break;
      }
   }
   if (find == 0) {
      fprintf(stderr,
              "WARNING: JPCommonLabelWord_initialize() in jpcommon_label.c: %s is unknown POS.\n",
              pos);
      i = 0;
   }
   w->pos = duplicate_or_nodata(jpcommon_pos_list[i + 1]);

   // NOTE: 活用型 ID を設定する
   for (i = 0, find = 0; jpcommon_ctype_list[i] != NULL; i += 2) {
      if (strcmp(jpcommon_ctype_list[i], ctype) == 0) {
         find = 1;
         break;
      }
   }
   if (find == 0) {
      fprintf(stderr,
              "WARNING: JPCommonLabelWord_initialize() in jpcommon_label.c: %s is unknown conjugation type.\n",
              ctype);
      i = 0;
   }
   w->ctype = duplicate_or_nodata(jpcommon_ctype_list[i + 1]);

   // NOTE: 活用形 ID を設定する
   for (i = 0, find = 0; jpcommon_cform_list[i] != NULL; i += 2) {
      if (strcmp(jpcommon_cform_list[i], cform) == 0) {
         find = 1;
         break;
      }
   }
   if (find == 0) {
      fprintf(stderr,
              "WARNING: JPCommonLabelWord_initialize() in jpcommon_label.c: %s is unknown conjugation form .\n",
              cform);
      i = 0;
   }
   w->cform = duplicate_or_nodata(jpcommon_cform_list[i + 1]);

   // NOTE: head/tail/prev/next を設定する
   w->head = head;
   w->tail = tail;
   w->prev = prev;
   w->next = next;
}

static void JPCommonLabelWord_clear(JPCommonLabelWord * w)
{
   if (w->pron != nodata)
      free(w->pron);
   if (w->pos != nodata)
      free(w->pos);
   if (w->ctype != nodata)
      free(w->ctype);
   if (w->cform != nodata)
      free(w->cform);
}

static void JPCommonLabelAccentPhrase_initialize(JPCommonLabelAccentPhrase * a, int acc,
                                                 const char *emotion, const char *excl, JPCommonLabelWord * head,
                                                 JPCommonLabelWord * tail,
                                                 JPCommonLabelAccentPhrase * prev,
                                                 JPCommonLabelAccentPhrase * next,
                                                 JPCommonLabelBreathGroup * up)
{
   a->accent = acc;
   if (emotion != NULL)
      a->emotion = duplicate_or_nodata(emotion);
   else
      a->emotion = NULL;

   if (excl != NULL)
      a->excl = duplicate_or_nodata(excl);
   else
      a->excl = NULL;

   a->head = head;
   a->tail = tail;
   a->prev = prev;
   a->next = next;
   a->up = up;
}

static void JPCommonLabelAccentPhrase_clear(JPCommonLabelAccentPhrase * a)
{
   if (a->emotion != NULL && a->emotion != nodata)
      free(a->emotion);
   if (a->excl != NULL && a->excl != nodata)
      free(a->excl);
}

static void JPCommonLabelBreathGroup_initialize(JPCommonLabelBreathGroup * b,
                                                JPCommonLabelAccentPhrase * head,
                                                JPCommonLabelAccentPhrase * tail,
                                                JPCommonLabelBreathGroup * prev,
                                                JPCommonLabelBreathGroup * next)
{
   b->head = head;
   b->tail = tail;
   b->prev = prev;
   b->next = next;
}

static void JPCommonLabelBreathGroup_clear(JPCommonLabelBreathGroup * b)
{
}

static int index_mora_in_accent_phrase(JPCommonLabelMora * m)
// NOTE: アクセント句におけるモーラのインデックス（1始まり）を算出する。
{
   int i;
   JPCommonLabelMora *index;

   // NOTE: `index` の初期値は head mora (MR -> [up] -> WD -> [up] -> AP -> [head] -> WD -> [head] -> MR)
   for (i = 0, index = m->up->up->head->head; index != NULL; index = index->next) {
      i++;
      if (index == m)
         break;
   }
   return i;
}

static int count_mora_in_accent_phrase(JPCommonLabelMora * m)
// NOTE: アクセント句に含まれるモーラの数を算出する。
{
   int i;
   JPCommonLabelMora *index;

   // NOTE: `index` の初期値は head mora (MR -> [up] -> WD -> [up] -> AP -> [head] -> WD -> [head] -> MR)
   for (i = 0, index = m->up->up->head->head; index != NULL; index = index->next) {
      i++;
      if (index == m->up->up->tail->tail)
         break;
   }
   return i;
}

static int index_accent_phrase_in_breath_group(JPCommonLabelAccentPhrase * a)
// NOTE: BreathGroup におけるアクセント句のインデックス（1始まり）を算出する。
{
   int i;
   JPCommonLabelAccentPhrase *index;

   // NOTE: `index` の初期値は head accent phrase (AP -> [up] -> BG -> [head] -> AP)
   for (i = 0, index = a->up->head; index != NULL; index = index->next) {
      i++;
      if (index == a)
         break;
   }
   return i;
}

static int count_accent_phrase_in_breath_group(JPCommonLabelAccentPhrase * a)
// NOTE: BreathGroup に含まれるアクセント句の数を算出する。
{
   int i;
   JPCommonLabelAccentPhrase *index;

   // NOTE: `index` の初期値は head accent phrase (AP -> [up] -> BG -> [head] -> AP)
   for (i = 0, index = a->up->head; index != NULL; index = index->next) {
      i++;
      if (index == a->up->tail)
         break;
   }
   return i;
}

static int index_mora_in_breath_group(JPCommonLabelMora * m)
// NOTE: BreathGroup におけるモーラのインデックス（1始まり）を算出する。
{
   int i;
   JPCommonLabelMora *index;

   // NOTE: `index` の初期値は head mora (MR -> [up] -> WD -> [up] -> AP -> [up] -> BG -> [head] -> AP -> [head] -> WD -> [head] -> MR)
   for (i = 0, index = m->up->up->up->head->head->head; index != NULL; index = index->next) {
      i++;
      if (index == m)
         break;
   }
   return i;
}

static int count_mora_in_breath_group(JPCommonLabelMora * m)
{
   int i;
   JPCommonLabelMora *index;

   for (i = 0, index = m->up->up->up->head->head->head; index != NULL; index = index->next) {
      i++;
      if (index == m->up->up->up->tail->tail->tail)
         break;
   }
   return i;
}

static int index_breath_group_in_utterance(JPCommonLabelBreathGroup * b)
{
   int i;
   JPCommonLabelBreathGroup *index;

   for (i = 0, index = b; index != NULL; index = index->prev)
      i++;
   return i;
}

static int count_breath_group_in_utterance(JPCommonLabelBreathGroup * b)
{
   int i;
   JPCommonLabelBreathGroup *index;

   for (i = 0, index = b->next; index != NULL; index = index->next)
      i++;
   return index_breath_group_in_utterance(b) + i;
}

static int index_accent_phrase_in_utterance(JPCommonLabelAccentPhrase * a)
{
   int i;
   JPCommonLabelAccentPhrase *index;

   for (i = 0, index = a; index != NULL; index = index->prev)
      i++;
   return i;
}

static int count_accent_phrase_in_utterance(JPCommonLabelAccentPhrase * a)
{
   int i;
   JPCommonLabelAccentPhrase *index;

   for (i = 0, index = a->next; index != NULL; index = index->next)
      i++;
   return index_accent_phrase_in_utterance(a) + i;
}

static int index_mora_in_utterance(JPCommonLabelMora * m)
{
   int i;
   JPCommonLabelMora *index;

   for (i = 0, index = m; index != NULL; index = index->prev)
      i++;
   return i;
}

static int count_mora_in_utterance(JPCommonLabelMora * m)
{
   int i;
   JPCommonLabelMora *index;

   for (i = 0, index = m->next; index != NULL; index = index->next)
      i++;
   return index_mora_in_utterance(m) + i;
}

void JPCommonLabel_initialize(JPCommonLabel * label)
{
   label->is_valid = 1;
   label->short_pause_flag = 0;
   label->breath_head = NULL;
   label->breath_tail = NULL;
   label->accent_head = NULL;
   label->accent_tail = NULL;
   label->word_head = NULL;
   label->word_tail = NULL;
   label->mora_head = NULL;
   label->mora_tail = NULL;
   label->phoneme_head = NULL;
   label->phoneme_tail = NULL;

   label->size = 0;
   label->feature = NULL;
}

// NOTE:
// Label に `short_pause_flag` フラグが経っていた場合、フラグを消費して末尾に pau 音素（.up 無し）を追加する
// "pau flag ON No.1" と "pau flag ON No.2" の2箇所でのみフラグが ON になる。

static void JPCommonLabel_insert_pause(JPCommonLabel * label)
{
   /* insert short pause */
   if (label->short_pause_flag == 1) {
      if (label->phoneme_tail != NULL) {
         // NOTE: 空の Label ではない
         if (strcmp(label->phoneme_tail->phoneme, JPCOMMON_PHONEME_SHORT_PAUSE) == 0) {
            // NOTE: pau は連続しない
            fprintf(stderr,
                    "WARNING: JPCommonLabel_insert_pause() in jpcommon_label.c: Short pause should not be chained.\n");
            return;
         }
         // NOTE: up 無しの pau 音素を追加する
         label->phoneme_tail->next =
             (JPCommonLabelPhoneme *) calloc(1, sizeof(JPCommonLabelPhoneme));
         if (label->phoneme_tail->next == NULL) {
            fprintf(stderr, "WARNING: JPCommonLabel_insert_pause() in jpcommon_label.c: Failed to allocate phoneme.\n");
            label->is_valid = 0;
            return;
         }
         JPCommonLabelPhoneme_initialize(label->phoneme_tail->next, JPCOMMON_PHONEME_SHORT_PAUSE,
                                         label->phoneme_tail, NULL, NULL);
         label->phoneme_tail = label->phoneme_tail->next;
      } else {
         // NOTE: 文頭の括弧や引用符に由来する短ポーズは音声上の先行要素がないため追加しない
         // 比較的高頻度で発生するエラーでうるさいのでコメントアウト
         // fprintf(stderr,
         //    "WARNING: JPCommonLabel_insert_pause() in jpcommon_label.c: First mora should not be short pause.\n");
      }

      // NOTE: フラグを消費する
      label->short_pause_flag = 0;
   }
}

void JPCommonLabel_push_word(JPCommonLabel * label, const char *pron, const char *pos,
                             const char *ctype, const char *cform, int acc, int chain_flag)
// NOTE:
// ワードの情報を構造化された JPCommonLabel へ収納する。
// `pos`/`ctype`/`cform` は詰め替えされるだけで変更も利用もされない。
// 利用先は `JPCommon_make_label()` のみ。
{
   int i;
   int find; // NOTE: 発音中に検出されたモーラのバイト長
   int is_first_word = 1; // NOTE: この呼び出し中にワードが未生成である

   // NOTE: `、` 単体の場合、Label に pau フラグを立てるのみで終了する
   if (strcmp(pron, JPCOMMON_MORA_SHORT_PAUSE) == 0) {
      // NOTE: pau flag ON No.1
      label->short_pause_flag = 1;
      return;
   }

   /* set emotion flag */
   // NOTE: `？` 単体の場合、アクセント句に疑問形フラグを・Label に pau フラグを立てるのみで終了する
   if (strcmp(pron, JPCOMMON_MORA_QUESTION) == 0) {
      // NOTE: アクセント句に疑問形フラグを立てる
      if (label->phoneme_tail != NULL) {
         if (strcmp(label->phoneme_tail->phoneme, JPCOMMON_PHONEME_SHORT_PAUSE) == 0) {
            // NOTE: 「`a`→`pau`→`？`」の場合は `a` が所属するアクセント句に設定する
            if (label->phoneme_tail->prev->up->up->up->emotion == NULL)
               label->phoneme_tail->prev->up->up->up->emotion = duplicate_or_nodata(JPCOMMON_FLAG_QUESTION);
         } else {
            // NOTE: 「`a`→`？`」の場合は `a` が所属するアクセント句に設定する
            if (label->phoneme_tail->up->up->up->emotion == NULL)
               label->phoneme_tail->up->up->up->emotion = duplicate_or_nodata(JPCOMMON_FLAG_QUESTION);
         }
      } else {
         // NOTE: 空 Label の先頭が「？」のときは警告を出して無視する
         fprintf(stderr,
                 "WARNING: JPCommonLabel_push_word() in jpcommon_label.c: First mora should not be question flag.\n");
      }

      // NOTE: Label に pau フラグを立てる
      // NOTE: pau flag ON No.2
      label->short_pause_flag = 1;

      return;
   }

   /* set exclamation flag */ // added by me
   if (strcmp(pron, JPCOMMON_MORA_EXCLAMATION) == 0) {
      if (label->phoneme_tail != NULL) {
         if (strcmp(label->phoneme_tail->phoneme, JPCOMMON_PHONEME_SHORT_PAUSE) == 0) {
            if (label->phoneme_tail->prev->up->up->up->excl == NULL)
               label->phoneme_tail->prev->up->up->up->excl = duplicate_or_nodata(JPCOMMON_FLAG_EXCLAMATION);
         } else {
            if (label->phoneme_tail->up->up->up->excl == NULL)
               label->phoneme_tail->up->up->up->excl = duplicate_or_nodata(JPCOMMON_FLAG_EXCLAMATION);
         }
      } else {
         fprintf(stderr,
                 "WARNING: JPCommonLabel_push_word() in jpcommon_label.c: First mora should not be exclamation flag.\n");
      }
      label->short_pause_flag = 1;
      return;
   }

   // NOTE: pau flag ON (`label->short_pause_flag = 1`) はこれ以降おこなわれない

   /* analysis pron */
   // NOTE:
   // ワードの発音からワード以下の各階層のオブジェクトを生成する。
   // 以下の4ルートのいずれかに入る：
   //   - route_A: 長音「ー」
   //   - route_B: 無声化「’」
   //   - route_C: 一般モーラ
   //   - route_D: リスト外の入力
   /* NOTE:
      インスタンス生成は一定のパターンに従っている。
      大枠としては「`calloc()` による収納先のメモリ確保 -> `*_initialize()` による初期化」になっている。
      収納先は Label の状況によって異なり、先行要素が無ければ `label.*_tail`、あれば `label.*_tail.next` になる。
      `*_initialize()` の引数も状況によって異なり、先行要素が無ければ prev=NULL/next=NULL、あれば prev=tail/next=NULL になる。
   */
   while (pron[0] != '\0') {
      find = strtopcmp(pron, JPCOMMON_MORA_LONG_VOWEL);
      if (find != -1) {
         /* for long vowel */
         // NOTE: route_A:「ー」に応じ、音素とモーラを追加する
         if (label->phoneme_tail != NULL && label->short_pause_flag == 0) {
            // NOTE: 先行音素が存在する
            JPCommonLabel_insert_pause(label);
            // NOTE: 「前の音素と同じ記号の音素」を新しいモーラへ追加する
            label->phoneme_tail->next =
                (JPCommonLabelPhoneme *) calloc(1, sizeof(JPCommonLabelPhoneme));
            label->mora_tail->next = (JPCommonLabelMora *) calloc(1, sizeof(JPCommonLabelMora));
            if (label->phoneme_tail->next == NULL || label->mora_tail->next == NULL) {
               fprintf(stderr, "WARNING: JPCommonLabel_push_word() in jpcommon_label.c: Failed to allocate long-vowel nodes.\n");
               if (label->phoneme_tail->next != NULL) {
                  free(label->phoneme_tail->next);
                  label->phoneme_tail->next = NULL;
               }
               if (label->mora_tail->next != NULL) {
                  free(label->mora_tail->next);
                  label->mora_tail->next = NULL;
               }
               label->is_valid = 0;
               return;
            }
            JPCommonLabelPhoneme_initialize(label->phoneme_tail->next, label->phoneme_tail->phoneme,
                                            label->phoneme_tail, NULL, label->mora_tail->next);
            // NOTE: 長音は音素1つでモーラを作るので head == tail となる
            // NOTE: 長音は前に続くので先行モーラと同じワードに属する
            JPCommonLabelMora_initialize(label->mora_tail->next, JPCOMMON_MORA_LONG_VOWEL,
                                         label->phoneme_tail->next, label->phoneme_tail->next,
                                         label->mora_tail, NULL, label->mora_tail->up);
            label->phoneme_tail = label->phoneme_tail->next;
            label->mora_tail = label->mora_tail->next;
            label->word_tail->tail = label->mora_tail;
         } else {
            // NOTE: 先頭が「ー」のときや「pau → ー」のときは警告を出して無視する
            fprintf(stderr,
                    "WARNING: JPCommonLabel_push_word() in jpcommon_label.c: First mora should not be long vowel symbol.\n");
         }
         // NOTE: 一致した文字数分、ポインターを前進させる
         pron += find;
      } else {
         find = strtopcmp(pron, JPCOMMON_MORA_UNVOICE);
         if (find != -1) {
            // NOTE:
            // route_B:「’」に応じ、音素を無声化する
            // 既存の音素を更新するため、音素やモーラの新規追加は無い
            /* for unvoice */
            if (label->phoneme_tail != NULL && is_first_word != 1)
               JPCommonLabelPhoneme_convert_unvoice(label->phoneme_tail);
            else
               fprintf(stderr,
                       "WARNING: JPCommonLabel_push_word() in jpcommon_label.c: First mora should not be unvoice flag.\n");
            // NOTE: 一致した文字数分、ポインターを前進させる
            pron += find;
         } else {
            /* for normal word */
            // NOTE: `jpcommon_mora_list` は文字数の多いモーラを小さいインデックス側に置いているため longest match になっている
            for (i = 0; jpcommon_mora_list[i] != NULL; i += 3) {
               find = strtopcmp(pron, jpcommon_mora_list[i]);
               if (find != -1)
                  break;
            }
            if (find != -1) {
               // NOTE: route_C: モーラを追加する
               if (label->phoneme_tail == NULL) {
                  // NOTE: route_C1: 空の Label であるため先行要素が無く、ワードレベルから生成する
                  JPCommonLabel_insert_pause(label);
                  // NOTE: 1つめの音素を新しいモーラへ追加し、モーラも新しいワードに追加する
                  label->phoneme_tail =
                      (JPCommonLabelPhoneme *) calloc(1, sizeof(JPCommonLabelPhoneme));
                  label->mora_tail = (JPCommonLabelMora *) calloc(1, sizeof(JPCommonLabelMora));
                  label->word_tail = (JPCommonLabelWord *) calloc(1, sizeof(JPCommonLabelWord));
                  if (label->phoneme_tail == NULL || label->mora_tail == NULL || label->word_tail == NULL) {
                     fprintf(stderr, "WARNING: JPCommonLabel_push_word() in jpcommon_label.c: Failed to allocate initial word nodes.\n");
                     if (label->phoneme_tail != NULL) {
                        free(label->phoneme_tail);
                        label->phoneme_tail = NULL;
                     }
                     if (label->mora_tail != NULL) {
                        free(label->mora_tail);
                        label->mora_tail = NULL;
                     }
                     if (label->word_tail != NULL) {
                        free(label->word_tail);
                        label->word_tail = NULL;
                     }
                     label->is_valid = 0;
                     return;
                  }
                  JPCommonLabelPhoneme_initialize(label->phoneme_tail, jpcommon_mora_list[i + 1],
                                                  NULL, NULL, label->mora_tail);
                  // NOTE: 1つめの音素・モーラしかまだ存在しないので head == tail となる
                  // NOTE: 新規ワードに属する
                  JPCommonLabelMora_initialize(label->mora_tail, jpcommon_mora_list[i],
                                               label->phoneme_tail, label->phoneme_tail, NULL, NULL,
                                               label->word_tail);
                  JPCommonLabelWord_initialize(label->word_tail, pron, pos, ctype, cform,
                                               label->mora_tail, label->mora_tail, NULL, NULL);
                  label->phoneme_head = label->phoneme_tail;
                  label->mora_head = label->mora_tail;
                  label->word_head = label->word_tail;
                  // NOTE: is_first_word フラグを立てる
                  is_first_word = 0;
               } else {
                  // NOTE: 空の Label でない
                  if (is_first_word == 1) {
                     // NOTE: 先行要素が存在し、この呼び出しで初めてのワード追加である
                     JPCommonLabel_insert_pause(label);
                     // NOTE: 1つめの音素を新しいモーラへ追加し、モーラも新しいワードへ追加する
                     label->phoneme_tail->next =
                         (JPCommonLabelPhoneme *) calloc(1, sizeof(JPCommonLabelPhoneme));
                     label->mora_tail->next =
                         (JPCommonLabelMora *) calloc(1, sizeof(JPCommonLabelMora));
                     label->word_tail->next =
                         (JPCommonLabelWord *) calloc(1, sizeof(JPCommonLabelWord));
                     if (label->phoneme_tail->next == NULL || label->mora_tail->next == NULL ||
                         label->word_tail->next == NULL) {
                        fprintf(stderr, "WARNING: JPCommonLabel_push_word() in jpcommon_label.c: Failed to allocate first-word continuation nodes.\n");
                        if (label->phoneme_tail->next != NULL) {
                           free(label->phoneme_tail->next);
                           label->phoneme_tail->next = NULL;
                        }
                        if (label->mora_tail->next != NULL) {
                           free(label->mora_tail->next);
                           label->mora_tail->next = NULL;
                        }
                        if (label->word_tail->next != NULL) {
                           free(label->word_tail->next);
                           label->word_tail->next = NULL;
                        }
                        label->is_valid = 0;
                        return;
                     }
                     JPCommonLabelPhoneme_initialize(label->phoneme_tail->next,
                                                     jpcommon_mora_list[i + 1], label->phoneme_tail,
                                                     NULL, label->mora_tail->next);
                     // NOTE: 新しいワードに属する音素とモーラしかまだ1つしか存在しないので head == tail となる
                     JPCommonLabelMora_initialize(label->mora_tail->next, jpcommon_mora_list[i],
                                                  label->phoneme_tail->next,
                                                  label->phoneme_tail->next, label->mora_tail, NULL,
                                                  label->word_tail->next);
                     JPCommonLabelWord_initialize(label->word_tail->next, pron, pos, ctype, cform,
                                                  label->mora_tail->next, label->mora_tail->next,
                                                  label->word_tail, NULL);
                     label->phoneme_tail = label->phoneme_tail->next;
                     label->mora_tail = label->mora_tail->next;
                     label->word_tail = label->word_tail->next;
                     is_first_word = 0;
                  } else {
                     // NOTE: 先行要素が存在し、既にこの呼び出し内でワードが追加されている
                     JPCommonLabel_insert_pause(label);
                     // NOTE: 1つめの音素を新しいモーラへ追加する
                     label->phoneme_tail->next =
                         (JPCommonLabelPhoneme *) calloc(1, sizeof(JPCommonLabelPhoneme));
                     label->mora_tail->next =
                         (JPCommonLabelMora *) calloc(1, sizeof(JPCommonLabelMora));
                     if (label->phoneme_tail->next == NULL || label->mora_tail->next == NULL) {
                        fprintf(stderr, "WARNING: JPCommonLabel_push_word() in jpcommon_label.c: Failed to allocate mora continuation nodes.\n");
                        if (label->phoneme_tail->next != NULL) {
                           free(label->phoneme_tail->next);
                           label->phoneme_tail->next = NULL;
                        }
                        if (label->mora_tail->next != NULL) {
                           free(label->mora_tail->next);
                           label->mora_tail->next = NULL;
                        }
                        label->is_valid = 0;
                        return;
                     }
                     JPCommonLabelPhoneme_initialize(label->phoneme_tail->next,
                                                     jpcommon_mora_list[i + 1], label->phoneme_tail,
                                                     NULL, label->mora_tail->next);
                     // NOTE: 1つめの音素しかまだ存在しないので head == tail となる
                     // NOTE: 先行のワード追加時にモーラが追加されており、同じワード所属なのでこれと同じワードへ属する。
                     JPCommonLabelMora_initialize(label->mora_tail->next, jpcommon_mora_list[i],
                                                  label->phoneme_tail->next,
                                                  label->phoneme_tail->next, label->mora_tail, NULL,
                                                  label->mora_tail->up);
                     label->phoneme_tail = label->phoneme_tail->next;
                     label->mora_tail = label->mora_tail->next;
                     label->word_tail->tail = label->mora_tail;
                  }
               }

               // NOTE: 2音素モーラの2音素目を追加する
               if (jpcommon_mora_list[i + 2] != NULL) {
                  // NOTE: 先行要素が存在する
                  JPCommonLabel_insert_pause(label);
                  // NOTE: 2つめの音素を既存のモーラへ追加する
                  label->phoneme_tail->next =
                      (JPCommonLabelPhoneme *) calloc(1, sizeof(JPCommonLabelPhoneme));
                  if (label->phoneme_tail->next == NULL) {
                     fprintf(stderr, "WARNING: JPCommonLabel_push_word() in jpcommon_label.c: Failed to allocate second phoneme.\n");
                     label->is_valid = 0;
                     return;
                  }
                  JPCommonLabelPhoneme_initialize(label->phoneme_tail->next,
                                                  jpcommon_mora_list[i + 2], label->phoneme_tail,
                                                  NULL, label->mora_tail);
                  label->phoneme_tail = label->phoneme_tail->next;
                  label->mora_tail->tail = label->phoneme_tail;
               }

               // NOTE: 一致した文字数分、ポインターを前進させる
               pron += find;
            } else {
               // NOTE: route_D: モーラリストに存在しない発音が検出された
               fprintf(stderr,
                       "WARNING: JPCommonLabel_push_word() in jpcommon_label.c: %s is wrong mora list.\n",
                       pron);
               // NOTE: ポインターを前進させずに break
               break;
            }
         }
      }
   }

   /* check */
   // NOTE: ワードの追加が無かった（例: 冒頭に不正な発音で打ち切り）
   if (is_first_word == 1)
      return;
   // NOTE: 音素が存在しない（例: pron が空）
   if (label->phoneme_tail == NULL)
      return;
   // NOTE:
   // pau のあとに音素が追加されていない
   // `JPCommonLabel_insert_pause()` の後に必ず音素追加が走っているので、起きないはず？
   if (strcmp(label->phoneme_tail->phoneme, JPCOMMON_PHONEME_SHORT_PAUSE) == 0)
      return;

   /* make accent, phrase */
   // NOTE: アクセント句と BreathGroup を更新する。
   if (label->word_head == label->word_tail) {
      /* first word */
      // NOTE: この呼び出しでワードを追加し、かつ Label にワードが1つだけなので、全体の first word である
      label->accent_tail =
          (JPCommonLabelAccentPhrase *) calloc(1, sizeof(JPCommonLabelAccentPhrase));
      label->breath_tail = (JPCommonLabelBreathGroup *) calloc(1, sizeof(JPCommonLabelBreathGroup));
      if (label->accent_tail == NULL || label->breath_tail == NULL) {
         fprintf(stderr, "WARNING: JPCommonLabel_push_word() in jpcommon_label.c: Failed to allocate initial accent/breath group.\n");
         if (label->accent_tail != NULL) {
            free(label->accent_tail);
            label->accent_tail = NULL;
         }
         if (label->breath_tail != NULL) {
            free(label->breath_tail);
            label->breath_tail = NULL;
         }
         label->is_valid = 0;
         return;
      }
      // NOTE: ワードにアクセント句を紐づける
      label->word_tail->up = label->accent_tail;
      // NOTE: 1つめのワード・アクセント句しかまだ存在しないので head == tail となる
      // NOTE: AP head word の acc を AP のアクセントとする
      JPCommonLabelAccentPhrase_initialize(label->accent_tail, acc, NULL, NULL, label->word_tail,
                                           label->word_tail, NULL, NULL, label->breath_tail);
      JPCommonLabelBreathGroup_initialize(label->breath_tail, label->accent_tail,
                                          label->accent_tail, NULL, NULL);
      label->accent_head = label->accent_tail;
      label->breath_head = label->breath_tail;
   } else if (chain_flag == 1) {
      /* common accent phrase and common phrase */
      // NOTE: ワードが2つ以上存在し、かつワードの連鎖フラグが立っている
      // NOTE: 追加したワードの `.up` を既存のアクセント句に設定し、同様に `.tail` を更新する
      label->word_tail->up = label->accent_tail;
      label->accent_tail->tail = label->word_tail;
   } else
       if (strcmp(label->word_tail->prev->tail->tail->next->phoneme, JPCOMMON_PHONEME_SHORT_PAUSE)
           != 0) {
      // NOTE: ワードが2つ以上存在し、ワードの連鎖フラグが立っておらず、前のワードの末尾モーラが pau ではない
      /* different accent phrase && common phrase */
      // NOTE: pau がないため同じ BreathGroup で、連鎖していないので新しいアクセント句となる
      label->accent_tail->next =
          (JPCommonLabelAccentPhrase *) calloc(1, sizeof(JPCommonLabelAccentPhrase));
      if (label->accent_tail->next == NULL) {
         fprintf(stderr, "WARNING: JPCommonLabel_push_word() in jpcommon_label.c: Failed to allocate accent phrase.\n");
         label->is_valid = 0;
         return;
      }
      label->word_tail->up = label->accent_tail->next;
      // NOTE: 新しいアクセント句にワードが1つしかないので head==tail となる
      // NOTE: AP head word の acc を AP のアクセントとする
      JPCommonLabelAccentPhrase_initialize(label->accent_tail->next, acc, NULL, NULL, label->word_tail,
                                           label->word_tail, label->accent_tail, NULL,
                                           label->breath_tail);
      label->breath_tail->tail = label->accent_tail->next;
      label->accent_tail = label->accent_tail->next;
   } else {
      // NOTE: ワードが2つ以上存在し、ワードの連鎖フラグが立っておらず、前のワードの末尾モーラが pau である
      /* different accent phrase && different phrase */
      // NOTE: pau があるため新しい BreathGroup で、連鎖していないので新しいアクセント句となる
      label->accent_tail->next =
          (JPCommonLabelAccentPhrase *) calloc(1, sizeof(JPCommonLabelAccentPhrase));
      label->breath_tail->next =
          (JPCommonLabelBreathGroup *) calloc(1, sizeof(JPCommonLabelBreathGroup));
      if (label->accent_tail->next == NULL || label->breath_tail->next == NULL) {
         fprintf(stderr, "WARNING: JPCommonLabel_push_word() in jpcommon_label.c: Failed to allocate accent/breath next nodes.\n");
         if (label->accent_tail->next != NULL) {
            free(label->accent_tail->next);
            label->accent_tail->next = NULL;
         }
         if (label->breath_tail->next != NULL) {
            free(label->breath_tail->next);
            label->breath_tail->next = NULL;
         }
         label->is_valid = 0;
         return;
      }
      label->word_tail->up = label->accent_tail->next;
      // NOTE: 新しいアクセント句にワードが1つしかないので head==tail となる
      // NOTE: AP head word の acc を AP のアクセントとする
      JPCommonLabelAccentPhrase_initialize(label->accent_tail->next, acc, NULL, NULL, label->word_tail,
                                           label->word_tail, label->accent_tail, NULL,
                                           label->breath_tail->next);
      // NOTE: 新しい BreathGroup にアクセント句が1つしかないので head==tail となる
      JPCommonLabelBreathGroup_initialize(label->breath_tail->next, label->accent_tail->next,
                                          label->accent_tail->next, label->breath_tail, NULL);
      label->accent_tail = label->accent_tail->next;
      label->breath_tail = label->breath_tail->next;
   }
}

void JPCommonLabel_make(JPCommonLabel * label)
// NOTE: フルコンテキストラベル文字列を生成し、label->feature へ収納する
{
   int i, tmp1, tmp2, tmp3;
   JPCommonLabelPhoneme *p;
   JPCommonLabelWord *w;
   JPCommonLabelAccentPhrase *a;
   JPCommonLabelBreathGroup *b;
   char **phoneme_list;
   int short_pause_flag;
   int is_feature_in_range;

   if (label->is_valid == 0) {
      fprintf(stderr, "WARNING: JPCommonLabel_make() in jpcommon_label.c: Label state is invalid.\n");
      label->size = 0;
      return;
   }

   /* initialize */
   // NOTE: 音素数をカウントし必要なサイズを計算する
   for (p = label->phoneme_head, label->size = 0; p != NULL; p = p->next)
      label->size++;
   if (label->size < 1) {
      fprintf(stderr, "WARNING: JPCommonLabel_make() in jcomon_label.c: No phoneme.\n");
      return;
   }
   label->size += 2;
   label->feature = (char **) calloc(label->size, sizeof(char *)); // NOTE: フルコンテキストラベル系列の収納先
   if (label->feature == NULL) {
      fprintf(stderr, "WARNING: JPCommonLabel_make() in jpcommon_label.c: Failed to allocate label feature.\n");
      label->size = 0;
      return;
   }
   for (i = 0; i < label->size; i++) {
      label->feature[i] = (char *) calloc(MAXBUFLEN, sizeof(char)); // NOTE: フルコンテキストラベルの収納先
      if (label->feature[i] == NULL) {
         int cleanup_index;

         fprintf(stderr, "WARNING: JPCommonLabel_make() in jpcommon_label.c: Failed to allocate each label feature.\n");
         for (cleanup_index = 0; cleanup_index < i; cleanup_index++) {
            free(label->feature[cleanup_index]);
         }
         free(label->feature);
         label->feature = NULL;
         label->size = 0;
         return;
      }
   }

   /* phoneme list */
   // NOTE: 前後に音素を足して ["xx", "xx", "sil", contents, "sil", "xx", "xx"] とする。
   phoneme_list = (char **) calloc(label->size + 4, sizeof(char *)); // NOTE: 音素の一覧
   if (phoneme_list == NULL) {
      fprintf(stderr, "WARNING: JPCommonLabel_make() in jpcommon_label.c: Failed to allocate phoneme list.\n");
      for (i = 0; i < label->size; i++) {
         free(label->feature[i]);
      }
      free(label->feature);
      label->feature = NULL;
      label->size = 0;
      return;
   }
   phoneme_list[0] = JPCOMMON_PHONEME_UNKNOWN;
   phoneme_list[1] = JPCOMMON_PHONEME_UNKNOWN;
   phoneme_list[2] = JPCOMMON_PHONEME_SILENT;
   phoneme_list[label->size + 1] = JPCOMMON_PHONEME_SILENT;
   phoneme_list[label->size + 2] = JPCOMMON_PHONEME_UNKNOWN;
   phoneme_list[label->size + 3] = JPCOMMON_PHONEME_UNKNOWN;
   for (i = 3, p = label->phoneme_head; p != NULL; p = p->next)
      phoneme_list[i++] = p->phoneme;

   // NOTE: 音素ごとにフルコンテキストラベルを生成する
   for (i = 0, p = label->phoneme_head; i < label->size; i++) {
      // NOTE: `pau` のフラグを立てる
      if (strcmp(p->phoneme, JPCOMMON_PHONEME_SHORT_PAUSE) == 0)
         short_pause_flag = 1;
      else
         short_pause_flag = 0;
      is_feature_in_range = 1;

      /* for phoneme */
      // NOTE: 音素を前後の音素ごとダンプする
      if (snprintf(label->feature[i], MAXBUFLEN, "%s^%s-%s+%s=%s", phoneme_list[i], phoneme_list[i + 1],
                   phoneme_list[i + 2], phoneme_list[i + 3], phoneme_list[i + 4]) >= MAXBUFLEN) {
         label->feature[i][MAXBUFLEN - 1] = '\0';
         is_feature_in_range = 0;
      }

      /* for A: */
      if (i == 0 || i == label->size - 1 || short_pause_flag == 1)
         is_feature_in_range = append_format(label->feature[i], MAXBUFLEN, "/A:xx+xx+xx") && is_feature_in_range;
      else {
         tmp1 = index_mora_in_accent_phrase(p->up);
         tmp2 =
             p->up->up->up->accent ==
             0 ? count_mora_in_accent_phrase(p->up) : p->up->up->up->accent;
         is_feature_in_range =
            append_format(label->feature[i], MAXBUFLEN, "/A:%d+%d+%d", limit(tmp1 - tmp2, -MAX_M, MAX_M),
                          limit(tmp1, 1, MAX_M), limit(count_mora_in_accent_phrase(p->up) - tmp1 + 1, 1, MAX_M)) && is_feature_in_range;
      }

      /* for B: */
      // NOTE: 前の Word の品詞と活用をダンプする
      if (short_pause_flag == 1)
         w = p->prev->up->up;
      else if (p->up->up->prev == NULL)
         w = NULL;
      else if (i == label->size - 1)
         w = p->up->up;
      else
         w = p->up->up->prev;
      if (w == NULL)
         is_feature_in_range = append_format(label->feature[i], MAXBUFLEN, "/B:xx-xx_xx") && is_feature_in_range;
      else
         is_feature_in_range = append_format(label->feature[i], MAXBUFLEN, "/B:%s-%s_%s", w->pos, w->ctype, w->cform) && is_feature_in_range;

      /* for C: */
      // NOTE: この Word の品詞と活用をダンプする
      if (i == 0 || i == label->size - 1 || short_pause_flag)
         is_feature_in_range = append_format(label->feature[i], MAXBUFLEN, "/C:xx_xx+xx") && is_feature_in_range;
      else
         is_feature_in_range =
            append_format(label->feature[i], MAXBUFLEN, "/C:%s_%s+%s", p->up->up->pos, p->up->up->ctype, p->up->up->cform) && is_feature_in_range;

      /* for D: */
      // NOTE: 次の Word の品詞と活用をダンプする
      if (short_pause_flag == 1)
         w = p->next->up->up;
      else if (p->up->up->next == NULL)
         w = NULL;
      else if (i == 0)
         w = p->up->up;
      else
         w = p->up->up->next;
      if (w == NULL)
         is_feature_in_range = append_format(label->feature[i], MAXBUFLEN, "/D:xx+xx_xx") && is_feature_in_range;
      else
         is_feature_in_range = append_format(label->feature[i], MAXBUFLEN, "/D:%s+%s_%s", w->pos, w->ctype, w->cform) && is_feature_in_range;

      /* for E: */
      // NOTE: 前のアクセント句のモーラ数・アクセント・疑問形有無・ポーズ有無をダンプする
      if (short_pause_flag == 1)
         a = p->prev->up->up->up;
      else if (i == label->size - 1)
         a = p->up->up->up;
      else
         a = p->up->up->up->prev;
      if (a == NULL)
         is_feature_in_range = append_format(label->feature[i], MAXBUFLEN, "/E:xx_xx!xx_xx") && is_feature_in_range;
      else
         is_feature_in_range =
            append_format(label->feature[i], MAXBUFLEN, "/E:%d_%d!%s_%s",
                          limit(count_mora_in_accent_phrase(a->head->head), 1, MAX_M),
                          limit(a->accent == 0 ? count_mora_in_accent_phrase(a->head->head) : a->accent, 1, MAX_M),
                          a->emotion == NULL ? "0" : a->emotion, a->excl == NULL ? "0" : a->excl) && is_feature_in_range;
      if (i == 0 || i == label->size - 1 || short_pause_flag == 1 || a == NULL)
         is_feature_in_range = append_format(label->feature[i], MAXBUFLEN, "-xx") && is_feature_in_range;
      else
         is_feature_in_range = append_format(label->feature[i], MAXBUFLEN, "-%d",
                                             strcmp(a->tail->tail->tail->next->phoneme, JPCOMMON_PHONEME_SHORT_PAUSE) == 0
                                                ? 0
                                                : 1) && is_feature_in_range;

      /* for F: */
      // NOTE: アクセント句のモーラ数・アクセントなどをダンプする
      if (i == 0 || i == label->size - 1 || short_pause_flag == 1)
         a = NULL;
      else
         a = p->up->up->up;
      if (a == NULL)
         is_feature_in_range = append_format(label->feature[i], MAXBUFLEN, "/F:xx_xx#xx_xx@xx_xx|xx_xx") && is_feature_in_range;
      else {
         tmp1 = index_accent_phrase_in_breath_group(a);
         tmp2 = index_mora_in_breath_group(a->head->head);
         is_feature_in_range =
            append_format(label->feature[i], MAXBUFLEN, "/F:%d_%d#%s_%s@%d_%d|%d_%d",
                          limit(count_mora_in_accent_phrase(a->head->head), 1, MAX_M), // NOTE: f1. アクセント句に含まれるモーラの数
                          limit(a->accent == 0 ? count_mora_in_accent_phrase(a->head->head) : a->accent, 1, MAX_M), // NOTE: f2. 句アクセントの位置
                          a->emotion == NULL ? "0" : a->emotion, a->excl == NULL ? "0" : a->excl, // NOTE: f3. 疑問形フラグ、(f4無し)
                          limit(tmp1, 1, MAX_M), // NOTE: f5. BreathGroup 内のアクセント句のインデックス
                          limit(count_accent_phrase_in_breath_group(a) - tmp1 + 1, 1, MAX_M), limit(tmp2, 1, MAX_L), // NOTE: f6.、f7.
                          limit(count_mora_in_breath_group(a->head->head) - tmp2 + 1, 1, MAX_L)) && is_feature_in_range; // NOTE: f8.
      }

      /* for G: */
      if (short_pause_flag == 1)
         a = p->next->up->up->up;
      else if (i == 0)
         a = p->up->up->up;
      else
         a = p->up->up->up->next;
      if (a == NULL)
         is_feature_in_range = append_format(label->feature[i], MAXBUFLEN, "/G:xx_xx%%xx_xx") && is_feature_in_range;
      else
         is_feature_in_range =
            append_format(label->feature[i], MAXBUFLEN, "/G:%d_%d%%%s_%s",
                          limit(count_mora_in_accent_phrase(a->head->head), 1, MAX_M),
                          limit(a->accent == 0 ? count_mora_in_accent_phrase(a->head->head) : a->accent, 1, MAX_M),
                          a->emotion == NULL ? "0" : a->emotion, a->excl == NULL ? "0" : a->excl) && is_feature_in_range;
      if (i == 0 || i == label->size - 1 || short_pause_flag == 1 || a == NULL)
         is_feature_in_range = append_format(label->feature[i], MAXBUFLEN, "_xx") && is_feature_in_range;
      else
         is_feature_in_range = append_format(label->feature[i], MAXBUFLEN, "_%d",
                                             strcmp(a->head->head->head->prev->phoneme, JPCOMMON_PHONEME_SHORT_PAUSE) == 0
                                                ? 0
                                                : 1) && is_feature_in_range;

      /* for H: */
      // NOTE: 前の BreathGroup のアクセント句数とモーラ数をダンプする。
      if (short_pause_flag == 1)
         b = p->prev->up->up->up->up;
      else if (i == label->size - 1)
         b = p->up->up->up->up;
      else
         b = p->up->up->up->up->prev;
      if (b == NULL)
         is_feature_in_range = append_format(label->feature[i], MAXBUFLEN, "/H:xx_xx") && is_feature_in_range;
      else
         is_feature_in_range =
            append_format(label->feature[i], MAXBUFLEN, "/H:%d_%d", limit(count_accent_phrase_in_breath_group(b->head), 1, MAX_M),
                          limit(count_mora_in_breath_group(b->head->head->head), 1, MAX_L)) && is_feature_in_range;

      /* for I: */
      // NOTE: BreathGroup のアクセント句数とモーラ数などをダンプする。
      if (i == 0 || i == label->size - 1 || short_pause_flag == 1)
         b = NULL;
      else
         b = p->up->up->up->up;
      if (b == NULL)
         is_feature_in_range = append_format(label->feature[i], MAXBUFLEN, "/I:xx-xx@xx+xx&xx-xx|xx+xx") && is_feature_in_range;
      else {
         tmp1 = index_breath_group_in_utterance(b);
         tmp2 = index_accent_phrase_in_utterance(b->head);
         tmp3 = index_mora_in_utterance(b->head->head->head);
         is_feature_in_range =
            append_format(label->feature[i], MAXBUFLEN, "/I:%d-%d@%d+%d&%d-%d|%d+%d",
                          limit(count_accent_phrase_in_breath_group(b->head), 1, MAX_M),
                          limit(count_mora_in_breath_group(b->head->head->head), 1, MAX_L),
                          limit(tmp1, 1, MAX_S), // NOTE: i3. breathGroup のインデックス
                          limit(count_breath_group_in_utterance(b) - tmp1 + 1, 1, MAX_S), limit(tmp2, 1, MAX_M),
                          limit(count_accent_phrase_in_utterance(b->head) - tmp2 + 1, 1, MAX_M), limit(tmp3, 1, MAX_LL),
                          limit(count_mora_in_utterance(b->head->head->head) - tmp3 + 1, 1, MAX_LL)) && is_feature_in_range;
      }

      /* for J: */
      if (short_pause_flag == 1)
         b = p->next->up->up->up->up;
      else if (i == 0)
         b = p->up->up->up->up;
      else
         b = p->up->up->up->up->next;
      if (b == NULL)
         is_feature_in_range = append_format(label->feature[i], MAXBUFLEN, "/J:xx_xx") && is_feature_in_range;
      else
         is_feature_in_range =
            append_format(label->feature[i], MAXBUFLEN, "/J:%d_%d", limit(count_accent_phrase_in_breath_group(b->head), 1, MAX_M),
                          limit(count_mora_in_breath_group(b->head->head->head), 1, MAX_L)) && is_feature_in_range;

      /* for K: */
      is_feature_in_range =
         append_format(label->feature[i], MAXBUFLEN, "/K:%d+%d-%d",
                       limit(count_breath_group_in_utterance(label->breath_head), 1, MAX_S),
                       limit(count_accent_phrase_in_utterance(label->accent_head), 1, MAX_M),
                       limit(count_mora_in_utterance(label->mora_head), 1, MAX_LL)) && is_feature_in_range;
      if (is_feature_in_range == 0) {
         fprintf(stderr,
                 "WARNING: JPCommonLabel_make() in jpcommon_label.c: Label buffer exceeded. Feature has been truncated.\n");
      }

      // NOTE: 次の音素を設定する
      if (0 < i && i < label->size - 2)
         p = p->next;
   }

   /* free */
   free(phoneme_list);
}

int JPCommonLabel_get_size(JPCommonLabel * label)
{
   return label->size;
}

char **JPCommonLabel_get_feature(JPCommonLabel * label)
// NOTE: フルコンテキストラベル系列を取得する。
{
   return label->feature;
}

void JPCommonLabel_print(JPCommonLabel * label)
{
   JPCommonLabel_fprint(label, stdout);
}

void JPCommonLabel_fprint(JPCommonLabel * label, FILE * fp)
{
   JPCommonLabelPhoneme *p;
   JPCommonLabelMora *m;
   JPCommonLabelWord *w;
   JPCommonLabelAccentPhrase *a;
   JPCommonLabelBreathGroup *b;
   int i = 0;
   int j = 0;

   for (b = label->breath_head; b != NULL; b = b->next) {
      fprintf(fp, "%d\n", j++);
      for (a = b->head; a != NULL; a = a->next) {
         fprintf(fp, "   %d\n", i++);
         for (w = a->head; w != NULL; w = w->next) {
            fprintf(fp, "      %s %s %s %s\n", w->pron, w->pos, w->ctype, w->cform);
            for (m = w->head; m != NULL; m = m->next) {
               fprintf(fp, "         %s\n", m->mora);
               for (p = m->head; p != NULL; p = p->next) {
                  fprintf(fp, "            %s\n", p->phoneme);
                  if (p == m->tail)
                     break;
               }
               if (m == w->tail)
                  break;
            }
            if (w == a->tail)
               break;
         }
         if (a == b->tail)
            break;
      }
   }
}

void JPCommonLabel_clear(JPCommonLabel * label)
{
   int i;
   JPCommonLabelPhoneme *p, *pn;
   JPCommonLabelMora *m, *mn;
   JPCommonLabelWord *w, *wn;
   JPCommonLabelAccentPhrase *a, *an;
   JPCommonLabelBreathGroup *b, *bn;

   for (p = label->phoneme_head; p != NULL; p = pn) {
      pn = p->next;
      JPCommonLabelPhoneme_clear(p);
      free(p);
   }
   for (m = label->mora_head; m != NULL; m = mn) {
      mn = m->next;
      JPCommonLabelMora_clear(m);
      free(m);
   }
   for (w = label->word_head; w != NULL; w = wn) {
      wn = w->next;
      JPCommonLabelWord_clear(w);
      free(w);
   }
   for (a = label->accent_head; a != NULL; a = an) {
      an = a->next;
      JPCommonLabelAccentPhrase_clear(a);
      free(a);
   }
   for (b = label->breath_head; b != NULL; b = bn) {
      bn = b->next;
      JPCommonLabelBreathGroup_clear(b);
      free(b);
   }
   if (label->feature != NULL) {
      for (i = 0; i < label->size; i++)
         free(label->feature[i]);
      free(label->feature);
   }
}

JPCOMMON_LABEL_C_END;

#endif                          /* !JPCOMMON_LABEL_C */
