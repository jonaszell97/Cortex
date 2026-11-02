#!/usr/bin/env python3 -I
"""Generates CortexCore/Sources/CortexCore/Emoji/emoji.json for the emoji search.

Source: the Emojibase data package (https://emojibase.dev, MIT; names and
keywords are from the Unicode CLDR), English and German, plus the CLDR and
GitHub shortcodes. Run when moving to a newer Emoji version:

    scripts/generate-emoji-data.py [emojibase-data version]

Skin tone variants are folded into their base emoji; components (the skin
tone and hair modifiers on their own) and regional indicators are dropped.
"""

import json
import sys
import urllib.request
from pathlib import Path

VERSION = sys.argv[1] if len(sys.argv) > 1 else "16.0.3"
LANGUAGES = ["en", "de"]
BASE = f"https://cdn.jsdelivr.net/npm/emojibase-data@{VERSION}"
OUTPUT = Path(__file__).resolve().parent.parent / "CortexCore/Sources/CortexCore/Emoji/emoji.json"

# Emojibase group numbers in display order; the output uses the index. Group 2
# (components) is left out.
GROUPS = [0, 1, 3, 4, 5, 6, 7, 8, 9]


def fetch(path):
    with urllib.request.urlopen(f"{BASE}/{path}", timeout=60) as response:
        return json.load(response)


def shortcodes(*tables):
    merged = {}
    for table in tables:
        for hexcode, value in table.items():
            names = [value] if isinstance(value, str) else value
            known = merged.setdefault(hexcode, [])
            known.extend(name for name in names if name not in known)
    return merged


def main():
    data = {language: fetch(f"{language}/data.json") for language in LANGUAGES}
    codes = shortcodes(fetch("en/shortcodes/cldr.json"), fetch("en/shortcodes/github.json"))
    names = {language: {entry["hexcode"]: entry for entry in data[language]} for language in LANGUAGES}

    emoji = []
    for entry in data["en"]:
        if entry.get("group") not in GROUPS:
            continue
        hexcode = entry["hexcode"]
        record = {
            "c": entry["emoji"],
            "o": entry["order"],
            "g": GROUPS.index(entry["group"]),
            "v": entry["version"],
            "s": codes.get(hexcode, []),
            "l": {},
        }
        for language in LANGUAGES:
            localized = names[language].get(hexcode)
            if localized:
                record["l"][language] = {"n": localized["label"], "k": localized.get("tags", [])}
        # Five variants, light to dark. Emoji with two tones (couples) have none.
        skins = [skin for skin in entry.get("skins", []) if isinstance(skin.get("tone"), int)]
        skins.sort(key=lambda skin: skin["tone"])
        if [skin["tone"] for skin in skins] == [1, 2, 3, 4, 5]:
            record["t"] = [skin["emoji"] for skin in skins]
        emoji.append(record)

    emoji.sort(key=lambda record: (record["g"], record["o"]))
    document = {"source": f"emojibase-data {VERSION}", "languages": LANGUAGES, "emoji": emoji}
    OUTPUT.write_text(json.dumps(document, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    print(f"{len(emoji)} emoji, {OUTPUT.stat().st_size // 1024} KB -> {OUTPUT}")


main()
