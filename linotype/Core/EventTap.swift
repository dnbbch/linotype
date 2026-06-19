import Cocoa
import Carbon

protocol EventTapDelegate: AnyObject {
    /// A word was finished by typing `separator` (already in the document).
    func eventTap(_ tap: EventTap, didCompleteWord word: String, separator: Character)
    /// Manual switch trigger. `separator == nil` means the word is unfinished;
    /// otherwise it was just completed by that separator.
    func eventTap(_ tap: EventTap, didReceiveDoubleShift word: String, separator: Character?)
    /// Convert-selection hotkey (⌘⌥L).
    func eventTapDidRequestConvertSelection(_ tap: EventTap)
    /// Smart-quotes hotkey (⌘⌥').
    func eventTapDidRequestSmartQuotes(_ tap: EventTap)
    /// Mid-typing checkpoint for early switching. Returns the corrected word if
    /// a switch happened, otherwise nil.
    func eventTap(_ tap: EventTap, earlyCheckpoint word: String) -> String?
    /// Smart substitution: delete `deleteCount` chars and insert `text`.
    func eventTap(_ tap: EventTap, substituteDeletingLast deleteCount: Int, with text: String)
}

/// Intercepts keystrokes via a CGEventTap on the main run loop.
final class EventTap {

    weak var delegate: EventTapDelegate?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let textBuffer = TextBuffer()
    private var lastModTapTime: TimeInterval = 0
    private let doubleTapInterval: TimeInterval = 0.4

    // Single-Option trigger: track a "clean" tap with no other keys.
    private var optionDownTime: TimeInterval = 0
    private var optionSolo = false

    // Last completed word and its separator, for a manual switch after the space.
    // justCompletedWord stays true only while the cursor sits right after it.
    private var lastCompletedWord: String = ""
    private var lastSeparator: Character?
    private var justCompletedWord = false

    // Don't re-touch a word that was already early-switched.
    private var earlySwitchedCurrentWord = false

    // Race guard: bumped on every text-affecting keystroke so a queued async
    // replacement can detect that the cursor has since moved.
    private(set) var inputGeneration = 0

    // Last typed chars, for smart dashes.
    private var recentChars: [Character] = []

    private var excludedBundleIDs: Set<String> { SettingsStore.shared.excludedBundleIDs }

    private static let wordBoundaries: Set<Character> = [
        " ", ".", ",", "!", "?", ":", ";", "\n", "\r", "\t",
        "(", ")", "[", "]", "{", "}", "\"", "'", "/", "\\",
        "-", "=", "+", "*", "&", "^", "%", "$", "#", "@",
    ]

    var isRunning: Bool { tap != nil }

    /// Creates the tap. Throws if Accessibility permission is missing
    /// (tapCreate returns nil). A no-op if the tap is already active.
    func start() throws {
        guard tap == nil else { return }

        // keyDown for characters; flagsChanged for Shift (modifiers send no keyDown).
        let eventMask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        )

        guard let port = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw EventTapError.tapCreationFailed
        }

        self.tap = port
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    fileprivate func requestConvertSelection() {
        delegate?.eventTapDidRequestConvertSelection(self)
    }

    fileprivate func requestSmartQuotes() {
        delegate?.eventTapDidRequestSmartQuotes(self)
    }

    /// Re-enable the tap after the system disabled it
    /// (.tapDisabledByTimeout / .tapDisabledByUserInput).
    fileprivate func reEnable() {
        if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        if let port = tap { CGEvent.tapEnable(tap: port, enable: false) }
        tap = nil
        runLoopSource = nil
    }

    fileprivate func handle(event: CGEvent) {
        // Ignore our own injected events, or the tap would catch the correction
        // keystrokes as user input and cascade.
        if event.getIntegerValueField(.eventSourceUserData) == linotypeInjectedEventMagic {
            return
        }

        // Secure input (password fields): don't intercept, clear the buffer.
        if IsSecureEventInputEnabled() {
            textBuffer.clear()
            justCompletedWord = false
            return
        }

        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           excludedBundleIDs.contains(bundleID) {
            return
        }

        // Any ordinary key breaks a double-tap and an Option "solo".
        lastModTapTime = 0
        optionSolo = false

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        // Cmd/Ctrl combos are shortcuts, not text.
        if event.flags.contains(.maskCommand) || event.flags.contains(.maskControl) {
            return
        }

        if keyCode == 0x33 {  // Backspace
            textBuffer.backspace()
            justCompletedWord = false
            earlySwitchedCurrentWord = false
            recentChars.removeAll()
            inputGeneration &+= 1
            return
        }

        if keyCode == 0x35 {  // Escape
            textBuffer.clear()
            justCompletedWord = false
            earlySwitchedCurrentWord = false
            recentChars.removeAll()
            return
        }

        // Return/Enter: finish the word but never auto-correct — the newline may
        // have already submitted a form/message, so deleting would be dangerous.
        if keyCode == 0x24 || keyCode == 0x4C {
            textBuffer.wordCompleted()
            justCompletedWord = false
            earlySwitchedCurrentWord = false
            recentChars.removeAll()
            return
        }

        guard let char = keyCodeToChar(event: event) else { return }
        inputGeneration &+= 1

        if SettingsStore.shared.smartDashes {
            recentChars.append(char)
            if recentChars.count > 4 { recentChars.removeFirst(recentChars.count - 4) }
            if let sub = dashSubstitution() {
                delegate?.eventTap(self, substituteDeletingLast: sub.delete, with: sub.insert)
                recentChars = Array(sub.insert.suffix(4))
            }
        }

        if EventTap.wordBoundaries.contains(char) {
            let word = textBuffer.wordCompleted()
            earlySwitchedCurrentWord = false
            if !word.isEmpty {
                lastCompletedWord = word
                lastSeparator = char
                justCompletedWord = true
            }
            if word.count >= TextBuffer.minWordLength {
                delegate?.eventTap(self, didCompleteWord: word, separator: char)
            }
        } else {
            textBuffer.append(char: char)
            justCompletedWord = false

            if SettingsStore.shared.earlySwitchEnabled,
               !earlySwitchedCurrentWord,
               textBuffer.currentWord.count >= 4 {
                if let corrected = delegate?.eventTap(self, earlyCheckpoint: textBuffer.currentWord) {
                    textBuffer.replaceCurrentWord(corrected)
                    earlySwitchedCurrentWord = true
                }
            }
        }
    }

    /// Handles flagsChanged to catch the manual-switch modifier (Shift or Option).
    fileprivate func handleFlagsChanged(event: CGEvent) {
        if event.getIntegerValueField(.eventSourceUserData) == linotypeInjectedEventMagic { return }
        if IsSecureEventInputEnabled() { return }
        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           excludedBundleIDs.contains(bundleID) {
            return
        }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        switch SettingsStore.shared.manualTrigger {
        case .doubleShift:
            guard keyCode == 0x38 || keyCode == 0x3C else { return }
            if event.flags.contains(.maskShift) { handleDoubleTap() }
        case .doubleOption:
            guard keyCode == 0x3A || keyCode == 0x3D else { return }
            if event.flags.contains(.maskAlternate) { handleDoubleTap() }
        case .singleOption:
            guard keyCode == 0x3A || keyCode == 0x3D else { return }
            handleSingleOption(down: event.flags.contains(.maskAlternate), flags: event.flags)
        }
    }

    private func handleDoubleTap() {
        let now = Date().timeIntervalSince1970
        if now - lastModTapTime <= doubleTapInterval {
            lastModTapTime = 0
            fireManualSwitch()
        } else {
            lastModTapTime = now
        }
    }

    /// A clean single Option tap: pressed and released without touching other keys.
    private func handleSingleOption(down: Bool, flags: CGEventFlags) {
        let otherMods = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskShift)
        if down {
            optionDownTime = Date().timeIntervalSince1970
            optionSolo = !otherMods
        } else {
            let quick = Date().timeIntervalSince1970 - optionDownTime < doubleTapInterval
            if optionSolo && quick && !otherMods { fireManualSwitch() }
            optionSolo = false
        }
    }

    private func fireManualSwitch() {
        let current = textBuffer.currentWord
        if !current.isEmpty {
            delegate?.eventTap(self, didReceiveDoubleShift: current, separator: nil)
        } else if justCompletedWord, !lastCompletedWord.isEmpty {
            delegate?.eventTap(self, didReceiveDoubleShift: lastCompletedWord, separator: lastSeparator)
        }
    }

    /// Context-based dash substitution. Returns (chars to delete, replacement).
    private func dashSubstitution() -> (delete: Int, insert: String)? {
        let r = recentChars
        guard r.count >= 3 else { return nil }
        let c = r[r.count - 1]
        let p1 = r[r.count - 2]
        let p2 = r[r.count - 3]
        // digit-hyphen-digit → en dash, on the digit after the hyphen.
        if c.isNumber, p1 == "-", p2.isNumber {
            return (2, "\u{2013}" + String(c))
        }
        // space-hyphen-space → em dash, on the second space.
        if c == " ", p1 == "-", p2 == " " {
            return (2, "\u{2014} ")
        }
        return nil
    }

    private func keyCodeToChar(event: CGEvent) -> Character? {
        guard let currentKeyboard = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(currentKeyboard, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let dataRef = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue()
        let keyLayout = unsafeBitCast(CFDataGetBytePtr(dataRef),
                                      to: UnsafePointer<UCKeyboardLayout>.self)

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        // Feed Shift/Caps Lock to preserve case. UCKeyTranslate wants modifiers
        // as (carbonFlags >> 8) & 0xFF: shiftKey → 0x02, alphaLock → 0x04.
        var modifiers: UInt32 = 0
        if event.flags.contains(.maskShift) { modifiers |= 0x02 }
        if event.flags.contains(.maskAlphaShift) { modifiers |= 0x04 }

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var actualLength = 0

        let status = UCKeyTranslate(
            keyLayout, keyCode, UInt16(kUCKeyActionDown), modifiers,
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState, 4, &actualLength, &chars
        )

        guard status == noErr, actualLength > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: actualLength).first
    }
}

/// Marker (ASCII "LINO") stamped into eventSourceUserData of every event we
/// inject, so the tap ignores its own events and avoids a feedback loop.
let linotypeInjectedEventMagic: Int64 = 0x4C_49_4E_4F

enum EventTapError: LocalizedError {
    case tapCreationFailed

    var errorDescription: String? {
        "Не удалось создать CGEventTap. Убедитесь, что разрешение Accessibility предоставлено в Системных настройках → Конфиденциальность → Универсальный доступ."
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let tap = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        tap.reEnable()
        return Unmanaged.passUnretained(event)
    }

    switch type {
    case .keyDown:
        let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let f = event.flags
        let notInjected = event.getIntegerValueField(.eventSourceUserData) != linotypeInjectedEventMagic
        // ⌘⌥L — convert selection (consumed, not passed to the app).
        if kc == 0x25, f.contains(.maskCommand), f.contains(.maskAlternate),
           !f.contains(.maskControl), notInjected {
            tap.requestConvertSelection()
            return nil
        }
        // ⌘⌥' — quotes → «ёлочки» (quote keycode 0x27, layout-independent).
        if kc == 0x27, f.contains(.maskCommand), f.contains(.maskAlternate),
           !f.contains(.maskControl), notInjected {
            tap.requestSmartQuotes()
            return nil
        }
        tap.handle(event: event)
    case .flagsChanged:
        tap.handleFlagsChanged(event: event)
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}
