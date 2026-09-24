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

#ifndef NJD_SET_ACCENT_TYPE_C
#define NJD_SET_ACCENT_TYPE_C

#ifdef __cplusplus
#define NJD_SET_ACCENT_TYPE_C_START extern "C" {
#define NJD_SET_ACCENT_TYPE_C_END   }
#else
#define NJD_SET_ACCENT_TYPE_C_START
#define NJD_SET_ACCENT_TYPE_C_END
#endif                          /* __CPLUSPLUS */

NJD_SET_ACCENT_TYPE_C_START;

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "njd.h"
#include "njd_set_accent_type.h"

#ifdef ASCII_HEADER
#if defined(CHARSET_EUC_JP)
#include "njd_set_accent_type_rule_ascii_for_euc_jp.h"
#elif defined(CHARSET_SHIFT_JIS)
#include "njd_set_accent_type_rule_ascii_for_shift_jis.h"
#elif defined(CHARSET_UTF_8)
#include "njd_set_accent_type_rule_ascii_for_utf_8.h"
#else
#error CHARSET is not specified
#endif
#else
#if defined(CHARSET_EUC_JP)
#include "njd_set_accent_type_rule_euc_jp.h"
#elif defined(CHARSET_SHIFT_JIS)
#include "njd_set_accent_type_rule_shift_jis.h"
#elif defined(CHARSET_UTF_8)
#include "njd_set_accent_type_rule_utf_8.h"
#else
#error CHARSET is not specified
#endif
#endif

#define MAXBUFLEN 1024

static char get_token_from_string(const char *str, int *index, char *buff, size_t buff_size)
{
   char c;
   int i = 0;
   int is_truncated = 0;

   if (buff == NULL || buff_size == 0) {
      return '\0';
   }

   c = str[(*index)];
   if (c != '\0') {
      while (c != '%' && c != '@' && c != '/' && c != '\0') {
         if (i < (int) buff_size - 1) {
            buff[i++] = c;
         } else {
            is_truncated = 1;
         }
         c = str[++(*index)];
      }
      if (c == '%' || c == '@' || c == '/')
         (*index)++;
   }
   buff[i] = '\0';

   if (is_truncated == 1) {
      fprintf(stderr,
              "WARNING: get_token_from_string() in njd_set_accent_type.c: Token is too long and has been truncated.\n");
   }

   return c;
}

static void get_rule(const char *input_rule, const char *prev_pos, char *rule, int *add_type)
{
   int index = 0;
   char buff[MAXBUFLEN];
   char c = ' ';

   if (input_rule) {
      while (c != '\0') {
         c = get_token_from_string(input_rule, &index, buff, sizeof(buff));
         if ((c == '%' && strstr(prev_pos, buff) != NULL) || c == '@' || c == '/' || c == '\0') {
            /* find */
            if (c == '%')
               c = get_token_from_string(input_rule, &index, rule, MAXBUFLEN);
            else
               strcpy(rule, buff);
            if (c == '@') {
               c = get_token_from_string(input_rule, &index, buff, sizeof(buff));
               (*add_type) = atoi(buff);
            } else {
               (*add_type) = 0;
            }
            return;
         } else {
            /* skip */
            while (c == '%' || c == '@')
               c = get_token_from_string(input_rule, &index, buff, sizeof(buff));
         }
      }
   }

   /* not found */
   strcpy(rule, "*");
   (*add_type) = 0;
}

void njd_set_accent_type(NJD * njd)
// NOTE:
// アクセント句境界と各ノードのアクセント連鎖タイプに基づき、`.acc` を非負の整数に設定する。
// 利用は以下：
//   - `Open_JTalk_synthesis()` 内で
//   - パブリック関数として外部で
//     - pyopenjtalk `OpenJTalk.run_frontend()` 内で
{
   NJDNode *node;
   NJDNode *top_node = NULL;
   char rule[MAXBUFLEN];
   int add_type = 0;
   int mora_size = 0; // NOTE: アクセント句の先頭から現ノードまでの合計モーラ数。
   int top_acc = 0;
   int top_mora_size = 0;

   if (njd == NULL || njd->head == NULL)
      return;

   // NOTE: アクセント句の末尾ノードになるまで先頭ノードの `.acc` を上書き
   for (node = njd->head; node != NULL; node = node->next) {
      if (NJDNode_get_string(node) == NULL)
         continue;

      // NOTE: アクセント句の境界に到達したのでリセットする。
      if ((node == njd->head) || (NJDNode_get_chain_flag(node) != 1)) {
         /* store the top node */
         top_node = node;
         mora_size = 0;
         top_acc = NJDNode_get_acc(node);
         top_mora_size = NJDNode_get_mora_size(node);

      } else if (node->prev != NULL && NJDNode_get_chain_flag(node) == 1) {
         /* get accent change type */
         get_rule(NJDNode_get_chain_rule(node), NJDNode_get_pos(node->prev), rule, &add_type);

         /* change accent type */
         // NOTE: アクセント句の先頭ノードの `.acc` を更新する。
         if (strcmp(NJDNode_get_chain_rule(top_node), "P2") == 0 && top_acc != 0 && top_mora_size > top_acc) {
            NJDNode_set_acc(top_node, top_acc);
         } else if (strcmp(rule, "*") == 0) {  /* no change */
         } else if (strcmp(rule, "F1") == 0) {  /* for ancillary word */
         } else if (strcmp(rule, "F2") == 0) {
            if (NJDNode_get_acc(top_node) == 0)
               NJDNode_set_acc(top_node, mora_size + add_type);
         } else if (strcmp(rule, "F3") == 0) {
            if (NJDNode_get_acc(top_node) != 0)
               NJDNode_set_acc(top_node, mora_size + add_type);
         } else if (strcmp(rule, "F4") == 0) {
            NJDNode_set_acc(top_node, mora_size + add_type);
         } else if (strcmp(rule, "F5") == 0) {
            NJDNode_set_acc(top_node, 0);
         } else if (strcmp(rule, "C1") == 0) {  /* for noun */
            NJDNode_set_acc(top_node, mora_size + NJDNode_get_acc(node));
         } else if (strcmp(rule, "C2") == 0) {
            NJDNode_set_acc(top_node, mora_size + 1);
         } else if (strcmp(rule, "C3") == 0) {
            NJDNode_set_acc(top_node, mora_size);
         } else if (strcmp(rule, "C4") == 0) {
            NJDNode_set_acc(top_node, 0);
         } else if (strcmp(rule, "C5") == 0) {
         } else if (strcmp(rule, "P1") == 0) {  /* for postfix */
            if (NJDNode_get_acc(node) == 0)
               NJDNode_set_acc(top_node, 0);
            else
               NJDNode_set_acc(top_node, mora_size + NJDNode_get_acc(node));
         } else if (strcmp(rule, "P6") == 0) {
            NJDNode_set_acc(top_node, 0);
         } else if (strcmp(rule, "P14") == 0) {
            if (NJDNode_get_acc(node) != 0)
               NJDNode_set_acc(top_node, mora_size + NJDNode_get_acc(node));
         }
      }

      /* change accent type for digit */
      // NOTE: `node.prev.acc` を更新する。
      if (node->prev != NULL && NJDNode_get_chain_flag(node) == 1 &&
          strcmp(NJDNode_get_pos_group1(node->prev), NJD_SET_ACCENT_TYPE_KAZU) == 0 &&
          strcmp(NJDNode_get_pos_group1(node), NJD_SET_ACCENT_TYPE_KAZU) == 0) {
         if (strcmp(NJDNode_get_string(node), NJD_SET_ACCENT_TYPE_JYUU) == 0) { /* 10^1 */
            if (NJDNode_get_string(node->prev) != NULL &&
                (strcmp(NJDNode_get_string(node->prev), NJD_SET_ACCENT_TYPE_SAN) == 0 ||
                 strcmp(NJDNode_get_string(node->prev), NJD_SET_ACCENT_TYPE_YON) == 0 ||
                 strcmp(NJDNode_get_string(node->prev), NJD_SET_ACCENT_TYPE_KYUU) == 0 ||
                 strcmp(NJDNode_get_string(node->prev), NJD_SET_ACCENT_TYPE_NAN) == 0 ||
                 strcmp(NJDNode_get_string(node->prev), NJD_SET_ACCENT_TYPE_SUU) == 0)) {
               NJDNode_set_acc(node->prev, 1);
            } else {
               NJDNode_set_acc(node->prev, 1);
            }
            if (NJDNode_get_string(node->prev) != NULL &&
                (strcmp(NJDNode_get_string(node->prev), NJD_SET_ACCENT_TYPE_GO) == 0 ||
                 strcmp(NJDNode_get_string(node->prev), NJD_SET_ACCENT_TYPE_ROKU) == 0 ||
                 strcmp(NJDNode_get_string(node->prev), NJD_SET_ACCENT_TYPE_HACHI) == 0)) {
               if (node->next != NULL && NJDNode_get_string(node->next) != NULL
                   && (strcmp(NJDNode_get_string(node->next), NJD_SET_ACCENT_TYPE_ICHI) == 0
                       || strcmp(NJDNode_get_string(node->next), NJD_SET_ACCENT_TYPE_NI) == 0
                       || strcmp(NJDNode_get_string(node->next), NJD_SET_ACCENT_TYPE_SAN) == 0
                       || strcmp(NJDNode_get_string(node->next), NJD_SET_ACCENT_TYPE_YON) == 0
                       || strcmp(NJDNode_get_string(node->next), NJD_SET_ACCENT_TYPE_GO) == 0
                       || strcmp(NJDNode_get_string(node->next), NJD_SET_ACCENT_TYPE_ROKU) == 0
                       || strcmp(NJDNode_get_string(node->next), NJD_SET_ACCENT_TYPE_NANA) == 0
                       || strcmp(NJDNode_get_string(node->next), NJD_SET_ACCENT_TYPE_HACHI) == 0
                       || strcmp(NJDNode_get_string(node->next), NJD_SET_ACCENT_TYPE_KYUU) == 0))
                  NJDNode_set_acc(node->prev, 0);
            }
         } else if (strcmp(NJDNode_get_string(node), NJD_SET_ACCENT_TYPE_HYAKU) == 0) { /* 10^2 */
            if (NJDNode_get_string(node->prev) != NULL
                && strcmp(NJDNode_get_string(node->prev), NJD_SET_ACCENT_TYPE_NANA) == 0) {
               NJDNode_set_acc(node->prev, 2);
            } else if (NJDNode_get_string(node->prev) != NULL &&
                       (strcmp(NJDNode_get_string(node->prev), NJD_SET_ACCENT_TYPE_SAN) == 0 ||
                        strcmp(NJDNode_get_string(node->prev), NJD_SET_ACCENT_TYPE_YON) == 0 ||
                        strcmp(NJDNode_get_string(node->prev), NJD_SET_ACCENT_TYPE_KYUU) == 0 ||
                        strcmp(NJDNode_get_string(node->prev), NJD_SET_ACCENT_TYPE_NAN) == 0)) {
               NJDNode_set_acc(node->prev, 1);
            } else {
               NJDNode_set_acc(node->prev,
                               NJDNode_get_mora_size(node->prev) + NJDNode_get_mora_size(node));
            }
         } else if (strcmp(NJDNode_get_string(node), NJD_SET_ACCENT_TYPE_SEN) == 0) {   /* 10^3 */
            NJDNode_set_acc(node->prev, NJDNode_get_mora_size(node->prev) + 1);
         } else if (strcmp(NJDNode_get_string(node), NJD_SET_ACCENT_TYPE_MAN) == 0) {   /* 10^4 */
            NJDNode_set_acc(node->prev, NJDNode_get_mora_size(node->prev) + 1);
         } else if (strcmp(NJDNode_get_string(node), NJD_SET_ACCENT_TYPE_OKU) == 0) {   /* 10^8 */
            if (NJDNode_get_string(node->prev) != NULL &&
                (strcmp(NJDNode_get_string(node->prev), NJD_SET_ACCENT_TYPE_ICHI) == 0 ||
                 strcmp(NJDNode_get_string(node->prev), NJD_SET_ACCENT_TYPE_ROKU) == 0 ||
                 strcmp(NJDNode_get_string(node->prev), NJD_SET_ACCENT_TYPE_NANA) == 0 ||
                 strcmp(NJDNode_get_string(node->prev), NJD_SET_ACCENT_TYPE_HACHI) == 0 ||
                 strcmp(NJDNode_get_string(node->prev), NJD_SET_ACCENT_TYPE_IKU) == 0)) {
               NJDNode_set_acc(node->prev, 2);
            } else {
               NJDNode_set_acc(node->prev, 1);
            }
         } else if (strcmp(NJDNode_get_string(node), NJD_SET_ACCENT_TYPE_CHOU) == 0) {  /* 10^12 */
            if (NJDNode_get_string(node->prev) != NULL &&
                (strcmp(NJDNode_get_string(node->prev), NJD_SET_ACCENT_TYPE_ROKU) == 0 ||
                 strcmp(NJDNode_get_string(node->prev), NJD_SET_ACCENT_TYPE_NANA) == 0)) {
               NJDNode_set_acc(node->prev, 2);
            } else {
               NJDNode_set_acc(node->prev, 1);
            }
         }
      }

      if (strcmp(NJDNode_get_string(node), NJD_SET_ACCENT_TYPE_JYUU) == 0 &&
          NJDNode_get_chain_flag(node) != 1 && node->next != NULL &&
          strcmp(NJDNode_get_pos_group1(node->next), NJD_SET_ACCENT_TYPE_KAZU) == 0) {
         NJDNode_set_acc(node, 0);
      }

      // NOTE: アクセント句の先頭からこのノードまでの合計モーラ数を更新する。
      mora_size += NJDNode_get_mora_size(node);
   }
}

NJD_SET_ACCENT_TYPE_C_END;

#endif                          /* !NJD_SET_ACCENT_TYPE_C */
