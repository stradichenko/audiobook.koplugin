#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Write l10n/sk/koreader.po from TRANSLATIONS_SK using the same extractor as fr/es."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import extract_i18n as ex  # noqa: E402
from translations_sk import TRANSLATIONS_SK  # noqa: E402

PLURAL = "nplurals=3; plural=(n==1) ? 0 : (n>=2 && n<=4) ? 1 : 2;"


def main() -> int:
    msgs = ex.collect_msgids()
    ordered = sorted(msgs.keys(), key=lambda s: (msgs[s][0][0], msgs[s][0][1], s))
    missing = [m for m in ordered if not TRANSLATIONS_SK.get(m)]
    for m in missing[:30]:
        print("  SK missing:", repr(m)[:120])
    out = [ex.write_po_header("sk", PLURAL)]
    for m in ordered:
        refs = " ".join(f"{f}:{ln}" for f, ln in msgs[m][:8])
        out.append(f"#: {refs}")
        out.append(f"msgid {ex.format_po_string(m)}")
        out.append(f"msgstr {ex.format_po_string(TRANSLATIONS_SK.get(m, ''))}")
        out.append("")
    path = ex.L10N / "sk" / "koreader.po"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(out) + "\n", encoding="utf-8")
    n, ne = ex.count_msgids(path)
    print(f"wrote {path}: {n} msgids, {ne} translated, {len(missing)} missing")
    return 0 if not missing else 1


if __name__ == "__main__":
    raise SystemExit(main())
