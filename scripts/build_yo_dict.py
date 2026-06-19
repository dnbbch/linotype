#!/usr/bin/env python3
"""
Скачивает словарь однозначных ё-слов (eyo-kernel, dictionary/safe.txt),
разворачивает паттерны «основа(оконч1|оконч2|...)» в плоский список словоформ
и сохраняет ../linotype/Model/yo_dict.json (массив ё-слов в нижнем регистре).

Swift строит из него карту «е-форма → ё-форма» на старте.
"""
import json
import re
import urllib.request
from pathlib import Path

URL = "https://raw.githubusercontent.com/e2yo/eyo-kernel/master/dictionary/safe.txt"
OUT = Path(__file__).parent.parent / "linotype" / "Model" / "yo_dict.json"

PATTERN = re.compile(r"^([^(]*)\((.*)\)$")


def expand(line: str) -> list:
    line = line.strip()
    if not line:
        return []
    m = PATTERN.match(line)
    if not m:
        return [line]
    stem, alts = m.group(1), m.group(2)
    return [stem + alt for alt in alts.split("|")]


def main():
    print(f"Скачиваю {URL} ...")
    text = urllib.request.urlopen(URL, timeout=60).read().decode("utf-8")

    forms = set()
    for line in text.splitlines():
        for form in expand(line):
            low = form.lower().lstrip("_").strip()  # eyo иногда метит слова ведущим "_"
            if "ё" in low and low.isalpha():
                forms.add(low)

    words = sorted(forms)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(words, f, ensure_ascii=False)

    size_kb = OUT.stat().st_size / 1024
    print(f"Готово: {len(words):,} ё-словоформ, {size_kb:.0f} КБ → {OUT}")
    print("Примеры:", ", ".join(words[i] for i in (0, len(words)//3, len(words)//2, -1)))


if __name__ == "__main__":
    main()
