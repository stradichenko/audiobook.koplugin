# csrc/openjtalk — 取り込んだ第三者コード

**改変は下表の 1 件だけ。** それ以外は上流のまま。
`scripts/k1/k4b_vendor.py --check` が「上流 + 下表」と突き合わせるので、
**表に無い改変は落ちる**。

## 当てている改変

| ファイル | 置換 | なぜ |
|---|---|---|
| `jpcommon_label.c` | `#define MAXBUFLEN 1024` → `#define MAXBUFLEN 256` | K-5: フルコンテキストラベル 1 本あたりの固定バッファ。1 文で最大 214 本確保するので、1024 だと 219,136 B を占めて**1 文ピークの 83.7%** になる。実測の最長ラベルは **166 B**（35,097 本。うち最長文 100 文を含む）。溢れても上流が snprintf で打ち切り、`Label buffer exceeded` を stderr に出すので**黙って壊れない**。 |

| | |
|---|---|
| 出所 | Open JTalk（HTS Working Group / Nagoya Institute of Technology） |
| 取得元 | **pyopenjtalk_plus-0.4.1.post9（--src 指定）** の sdist 同梱（`lib/open_jtalk/src`） |
| ライセンス | **修正 BSD**（[`COPYING`](COPYING)。Copyright (c) 2008-2016） |
| ファイル数 | 34（+ COPYING） |
| 行数 | 8,928 |
| 全ファイル連結の SHA-256 | `572fc2b7341530ff56d9c415fdb7df41886ad9ed57e6975579cb3a4b644a5f43` |

⚠️ **取得元は素の `pyopenjtalk` ではなく `pyopenjtalk-plus`。**
本プロジェクトのホスト側（ラベル生成・検証ベクタ）が動かしているのがこちらで、
**素の pyopenjtalk 0.4.1 とは 22 / 34 ファイルが食い違う**（C-048）。
`njd_set_accent_phrase.c` の Rule 13 のように**規則そのものが違う**ので、
取り違えると G14a が落ちる。

⚠️ **GPL-3.0 の `Ampixa/sanoTTS` とは別物**。D-032 の凍結対象ではない。

## 取り込んだモジュール

`text2mecab` / `mecab2njd` / `njd` / `njd_set_pronunciation` / `njd_set_digit` / `njd_set_accent_phrase` / `njd_set_accent_type` / `njd_set_unvoiced_vowel` / `njd_set_long_vowel` / `njd2jpcommon` / `jpcommon`

## 取り込まなかったもの

**文字コード別のヘッダ**（`*_shift_jis.h` / `*_euc_jp.h` / `*_ascii*.h`）。
本プロジェクトは UTF-8 だけを扱う。`mecab/` も取らない（K-1 / K-2 が置き換える）。

## 改変の方針

⚠️ **勝手に改変しない。** 改変すると「ホストと一致するか」の基準が
自分の改変に依存してしまう（K-4b の G14a）。変える必要が出たら
`k4b_vendor.py` の `PATCHES` に**理由つきで**足すこと。
`--check` が「上流 + PATCHES」と突き合わせるので、表に無い改変は落ちる。

## 更新のしかた

```bash
uv run python scripts/k1/k4b_vendor.py --sdist pyopenjtalk_plus-<ver>.tar.gz
make -C csrc njd-rules        # ⚠️ **必ず G14a を通し直す**
```
