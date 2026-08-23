#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Extract _("...") / _([[...]]) strings and write koreader.pot + fr/es .po files."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
L10N = ROOT / "l10n"
VERSION = "0.1.17.40"

SKIP_NAME_EXACT = {"debuglog.lua"}
SKIP_NAME_SUBSTR = (".fix", ".v25")
# Untracked local checkouts / build outputs that must never feed the catalog.
SKIP_DIR_NAMES = {"kobo-tts-bundle", "koreader-src"}


def should_skip(path: Path) -> bool:
    if any(part in SKIP_DIR_NAMES for part in path.parts):
        return True
    name = path.name
    if name in SKIP_NAME_EXACT:
        return True
    if any(s in name for s in SKIP_NAME_SUBSTR):
        return True
    if name == "audiobook_gettext.lua":
        return True
    return False


def unescape_lua_string(s: str) -> str:
    """Unescape Lua short-string escapes.

    Decimal/hex escapes insert raw bytes (Lua string = byte string). Other
    characters come from the UTF-8 source file as Unicode. We build a UTF-8
    byte sequence then decode so ``\\226\\128\\166`` becomes ``…``.
    """
    raw = bytearray()
    i = 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            nch = s[i + 1]
            mapping = {
                "n": b"\n",
                "t": b"\t",
                "r": b"\r",
                '"': b'"',
                "'": b"'",
                "\\": b"\\",
                "a": b"\a",
                "b": b"\b",
                "f": b"\f",
                "v": b"\v",
            }
            if nch in mapping:
                raw.extend(mapping[nch])
                i += 2
                continue
            if nch.isdigit():
                j = i + 1
                digits: list[str] = []
                while j < len(s) and s[j].isdigit() and len(digits) < 3:
                    digits.append(s[j])
                    j += 1
                raw.append(int("".join(digits), 10) & 0xFF)
                i = j
                continue
            if nch == "x" and i + 3 < len(s):
                raw.append(int(s[i + 2 : i + 4], 16) & 0xFF)
                i += 4
                continue
            raw.extend(nch.encode("utf-8"))
            i += 2
        else:
            raw.extend(s[i].encode("utf-8"))
            i += 1
    return raw.decode("utf-8")


def _skip_ws(text: str, j: int) -> int:
    n = len(text)
    while j < n:
        c = text[j]
        if c in " \t\n\r":
            j += 1
            continue
        if c == "-" and j + 1 < n and text[j + 1] == "-":
            if j + 2 < n and text[j + 2] == "[":
                eq = 0
                k = j + 3
                while k < n and text[k] == "=":
                    eq += 1
                    k += 1
                if k < n and text[k] == "[":
                    close = "]" + ("=" * eq) + "]"
                    end = text.find(close, k + 1)
                    j = n if end < 0 else end + len(close)
                    continue
            while j < n and text[j] != "\n":
                j += 1
            continue
        break
    return j


def _parse_string_literal(text: str, j: int) -> tuple[str, int] | None:
    n = len(text)
    j = _skip_ws(text, j)
    if j >= n:
        return None
    if text[j] == "[":
        eq = 0
        k = j + 1
        while k < n and text[k] == "=":
            eq += 1
            k += 1
        if k < n and text[k] == "[":
            close = "]" + ("=" * eq) + "]"
            k += 1
            end = text.find(close, k)
            if end < 0:
                return None
            return text[k:end], end + len(close)
        return None
    if text[j] in "\"'":
        quote = text[j]
        k = j + 1
        raw_chars: list[str] = []
        while k < n:
            c = text[k]
            if c == "\\" and k + 1 < n:
                nch = text[k + 1]
                if nch.isdigit():
                    kk = k + 1
                    while kk < n and text[kk].isdigit() and (kk - (k + 1)) < 3:
                        kk += 1
                    raw_chars.append(text[k:kk])
                    k = kk
                    continue
                if nch == "x" and k + 3 < n:
                    raw_chars.append(text[k : k + 4])
                    k += 4
                    continue
                raw_chars.append(text[k : k + 2])
                k += 2
                continue
            if c == quote:
                return unescape_lua_string("".join(raw_chars)), k + 1
            raw_chars.append(c)
            k += 1
        return None
    return None


def parse_static_gettext_arg(text: str, open_paren: int) -> tuple[str, int] | None:
    """Parse _("..." .. "...") static concatenation. open_paren points at '('."""
    j = _skip_ws(text, open_paren + 1)
    parts: list[str] = []
    while True:
        parsed = _parse_string_literal(text, j)
        if parsed is None:
            return None
        val, j = parsed
        parts.append(val)
        j = _skip_ws(text, j)
        if j >= len(text):
            return None
        if text[j] == ")":
            return "".join(parts), j + 1
        if text.startswith("..", j):
            j = _skip_ws(text, j + 2)
            continue
        return None


def extract_from_text(text: str) -> list[tuple[str, int]]:
    strings: list[tuple[str, int]] = []
    i = 0
    n = len(text)
    while i < n:
        if text[i] == "_" and i + 1 < n and text[i + 1] == "(":
            if i > 0 and (text[i - 1].isalnum() or text[i - 1] == "_"):
                i += 1
                continue
            start = i
            result = parse_static_gettext_arg(text, i + 1)
            if result is None:
                i += 2
                continue
            content, end = result
            lineno = text.count("\n", 0, start) + 1
            # Empty msgid is reserved for the PO header — skip _("")
            if content != "":
                strings.append((content, lineno))
            i = end
            continue
        i += 1
    return strings


def po_escape(s: str) -> str:
    return (
        s.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\t", "\\t")
        .replace("\r", "\\r")
    )


def format_po_string(s: str) -> str:
    if "\n" in s:
        parts = s.split("\n")
        lines = ['""']
        for idx, part in enumerate(parts):
            if idx < len(parts) - 1:
                lines.append(f'"{po_escape(part)}\\n"')
            elif part:
                lines.append(f'"{po_escape(part)}"')
        return "\n".join(lines)
    return f'"{po_escape(s)}"'


def write_po_header(lang: str, plural: str) -> str:
    return f'''msgid ""
msgstr ""
"Project-Id-Version: audiobook.koplugin {VERSION}\\n"
"Report-Msgid-Bugs-To: \\n"
"POT-Creation-Date: 2026-08-13 11:00+0200\\n"
"PO-Revision-Date: 2026-08-13 11:00+0200\\n"
"Last-Translator: \\n"
"Language-Team: \\n"
"Language: {lang}\\n"
"MIME-Version: 1.0\\n"
"Content-Type: text/plain; charset=UTF-8\\n"
"Content-Transfer-Encoding: 8bit\\n"
"Plural-Forms: {plural}\\n"
'''


def write_pot_header() -> str:
    return f'''msgid ""
msgstr ""
"Project-Id-Version: audiobook.koplugin {VERSION}\\n"
"Report-Msgid-Bugs-To: \\n"
"POT-Creation-Date: 2026-08-13 11:00+0200\\n"
"PO-Revision-Date: YEAR-MO-DA HO:MI+ZONE\\n"
"Last-Translator: FULL NAME <EMAIL@ADDRESS>\\n"
"Language-Team: LANGUAGE <LL@li.org>\\n"
"Language: \\n"
"MIME-Version: 1.0\\n"
"Content-Type: text/plain; charset=UTF-8\\n"
"Content-Transfer-Encoding: 8bit\\n"
'''


def collect_msgids() -> dict[str, list[tuple[str, int]]]:
    msgs: dict[str, list[tuple[str, int]]] = {}
    for path in sorted(ROOT.rglob("*.lua")):
        if should_skip(path):
            continue
        try:
            path.relative_to(ROOT / "tools")
            continue
        except ValueError:
            pass
        try:
            path.relative_to(ROOT / "l10n")
            continue
        except ValueError:
            pass
        text = path.read_text(encoding="utf-8")
        rel = str(path.relative_to(ROOT)).replace("\\", "/")
        for content, lineno in extract_from_text(text):
            msgs.setdefault(content, []).append((rel, lineno))
    return msgs


def decode_po_string(raw: str) -> str:
    chunks = re.findall(r'"((?:\\.|[^"\\])*)"', raw)
    s = "".join(chunks)
    out: list[str] = []
    i = 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            nch = s[i + 1]
            mapping = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}
            out.append(mapping.get(nch, nch))
            i += 2
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def count_msgids(p: Path) -> tuple[int, int]:
    text = p.read_text(encoding="utf-8")
    # Match msgid/msgstr values that may span multiple quoted lines, with escapes
    entries = re.findall(
        r'^msgid ((?:""\n)?(?:"(?:\\.|[^"\\])*"\n?)+)'
        r'^msgstr ((?:""\n)?(?:"(?:\\.|[^"\\])*"\n?)+)',
        text,
        flags=re.MULTILINE,
    )
    total = 0
    nonempty = 0
    for mid, mstr in entries:
        decoded_mid = decode_po_string(mid)
        decoded_mstr = decode_po_string(mstr)
        if decoded_mid == "":
            continue
        total += 1
        if decoded_mstr:
            nonempty += 1
    return total, nonempty


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "generate"
    msgs = collect_msgids()
    ordered = sorted(msgs.keys(), key=lambda s: (msgs[s][0][0], msgs[s][0][1], s))

    if mode == "list":
        out = ROOT / "tools" / "_msgids.json"
        data = [{"msgid": m, "refs": [f"{f}:{ln}" for f, ln in msgs[m]]} for m in ordered]
        out.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"Wrote {len(ordered)} msgids to {out}")
        return 0

    from translations import TRANSLATIONS_FR, TRANSLATIONS_ES  # noqa: WPS433

    missing_fr = [m for m in ordered if not TRANSLATIONS_FR.get(m)]
    missing_es = [m for m in ordered if not TRANSLATIONS_ES.get(m)]
    if missing_fr or missing_es:
        print(f"MISSING FR: {len(missing_fr)}  ES: {len(missing_es)}")
        for m in missing_fr[:30]:
            print("  FR:", repr(m)[:120])
        for m in missing_es[:30]:
            print("  ES:", repr(m)[:120])
        miss_path = ROOT / "tools" / "_missing.json"
        miss_path.write_text(
            json.dumps({"fr": missing_fr, "es": missing_es}, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        print(f"Wrote missing list to {miss_path}")
        return 1

    pot_dir = L10N / "templates"
    pot_dir.mkdir(parents=True, exist_ok=True)
    pot_path = pot_dir / "koreader.pot"
    lines = [write_pot_header()]
    for m in ordered:
        refs = msgs[m]
        ref_str = " ".join(f"{f}:{ln}" for f, ln in refs[:8])
        lines.append(f"#: {ref_str}")
        lines.append(f"msgid {format_po_string(m)}")
        lines.append('msgstr ""')
        lines.append("")
    pot_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def write_lang(lang: str, plural: str, translations: dict[str, str], path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        out_lines = [write_po_header(lang, plural)]
        for m in ordered:
            refs = msgs[m]
            ref_str = " ".join(f"{f}:{ln}" for f, ln in refs[:8])
            out_lines.append(f"#: {ref_str}")
            out_lines.append(f"msgid {format_po_string(m)}")
            out_lines.append(f"msgstr {format_po_string(translations[m])}")
            out_lines.append("")
        path.write_text("\n".join(out_lines) + "\n", encoding="utf-8")

    fr_path = L10N / "fr" / "koreader.po"
    es_path = L10N / "es" / "koreader.po"
    write_lang("fr", "nplurals=2; plural=(n > 1);", TRANSLATIONS_FR, fr_path)
    write_lang("es", "nplurals=2; plural=(n != 1);", TRANSLATIONS_ES, es_path)

    pot_n, _ = count_msgids(pot_path)
    fr_n, fr_ne = count_msgids(fr_path)
    es_n, es_ne = count_msgids(es_path)
    print(f"unique extracted: {len(ordered)}")
    print(f"pot msgids: {pot_n}")
    print(f"fr msgids: {fr_n}, nonempty msgstr: {fr_ne}")
    print(f"es msgids: {es_n}, nonempty msgstr: {es_ne}")
    print(f"wrote: {pot_path}")
    print(f"wrote: {fr_path}")
    print(f"wrote: {es_path}")

    meta = next((m for m in ordered if m.startswith("Text-to-Speech with synchronized")), None)
    if meta:
        print("meta FR:", TRANSLATIONS_FR[meta][:70])
        print("meta ES:", TRANSLATIONS_ES[meta][:70])

    ok = pot_n == fr_n == es_n == fr_ne == es_ne == len(ordered)
    print("VERIFY OK" if ok else "VERIFY FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
