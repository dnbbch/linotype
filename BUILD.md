# Сборка linotype

## Требования

- macOS 13.0+, Apple Silicon (M1–M4) или Intel
- Xcode 15+
- Python 3.10+ (для обучения модели)
- ~3 GB свободного места (корпуса + обучение)

---

## Шаг 1 — Обучение модели

```bash
cd scripts

# Создать виртуальное окружение
python3 -m venv .venv
source .venv/bin/activate

# Установить зависимости
pip install -r requirements.txt

# Запустить обучение (скачает корпуса автоматически, ~10-20 минут)
python train_model.py

# Или с уже скачанными корпусами:
# python train_model.py \
#   --ru-corpus /path/to/rus_news-sentences.txt \
#   --en-corpus /path/to/eng_news-sentences.txt
```

После успешного обучения скрипт создаст два файла:
- `linotype/Model/LinotypeModel.mlmodel` — CoreML модель
- `linotype/Model/vocab.json` — словарь для Swift-кода

Ожидаемая точность: ≥97% на тестовой выборке.

### Проверка качества модели

```bash
python test_model.py
```

---

## Шаг 2 — Добавление файлов модели в Xcode

После обучения файлы уже лежат в `linotype/Model/` — они уже прописаны в `project.pbxproj`.

Если открываете проект в Xcode впервые, убедитесь что:
1. `LinotypeModel.mlmodel` виден в навигаторе проекта
2. `vocab.json` добавлен в target → Copy Bundle Resources

---

## Шаг 3 — Сборка в Xcode

```bash
open linotype.xcodeproj
```

1. Выберите схему `linotype` и целевое устройство "My Mac"
2. Нажмите **⌘B** (Build) или **⌘R** (Run)
3. При первом запуске macOS попросит разрешение Accessibility — разрешите

### Сборка через командную строку (проверенный способ)

```bash
# 1. Сборка (без подписи — чтобы поймать ошибки компиляции)
xcodebuild -project linotype.xcodeproj -scheme linotype -configuration Release \
  -derivedDataPath build/DD \
  CODE_SIGNING_ALLOWED=NO build

# Готовый бандл: build/DD/Build/Products/Release/linotype.app

# 2. Подпись своим сертификатом разработчика + hardened runtime.
#    Стабильная подпись (тот же Identifier) => выданное разрешение
#    Accessibility сохраняется между пересборками.
codesign --force --options runtime \
  --entitlements linotype/App/linotype.entitlements \
  --sign "Apple Development: ВАШ_EMAIL (TEAMID)" \
  --timestamp=none \
  build/DD/Build/Products/Release/linotype.app

# Список доступных идентичностей:  security find-identity -v -p codesigning
# Проверка подписи:                codesign --verify --strict build/DD/Build/Products/Release/linotype.app
```

---

## Шаг 4 — Установка

Скопируйте `linotype.app` в `/Applications`:

```bash
xattr -dr com.apple.quarantine build/DD/Build/Products/Release/linotype.app
cp -R build/DD/Build/Products/Release/linotype.app /Applications/
open /Applications/linotype.app
```

### Разрешение Accessibility

1. **Системные настройки** → **Конфиденциальность и безопасность** → **Универсальный доступ**
2. Нажмите `+` и добавьте `linotype.app`
3. Включите тумблер

---

## Устранение неполадок

### CGEventTap не создаётся

Проверьте разрешение Accessibility (шаг выше). Для тестирования без подписи:

```bash
# Сбросить карантин
xattr -dr com.apple.quarantine /Applications/linotype.app
```

### Модель не найдена

Убедитесь что `LinotypeModel.mlmodel` и `vocab.json` добавлены в Target Membership в Xcode:
- Выберите файл в навигаторе
- В инспекторе справа → Target Membership → ✓ linotype

### Раскладка не переключается

Проверьте что в Системных настройках → Клавиатура → Источники ввода добавлены:
- Russian — PC (или Russian)
- ABC (или U.S.)

---

## Архитектура

### Рантайм (Swift)

```
EventTap → TextBuffer → Classifier (CoreML) → LayoutSwitcher
                                    ↓
                          confidence > 0.85? → replaceLastWord()
                                    ↓
                           Double Shift → manual correct
```

### ML-модель

Классификатор языка построен на **символьных n-граммах (char_wb, длина 2–4)
+ LogisticRegression**, экспортированных в CoreML как `innerProduct + softmax`.

Почему не FastText (как в исходном ТЗ): subword-хеширование FastText (по ~2M
бакетов) невозможно компактно и точно воспроизвести в CoreML, а именно оно
отвечает за классификацию OOV-слов и слов в неправильной раскладке (`ghbdtn`).
Линейная модель на явных char-n-граммах воспроизводится в CoreML **точно**
(нет хеширования — Swift и Python используют один и тот же словарь n-грамм
из `vocab.json`), даёт более высокую точность и крошечный размер.

Реплика `sklearn CountVectorizer(analyzer='char_wb')` в Swift —
`Classifier.charWbNgrams(_:)`; она побайтово совпадает с обучением.

Достигнутые метрики:

| Метрика | Цель | Факт |
|---------|------|------|
| Точность (тест 190k слов) | ≥97% | **99.89%** |
| Размер `LinotypeModel.mlmodel` | <5 МБ | **0.31 МБ** |
| Inference (CoreML, M-серия) | <2 мс | **~0.04 мс** |
| Размер `linotype.app` | <10 МБ | **1.1 МБ** |

## Структура файлов

```
linotype/
├── linotype.xcodeproj/
│   └── project.pbxproj
├── linotype/
│   ├── App/
│   │   ├── LinotypeApp.swift     # @main, AppDelegate, menu bar
│   │   ├── Info.plist            # LSUIElement=true, NSAccessibilityUsageDescription
│   │   └── linotype.entitlements
│   ├── Core/
│   │   ├── EventTap.swift        # CGEventTap — перехват keyDown
│   │   ├── TextBuffer.swift      # Буфер текущего слова
│   │   ├── Classifier.swift      # CoreML inference + перекодировка
│   │   └── LayoutSwitcher.swift  # TISInputSource + CGEvent замена текста
│   ├── Model/
│   │   ├── LinotypeModel.mlmodel # (генерируется train_model.py)
│   │   └── vocab.json            # (генерируется train_model.py)
│   └── Resources/
│       └── Assets.xcassets
└── scripts/
    ├── requirements.txt
    ├── train_model.py            # char n-gram + LogisticRegression → CoreML
    ├── test_model.py             # Тест точности CoreML-модели
    └── corpora/                  # Корпуса (скачиваются автоматически)
```
