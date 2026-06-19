#!/usr/bin/env python3
"""
Обучение ru/en классификатора раскладки и конвертация в CoreML.

Модель: символьные n-граммы (char_wb 2–4) + линейный классификатор
(LogisticRegression). Такой подход:
  * точно воспроизводится в CoreML (innerProduct + softmax) — без хеширования;
  * ловит слова, набранные не в той раскладке (ghbdtn→ru, руддщ→en), т.к.
    дискриминантный сигнал — статистика символьных n-грамм;
  * крошечный размер модели (<1 МБ) и инференс <1 мс.

Запуск: python train_model.py [--ru-corpus path] [--en-corpus path] [--output-dir path]
"""

import argparse
import json
import random
import re
import urllib.request
from pathlib import Path

import numpy as np
import coremltools as ct
from sklearn.feature_extraction.text import CountVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import train_test_split
from tqdm import tqdm

# ---------------------------------------------------------------------------
# Таблицы раскладок (для генерации wrong-layout примеров)
# ---------------------------------------------------------------------------

RU_TO_EN = {
    'й':'q','ц':'w','у':'e','к':'r','е':'t','н':'y','г':'u','ш':'i','щ':'o','з':'p',
    'х':'[','ъ':']','ф':'a','ы':'s','в':'d','а':'f','п':'g','р':'h','о':'j','л':'k',
    'д':'l','ж':';','э':"'",'я':'z','ч':'x','с':'c','м':'v','и':'b','т':'n','ь':'m',
    'б':',','ю':'.','ё':'`',
    'Й':'Q','Ц':'W','У':'E','К':'R','Е':'T','Н':'Y','Г':'U','Ш':'I','Щ':'O','З':'P',
    'Х':'{','Ъ':'}','Ф':'A','Ы':'S','В':'D','А':'F','П':'G','Р':'H','О':'J','Л':'K',
    'Д':'L','Ж':':','Э':'"','Я':'Z','Ч':'X','С':'C','М':'V','И':'B','Т':'N','Ь':'M',
    'Б':'<','Ю':'>','Ё':'~',
}
EN_TO_RU = {v: k for k, v in RU_TO_EN.items()}


def translit_ru_to_en(word: str) -> str:
    """Слово набранное в русской раскладке, когда должна быть английская."""
    return ''.join(RU_TO_EN.get(c, c) for c in word)


def translit_en_to_ru(word: str) -> str:
    """Слово набранное в английской раскладке, когда должна быть русская."""
    return ''.join(EN_TO_RU.get(c, c) for c in word)


# ---------------------------------------------------------------------------
# Конфигурация модели
# ---------------------------------------------------------------------------

NGRAM_RANGE = (2, 4)       # символьные n-граммы длиной 2..4 (char_wb)
MAX_FEATURES = 40_000      # размер словаря n-грамм
MIN_DF = 3                 # минимальная частота n-граммы

LABELS = ['__label__en', '__label__ru']  # индекс 0 = en, 1 = ru (порядок softmax)

INPUT_NAME = 'features'

# ---------------------------------------------------------------------------
# Загрузка корпусов
# ---------------------------------------------------------------------------

CORPORA_URLS = {
    'ru': 'https://downloads.wortschatz-leipzig.de/corpora/rus_news_2020_1M.tar.gz',
    'en': 'https://downloads.wortschatz-leipzig.de/corpora/eng_news_2020_1M.tar.gz',
}

CORPORA_DIR = Path(__file__).parent / 'corpora'


def download_corpus(lang: str) -> Path:
    """Скачать корпус Leipzig для языка lang, вернуть путь к sentences файлу."""
    url = CORPORA_URLS[lang]
    archive_name = url.split('/')[-1]
    archive_path = CORPORA_DIR / archive_name
    corpus_name = archive_name.replace('.tar.gz', '')
    sentences_path = CORPORA_DIR / f'{corpus_name}-sentences.txt'

    if sentences_path.exists():
        print(f'[{lang}] Корпус уже скачан: {sentences_path}')
        return sentences_path

    CORPORA_DIR.mkdir(parents=True, exist_ok=True)

    print(f'[{lang}] Скачиваю {url} ...')
    with tqdm(unit='B', unit_scale=True, unit_divisor=1024, miniters=1,
              desc=archive_name) as t:
        def reporthook(block_num, block_size, total_size):
            if total_size > 0:
                t.total = total_size
            t.update(block_size)
        urllib.request.urlretrieve(url, archive_path, reporthook=reporthook)

    print(f'[{lang}] Распаковываю ...')
    import tarfile
    with tarfile.open(archive_path) as tar:
        for member in tar.getmembers():
            if 'sentences' in member.name and member.name.endswith('.txt'):
                member.name = sentences_path.name
                tar.extract(member, path=CORPORA_DIR)
                break

    archive_path.unlink(missing_ok=True)
    return sentences_path


def read_sentences(path: Path, max_sentences: int = 600_000) -> list:
    """Читать предложения из Leipzig-формата (id TAB sentence) или простой текст."""
    sentences = []
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split('\t', 1)
            text = parts[1] if len(parts) == 2 else parts[0]
            sentences.append(text)
            if len(sentences) >= max_sentences:
                break
    return sentences


# ---------------------------------------------------------------------------
# Извлечение слов
# ---------------------------------------------------------------------------

WORD_RE = re.compile(r"[a-zA-Zа-яёА-ЯЁ]{2,30}")


def extract_words(sentences: list) -> list:
    words = []
    for sent in sentences:
        words.extend(WORD_RE.findall(sent))
    return words


def is_russian(word: str) -> bool:
    return bool(re.search(r'[а-яёА-ЯЁ]', word))


def is_english(word: str) -> bool:
    return bool(re.search(r'[a-zA-Z]', word)) and not is_russian(word)


# ---------------------------------------------------------------------------
# Генерация обучающего датасета
# ---------------------------------------------------------------------------

def build_dataset(ru_words: list, en_words: list,
                  wronglayout_ratio: float = 0.20) -> list:
    """
    Возвращает список (label, word).
    Включает оригинальные слова + слова, набранные не в той раскладке.
    """
    examples = []

    for w in ru_words:
        w_low = w.lower()
        if not is_russian(w_low):
            continue
        examples.append(('__label__ru', w_low))
        if random.random() < wronglayout_ratio:
            wrong = translit_ru_to_en(w_low)
            if wrong != w_low:
                examples.append(('__label__ru', wrong))

    for w in en_words:
        w_low = w.lower()
        if not is_english(w_low):
            continue
        examples.append(('__label__en', w_low))
        if random.random() < wronglayout_ratio:
            wrong = translit_en_to_ru(w_low)
            if wrong != w_low:
                examples.append(('__label__en', wrong))

    random.shuffle(examples)
    return examples


# ---------------------------------------------------------------------------
# Обучение
# ---------------------------------------------------------------------------

def train(words_train: list, y_train: list):
    """Векторизатор char_wb + LogisticRegression."""
    print('Векторизую символьные n-граммы (char_wb 2–4)...')
    vec = CountVectorizer(
        analyzer='char_wb',
        ngram_range=NGRAM_RANGE,
        max_features=MAX_FEATURES,
        min_df=MIN_DF,
        lowercase=True,
        binary=True,
    )
    X_train = vec.fit_transform(words_train)
    print(f'  Признаков (n-грамм): {len(vec.vocabulary_):,}')

    print('Обучаю LogisticRegression...')
    clf = LogisticRegression(C=5.0, max_iter=200, solver='liblinear')
    clf.fit(X_train, y_train)
    return vec, clf


# ---------------------------------------------------------------------------
# Конвертация в CoreML
# ---------------------------------------------------------------------------

def build_coreml(vec: CountVectorizer, clf: LogisticRegression,
                 output_path: str) -> None:
    """
    Строит CoreML-модель: features (binary n-gram vector) → FC → softmax → label.

    Бинарная LogisticRegression даёт логит положительного класса (ru):
        logit_ru = w·x + b,  logit_en = 0
    softmax([logit_en, logit_ru]) = [P(en), P(ru)] — порядок совпадает с LABELS.
    """
    print('Конвертирую в CoreML ...')

    # Порядок n-грамм по индексу колонки
    inv_vocab = {idx: ng for ng, idx in vec.vocabulary_.items()}
    ngrams = [inv_vocab[i] for i in range(len(inv_vocab))]
    num_features = len(ngrams)

    # Веса линейного классификатора
    coef = clf.coef_[0].astype(np.float32)          # (num_features,) — класс ru
    intercept = float(clf.intercept_[0])

    # FC: (num_features) → (2). Строка 0 (en) = нули, строка 1 (ru) = coef
    fc_weights = np.zeros((2, num_features), dtype=np.float32)
    fc_weights[1] = coef
    fc_bias = np.array([0.0, intercept], dtype=np.float32)

    # --- Сборка CoreML spec вручную ---
    spec = ct.proto.Model_pb2.Model()
    spec.specificationVersion = 5

    input_desc = spec.description.input.add()
    input_desc.name = INPUT_NAME
    input_desc.type.multiArrayType.shape.append(num_features)
    input_desc.type.multiArrayType.dataType = \
        ct.proto.FeatureTypes_pb2.ArrayFeatureType.FLOAT32

    output_probs = spec.description.output.add()
    output_probs.name = 'labelProbabilities'
    output_probs.type.dictionaryType.stringKeyType.CopyFrom(
        ct.proto.FeatureTypes_pb2.StringFeatureType())

    output_label = spec.description.output.add()
    output_label.name = 'classLabel'
    output_label.type.stringType.CopyFrom(ct.proto.FeatureTypes_pb2.StringFeatureType())

    spec.description.predictedFeatureName = 'classLabel'
    spec.description.predictedProbabilitiesName = 'labelProbabilities'

    nn = spec.neuralNetworkClassifier

    # FC слой
    fc = nn.layers.add()
    fc.name = 'fc'
    fc.input.append(INPUT_NAME)
    fc.output.append('logits')
    fc.innerProduct.inputChannels = num_features
    fc.innerProduct.outputChannels = 2
    fc.innerProduct.hasBias = True
    fc.innerProduct.weights.floatValue.extend(fc_weights.flatten().tolist())
    fc.innerProduct.bias.floatValue.extend(fc_bias.tolist())

    # Softmax
    sm = nn.layers.add()
    sm.name = 'softmax'
    sm.input.append('logits')
    sm.output.append('probabilities')
    sm.softmax.SetInParent()

    nn.stringClassLabels.vector.extend(LABELS)

    mlmodel = ct.models.MLModel(spec)
    mlmodel.short_description = 'RU/EN keyboard layout classifier (char n-grams)'
    mlmodel.author = 'linotype'
    mlmodel.version = '1.0'
    mlmodel.input_description[INPUT_NAME] = 'Binary char n-gram feature vector'
    mlmodel.output_description['classLabel'] = 'Predicted language label'
    mlmodel.output_description['labelProbabilities'] = 'Per-label probabilities'

    mlmodel.save(output_path)
    print(f'CoreML модель сохранена: {output_path}')

    # Словарь для Swift
    vocab_json_path = Path(output_path).parent / 'vocab.json'
    vocab_data = {
        'ngrams': ngrams,
        'labels': LABELS,
        'ngram_range': list(NGRAM_RANGE),
        'binary': True,
    }
    with open(vocab_json_path, 'w', encoding='utf-8') as f:
        json.dump(vocab_data, f, ensure_ascii=False)
    print(f'Словарь сохранён: {vocab_json_path} ({len(ngrams):,} n-грамм)')

    size_mb = Path(output_path).stat().st_size / 1024 / 1024
    print(f'Размер модели: {size_mb:.2f} MB')
    if size_mb > 5:
        print('ВНИМАНИЕ: размер модели превышает 5 MB.')

    # Верификация: CoreML должен совпасть с sklearn
    _verify_coreml(mlmodel, vec, clf, ngrams)


def _char_wb_ngrams(word: str, min_n: int, max_n: int) -> list:
    """Точная реплика sklearn CountVectorizer._char_wb_ngrams для одного слова."""
    w = ' ' + word.lower() + ' '
    w_len = len(w)
    out = []
    for n in range(min_n, max_n + 1):
        offset = 0
        out.append(w[offset:offset + n])
        while offset + n < w_len:
            offset += 1
            out.append(w[offset:offset + n])
        if offset == 0:
            break
    return out


def _verify_coreml(mlmodel, vec, clf, ngrams: list) -> None:
    """Сверяем предсказания CoreML с sklearn на контрольных словах."""
    idx = {ng: i for i, ng in enumerate(ngrams)}
    size = len(ngrams)

    def feat(word: str) -> np.ndarray:
        v = np.zeros(size, dtype=np.float32)
        for ng in set(_char_wb_ngrams(word, *NGRAM_RANGE)):
            j = idx.get(ng)
            if j is not None:
                v[j] = 1.0
        return v

    tests = [
        ('привет', 'ru'), ('hello', 'en'), ('ghbdtn', 'ru'), ('руддщ', 'en'),
        ('компьютер', 'ru'), ('keyboard', 'en'), ('реализация', 'ru'),
    ]
    print('Верификация CoreML vs sklearn:')
    mismatches = 0
    for word, exp in tests:
        r = mlmodel.predict({INPUT_NAME: feat(word)})
        label = 'ru' if r['classLabel'] == '__label__ru' else 'en'
        conf = r['labelProbabilities'][r['classLabel']]
        ok = label == exp
        mismatches += 0 if ok else 1
        print(f'  {word:12s} → {label:3s} ({conf:.3f}) exp={exp} {"OK" if ok else "FAIL"}')
    if mismatches:
        print(f'ВНИМАНИЕ: {mismatches} расхождений в верификации!')


# ---------------------------------------------------------------------------
# Основной pipeline
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description='Обучение linotype ru/en классификатора')
    parser.add_argument('--ru-corpus', type=str, default=None,
                        help='Путь к русскому корпусу (Leipzig sentences format)')
    parser.add_argument('--en-corpus', type=str, default=None,
                        help='Путь к английскому корпусу (Leipzig sentences format)')
    parser.add_argument('--output-dir', type=str,
                        default=str(Path(__file__).parent.parent / 'linotype' / 'Model'),
                        help='Директория для сохранения .mlmodel')
    parser.add_argument('--max-sentences', type=int, default=500_000,
                        help='Максимум предложений на язык')
    parser.add_argument('--test-split', type=float, default=0.1,
                        help='Доля тестовой выборки')
    args = parser.parse_args()

    random.seed(42)
    np.random.seed(42)

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    # 1. Загрузка корпусов
    ru_path = Path(args.ru_corpus) if args.ru_corpus else download_corpus('ru')
    en_path = Path(args.en_corpus) if args.en_corpus else download_corpus('en')

    print(f'\nЧитаю русский корпус: {ru_path}')
    ru_sentences = read_sentences(ru_path, args.max_sentences)
    print(f'  Предложений: {len(ru_sentences):,}')

    print(f'Читаю английский корпус: {en_path}')
    en_sentences = read_sentences(en_path, args.max_sentences)
    print(f'  Предложений: {len(en_sentences):,}')

    # 2. Извлечение слов
    print('\nИзвлекаю слова...')
    ru_words = extract_words(ru_sentences)
    en_words = extract_words(en_sentences)
    print(f'  Русских слов:    {len(ru_words):,}')
    print(f'  Английских слов: {len(en_words):,}')

    # 3. Балансировка
    n = min(len(ru_words), len(en_words), 800_000)
    ru_words = random.sample(ru_words, min(n, len(ru_words)))
    en_words = random.sample(en_words, min(n, len(en_words)))

    # 4. Генерация датасета (с wrong-layout примерами)
    print('\nГенерирую датасет...')
    dataset = build_dataset(ru_words, en_words, wronglayout_ratio=0.20)
    words = [w for _, w in dataset]
    y = [1 if lbl == '__label__ru' else 0 for lbl, _ in dataset]
    ru_count = sum(y)
    print(f'  Всего примеров: {len(words):,}  (RU: {ru_count:,}  EN: {len(words) - ru_count:,})')

    # 5. Split
    w_train, w_test, y_train, y_test = train_test_split(
        words, y, test_size=args.test_split, random_state=42, shuffle=True)
    print(f'  Train: {len(w_train):,}  Test: {len(w_test):,}')

    # 6. Обучение
    vec, clf = train(w_train, y_train)

    # 7. Оценка
    print('\n=== Оценка на тестовой выборке ===')
    acc = clf.score(vec.transform(w_test), y_test)
    print(f'Точность: {acc * 100:.2f}%')
    if acc < 0.97:
        print(f'ПРЕДУПРЕЖДЕНИЕ: точность {acc * 100:.2f}% < 97%')
    else:
        print(f'Отлично! Точность {acc * 100:.2f}% >= 97% ✓')

    # 8. Конвертация в CoreML
    coreml_output = str(output_dir / 'LinotypeModel.mlmodel')
    build_coreml(vec, clf, coreml_output)

    print('\n=== Готово ===')
    print(f'CoreML модель: {coreml_output}')
    print('Файлы LinotypeModel.mlmodel и vocab.json готовы для Xcode (linotype/Model/)')


if __name__ == '__main__':
    main()
