import Cocoa
import Carbon

protocol EventTapDelegate: AnyObject {
    /// A word was finished by typing `separator` (already in the document).
    func eventTap(_ tap: EventTap, didCompleteWord word: String, separator: Character)
    /// Manual switch trigger. `separator == nil` means the word is unfinished;
    /// otherwise it was just completed by that separator. Returns the word now on
    /// screen so the buffer can be kept in sync (nil if nothing changed).
    func eventTap(_ tap: EventTap, didReceiveDoubleShift word: String, separator: Character?) -> String?
    /// Convert-selection hotkey (⌘⌥L).
    func eventTapDidRequestConvertSelection(_ tap: EventTap)
    /// Smart-quotes hotkey (⌘⌥').
    func eventTapDidRequestSmartQuotes(_ tap: EventTap)
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
    // Clean single-Option taps observed in the field held 0.4-0.7s — longer than
    // the double-tap window — so give the solo trigger its own, looser budget.
    private let optionHoldMax: TimeInterval = 0.6

    // Single-Option trigger: track a "clean" tap with no other keys.
    private var optionDownTime: TimeInterval = 0
    private var optionSolo = false

    // Last completed word and its separator, for a manual switch after the space.
    // justCompletedWord stays true only while the cursor sits right after it.
    private var lastCompletedWord: String = ""
    private var lastSeparator: Character?
    private var justCompletedWord = false

    // Race guard: bumped on every text-affecting keystroke so a queued async
    // replacement can detect that the cursor has since moved.
    private(set) var inputGeneration = 0

    // Last typed chars, for smart dashes.
    private var recentChars: [Character] = []

    // Refreshed via notifications instead of per event: rebuilding the exclusion
    // set from UserDefaults and querying NSWorkspace are both too expensive for
    // a path that runs on every keystroke.
    private var excludedBundleIDs = SettingsStore.shared.excludedBundleIDs
    private var frontmostBundleID: String?

    // Last logged secure-input state, so only the on/off transitions hit the log
    // (the check itself runs on every event).
    private var lastSecureInput = false

    // UCKeyTranslate layout, resolved once per input source instead of per
    // keydown. The source and its data are retained together: the raw layout
    // pointer is only valid while the owning input source lives.
    private var cachedInputSource: TISInputSource?
    private var cachedLayoutData: CFData?

    private var settingsObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var layoutChangeObserver: NSObjectProtocol?

    private static let wordBoundaries: Set<Character> = [
        " ", ".", ",", "!", "?", ":", ";", "\n", "\r", "\t",
        "(", ")", "[", "]", "{", "}", "\"", "'", "/", "\\",
        "-", "=", "+", "*", "&", "^", "%", "$", "#", "@",
    ]

    var isRunning: Bool { tap != nil }

    init() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .linotypeSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.excludedBundleIDs = SettingsStore.shared.excludedBundleIDs
        }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let bundleID =
                (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            self.frontmostBundleID = bundleID
            if let bundleID {
                // Explains sudden silences in the log: excluded app in front.
                DiagnosticLog.log("APP \(bundleID)\(self.excludedBundleIDs.contains(bundleID) ? " EXCLUDED" : "")")
            }
        }
        layoutChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.cachedInputSource = nil
            self?.cachedLayoutData = nil
        }
    }

    deinit {
        if let o = settingsObserver { NotificationCenter.default.removeObserver(o) }
        if let o = appActivationObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let o = layoutChangeObserver { DistributedNotificationCenter.default().removeObserver(o) }
    }

    /// Creates the tap. Throws if Accessibility permission is missing
    /// (tapCreate returns nil). A no-op if the tap is already active.
    func start() throws {
        guard tap == nil else { return }

        // Seed the cache; kept fresh by the app-activation observer afterwards.
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // keyDown for characters; flagsChanged for Shift (modifiers send no keyDown);
        // mouse-downs to resync the buffer when a click moves the caret elsewhere.
        let eventMask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue)
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
        // stop() is also called when already stopped (settings changes) —
        // only log an actual teardown.
        let wasRunning = tap != nil
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        if let port = tap { CGEvent.tapEnable(tap: port, enable: false) }
        tap = nil
        runLoopSource = nil
        if wasRunning { DiagnosticLog.log("TAP stopped") }
    }

    /// Wraps IsSecureEventInputEnabled(), logging only the on/off transitions —
    /// a stuck secure-input session is a classic "stopped switching" cause.
    private func secureInputActive() -> Bool {
        let secure = IsSecureEventInputEnabled()
        if secure != lastSecureInput {
            lastSecureInput = secure
            DiagnosticLog.log(secure ? "SECURE on" : "SECURE off")
        }
        return secure
    }

    /// Echoes our own injected keyDowns: proof each synthetic event actually
    /// traversed the session event stream, ordered against the real KEY lines —
    /// without this a target field silently swallowing events is invisible.
    private func logInjectedEcho(_ event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if keyCode == 0x33 {
            DiagnosticLog.log("INJ ⌫")
            return
        }
        var length = 0
        var chars = [UniChar](repeating: 0, count: 64)
        event.keyboardGetUnicodeString(maxStringLength: 64, actualStringLength: &length, unicodeString: &chars)
        if length > 0 {
            DiagnosticLog.log("INJ \"\(String(utf16CodeUnits: chars, count: length))\"")
        } else {
            DiagnosticLog.log("INJ kc=\(keyCode)")
        }
    }

    fileprivate func handle(event: CGEvent) {
        // Ignore our own injected events, or the tap would catch the correction
        // keystrokes as user input and cascade.
        if event.getIntegerValueField(.eventSourceUserData) == linotypeInjectedEventMagic {
            logInjectedEcho(event)
            return
        }

        // Secure input (password fields): don't intercept, clear the buffer.
        if secureInputActive() {
            textBuffer.clear()
            justCompletedWord = false
            return
        }

        if let bundleID = frontmostBundleID, excludedBundleIDs.contains(bundleID) {
            return
        }

        // Any ordinary key breaks a double-tap and an Option "solo".
        lastModTapTime = 0
        optionSolo = false

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        // Cmd/Ctrl combos are shortcuts, not text — and may have changed the
        // document (⌘V/⌘A/⌘Z etc.), so the buffer can no longer be trusted.
        if event.flags.contains(.maskCommand) || event.flags.contains(.maskControl) {
            DiagnosticLog.log("KEY combo kc=\(keyCode)")
            textBuffer.clear()
            justCompletedWord = false
            recentChars.removeAll()
            inputGeneration &+= 1
            return
        }

        if keyCode == 0x33 {  // Backspace
            if event.flags.contains(.maskAlternate) {
                // ⌥⌫ deletes the whole word on screen, not just one char.
                textBuffer.clear()
                DiagnosticLog.log("KEY ⌥⌫ clear")
            } else {
                textBuffer.backspace()
                DiagnosticLog.log("KEY ⌫ word=\"\(textBuffer.currentWord)\"")
            }
            justCompletedWord = false
            recentChars.removeAll()
            inputGeneration &+= 1
            return
        }

        if keyCode == 0x35 {  // Escape
            DiagnosticLog.log("KEY esc")
            textBuffer.clear()
            justCompletedWord = false
            recentChars.removeAll()
            return
        }

        // Return/Enter: finish the word but never auto-correct — the newline may
        // have already submitted a form/message, so deleting would be dangerous.
        if keyCode == 0x24 || keyCode == 0x4C {
            DiagnosticLog.log("KEY ↵ word=\"\(textBuffer.currentWord)\"")
            textBuffer.wordCompleted()
            justCompletedWord = false
            recentChars.removeAll()
            return
        }

        // Tab usually moves focus to another field, so a correction here would
        // type into the wrong place — finish the word silently, like Return.
        if keyCode == 0x30 {
            DiagnosticLog.log("KEY ⇥ word=\"\(textBuffer.currentWord)\"")
            textBuffer.wordCompleted()
            justCompletedWord = false
            recentChars.removeAll()
            return
        }

        guard let char = keyCodeToChar(event: event) else {
            DiagnosticLog.log("KEY kc=\(keyCode) (no char)")
            return
        }
        inputGeneration &+= 1

        // Arrows/Home/End/PageUp/etc. translate to invisible control chars that
        // would otherwise get appended to the buffer as garbage.
        if let scalar = char.unicodeScalars.first,
           scalar.value < 0x20 || scalar.value == 0x7F || (0xF700...0xF8FF).contains(scalar.value) {
            DiagnosticLog.log("NAV kc=\(keyCode) clear")
            textBuffer.clear()
            justCompletedWord = false
            recentChars.removeAll()
            return
        }

        DiagnosticLog.log("KEY '\(char)' kc=\(keyCode) shift=\(event.flags.contains(.maskShift)) word=\"\(textBuffer.currentWord)\"")

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
            if !word.isEmpty {
                lastCompletedWord = word
                lastSeparator = char
                justCompletedWord = true
            } else {
                justCompletedWord = false
            }
            if word.count >= TextBuffer.minWordLength {
                delegate?.eventTap(self, didCompleteWord: word, separator: char)
            }
        } else {
            textBuffer.append(char: char)
            justCompletedWord = false
        }
    }

    /// A mouse click likely moves the caret, so the buffer no longer reflects what's
    /// under it (e.g. clicking mid-word merges the next keystrokes into it on screen
    /// but not in our buffer). Resync by dropping whatever we were tracking.
    fileprivate func handleMouseDown() {
        inputGeneration &+= 1
        lastModTapTime = 0
        optionSolo = false
        if !textBuffer.currentWord.isEmpty || justCompletedWord {
            DiagnosticLog.log("CLICK clear word=\"\(textBuffer.currentWord)\"")
        }
        textBuffer.clear()
        justCompletedWord = false
        recentChars.removeAll()
    }

    /// Handles flagsChanged to catch the manual-switch modifier (Shift or Option).
    fileprivate func handleFlagsChanged(event: CGEvent) {
        if event.getIntegerValueField(.eventSourceUserData) == linotypeInjectedEventMagic { return }
        if secureInputActive() { return }
        if let bundleID = frontmostBundleID, excludedBundleIDs.contains(bundleID) {
            return
        }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        DiagnosticLog.log("MOD kc=\(keyCode) alt=\(event.flags.contains(.maskAlternate)) shift=\(event.flags.contains(.maskShift)) cmd=\(event.flags.contains(.maskCommand)) trig=\(SettingsStore.shared.manualTrigger.rawValue)")

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
        let delta = now - lastModTapTime
        if delta <= doubleTapInterval {
            lastModTapTime = 0
            DiagnosticLog.log("TAP double delta=\(String(format: "%.2f", delta)) → FIRE")
            fireManualSwitch()
        } else {
            DiagnosticLog.log("TAP first delta=\(String(format: "%.2f", delta))")
            lastModTapTime = now
        }
    }

    /// A clean single Option tap: pressed and released without touching other keys.
    private func handleSingleOption(down: Bool, flags: CGEventFlags) {
        let otherMods = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskShift)
        if down {
            optionDownTime = Date().timeIntervalSince1970
            optionSolo = !otherMods
            DiagnosticLog.log("OPT down solo=\(optionSolo)")
        } else {
            let held = Date().timeIntervalSince1970 - optionDownTime
            let quick = held < optionHoldMax
            let fire = optionSolo && quick && !otherMods
            DiagnosticLog.log("OPT up held=\(String(format: "%.2f", held)) solo=\(optionSolo) quick=\(quick) other=\(otherMods) → \(fire ? "FIRE" : "ignore")")
            if fire { fireManualSwitch() }
            optionSolo = false
        }
    }

    private func fireManualSwitch() {
        let current = textBuffer.currentWord
        if !current.isEmpty {
            // Keep the buffer in sync with the on-screen word so further typing
            // doesn't merge into the stale form ("ujnjdj" + "готово").
            if let result = delegate?.eventTap(self, didReceiveDoubleShift: current, separator: nil) {
                textBuffer.replaceCurrentWord(result)
            }
        } else if justCompletedWord, !lastCompletedWord.isEmpty {
            if let result = delegate?.eventTap(self, didReceiveDoubleShift: lastCompletedWord, separator: lastSeparator) {
                lastCompletedWord = result
            }
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

    /// Layout data for UCKeyTranslate, cached until the input source changes
    /// (the distributed TIS notification clears it).
    private func currentLayoutData() -> CFData? {
        if let cached = cachedLayoutData { return cached }
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue()
        cachedInputSource = source
        cachedLayoutData = data
        return data
    }

    private func keyCodeToChar(event: CGEvent) -> Character? {
        guard let dataRef = currentLayoutData() else { return nil }
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
        // The #1 suspect when switching "silently stops" — must be visible.
        DiagnosticLog.log("TAP disabled (\(type == .tapDisabledByTimeout ? "timeout" : "userInput")) → re-enable")
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
    case .leftMouseDown, .rightMouseDown, .otherMouseDown:
        tap.handleMouseDown()
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}
