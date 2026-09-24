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

#ifndef NJD_NODE_C
#define NJD_NODE_C

#ifdef __cplusplus
#define NJD_NODE_C_START extern "C" {
#define NJD_NODE_C_END   }
#else
#define NJD_NODE_C_START
#define NJD_NODE_C_END
#endif                          /* __CPLUSPLUS */

NJD_NODE_C_START;

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "njd.h"

static const char *nodata = "*";

#define MAXBUFLEN 1024

static void get_token_from_string(const char *str, int *index, char *buff, char d)
{
   char c;
   int i = 0;

   c = str[(*index)];
   if (c != '\0') {
      while (c != d && c != '\0') {
         if (i >= MAXBUFLEN - 1) {
            /* Buffer full - skip rest but continue parsing */
            fprintf(stderr, "WARNING: %s() in %s:%d: Token too long, truncating at %d bytes.\n", __func__, __FILE__, __LINE__, MAXBUFLEN - 1);
            while (c != d && c != '\0') {
               c = str[++(*index)];
            }
            break;
         }
         buff[i++] = c;
         c = str[++(*index)];
      }
      if (c == d)
         (*index)++;
   }
   buff[i] = '\0';
}

void NJDNode_initialize(NJDNode * node)
{
   node->string = NULL;
   node->pos = NULL;
   node->pos_group1 = NULL;
   node->pos_group2 = NULL;
   node->pos_group3 = NULL;
   node->ctype = NULL;
   node->cform = NULL;
   node->orig = NULL;
   node->read = NULL;
   node->pron = NULL;
   node->acc = 0;
   node->mora_size = 0;
   node->chain_rule = NULL;
   node->chain_flag = -1;
   node->prev = NULL;
   node->next = NULL;
}

void NJDNode_set_string(NJDNode * node, const char *str)
{
   if (node->string != NULL)
      free(node->string);
   if (str == NULL || strlen(str) == 0)
      node->string = NULL;
   else
      node->string = strdup(str);
}

void NJDNode_set_pos(NJDNode * node, const char *str)
{
   if (node->pos != NULL)
      free(node->pos);
   if (str == NULL || strlen(str) == 0)
      node->pos = NULL;
   else
      node->pos = strdup(str);
}

void NJDNode_set_pos_group1(NJDNode * node, const char *str)
{
   if (node->pos_group1 != NULL)
      free(node->pos_group1);
   if (str == NULL || strlen(str) == 0)
      node->pos_group1 = NULL;
   else
      node->pos_group1 = strdup(str);
}

void NJDNode_set_pos_group2(NJDNode * node, const char *str)
{
   if (node->pos_group2 != NULL)
      free(node->pos_group2);
   if (str == NULL || strlen(str) == 0)
      node->pos_group2 = NULL;
   else
      node->pos_group2 = strdup(str);
}

void NJDNode_set_pos_group3(NJDNode * node, const char *str)
{
   if (node->pos_group3 != NULL)
      free(node->pos_group3);
   if (str == NULL || strlen(str) == 0)
      node->pos_group3 = NULL;
   else
      node->pos_group3 = strdup(str);
}

void NJDNode_set_ctype(NJDNode * node, const char *str)
{
   if (node->ctype != NULL)
      free(node->ctype);
   if (str == NULL || strlen(str) == 0)
      node->ctype = NULL;
   else
      node->ctype = strdup(str);
}

void NJDNode_set_cform(NJDNode * node, const char *str)
{
   if (node->cform != NULL)
      free(node->cform);
   if (str == NULL || strlen(str) == 0)
      node->cform = NULL;
   else
      node->cform = strdup(str);
}

void NJDNode_set_orig(NJDNode * node, const char *str)
{
   if (node->orig != NULL)
      free(node->orig);
   if (str == NULL || strlen(str) == 0)
      node->orig = NULL;
   else
      node->orig = strdup(str);
}

void NJDNode_set_read(NJDNode * node, const char *str)
{
   if (node->read != NULL)
      free(node->read);
   if (str == NULL || strlen(str) == 0)
      node->read = NULL;
   else
      node->read = strdup(str);
}

void NJDNode_set_pron(NJDNode * node, const char *str)
{
   if (node->pron != NULL)
      free(node->pron);
   if (str == NULL || strlen(str) == 0)
      node->pron = NULL;
   else
      node->pron = strdup(str);
}

void NJDNode_set_acc(NJDNode * node, int acc)
{
   node->acc = acc;
   if (node->acc < 0) {
      fprintf(stderr, "WARNING: NJDNode_set_acc() in njd_node.c: Accent must be positive value.\n");
      node->acc = 0;
   }
}

void NJDNode_set_mora_size(NJDNode * node, int size)
{
   node->mora_size = size;
   if (node->mora_size < 0) {
      fprintf(stderr,
              "WARNING: NJDNode_set_mora_size() in njd_node.c: Mora size must be positive value.\n");
      node->mora_size = 0;
   }
}

void NJDNode_set_chain_rule(NJDNode * node, const char *str)
{
   if (node->chain_rule != NULL)
      free(node->chain_rule);
   if (str == NULL || strlen(str) == 0)
      node->chain_rule = NULL;
   else
      node->chain_rule = strdup(str);
}

void NJDNode_set_chain_flag(NJDNode * node, int flag)
{
   node->chain_flag = flag;
}

void NJDNode_add_string(NJDNode * node, const char *str)
{
   char *c;

   if (str != NULL) {
      if (node->string == NULL) {
         node->string = strdup(str);
      } else {
         c = (char *) calloc(strlen(node->string) + strlen(str) + 1, sizeof(char));
         if (c == NULL) {
            fprintf(stderr, "WARNING: NJDNode_add_string() in njd_node.c: Failed to allocate memory.\n");
            return;
         }
         strcpy(c, node->string);
         strcat(c, str);
         free(node->string);
         node->string = c;
      }
   }
}

void NJDNode_add_orig(NJDNode * node, const char *str)
{
   char *c;

   if (str != NULL) {
      if (node->orig == NULL) {
         node->orig = strdup(str);
      } else {
         c = (char *) calloc(strlen(node->orig) + strlen(str) + 1, sizeof(char));
         if (c == NULL) {
            fprintf(stderr, "WARNING: NJDNode_add_orig() in njd_node.c: Failed to allocate memory.\n");
            return;
         }
         strcpy(c, node->orig);
         strcat(c, str);
         free(node->orig);
         node->orig = c;
      }
   }
}

void NJDNode_add_read(NJDNode * node, const char *str)
{
   char *c;

   if (str != NULL) {
      if (node->read == NULL) {
         node->read = strdup(str);
      } else {
         c = (char *) calloc(strlen(node->read) + strlen(str) + 1, sizeof(char));
         if (c == NULL) {
            fprintf(stderr, "WARNING: NJDNode_add_read() in njd_node.c: Failed to allocate memory.\n");
            return;
         }
         strcpy(c, node->read);
         strcat(c, str);
         free(node->read);
         node->read = c;
      }
   }
}

void NJDNode_add_pron(NJDNode * node, const char *str)
{
   char *c;

   if (str != NULL) {
      if (node->pron == NULL) {
         node->pron = strdup(str);
      } else {
         c = (char *) calloc(strlen(node->pron) + strlen(str) + 1, sizeof(char));
         if (c == NULL) {
            fprintf(stderr, "WARNING: NJDNode_add_pron() in njd_node.c: Failed to allocate memory.\n");
            return;
         }
         strcpy(c, node->pron);
         strcat(c, str);
         free(node->pron);
         node->pron = c;
      }
   }
}

void NJDNode_add_acc(NJDNode * node, int acc)
{
   node->acc += acc;
   if (node->acc < 0) {
      fprintf(stderr, "WARNING: NJDNode_add_acc() in njd_node.c: Accent must be positive value.\n");
      node->acc = 0;
   }
}

void NJDNode_add_mora_size(NJDNode * node, int size)
{
   node->mora_size += size;
   if (node->mora_size < 0) {
      fprintf(stderr,
              "WARNING: NJDNode_add_mora_size() in njd_node.c: Mora size must be positive value.\n");
      node->mora_size = 0;
   }
}

const char *NJDNode_get_string(NJDNode * node)
{
   if (node->string == NULL)
      return nodata;
   return node->string;
}

const char *NJDNode_get_pos(NJDNode * node)
{
   if (node->pos == NULL)
      return nodata;
   return node->pos;
}

const char *NJDNode_get_pos_group1(NJDNode * node)
{
   if (node->pos_group1 == NULL)
      return nodata;
   return node->pos_group1;
}

const char *NJDNode_get_pos_group2(NJDNode * node)
{
   if (node->pos_group2 == NULL)
      return nodata;
   return node->pos_group2;
}

const char *NJDNode_get_pos_group3(NJDNode * node)
{
   if (node->pos_group3 == NULL)
      return nodata;
   return node->pos_group3;
}

const char *NJDNode_get_ctype(NJDNode * node)
{
   if (node->ctype == NULL)
      return nodata;
   return node->ctype;
}

const char *NJDNode_get_cform(NJDNode * node)
{
   if (node->cform == NULL)
      return nodata;
   return node->cform;
}

const char *NJDNode_get_orig(NJDNode * node)
{
   if (node->orig == NULL)
      return nodata;
   return node->orig;
}

const char *NJDNode_get_read(NJDNode * node)
{
   if (node->read == NULL)
      return nodata;
   return node->read;
}

const char *NJDNode_get_pron(NJDNode * node)
{
   if (node->pron == NULL)
      return nodata;
   return node->pron;
}

int NJDNode_get_acc(NJDNode * node)
{
   return node->acc;
}

int NJDNode_get_mora_size(NJDNode * node)
{
   return node->mora_size;
}

const char *NJDNode_get_chain_rule(NJDNode * node)
{
   if (node->chain_rule == NULL)
      return nodata;
   return node->chain_rule;
}

int NJDNode_get_chain_flag(NJDNode * node)
{
   return node->chain_flag;
}

void NJDNode_load(NJDNode * node, const char *str)
{
   int i, j;
   int index = 0;
   char buff[MAXBUFLEN];
   char buff_string[MAXBUFLEN];
   char buff_orig[MAXBUFLEN];
   char buff_read[MAXBUFLEN];
   char buff_pron[MAXBUFLEN];
   char buff_acc[MAXBUFLEN];
   int count;
   int index_string;
   int index_orig;
   int index_read;
   int index_pron;
   int index_acc;
   int is_orig_aligned;
   NJDNode *prev = NULL;

   if (strlen(str) >= MAXBUFLEN * 6) {
      fprintf(stderr, "ERROR: %s() in %s:%d: Input too long (%zu bytes). Skipping node.\n", __func__, __FILE__, __LINE__, strlen(str));
      return;
   }

   /* load */
   // example: `笑止千万,1347,1347,4640,名詞,形容動詞語幹,*,*,*,*,笑止:千万,ショウシ:センバン,ショーシ:センバン,1/3:0/4,C1`
   get_token_from_string(str, &index, buff_string, ',');
   get_token_from_string(str, &index, buff, ',');
   NJDNode_set_pos(node, buff);
   get_token_from_string(str, &index, buff, ',');
   NJDNode_set_pos_group1(node, buff);
   get_token_from_string(str, &index, buff, ',');
   NJDNode_set_pos_group2(node, buff);
   get_token_from_string(str, &index, buff, ',');
   NJDNode_set_pos_group3(node, buff);
   get_token_from_string(str, &index, buff, ',');
   NJDNode_set_ctype(node, buff);
   get_token_from_string(str, &index, buff, ',');
   NJDNode_set_cform(node, buff);
   get_token_from_string(str, &index, buff_orig, ',');
   get_token_from_string(str, &index, buff_read, ',');
   get_token_from_string(str, &index, buff_pron, ',');
   get_token_from_string(str, &index, buff_acc, ',');
   get_token_from_string(str, &index, buff, ',');
   NJDNode_set_chain_rule(node, buff);
   get_token_from_string(str, &index, buff, ',');
   if (strcmp(buff, "1") == 0)
      NJDNode_set_chain_flag(node, 1);
   else if (strcmp(buff, "0") == 0)
      NJDNode_set_chain_flag(node, 0);

   /* for symbol */
   if (strstr(buff_acc, "*") != NULL || strstr(buff_acc, "/") == NULL) {
      NJDNode_set_string(node, buff_string);
      NJDNode_set_orig(node, buff_orig);
      NJDNode_set_read(node, buff_read);
      NJDNode_set_pron(node, buff_pron);
      NJDNode_set_acc(node, 0);
      NJDNode_set_mora_size(node, 0);
      return;
   }

   /* count chained word 
      NOTE: Count the number of `/` in the accent attribute.
            In chained word, e.g. `1/3:0/4`, there are multiple `/`s.
   **/
   for (i = 0, count = 0; buff_acc[i] != '\0'; i++)
      if (buff_acc[i] == '/')
         count++;

   /* for single word */
   if (count == 1) {
      NJDNode_set_string(node, buff_string);
      NJDNode_set_orig(node, buff_orig);
      NJDNode_set_read(node, buff_read);
      NJDNode_set_pron(node, buff_pron);
      index_acc = 0;
      get_token_from_string(buff_acc, &index_acc, buff, '/');
      if (buff[0] == '\0') {
         j = 0;
         fprintf(stderr, "WARNING: NJDNode_load() in njd_node.c: Accent is empty.\n");
      } else {
         j = atoi(buff);
      }
      NJDNode_set_acc(node, j);
      get_token_from_string(buff_acc, &index_acc, buff, ':');
      if (buff[0] == '\0') {
         j = 0;
         fprintf(stderr, "WARNING: NJDNode_load() in njd_node.c: Mora size is empty.\n");
      } else {
         j = atoi(buff);
      }
      NJDNode_set_mora_size(node, j);
      return;
   }

   /* parse chained word */
   /* NOTE: 最終ノードは活用によって `orig` と表層が異なるため、その手前の `orig`
      トークンだけが表層の先頭と一致すれば、残りの表層を最終ノードに割り当てられる
      外部のユーザー辞書から不正な複数アクセント句が渡され、この前提が崩れた場合、
      従来処理は表層の終端より後ろを読み、ゴミ文字列や UTF-8 デコード失敗を起こす
      不正な辞書を正当な入力として扱う分岐ではなく、NJD のメモリ安全性を保つため、
      先頭ノードに表層全体を入れ、以降は `orig` トークンで代用する */
   is_orig_aligned = 1;
   for (i = 0, j = 0; buff_orig[i] != '\0'; i++)
      if (buff_orig[i] == ':')
         j++;
   if (j != count - 1)
      is_orig_aligned = 0;

   index_orig = 0;
   index_string = 0;
   for (i = 0; is_orig_aligned == 1 && i + 1 < count; i++) {
      get_token_from_string(buff_orig, &index_orig, buff, ':');
      if (buff[0] == '\0' ||
          strncmp(&buff_string[index_string], buff, strlen(buff)) != 0) {
         is_orig_aligned = 0;
         break;
      }
      index_string += strlen(buff);
   }
   if (is_orig_aligned == 1 && buff_string[index_string] == '\0')
      is_orig_aligned = 0;

   /* 不正な辞書エントリを特定できるよう、表層と原形を含む警告を標準エラー出力へ記録する */
   if (is_orig_aligned == 0)
      fprintf(stderr,
              "WARNING: NJDNode_load() in njd_node.c: Chained orig does not match the surface prefix "
              "(surface: \"%s\", orig: \"%s\"). Using a safe fallback.\n",
              buff_string, buff_orig);

   index_string = 0;
   index_orig = 0;
   index_read = 0;
   index_pron = 0;
   index_acc = 0;
   for (i = 0; i < count; i++) {
      if (i > 0) {
         /* NOTE: Node for i-th sub-word. */
         node = (NJDNode *) calloc(1, sizeof(NJDNode));
         if (node == NULL) {
            fprintf(stderr, "WARNING: NJDNode_load() in njd_node.c: Failed to allocate chained NJDNode.\n");
            return;
         }
         NJDNode_initialize(node);
         NJDNode_copy(node, prev);
         /* NOTE: No needs of accent chaining because of explicit manual accent assignment. */
         NJDNode_set_chain_flag(node, 0);
         node->prev = prev;
         prev->next = node;
      }
      /* orig */
      get_token_from_string(buff_orig, &index_orig, buff, ':');
      NJDNode_set_orig(node, buff);
      /* string */
      if (is_orig_aligned == 1) {
         if (i + 1 < count) {
            NJDNode_set_string(node, buff);
            index_string += strlen(buff);
         } else {
            NJDNode_set_string(node, &buff_string[index_string]);
         }
      } else if (i == 0) {
         /* 表層を句境界で切れないため、先頭 sub-word が表層全体を保持する */
         NJDNode_set_string(node, buff_string);
      } else {
         /* 2個目以降の sub-word は読み (orig トークン) を表層の代替として使う */
         NJDNode_set_string(node, buff);
      }
      /* read */
      get_token_from_string(buff_read, &index_read, buff, ':');
      NJDNode_set_read(node, buff);
      /* pron */
      get_token_from_string(buff_pron, &index_pron, buff, ':');
      NJDNode_set_pron(node, buff);
      /* acc */
      get_token_from_string(buff_acc, &index_acc, buff, '/');
      if (buff[0] == '\0') {
         j = 0;
         fprintf(stderr, "WARNING: NJDNode_load() in njd_node.c: Accent is empty.\n");
      } else {
         j = atoi(buff);
      }
      NJDNode_set_acc(node, j);
      /* mora size */
      get_token_from_string(buff_acc, &index_acc, buff, ':');
      if (buff[0] == '\0') {
         j = 0;
         fprintf(stderr, "WARNING: NJDNode_load() in njd_node.c: Mora size is empty.\n");
      } else {
         j = atoi(buff);
      }
      NJDNode_set_mora_size(node, j);
      prev = node;
   }
}

NJDNode *NJDNode_insert(NJDNode * prev, NJDNode * next, NJDNode * node)
{
   NJDNode *tail;

   if (node == NULL) {
      fprintf(stderr, "WARNING: NJDNode_insert() in njd_node.c: node is NULL.\n");
      return prev;
   }
   // NOTE: prev == NULL は先頭挿入を意味するが、NJD.head の更新責任を持てないため拒否する
   if (prev == NULL) {
      fprintf(stderr, "WARNING: NJDNode_insert() in njd_node.c: prev is NULL.\n");
      return node;
   }
   for (tail = node; tail->next != NULL; tail = tail->next);
   prev->next = node;
   node->prev = prev;
   // NOTE: next == NULL の場合は末尾挿入として動作する
   // 呼び出し元で NJD.tail の修復が必要
   if (next != NULL) {
      next->prev = tail;
   }
   tail->next = next;

   return tail;
}

void NJDNode_copy(NJDNode * node1, NJDNode * node2)
{
   NJDNode_set_string(node1, node2->string);
   NJDNode_set_pos(node1, node2->pos);
   NJDNode_set_pos_group1(node1, node2->pos_group1);
   NJDNode_set_pos_group2(node1, node2->pos_group2);
   NJDNode_set_pos_group3(node1, node2->pos_group3);
   NJDNode_set_ctype(node1, node2->ctype);
   NJDNode_set_cform(node1, node2->cform);
   NJDNode_set_orig(node1, node2->orig);
   NJDNode_set_read(node1, node2->read);
   NJDNode_set_pron(node1, node2->pron);
   NJDNode_set_acc(node1, node2->acc);
   NJDNode_set_mora_size(node1, node2->mora_size);
   NJDNode_set_chain_rule(node1, node2->chain_rule);
   NJDNode_set_chain_flag(node1, node2->chain_flag);
}

void NJDNode_print(NJDNode * node)
{
   NJDNode_fprint(node, stdout);
}

void NJDNode_fprint(NJDNode * node, FILE * fp)
{
   fprintf(fp, "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%d/%d,%s,%d\n", NJDNode_get_string(node),
           NJDNode_get_pos(node), NJDNode_get_pos_group1(node), NJDNode_get_pos_group2(node),
           NJDNode_get_pos_group3(node), NJDNode_get_ctype(node), NJDNode_get_cform(node),
           NJDNode_get_orig(node), NJDNode_get_read(node), NJDNode_get_pron(node),
           NJDNode_get_acc(node), NJDNode_get_mora_size(node), NJDNode_get_chain_rule(node),
           NJDNode_get_chain_flag(node));
}

void NJDNode_sprint(NJDNode * node, char *buff, const char *split_code)
{
   size_t current_length;

   if (node == NULL || buff == NULL) {
      return;
   }

   if (split_code == NULL) {
      split_code = "";
   }

   current_length = strlen(buff);

   sprintf(buff + current_length, "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%d/%d,%s,%d%s",
           NJDNode_get_string(node), NJDNode_get_pos(node), NJDNode_get_pos_group1(node),
           NJDNode_get_pos_group2(node), NJDNode_get_pos_group3(node), NJDNode_get_ctype(node),
           NJDNode_get_cform(node), NJDNode_get_orig(node), NJDNode_get_read(node),
           NJDNode_get_pron(node), NJDNode_get_acc(node), NJDNode_get_mora_size(node),
           NJDNode_get_chain_rule(node), NJDNode_get_chain_flag(node), split_code);
}

void NJDNode_clear(NJDNode * node)
{
   if (node->string != NULL) {
      free(node->string);
      node->string = NULL;
   }
   if (node->pos != NULL) {
      free(node->pos);
      node->pos = NULL;
   }
   if (node->pos_group1 != NULL) {
      free(node->pos_group1);
      node->pos_group1 = NULL;
   }
   if (node->pos_group2 != NULL) {
      free(node->pos_group2);
      node->pos_group2 = NULL;
   }
   if (node->pos_group3 != NULL) {
      free(node->pos_group3);
      node->pos_group3 = NULL;
   }
   if (node->ctype != NULL) {
      free(node->ctype);
      node->ctype = NULL;
   }
   if (node->cform != NULL) {
      free(node->cform);
      node->cform = NULL;
   }
   if (node->orig != NULL) {
      free(node->orig);
      node->orig = NULL;
   }
   if (node->read != NULL) {
      free(node->read);
      node->read = NULL;
   }
   if (node->pron != NULL) {
      free(node->pron);
      node->pron = NULL;
   }
   node->acc = 0;
   node->mora_size = 0;
   if (node->chain_rule != NULL) {
      free(node->chain_rule);
      node->chain_rule = NULL;
   }
   node->chain_flag = -1;
   node->prev = NULL;
   node->next = NULL;
}

NJD_NODE_C_END;

#endif                          /* !NJD_NODE_C */
