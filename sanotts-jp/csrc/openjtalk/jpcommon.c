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

#ifndef JPCOMMON_C
#define JPCOMMON_C

#ifdef __cplusplus
#define JPCOMMON_C_START extern "C" {
#define JPCOMMON_C_END   }
#else
#define JPCOMMON_C_START
#define JPCOMMON_C_END
#endif                          /* __CPLUSPLUS */

JPCOMMON_C_START;

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "jpcommon.h"

void JPCommon_initialize(JPCommon * jpcommon)
{
   jpcommon->head = NULL;
   jpcommon->tail = NULL;
   jpcommon->label = NULL;
}

void JPCommon_push(JPCommon * jpcommon, JPCommonNode * node)
// NOTE: JPCommonNode を連結リストへ組み込んで JPCommon へ収納する。
{
   if (jpcommon->head == NULL) {
      jpcommon->head = node;
   } else {
      jpcommon->tail->next = node;
      node->prev = jpcommon->tail;
   }
   jpcommon->tail = node;
}

void JPCommon_make_label(JPCommon * jpcommon)
// NOTE:
// JPCommon から JPCommonLabel を生成する。
// 利用は以下：
//   - `Open_JTalk_synthesis()` 内で
//   - パブリック関数として外部で
//     - pyopenjtalk `OpenJTalk.make_label()` 内で
{
   JPCommonNode *node = jpcommon->head;

   /* initialize */
   if (jpcommon->label != NULL)
      JPCommonLabel_clear(jpcommon->label);
   else
      jpcommon->label = (JPCommonLabel *) calloc(1, sizeof(JPCommonLabel));
   if (jpcommon->label == NULL) {
      fprintf(stderr, "WARNING: JPCommon_make_label() in jpcommon.c: Failed to allocate JPCommonLabel.\n");
      return;
   }
   JPCommonLabel_initialize(jpcommon->label);

   /* push word */
   // NOTE:
   // JPCommon に含まれる JPCommonNode を先頭から JPCommonLabel へ収納する。
   // JPCommonNode は単語単位、JPCommonLabel は最小で音素単位であることに注意。
   for (node = jpcommon->head; node != NULL; node = node->next) {
      // NOTE: `JPCommonNode_get_*(node)` は全て単なるゲッター
      JPCommonLabel_push_word(jpcommon->label, JPCommonNode_get_pron(node),
                              JPCommonNode_get_pos(node),
                              JPCommonNode_get_ctype(node),
                              JPCommonNode_get_cform(node),
                              JPCommonNode_get_acc(node), JPCommonNode_get_chain_flag(node));
      // アロケーション失敗等で is_valid が 0 になった場合、壊れた構造体への
      // 後続操作を防ぐため即座にループを中断する
      if (jpcommon->label->is_valid == 0)
         break;
   }
   if (jpcommon->label->is_valid == 0) {
      fprintf(stderr, "WARNING: JPCommon_make_label() in jpcommon.c: Label generation aborted due to a previous error.\n");
      JPCommonLabel_clear(jpcommon->label);
      JPCommonLabel_initialize(jpcommon->label);
      return;
   }

   /* make label */
   // NOTE: フルコンテキストラベルをダンプして JPCommon.label.feature へ収納する
   JPCommonLabel_make(jpcommon->label);
}

int JPCommon_get_label_size(JPCommon * jpcommon)
{
   if (jpcommon->label != NULL)
      return JPCommonLabel_get_size(jpcommon->label);
   else
      return 0;
}

char **JPCommon_get_label_feature(JPCommon * jpcommon)
// NOTE: フルコンテキストラベル系列を取得する。
// 利用は以下：
//   - `Open_JTalk_synthesis()` 内で
//   - パブリック関数として外部で
//     - pyopenjtalk `OpenJTalk.make_label()` 内で

{
   if (jpcommon->label != NULL)
      return JPCommonLabel_get_feature(jpcommon->label);
   else
      return NULL;
}

void JPCommon_print(JPCommon * jpcommon)
{
   JPCommon_fprint(jpcommon, stdout);
}

void JPCommon_fprint(JPCommon * jpcommon, FILE * fp)
{
   JPCommonNode *node;

   for (node = jpcommon->head; node != NULL; node = node->next)
      JPCommonNode_fprint(node, fp);
}

void JPCommon_refresh(JPCommon * jpcommon)
{
   JPCommon_clear(jpcommon);
   JPCommon_initialize(jpcommon);
}

void JPCommon_clear(JPCommon * jpcommon)
{
   JPCommonNode *node;

   while (jpcommon->head != NULL) {
      node = jpcommon->head->next;
      JPCommonNode_clear(jpcommon->head);
      free(jpcommon->head);
      jpcommon->head = node;
   }
   jpcommon->tail = NULL;

   if (jpcommon->label != NULL) {
      JPCommonLabel_clear(jpcommon->label);
      free(jpcommon->label);
   }
   jpcommon->label = NULL;
}

JPCOMMON_C_END;

#endif                          /* !JPCOMMON_C */
