import Foundation
import CoreML

enum Language: String, CaseIterable {
    case ru = "__label__ru"
    case en = "__label__en"

    var opposite: Language { self == .ru ? .en : .ru }

    /// Label shown in the HUD.
    var hudLabel: String { self == .ru ? "РУ" : "EN" }
}

// QWERTY ↔ ЙЦУКЕН physical-key mapping.
private let ruToEn: [Character: Character] = [
    "й":"q","ц":"w","у":"e","к":"r","е":"t","н":"y","г":"u","ш":"i","щ":"o","з":"p",
    "х":"[","ъ":"]","ф":"a","ы":"s","в":"d","а":"f","п":"g","р":"h","о":"j","л":"k",
    "д":"l","ж":";","э":"'","я":"z","ч":"x","с":"c","м":"v","и":"b","т":"n","ь":"m",
    "б":",","ю":".","ё":"`",
    "Й":"Q","Ц":"W","У":"E","К":"R","Е":"T","Н":"Y","Г":"U","Ш":"I","Щ":"O","З":"P",
    "Х":"{","Ъ":"}","Ф":"A","Ы":"S","В":"D","А":"F","П":"G","Р":"H","О":"J","Л":"K",
    "Д":"L","Ж":":","Э":"\"","Я":"Z","Ч":"X","С":"C","М":"V","И":"B","Т":"N","Ь":"M",
    "Б":"<","Ю":">","Ё":"~",
]

private let enToRu: [Character: Character] = {
    var dict = [Character: Character]()
    for (ru, en) in ruToEn { dict[en] = ru }
    return dict
}()

/// CoreML wrapper that classifies a word as ru/en from character n-grams.
final class Classifier {

    private let model: LinotypeModel
    private let ngramIndex: [String: Int]
    private let featureCount: Int
    private let minN: Int
    private let maxN: Int

    init() throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        self.model = try LinotypeModel(configuration: config)

        guard let vocabURL = Bundle.main.url(forResource: "vocab", withExtension: "json"),
              let data = try? Data(contentsOf: vocabURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ngrams = json["ngrams"] as? [String] else {
            throw ClassifierError.vocabularyNotFound
        }

        var index = [String: Int](minimumCapacity: ngrams.count)
        for (i, ng) in ngrams.enumerated() { index[ng] = i }
        self.ngramIndex = index
        self.featureCount = ngrams.count

        let range = (json["ngram_range"] as? [Int]) ?? [2, 4]
        self.minN = range.first ?? 2
        self.maxN = range.count > 1 ? range[1] : 4
    }

    /// Classifies a word, returning its language and confidence in 0...1.
    func classify(word: String) throws -> (Language, Double) {
        let features = try buildFeatures(word: word)
        let output = try model.prediction(input: LinotypeModelInput(features: features))
        let label = output.classLabel
        let lang: Language = label == Language.ru.rawValue ? .ru : .en
        let confidence = output.labelProbabilities[label] ?? 0.5
        return (lang, confidence)
    }

    /// Re-types a word through the opposite layout's key mapping.
    func correct(word: String, targetLayout: Language) -> String {
        let table: [Character: Character] = targetLayout == .en ? ruToEn : enToRu
        return String(word.map { table[$0] ?? $0 })
    }

    /// Converts selected text to the opposite layout, picking the direction from
    /// the dominant script (Cyrillic → en, Latin → ru).
    func flip(_ text: String) -> String {
        var cyr = 0, lat = 0
        for u in text.unicodeScalars {
            if (0x0410...0x044F).contains(u.value) || u.value == 0x0401 || u.value == 0x0451 {
                cyr += 1
            } else if (0x41...0x5A).contains(u.value) || (0x61...0x7A).contains(u.value) {
                lat += 1
            }
        }
        guard cyr + lat > 0 else { return text }
        return correct(word: text, targetLayout: cyr >= lat ? .en : .ru)
    }

    /// Mirrors sklearn CountVectorizer's char_wb n-grams: pad the word with
    /// spaces, then slide windows of length minN...maxN. Must stay byte-identical
    /// to the training-time vectorizer.
    private func charWbNgrams(_ word: String) -> [String] {
        let padded = Array(" " + word.lowercased() + " ")
        let wLen = padded.count
        var result: [String] = []

        for n in minN...maxN {
            var offset = 0
            result.append(String(padded[0..<min(n, wLen)]))
            while offset + n < wLen {
                offset += 1
                result.append(String(padded[offset..<offset + n]))
            }
            if offset == 0 { break }  // word shorter than n: skip larger n, as sklearn does
        }
        return result
    }

    private func buildFeatures(word: String) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [NSNumber(value: featureCount)], dataType: .float32)
        let ptr = UnsafeMutablePointer<Float32>(OpaquePointer(array.dataPointer))
        for i in 0..<featureCount { ptr[i] = 0 }
        for ngram in Set(charWbNgrams(word)) where ngramIndex[ngram] != nil {
            ptr[ngramIndex[ngram]!] = 1.0
        }
        return array
    }
}

enum ClassifierError: LocalizedError {
    case vocabularyNotFound

    var errorDescription: String? {
        "vocab.json не найден в бандле приложения. Запустите train_model.py."
    }
}
