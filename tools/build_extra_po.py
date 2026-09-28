#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Write l10n/<lang>/koreader.po for the extra (sk, cs) catalogs.

Reuses the extractor from extract_i18n.py so msgid order and references
match the fr/es catalogs. Usage: python3 build_extra_po.py [sk] [cs]
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import extract_i18n as ex  # noqa: E402

WEST_SLAVIC_PLURAL = "nplurals=3; plural=(n==1) ? 0 : (n>=2 && n<=4) ? 1 : 2;"


def load(lang: str) -> dict[str, str]:
    if lang == "sk":
        from translations_sk import TRANSLATIONS_SK as t  # noqa: WPS433
    elif lang == "cs":
        from translations_cs import TRANSLATIONS_CS as t  # noqa: WPS433
    else:
        raise SystemExit(f"unknown language: {lang}")
    return t


LANGS = {"sk": WEST_SLAVIC_PLURAL, "cs": WEST_SLAVIC_PLURAL}


def build(lang: str, msgs: dict, ordered: list[str]) -> int:
    tr = load(lang)
    missing = [m for m in ordered if not tr.get(m)]
    for m in missing[:30]:
        print(f"  {lang.upper()} missing:", repr(m)[:120])
    out = [ex.write_po_header(lang, LANGS[lang])]
    for m in ordered:
        refs = " ".join(f"{f}:{ln}" for f, ln in msgs[m][:8])
        out.append(f"#: {refs}")
        out.append(f"msgid {ex.format_po_string(m)}")
        out.append(f"msgstr {ex.format_po_string(tr.get(m, ''))}")
        out.append("")
    path = ex.L10N / lang / "koreader.po"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(out) + "\n", encoding="utf-8")
    n, ne = ex.count_msgids(path)
    print(f"wrote {path}: {n} msgids, {ne} translated, {len(missing)} missing")
    return len(missing)


def main() -> int:
    langs = sys.argv[1:] or list(LANGS)
    msgs = ex.collect_msgids()
    ordered = sorted(msgs.keys(), key=lambda s: (msgs[s][0][0], msgs[s][0][1], s))
    return 1 if sum(build(lang, msgs, ordered) for lang in langs) else 0


if __name__ == "__main__":
    raise SystemExit(main())
