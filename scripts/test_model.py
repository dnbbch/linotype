#!/usr/bin/env python3
"""
Тест точности РАЗВЁРНУТОЙ CoreML-модели (то, что реально использует Swift).
Загружает LinotypeModel.mlmodel + vocab.json и прогоняет контрольные слова.

Запуск: python test_model.py [--model path/to/LinotypeModel.mlmodel]
"""

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np
import coremltools as ct

RU_TO_EN = {
    'й':'q','ц':'w','у':'e','к':'r','е':'t','н':'y','г':'u','ш':'i','щ':'o','з':'p',
    'х':'[','ъ':']','ф':'a','ы':'s','в':'d','а':'f','п':'g','р':'h','о':'j','л':'k',
    'д':'l','ж':';','э':"'",'я':'z','ч':'x','с':'c','м':'v','и':'b','т':'n','ь':'m',
    'б':',','ю':'.','ё':'`',
}
EN_TO_RU = {v: k for k, v in RU_TO_EN.items()}


def translit_ru_to_en(word: str) -> str:
    return ''.join(RU_TO_EN.get(c, c) for c in word)


def translit_en_to_ru(word: str) -> str:
    return ''.join(EN_TO_RU.get(c, c) for c in word)


TEST_CASES = {
    'Обычные русские слова': [
        ('привет', 'ru'), ('мир', 'ru'), ('работа', 'ru'),
        ('компьютер', 'ru'), ('программа', 'ru'), ('разработка', 'ru'),
        ('клавиатура', 'ru'), ('переключение', 'ru'), ('автоматически', 'ru'),
        ('приложение', 'ru'), ('система', 'ru'), ('пользователь', 'ru'),
    ],
    'Обычные английские слова': [
        ('hello', 'en'), ('world', 'en'), ('computer', 'en'),
        ('keyboard', 'en'), ('software', 'en'), ('development', 'en'),
        ('application', 'en'), ('system', 'en'), ('user', 'en'),
        ('programming', 'en'), ('language', 'en'), ('switch', 'en'),
    ],
    'Русские слова в EN-раскладке (wrong layout)': [
        (translit_ru_to_en('привет'), 'ru'),
        (translit_ru_to_en('компьютер'), 'ru'),
        (translit_ru_to_en('работа'), 'ru'),
        (translit_ru_to_en('программа'), 'ru'),
        (translit_ru_to_en('клавиатура'), 'ru'),
    ],
    'Английские слова в RU-раскладке (wrong layout)': [
        (translit_en_to_ru('hello'), 'en'),
        (translit_en_to_ru('computer'), 'en'),
        (translit_en_to_ru('keyboard'), 'en'),
        (translit_en_to_ru('software'), 'en'),
    ],
    'Короткие слова (сложные)': [
        ('ок', 'ru'), ('да', 'ru'), ('нет', 'ru'),
        ('ok', 'en'), ('no', 'en'), ('hi', 'en'),
    ],
    'Имена (ожидаемо сложные)': [
        ('иван', 'ru'), ('мария', 'ru'),
        ('john', 'en'), ('alice', 'en'),
    ],
}


class CoreMLClassifier:
    def __init__(self, model_path: str):
        self.model = ct.models.MLModel(model_path)
        vocab_path = Path(model_path).parent / 'vocab.json'
        vocab = json.load(open(vocab_path, encoding='utf-8'))
        self.ngrams = vocab['ngrams']
        self.index = {ng: i for i, ng in enumerate(self.ngrams)}
        self.size = len(self.ngrams)
        self.min_n, self.max_n = vocab['ngram_range']

    def _char_wb_ngrams(self, word: str) -> list:
        w = ' ' + word.lower() + ' '
        w_len = len(w)
        out = []
        for n in range(self.min_n, self.max_n + 1):
            offset = 0
            out.append(w[offset:offset + n])
            while offset + n < w_len:
                offset += 1
                out.append(w[offset:offset + n])
            if offset == 0:
                break
        return out

    def _features(self, word: str) -> np.ndarray:
        v = np.zeros(self.size, dtype=np.float32)
        for ng in set(self._char_wb_ngrams(word)):
            j = self.index.get(ng)
            if j is not None:
                v[j] = 1.0
        return v

    def predict(self, word: str):
        r = self.model.predict({'features': self._features(word)})
        label = 'ru' if r['classLabel'] == '__label__ru' else 'en'
        conf = r['labelProbabilities'][r['classLabel']]
        return label, float(conf)


def run_tests(model_path: str) -> None:
    print(f'Загружаю CoreML модель: {model_path}')
    clf = CoreMLClassifier(model_path)
    print(f'N-грамм в словаре: {clf.size:,}\n')

    total_correct = 0
    total_count = 0

    for category, cases in TEST_CASES.items():
        correct = 0
        print(f'── {category} ──')
        print(f'  {"Слово":<25} {"Ожид.":<6} {"Предсказано":<12} {"Conf":>6}  ✓/✗')
        print('  ' + '-' * 58)
        for word, expected in cases:
            predicted, confidence = clf.predict(word)
            ok = predicted == expected
            correct += int(ok)
            print(f'  {word:<25} {expected:<6} {predicted:<12} {confidence:>6.3f}  {"✓" if ok else "✗"}')
        total_correct += correct
        total_count += len(cases)
        print(f'  Точность категории: {correct}/{len(cases)} = {correct/len(cases)*100:.1f}%\n')

    print('=' * 60)
    overall = total_correct / total_count * 100 if total_count else 0
    print(f'Общая точность: {total_correct}/{total_count} = {overall:.1f}%')
    if overall >= 97:
        print('Результат: ОТЛИЧНО ✓ (≥ 97%)')
    elif overall >= 90:
        print('Результат: ХОРОШО (≥ 90%)')
    else:
        print('Результат: НЕДОСТАТОЧНО (< 90%)')

    # Производительность CoreML
    words = ['привет', 'hello', 'компьютер', 'keyboard'] * 250
    start = time.perf_counter()
    for w in words:
        clf.predict(w)
    avg_ms = (time.perf_counter() - start) / len(words) * 1000
    print(f'\nСкорость inference (CoreML, включая векторизацию): {avg_ms:.3f} ms/слово')


def main():
    parser = argparse.ArgumentParser(description='Тест CoreML модели linotype')
    parser.add_argument('--model', type=str,
                        default=str(Path(__file__).parent.parent / 'linotype' / 'Model' / 'LinotypeModel.mlmodel'),
                        help='Путь к LinotypeModel.mlmodel')
    args = parser.parse_args()

    if not Path(args.model).exists():
        print(f'Ошибка: модель не найдена: {args.model}')
        print('Сначала запустите: python train_model.py')
        sys.exit(1)

    run_tests(args.model)


if __name__ == '__main__':
    main()
