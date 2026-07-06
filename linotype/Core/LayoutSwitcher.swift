import Cocoa
import Carbon

/// Switches the system keyboard layout and replaces text via synthetic CGEvents.
final class LayoutSwitcher {

    /// Cached — TIS IPC on every word adds up. Refreshed on the system
    /// input-source-changed notification, so it never goes stale after a manual
    /// layout switch (the notification also fires for our own switchTo, which
    /// merely re-syncs the cache).
    var currentLayout: Language { detectCurrentLayout() }

    private var cachedLayout: Language?

    // The user's actual source per language, learned as they type — so switchTo
    // restores Colemak/British/RussianWin instead of a hardcoded stock layout.
    private var knownSources: [Language: TISInputSource] = [:]

    private var sourceChangeObserver: NSObjectProtocol?

    /// Where synthetic events are injected. Session level sits above the HID level
    /// where keyboard-sound apps (Klack) listen — so they stay silent — yet is low
    /// enough that picky fields (Finder search, Spotlight) still accept the input,
    /// unlike the annotated-session level. Word growth from out-of-order events is
    /// prevented separately by the buffer sync + manual-switch debounce.
    private let injectTap: CGEventTapLocation = .cgSessionEventTap

    // Gap inserted between synthetic keystrokes for slow fields. A single tunable
    // knob: bump it if a user's test still shows dropped backspaces.
    private let slowInjectionKeyDelay: useconds_t = 5000  // 5 ms

    init() {
        sourceChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.cachedLayout = nil
            // Fires for user switches and our own alike — both matter when
            // reconstructing "what layout was active" from the log.
            if let lang = self?.detectCurrentLayout() {
                DiagnosticLog.log("LAYOUT now=\(lang.short)")
            }
        }
    }

    deinit {
        if let observer = sourceChangeObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    func detectCurrentLayout() -> Language {
        if let cached = cachedLayout { return cached }
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return .en
        }
        let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        let lang: Language = id.lowercased().contains("russian") ? .ru : .en
        cachedLayout = lang
        knownSources[lang] = source
        return lang
    }

    func switchTo(_ language: Language) {
        guard language != detectCurrentLayout() else { return }

        // Prefer the source the user actually types in over the stock IDs below —
        // selecting hardcoded ABC would silently replace a Colemak/British layout.
        // Fall through if the remembered source stopped selecting (e.g. it was
        // removed from the input menu).
        if let known = knownSources[language], TISSelectInputSource(known) == noErr {
            cachedLayout = language
            return
        }

        let targetID: CFString = language == .ru
            ? "com.apple.keylayout.Russian" as CFString
            : "com.apple.keylayout.ABC" as CFString

        // A malformed TIS response must not crash an event-tap app: no force-casts.
        guard let inputSources = TISCreateInputSourceList(nil, false)?
            .takeRetainedValue() as? [TISInputSource] else { return }

        for source in inputSources {
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as CFString
            if id == targetID {
                select(source, for: language)
                return
            }
        }

        // Fallback: any source whose primary language matches.
        for source in inputSources {
            guard let langPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
                  let langs = Unmanaged<CFArray>.fromOpaque(langPtr).takeUnretainedValue() as? [String] else { continue }
            if langs.first == (language == .ru ? "ru" : "en") {
                select(source, for: language)
                return
            }
        }
    }

    private func select(_ source: TISInputSource, for language: Language) {
        guard TISSelectInputSource(source) == noErr else { return }
        knownSources[language] = source
        cachedLayout = language
    }

    /// Replaces the last word. Deletes exactly `original.count` chars (+1 for the
    /// separator the user already typed after the word, if any), switches layout,
    /// then inserts the corrected word. Precise backspaces — rather than ⌥⌫ —
    /// avoid app-specific word-boundary behaviour. Called synchronously from the
    /// on-main tap callback: posted events queue and apply in order after it
    /// returns, so no sleeps and no races.
    ///
    /// `slowInjection` spaces the backspace burst out with a few ms per key.
    /// Spotlight-class overlay/search fields coalesce or drop a zero-gap burst
    /// (leaving the first original char behind, e.g. "pзаметки"); a small gap lets
    /// the field's run loop keep up. The sleeps stay synchronous — this runs on
    /// the tap callback, so they add latency but reintroduce no async races.
    func replaceLastWord(original: String, corrected: String,
                         separator: Character?, targetLayout: Language, slowInjection: Bool = false) {
        let deleteCount = original.count + (separator == nil ? 0 : 1)
        var text = corrected
        if let separator { text.append(separator) }
        // Every injection explicit in the log, before any event is posted.
        DiagnosticLog.log("REPLACE del=\(deleteCount) insert=\"\(text)\" target=\(targetLayout.short)")
        if slowInjection { DiagnosticLog.log("REPLACE slow (\(deleteCount) del)") }
        for _ in 0..<deleteCount {
            postKey(keyCode: 0x33, tap: injectTap)
            if slowInjection { usleep(slowInjectionKeyDelay) }
        }
        switchTo(targetLayout)
        if slowInjection { usleep(slowInjectionKeyDelay) }
        postUnicodeString(text, tap: injectTap)
    }

    /// Sends ⌘+key for synthetic Copy/Paste.
    func sendCommand(keyCode: CGKeyCode) {
        postKey(keyCode: keyCode, flags: .maskCommand, tap: injectTap)
    }

    /// Deletes the last `deleteCount` chars and inserts `text` (smart dashes).
    func substitute(deleteCount: Int, with text: String) {
        for _ in 0..<deleteCount { postKey(keyCode: 0x33, tap: injectTap) }
        postUnicodeString(text, tap: injectTap)
    }

    // A fresh event source per call, exactly as field-tested for a week — sharing
    // one across a replacement coincided with corrupted on-screen output, and the
    // allocation is too cheap to risk it.
    private func postKey(keyCode: CGKeyCode, flags: CGEventFlags = [], tap: CGEventTapLocation) {
        let src = CGEventSource(stateID: .combinedSessionState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.setIntegerValueField(.eventSourceUserData, value: linotypeInjectedEventMagic)
            down.post(tap: tap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.setIntegerValueField(.eventSourceUserData, value: linotypeInjectedEventMagic)
            up.post(tap: tap)
        }
    }

    /// Inserts a whole string in one Unicode event — independent of the active
    /// layout and a single "click" for sound apps instead of one per character.
    private func postUnicodeString(_ string: String, tap: CGEventTapLocation) {
        let src = CGEventSource(stateID: .combinedSessionState)
        var chars = Array(string.utf16)
        guard !chars.isEmpty,
              let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return }
        down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        down.setIntegerValueField(.eventSourceUserData, value: linotypeInjectedEventMagic)
        up.setIntegerValueField(.eventSourceUserData, value: linotypeInjectedEventMagic)
        down.post(tap: tap)
        up.post(tap: tap)
    }
}
