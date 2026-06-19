import Foundation

/// Tracks the word currently being typed.
final class TextBuffer {

    private(set) var currentWord = ""

    /// Shortest word worth classifying.
    static let minWordLength = 2

    func append(char: Character) {
        currentWord.append(char)
    }

    /// Ends the current word, resets the buffer and returns the word.
    @discardableResult
    func wordCompleted() -> String {
        let word = currentWord
        currentWord = ""
        return word
    }

    /// Replaces the current word so the buffer matches text already corrected
    /// on screen (used after an in-place early switch).
    func replaceCurrentWord(_ word: String) {
        currentWord = word
    }

    func backspace() {
        if !currentWord.isEmpty { currentWord.removeLast() }
    }

    func clear() {
        currentWord = ""
    }
}
