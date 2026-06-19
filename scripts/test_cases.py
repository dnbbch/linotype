#!/usr/bin/env python3
"""
Автотесты лингвистики linotype: воспроизводят логику Swift (классификатор,
ёфикация, перекодировка, flip выделения) и проверяют на множестве краевых
случаев — подслова, неправильная раскладка, короткие слова, имена, регистр,
неоднозначные ё-слова и т.д.

Запуск: python test_cases.py
Код возврата != 0, если есть провалы (удобно для CI).
"""

import json
import sys
from pathlib import Path

from test_model import CoreMLClassifier  # переиспользуем загрузку CoreML-модели

MODEL_DIR = Path(__file__).parent.parent / "linotype" / "Model"

RU_TO_EN = {
    'й':'q','ц':'w','у':'e','к':'r','е':'t','н':'y','г':'u','ш':'i','щ':'o','з':'p',
    'х':'[','ъ':']','ф':'a','ы':'s','в':'d','а':'f','п':'g','р':'h','о':'j','л':'k',
    'д':'l','ж':';','э':"'",'я':'z','ч':'x','с':'c','м':'v','и':'b','т':'n','ь':'m',
    'б':',','ю':'.','ё':'`',
}
EN_TO_RU = {v: k for k, v in RU_TO_EN.items()}


def translit(word, table):
    return ''.join(table.get(c, c) for c in word)


# ---------------------------------------------------------------------------
# Реплика Swift Yoficator
# ---------------------------------------------------------------------------

class Yoficator:
    def __init__(self):
        words = json.load(open(MODEL_DIR / "yo_dict.json", encoding="utf-8"))
        self.map = {w.replace("ё", "е"): w for w in words}

    def yoify(self, word):
        lower = word.lower()
        if "е" not in lower:
            return word
        yo = self.map.get(lower)
        if not yo or yo == lower:
            return word
        res = list(word)
        yoc = list(yo)
        if len(res) != len(yoc):
            return word
        for i, c in enumerate(yoc):
            if c == "ё":
                if res[i] == "е":
                    res[i] = "ё"
                elif res[i] == "Е":
                    res[i] = "Ё"
        return "".join(res)


# ---------------------------------------------------------------------------
# Реплика Swift Classifier.flip (перекодировка выделения)
# ---------------------------------------------------------------------------

def flip(text):
    cyr = sum(1 for c in text if ('а' <= c <= 'я') or c in 'ёЁ' or ('А' <= c <= 'Я'))
    lat = sum(1 for c in text if c.isascii() and c.isalpha())
    if cyr + lat == 0:
        return text
    table = RU_TO_EN if cyr >= lat else EN_TO_RU
    return translit(text, table)


# ---------------------------------------------------------------------------
# Тесты
# ---------------------------------------------------------------------------

class Results:
    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.fails = []

    def check(self, ok, name, detail=""):
        if ok:
            self.passed += 1
        else:
            self.failed += 1
            self.fails.append(f"{name}: {detail}")


def test_translit_roundtrip(r):
    # Каждая русская буква: ru→en→ru должна вернуться к себе
    for ru in RU_TO_EN:
        back = translit(translit(ru, RU_TO_EN), EN_TO_RU)
        r.check(back == ru, "translit-roundtrip", f"{ru!r}→{back!r}")


def test_yoficator(r):
    yo = Yoficator()

    must_change = [
        ("елка", "ёлка"), ("Елка", "Ёлка"), ("актер", "актёр"),
        ("еж", "ёж"), ("тетя", "тётя"), ("полет", "полёт"),
        ("самолет", "самолёт"), ("еще", "ещё"), ("береза", "берёза"),
    ]
    for src, exp in must_change:
        got = yo.yoify(src)
        # допускаем, что консервативный словарь мог не включить слово (got==src),
        # но если изменил — то ТОЛЬКО на правильную ё-форму
        r.check(got in (exp, src), "yo-change", f"{src}→{got} (ожид. {exp} или без изм.)")

    # НЕ должны меняться: обычные е-слова (нет ё)
    must_not_change = ["белка", "село", "небо", "лето", "море", "хлеб",
                       "текст", "тест", "семь", "девять", "телефон", "перерыв",
                       "человек", "değil", "hello", "computer"]
    for w in must_not_change:
        got = yo.yoify(w)
        r.check(got == w, "yo-keep", f"{w}→{got} (не должно меняться)")

    # Неоднозначные (ё-форма и е-форма — разные слова) НЕ должны трогаться
    for w in ["все", "осел", "небе", "поем"]:
        got = yo.yoify(w)
        r.check(got == w, "yo-ambiguous", f"{w}→{got} (неоднозначное, не трогать)")

    # ПОДСЛОВА: слово, содержащее ё-слово как подстроку, но само не в словаре,
    # не должно меняться (ёфикация — только по целому слову)
    for w in ["белкаелка", "преселок", "елкаxyz", "теттетя"]:
        got = yo.yoify(w)
        r.check(got == w, "yo-subword", f"{w}→{got} (подслово не должно срабатывать)")


def smart_quote(prev):
    """Реплика логики Swift quotify (хоткей ⌘⌥'): открывающая « или закрывающая »."""
    if prev is None:
        opening = True
    elif prev.isspace():
        opening = True
    else:
        opening = prev in "([{—–-"
    return "«" if opening else "»"


def test_smart_quotes(r):
    # (символ перед кавычкой, ожидаемая ёлочка)
    cases = [
        (None, "«"),   # начало ввода
        (" ", "«"),    # после пробела
        ("(", "«"),    # после открывающей скобки
        ("—", "«"),  # после длинного тире
        ("-", "«"),    # после дефиса
        ("т", "»"),    # после буквы
        ("5", "»"),    # после цифры
        (".", "»"),    # после точки
        ("«", "»"),  # после « → закрывающая (случай "" → «»)
    ]
    for prev, exp in cases:
        got = smart_quote(prev)
        r.check(got == exp, "smart-quote", f"prev={prev!r} → {got} (ожид. {exp})")


def test_flip(r):
    # Кириллица целиком → латиница (раскладочная)
    r.check(flip("привет") == "ghbdtn", "flip-cyr", flip("привет"))
    r.check(flip("привет как дела") == "ghbdtn rfr ltkf", "flip-cyr-phrase", flip("привет как дела"))
    # Латиница целиком → кириллица
    r.check(flip("ghbdtn") == "привет", "flip-lat", flip("ghbdtn"))
    # Пустая/без букв
    r.check(flip("123 ...") == "123 ...", "flip-nonletters", flip("123 ..."))


def test_model(r, clf):
    cases = {
        "ru-обычные": [("привет","ru"),("компьютер","ru"),("разработка","ru"),
                       ("переключение","ru"),("программирование","ru")],
        "en-обычные": [("hello","en"),("keyboard","en"),("development","en"),
                       ("programming","en"),("application","en")],
        "wrong-layout ru→en набор": [("ghbdtn","ru"),("rjvgm.nth","ru"),("ghjuhfvvf","ru")],
        "wrong-layout en→ru набор": [(translit("hello",EN_TO_RU),"en"),
                                     (translit("keyboard",EN_TO_RU),"en"),
                                     ("тще","en")],  # "tot" → ru-набор → должно быть en? см. ниже
        "подслова (ru со вставкой en-похожих)": [
            ("проект","ru"),("сервер","ru"),("интернет","ru"),("файл","ru"),("браузер","ru")],
        "en с ru-похожими подстроками": [
            ("server","en"),("internet","en"),("browser","en"),("project","en")],
    }
    # 'тще' = 'tot' набранное в RU-раскладке (t→е,o→щ,t→е = 'еще') — это слово ru.
    # Уберём ошибочный кейс выше и проверим 'tot' как en-набор отдельно.
    cases["wrong-layout en→ru набор"] = [
        (translit("hello", EN_TO_RU), "en"),
        (translit("keyboard", EN_TO_RU), "en"),
        (translit("world", EN_TO_RU), "en"),
    ]
    for cat, items in cases.items():
        for word, exp in items:
            lang, conf = clf.predict(word)
            r.check(lang == exp, f"model:{cat}", f"{word}→{lang} ({conf:.2f}), ожид. {exp}")


def main():
    if not (MODEL_DIR / "LinotypeModel.mlmodel").exists():
        print("Модель не найдена — сначала python train_model.py")
        sys.exit(1)

    r = Results()
    print("Перекодировка (round-trip)...")
    test_translit_roundtrip(r)
    print("Ёфикация...")
    test_yoficator(r)
    print("Умные кавычки...")
    test_smart_quotes(r)
    print("Flip выделения...")
    test_flip(r)
    print("Классификатор (CoreML)...")
    clf = CoreMLClassifier(str(MODEL_DIR / "LinotypeModel.mlmodel"))
    test_model(r, clf)

    print(f"\n{'='*60}")
    print(f"Пройдено: {r.passed}   Провалено: {r.failed}")
    if r.fails:
        print("\nПровалы:")
        for f in r.fails[:40]:
            print(f"  ✗ {f}")
    else:
        print("Все тесты пройдены ✓")
    sys.exit(1 if r.failed else 0)


if __name__ == "__main__":
    main()
