import Cocoa
import Carbon

/// Switches the system keyboard layout and replaces text via synthetic CGEvents.
final class LayoutSwitcher {

    /// Always resolved fresh from the system so it never goes stale after the
    /// user switches layout manually.
    var currentLayout: Language { detectCurrentLayout() }

    /// Where synthetic events are injected. Posting at the session level (not the
    /// lowest HID level) means keyboard-sound apps that listen below — Klack does,
    /// for low latency — don't hear our backspaces/inserts and stay silent on a
    /// replacement. The target app still receives the text.
    private let injectTap: CGEventTapLocation = .cgSessionEventTap

    func detectCurrentLayout() -> Language {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return .en
        }
        let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        return id.lowercased().contains("russian") ? .ru : .en
    }

    func switchTo(_ language: Language) {
        guard language != detectCurrentLayout() else { return }

        let targetID: CFString = language == .ru
            ? "com.apple.keylayout.Russian" as CFString
            : "com.apple.keylayout.ABC" as CFString

        let inputSources = TISCreateInputSourceList(nil, false)
            .takeRetainedValue() as! [TISInputSource]

        for source in inputSources {
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as CFString
            if id == targetID {
                TISSelectInputSource(source)
                return
            }
        }

        // Fallback: any source whose primary language matches.
        for source in inputSources {
            guard let langPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { continue }
            let langs = Unmanaged<CFArray>.fromOpaque(langPtr).takeUnretainedValue() as! [String]
            if langs.first == (language == .ru ? "ru" : "en") {
                TISSelectInputSource(source)
                return
            }
        }
    }

    /// Replaces the last word. Deletes exactly `original.count` chars (+1 for the
    /// separator the user already typed after the word, if any), switches layout,
    /// then inserts the corrected word. Precise backspaces — rather than ⌥⌫ —
    /// avoid app-specific word-boundary behaviour. Called synchronously from the
    /// on-main tap callback: posted events queue and apply in order after it
    /// returns, so no sleeps and no races.
    func replaceLastWord(original: String, corrected: String,
                         separator: Character?, targetLayout: Language) {
        let deleteCount = original.count + (separator == nil ? 0 : 1)
        for _ in 0..<deleteCount { postKey(keyCode: 0x33) }
        switchTo(targetLayout)
        var text = corrected
        if let separator { text.append(separator) }
        postUnicodeString(text)
    }

    /// Synchronous in-place replacement for early (mid-word) switching.
    func replaceWordImmediately(deleteCount: Int, corrected: String, targetLayout: Language) {
        for _ in 0..<deleteCount { postKey(keyCode: 0x33) }
        switchTo(targetLayout)
        postUnicodeString(corrected)
    }

    /// Sends ⌘+key for synthetic Copy/Paste.
    func sendCommand(keyCode: CGKeyCode) {
        postKey(keyCode: keyCode, flags: .maskCommand)
    }

    /// Deletes the last `deleteCount` chars and inserts `text` (smart dashes).
    func substitute(deleteCount: Int, with text: String) {
        for _ in 0..<deleteCount { postKey(keyCode: 0x33) }
        postUnicodeString(text)
    }

    private func postKey(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .combinedSessionState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.setIntegerValueField(.eventSourceUserData, value: linotypeInjectedEventMagic)
            down.post(tap: injectTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.setIntegerValueField(.eventSourceUserData, value: linotypeInjectedEventMagic)
            up.post(tap: injectTap)
        }
    }

    /// Inserts a whole string in one Unicode event — independent of the active
    /// layout and a single "click" for sound apps instead of one per character.
    private func postUnicodeString(_ string: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        var chars = Array(string.utf16)
        guard !chars.isEmpty,
              let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return }
        down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        down.setIntegerValueField(.eventSourceUserData, value: linotypeInjectedEventMagic)
        up.setIntegerValueField(.eventSourceUserData, value: linotypeInjectedEventMagic)
        down.post(tap: injectTap)
        up.post(tap: injectTap)
    }
}
