# Корпуса для обучения модели

Скрипт `train_model.py` умеет скачивать данные автоматически через Leipzig Corpora Collection.
Если хотите использовать собственные корпуса — передайте пути через аргументы:

```bash
python train_model.py \
  --ru-corpus /path/to/russian_sentences.txt \
  --en-corpus /path/to/english_sentences.txt
```

## Автоматически скачиваемые корпуса

- **Русский**: Leipzig Corpora `rus_news_2020_1M` (~500k предложений)
- **Английский**: Leipzig Corpora `eng_news_2020_1M` (~500k предложений)

Данные сохраняются в эту папку (`scripts/corpora/`).

## Ожидаемый формат файлов (при использовании своих)

Один текст/предложение на строку, кодировка UTF-8:
```
Привет, это пример текста.
Hello, this is an example text.
```
