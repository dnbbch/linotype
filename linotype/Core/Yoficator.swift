import Foundation

/// Restores the letter ё in words that are unambiguously spelled with it
/// (eyo-kernel safe dictionary). The map (e-form → ё-form) is loaded lazily on
/// first use, so when ёфикация is disabled (the default) nothing is read into
/// memory and startup stays fast.
final class Yoficator {

    private lazy var map: [String: String] = Self.loadMap()

    private static func loadMap() -> [String: String] {
        guard let url = Bundle.main.url(forResource: "yo_dict", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let words = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return [:]
        }
        var m = [String: String](minimumCapacity: words.count)
        for yo in words {
            m[yo.replacingOccurrences(of: "ё", with: "е")] = yo
        }
        return m
    }

    /// Returns the ё-form (preserving the original case) when the word is
    /// unambiguous, otherwise nil.
    func yoify(_ word: String) -> String? {
        let lower = word.lowercased()
        // Cheap guard before touching the dictionary: no "е" → never loads it.
        guard lower.contains("е") else { return nil }
        guard let yo = map[lower], yo != lower else { return nil }

        var result = Array(word)
        let yoChars = Array(yo)
        guard result.count == yoChars.count else { return nil }
        for i in result.indices where yoChars[i] == "ё" {
            switch result[i] {
            case "е": result[i] = "ё"
            case "Е": result[i] = "Ё"
            default: break
            }
        }
        return String(result)
    }
}
