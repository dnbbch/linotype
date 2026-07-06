import Cocoa
import ServiceManagement

@main
final class LinotypeApp: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var eventTap: EventTap!
    private var classifier: Classifier?
    private var layoutSwitcher: LayoutSwitcher!
    private var settingsWindowController: SettingsWindowController?
    private let hud = SwitchHUD()
    private let yoficator = Yoficator()
    private let switchSound = NSSound(named: NSSound.Name("Pop"))

    private var isEnabled: Bool {
        get { SettingsStore.shared.autoSwitchEnabled }
        set { SettingsStore.shared.autoSwitchEnabled = newValue; updateMenuState() }
    }

    private var permissionTimer: Timer?

    // Keeps the 1.5s permission poll from writing an identical failure line on
    // every tick; reset once the tap starts so a later loss is logged again.
    private var loggedTapStartFailure = false

    // Last auto-correction, so a manual trigger right after can undo it.
    // generation pins the undo to the exact keystroke it followed: if anything
    // was typed or clicked since, the tap falls through to a genuine manual switch.
    private var lastCorrection: (original: String, corrected: String, separator: Character?,
                                 fromLayout: Language, at: Date, generation: Int)?

    // Serializes manual switches so rapid taps don't overlap into garbage.
    private var lastManualSwitchAt = Date.distantPast

    // Overlay/search fields that drop rapid synthetic backspaces — injection into
    // these is paced (see LayoutSwitcher.slowInjectionKeyDelay); everything else
    // keeps zero-latency injection.
    private static let slowInjectionApps: Set<String> = ["com.apple.Spotlight", "com.apple.finder"]

    // ⌘⌥L with no selection converts the just-typed word(s). Repeated presses
    // within the window extend the span one word further back each time; any real
    // keystroke (detected by a changed inputGeneration) resets the run.
    private var lastConvertTypedAt = Date.distantPast
    private var convertTypedWordCount = 0
    private var convertTypedGeneration = -1
    private static let convertTypedWindow: TimeInterval = 1.5

    // Recent auto-corrections (newest last), surfaced in the menu so the user can
    // teach "leave this alone" with one click. In-memory only — a session's worth.
    private var recentCorrections: [(original: String, corrected: String)] = []
    private static let maxRecentCorrections = 5

    // Temporary pause: a soft, timed disable that does NOT flip autoSwitchEnabled,
    // so it auto-resumes and the user's real preference is untouched.
    private var pausedUntil: Date?
    private var pauseTimer: Timer?
    private static let pauseDuration: TimeInterval = 15 * 60

    private var onboardingWindowController: OnboardingWindowController?

    // Resolved once: the NSSpellChecker language tag for each side, used to veto
    // corrections that turn short garbage into more garbage.
    private lazy var spellCheckerLanguages: [Language: String] = {
        let available = NSSpellChecker.shared.availableLanguages
        func tag(for prefix: String) -> String {
            available.first { $0.lowercased().hasPrefix(prefix) } ?? prefix
        }
        return [.ru: tag(for: "ru"), .en: tag(for: "en")]
    }()

    // MARK: - Lifecycle

    static func main() {
        let app = NSApplication.shared
        let delegate = LinotypeApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // no Dock icon
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Anchor every log session to a concrete build and configuration — an
        // "app not switching" report is undiagnosable without knowing which
        // binary ran and with what settings.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let s = SettingsStore.shared
        DiagnosticLog.log("START v\(version) (\(build)) path=\(Bundle.main.bundlePath) "
            + "trig=\(s.manualTrigger.rawValue) thr=\(String(format: "%.2f", s.confidenceThreshold)) "
            + "auto=\(s.autoSwitchEnabled) yo=\(s.smartYo) dashes=\(s.smartDashes) "
            + "learn=\(s.adaptiveLearning) excl=\(s.excludedBundleIDs.count)")

        setupMenuBar()
        setupComponents()
        ensureAccessibilityAndStart()
        setupLoginItem()
        maybeShowOnboarding()

        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: .linotypeSettingsChanged, object: nil)
    }

    /// First launch without Accessibility yet: explain the permission once. The
    /// flag ensures it never nags again, whether or not the user grants it now.
    private func maybeShowOnboarding() {
        guard !SettingsStore.shared.didOnboard, !AXIsProcessTrusted() else { return }
        SettingsStore.shared.didOnboard = true
        let controller = OnboardingWindowController()
        onboardingWindowController = controller
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        DiagnosticLog.log("STOP terminating")
        // The log queue is async; without draining it the STOP line would be
        // lost to process exit.
        DiagnosticLog.flush()
    }

    /// Re-launching an already-running instance (Spotlight/Finder/`open`) opens
    /// Settings — the escape hatch when the menu-bar icon is hidden by a crowded
    /// notch. An accessory app has no Dock icon, so reopen is the only reliable way
    /// back in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return true
    }

    @objc private func settingsChanged() {
        if isEnabled { ensureAccessibilityAndStart() } else { eventTap?.stop() }
        updateMenuState()
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let icon = NSImage(named: "StatusIcon")
            icon?.isTemplate = true
            icon?.size = NSSize(width: 18, height: 18)
            button.image = icon
        }

        let menu = NSMenu()

        let toggleItem = NSMenuItem(title: "Автопереключение", action: #selector(toggleEnabled), keyEquivalent: "")
        toggleItem.state = isEnabled ? .on : .off
        toggleItem.tag = 1
        menu.addItem(toggleItem)

        let statsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statsItem.tag = 2
        statsItem.isEnabled = false
        menu.addItem(statsItem)

        let pauseItem = NSMenuItem(title: "Пауза на 15 минут", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.tag = Self.pauseItemTag
        menu.addItem(pauseItem)

        // Dynamic sections (recent corrections, suggestions) are inserted here on
        // every open, between this separator and the static tail below.
        let dynamicAnchor = NSMenuItem.separator()
        dynamicAnchor.tag = Self.dynamicAnchorTag
        menu.addItem(dynamicAnchor)

        menu.addItem(NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Запускать при входе", action: #selector(toggleLaunchAtLogin), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit linotype", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        menu.delegate = self
        statusItem.menu = menu
        hud.statusItem = statusItem
        updateStatsItem()
    }

    // Tags for menu items that are updated or targeted after creation.
    private static let toggleItemTag = 1
    private static let statsItemTag = 2
    private static let pauseItemTag = 3
    private static let dynamicAnchorTag = 4
    // Dynamic items carry this tag so they can be cleared before each rebuild.
    private static let dynamicItemTag = 99

    private func updateStatsItem() {
        statusItem.menu?.item(withTag: 2)?.title = "Переключений: \(SettingsStore.shared.switchCount)"
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        // Briefly become a regular app so the window can take focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func updateMenuState() {
        guard let menu = statusItem.menu, let toggleItem = menu.item(withTag: Self.toggleItemTag) else { return }
        toggleItem.state = isEnabled ? .on : .off
        // Dim the icon while disabled, paused, or waiting for permission.
        let active = isEnabled && !isPaused && (eventTap?.isRunning == true)
        statusItem.button?.alphaValue = active ? 1.0 : 0.4
        updateStatsItem()
        updatePauseItem()
    }

    private var isPaused: Bool {
        guard let until = pausedUntil else { return false }
        return until > Date()
    }

    private func updatePauseItem() {
        guard let item = statusItem.menu?.item(withTag: Self.pauseItemTag) else { return }
        if isPaused, let until = pausedUntil {
            let minutes = max(1, Int(ceil(until.timeIntervalSinceNow / 60)))
            item.title = "Возобновить (ещё \(minutes) мин)"
        } else {
            item.title = "Пауза на 15 минут"
        }
    }

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        if isEnabled { ensureAccessibilityAndStart() } else { eventTap?.stop() }
        updateMenuState()
    }

    @objc private func togglePause() {
        if isPaused { resumeFromPause() } else { startPause() }
    }

    private func startPause() {
        pausedUntil = Date().addingTimeInterval(Self.pauseDuration)
        eventTap?.stop()
        pauseTimer?.invalidate()
        // Fire slightly past the deadline so isPaused reads false when it runs.
        pauseTimer = Timer.scheduledTimer(withTimeInterval: Self.pauseDuration + 0.5, repeats: false) { [weak self] _ in
            self?.resumeFromPause()
        }
        DiagnosticLog.log("PAUSE 15m")
        updateMenuState()
    }

    private func resumeFromPause() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        pausedUntil = nil
        // Restart through the normal path (re-checks permission, respects the
        // user's real enabled preference).
        if isEnabled { ensureAccessibilityAndStart() }
        DiagnosticLog.log("PAUSE resume")
        updateMenuState()
    }

    @objc private func toggleLaunchAtLogin() {
        guard let menu = statusItem.menu,
              let item = menu.item(withTitle: "Запускать при входе") else { return }

        if #available(macOS 13.0, *) {
            do {
                if item.state == .off {
                    try SMAppService.mainApp.register()
                    item.state = .on
                } else {
                    try SMAppService.mainApp.unregister()
                    item.state = .off
                }
            } catch {
                showAlert(title: "Ошибка", message: error.localizedDescription)
            }
        }
    }

    // MARK: - Components

    private func setupComponents() {
        layoutSwitcher = LayoutSwitcher()

        do {
            classifier = try Classifier()
        } catch {
            showAlert(title: "Ошибка загрузки модели", message: error.localizedDescription)
        }

        eventTap = EventTap()
        eventTap.delegate = self
        // The tap is started by ensureAccessibilityAndStart() once permission exists.
    }

    // MARK: - Accessibility

    /// Prompts for Accessibility and starts the tap once granted, polling every
    /// 1.5 s so no relaunch is needed.
    private func ensureAccessibilityAndStart() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        // A rebuild changes the ad-hoc signature and silently drops the
        // Accessibility grant — this line is the clue when switching stops.
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        DiagnosticLog.log("AX trusted=\(trusted)")

        tryStartTap()
        guard eventTap?.isRunning != true else { return }

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.tryStartTap()
            if self.eventTap?.isRunning == true {
                timer.invalidate()
                self.permissionTimer = nil
                // Permission just landed — the onboarding window has done its job.
                self.onboardingWindowController?.close()
                self.onboardingWindowController = nil
            }
            self.updateMenuState()
        }
    }

    private func tryStartTap() {
        // Never start the tap while paused — pause is a temporary disable.
        guard isEnabled, !isPaused, eventTap?.isRunning == false else { return }
        do {
            try eventTap?.start()
            loggedTapStartFailure = false
            DiagnosticLog.log("TAP started")
        } catch {
            if !loggedTapStartFailure {
                loggedTapStartFailure = true
                DiagnosticLog.log("TAP start failed: \(error)")
            }
        }
    }

    // MARK: - Login item

    private func setupLoginItem() {
        if #available(macOS 13.0, *) {
            guard let menu = statusItem.menu,
                  let item = menu.item(withTitle: "Запускать при входе") else { return }
            item.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    // MARK: - Helpers

    private func playSwitchSound() {
        guard SettingsStore.shared.switchSound, let sound = switchSound else { return }
        sound.stop()
        sound.play()
    }

    private func frontApp() -> String {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
    }

    /// Whether `word` is a recognized word in `language`, per the system spellchecker.
    private func isValidWord(_ word: String, language: Language) -> Bool {
        let tag = spellCheckerLanguages[language] ?? language.short
        let range = NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: tag, wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - AX introspection (diagnostics only)

    /// The AX-focused element system-wide, or nil. Accessibility permission is
    /// already required for the tap, so this is just API calls.
    private func axFocusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    /// Copies a string-valued AX attribute; nil when unsupported or non-string.
    private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    /// Replaces the last word via the Accessibility API — an atomic text edit with
    /// no synthetic keystrokes. Spotlight-class fields deterministically drop one
    /// backspace from a synthetic burst regardless of pacing; this sidesteps the
    /// keyboard path entirely. Returns false (caller falls back to backspaces) on
    /// any mismatch, so it never corrupts a field it can't reason about.
    /// The separator is intentionally left untouched: whether it already landed in
    /// the value or arrives right after as pass-through, replacing only `original`
    /// yields the correct result and avoids the separator-ordering race.
    private func axReplaceLastWord(original: String, corrected: String, separator: Character?) -> Bool {
        guard let element = axFocusedElement(),
              let value = axString(element, kAXValueAttribute) else { return false }

        // AX ranges are UTF-16; NSString gives matching length/substring semantics.
        let ns = value as NSString

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let raw = rangeValue, CFGetTypeID(raw) == AXValueGetTypeID() else { return false }
        var selection = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &selection) else { return false }
        // A selection's end is the caret; a plain caret has length 0.
        let caret = selection.location + selection.length
        let originalLen = (original as NSString).length

        // Locate `original` right before the caret, tolerating that the just-typed
        // separator may or may not have landed in `value` yet.
        let targetRange: CFRange
        if caret >= originalLen,
           ns.substring(with: NSRange(location: caret - originalLen, length: originalLen)) == original {
            targetRange = CFRange(location: caret - originalLen, length: originalLen)
        } else if separator != nil, caret - 1 >= originalLen,
                  ns.substring(with: NSRange(location: caret - 1 - originalLen, length: originalLen)) == original {
            targetRange = CFRange(location: caret - 1 - originalLen, length: originalLen)
        } else {
            return false
        }

        var mutableRange = targetRange
        guard let axRange = AXValueCreate(.cfRange, &mutableRange) else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success,
              AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, corrected as CFString) == .success else {
            return false
        }
        return true
    }

    /// Layout whose keys produce the dominant script in `text` — so typing after a
    /// convert continues in the language the user clearly meant. Cyrillic-heavy →
    /// .ru, otherwise .en (matches Classifier.flip's own dominant-script rule).
    private func dominantLayout(of text: String) -> Language {
        var cyr = 0, lat = 0
        for u in text.unicodeScalars {
            if (0x0410...0x044F).contains(u.value) || u.value == 0x0401 || u.value == 0x0451 {
                cyr += 1
            } else if (0x41...0x5A).contains(u.value) || (0x61...0x7A).contains(u.value) {
                lat += 1
            }
        }
        return cyr >= lat ? .ru : .en
    }

    /// The AX-focused element's selection as a caret position, or nil when AX
    /// value/selection is unavailable (caller must fall back). `length` is the
    /// current selection width (0 for a plain caret).
    private func axCaret() -> (element: AXUIElement, value: NSString, caret: Int, length: Int)? {
        guard let element = axFocusedElement(),
              let value = axString(element, kAXValueAttribute) else { return nil }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let raw = rangeValue, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &selection) else { return nil }
        return (element, value as NSString, selection.location + selection.length, selection.length)
    }

    /// Converts the last `wordCount` whitespace-delimited words before the caret via
    /// the AX API (atomic edit, no keystrokes), then switches the system layout to
    /// the flipped span's dominant script. Returns false when AX is unavailable or
    /// there is nothing to convert, so the caller can fall back. `flip` maps by the
    /// physical-key table and leaves spaces/punctuation alone, so a multi-word span
    /// flips correctly in one shot.
    private func axConvertTyped(wordCount: Int, flip: (String) -> String) -> Bool {
        guard let (element, ns, caret, _) = axCaret(), caret > 0 else { return false }

        // Walk back from the caret over N words. Skip one trailing separator right
        // before the caret (the space that just ended the word) but keep the words.
        var end = caret
        if isSpanSeparator(ns.character(at: end - 1)) { end -= 1 }
        guard end > 0 else { return false }
        var start = end
        var remaining = wordCount
        while start > 0, remaining > 0 {
            // Skip separators between words, then consume one word.
            while start > 0, isSpanSeparator(ns.character(at: start - 1)) { start -= 1 }
            while start > 0, !isSpanSeparator(ns.character(at: start - 1)) { start -= 1 }
            remaining -= 1
        }
        guard start < end else { return false }

        let range = NSRange(location: start, length: end - start)
        let before = ns.substring(with: range)
        let after = flip(before)
        guard after != before else { return false }

        var cfRange = CFRange(location: start, length: end - start)
        guard let axRange = AXValueCreate(.cfRange, &cfRange),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success,
              AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, after as CFString) == .success else {
            return false
        }
        layoutSwitcher.switchTo(dominantLayout(of: after))
        DiagnosticLog.log("CONVERTTYPED n=\(wordCount) \"\(before.suffix(40))\"→\"\(after.suffix(40))\"")
        return true
    }

    /// Word boundary for convert-typed spans: any non-alphanumeric UTF-16 unit.
    private func isSpanSeparator(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return true }
        return !(Character(scalar).isLetter || Character(scalar).isNumber)
    }

    /// AX-first replacement for slow fields: try the atomic edit, log which path
    /// ran, and on success still `switchTo` the target so subsequent typing is in
    /// the right layout (the AX edit itself is layout-independent). Returns true
    /// only when AX handled it; false means the caller must use the backspace path.
    private func tryAXReplace(original: String, corrected: String,
                              separator: Character?, targetLayout: Language) -> Bool {
        if axReplaceLastWord(original: original, corrected: corrected, separator: separator) {
            DiagnosticLog.log("AXREPLACE ok \"\(original)\"→\"\(corrected)\"")
            layoutSwitcher.switchTo(targetLayout)
            return true
        }
        DiagnosticLog.log("AXREPLACE fail → backspaces")
        return false
    }

    /// Bundle ID of the process owning the AX-focused element, or nil. Always-on
    /// (never gated behind logging): this is how Spotlight is detected, since
    /// NSWorkspace.frontmostApplication does not change for overlays.
    private func focusedProcessBundleID() -> String? {
        guard let element = axFocusedElement() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// "<bundleID>/<role>" of the AX-focused element, "?" parts when unavailable.
    /// NSWorkspace's frontmost app misses overlays (Spotlight!), so this is the
    /// only reliable record of where injected events actually land.
    private func focusedFieldInfo() -> String {
        guard let element = axFocusedElement() else { return "?" }
        var pid: pid_t = 0
        let bundleID = AXUIElementGetPid(element, &pid) == .success
            ? (NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?") : "?"
        let role = axString(element, kAXRoleAttribute) ?? "?"
        return "\(bundleID)/\(role)"
    }

    /// Whether the currently focused field needs paced injection (Spotlight-class).
    /// Must work with logging OFF — the slow decision is behaviour, not diagnostics.
    private func focusNeedsSlowInjection() -> Bool {
        focusedProcessBundleID().map(Self.slowInjectionApps.contains) ?? false
    }

    /// FOCUS lines only around replacements — per-word would be noise. The guard
    /// is hoisted here so the AX round-trip never runs while logging is off.
    private func logFocusForReplacement() {
        guard SettingsStore.shared.diagnosticLogging else { return }
        DiagnosticLog.log("FOCUS \(focusedFieldInfo())")
    }

    /// Reads the focused field back shortly after an injection, once the synthetic
    /// events have been processed. This is the ground truth of what the field
    /// actually contains — the only way to catch a target that swallowed part of
    /// the replacement (e.g. Spotlight dropping a backspace: "pзаметки").
    private func scheduleReplacementVerify() {
        guard SettingsStore.shared.diagnosticLogging else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, let element = self.axFocusedElement(),
                  let value = self.axString(element, kAXValueAttribute) else {
                DiagnosticLog.log("VERIFY value=?")
                return
            }
            // Tail only: fields can hold huge text and the replacement zone is
            // at the end.
            DiagnosticLog.log("VERIFY value=\"\(value.suffix(40))\"")
        }
    }
}

// MARK: - NSMenuDelegate

extension LinotypeApp: NSMenuDelegate {
    /// Re-reads state that can drift while the menu is closed (login item toggled
    /// in System Settings, pause timer, counter) and rebuilds the dynamic sections.
    func menuWillOpen(_ menu: NSMenu) {
        setupLoginItem()
        updateMenuState()
        rebuildDynamicMenuItems(in: menu)
    }

    /// Removes the previous dynamic items and inserts fresh ones just above the
    /// dynamic anchor separator, so opening the menu repeatedly never duplicates.
    private func rebuildDynamicMenuItems(in menu: NSMenu) {
        for item in menu.items where item.tag == Self.dynamicItemTag {
            menu.removeItem(item)
        }
        guard let anchor = menu.item(withTag: Self.dynamicAnchorTag) else { return }
        var index = menu.index(of: anchor)  // insert before the anchor separator

        func insert(_ item: NSMenuItem) {
            item.tag = Self.dynamicItemTag
            menu.insertItem(item, at: index)
            index += 1
        }

        // Pending suggestions: an offer to remember a repeatedly-fixed word.
        let suggestions = SettingsStore.shared.pendingSuggestions
        if !suggestions.isEmpty {
            for word in suggestions.keys.sorted() {
                let lang = suggestions[word] == "ru" ? "РУ" : "EN"
                let item = NSMenuItem(title: "Добавить в словарь: «\(word)» → \(lang)",
                                      action: #selector(acceptSuggestionItem(_:)), keyEquivalent: "")
                item.representedObject = word
                // Submenu with a "don't suggest" escape hatch.
                let sub = NSMenu()
                let dismiss = NSMenuItem(title: "Не предлагать", action: #selector(dismissSuggestionItem(_:)), keyEquivalent: "")
                dismiss.representedObject = word
                sub.addItem(dismiss)
                item.submenu = sub
                insert(item)
            }
            insert(.separator())
        }

        // Recent corrections: one click teaches "leave this word alone".
        let recentsHeader = NSMenuItem(title: "Недавние исправления", action: nil, keyEquivalent: "")
        let recentsSub = NSMenu()
        if recentCorrections.isEmpty {
            let empty = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentsSub.addItem(empty)
        } else {
            for correction in recentCorrections.reversed() {  // newest first
                let item = NSMenuItem(title: "«\(correction.original)» → «\(correction.corrected)»",
                                      action: #selector(keepRecentCorrection(_:)), keyEquivalent: "")
                item.representedObject = correction.original
                item.target = self
                recentsSub.addItem(item)
            }
        }
        recentsHeader.submenu = recentsSub
        insert(recentsHeader)
        insert(.separator())
    }

    @objc private func acceptSuggestionItem(_ sender: NSMenuItem) {
        guard let word = sender.representedObject as? String else { return }
        SettingsStore.shared.acceptSuggestion(word)
        NotificationCenter.default.post(name: .linotypeSettingsChanged, object: nil)
        hud.show("＋")
    }

    @objc private func dismissSuggestionItem(_ sender: NSMenuItem) {
        guard let word = sender.representedObject as? String else { return }
        SettingsStore.shared.dismissSuggestion(word)
    }

    @objc private func keepRecentCorrection(_ sender: NSMenuItem) {
        guard let word = sender.representedObject as? String else { return }
        SettingsStore.shared.learnKeep(word)
        NotificationCenter.default.post(name: .linotypeSettingsChanged, object: nil)
        hud.show("✓")
    }
}

// MARK: - EventTapDelegate

extension LinotypeApp: EventTapDelegate {

    // The delegate runs on the main run loop (the tap source is on main). CoreML
    // inference is fast (<1 ms) and TIS APIs (layout) MUST run on main — so all of
    // this stays synchronous here; nothing is dispatched off-main.

    func eventTap(_ tap: EventTap, didCompleteWord word: String, separator: Character) {
        guard isEnabled, let classifier else { return }
        // Every silent decision path must be visible in the log — an unlogged
        // exception skip once cost hours of diagnosis.
        if SettingsStore.shared.isWordExcluded(word) {
            DiagnosticLog.log("WORD \"\(word)\" SKIP exception app=\(frontApp())")
            return
        }

        let current = layoutSwitcher.currentLayout

        // Personal dictionary overrides the model for words the user taught.
        if let forced = SettingsStore.shared.learnedLanguage(for: word) {
            DiagnosticLog.log("WORD \"\(word)\" forced=\(forced.short) cur=\(current.short) app=\(frontApp())")
            if forced != current {
                var corrected = classifier.correct(word: word, targetLayout: forced)
                if SettingsStore.shared.smartYo, let yo = yoficator.yoify(corrected) { corrected = yo }
                let slow = focusNeedsSlowInjection()
                logFocusForReplacement()
                // Slow (Spotlight-class) fields: atomic AX edit first, backspaces only if it fails.
                if !(slow && tryAXReplace(original: word, corrected: corrected,
                                          separator: separator, targetLayout: forced)) {
                    layoutSwitcher.replaceLastWord(original: word, corrected: corrected,
                                                   separator: separator, targetLayout: forced, slowInjection: slow)
                }
                scheduleReplacementVerify()
                lastCorrection = (word, corrected, separator, current, Date(), tap.inputGeneration)
                noteAutoCorrection(original: word, corrected: corrected, from: current, to: forced)
                announceSwitch(forced)
            }
            return
        }

        guard let (lang, confidence) = try? classifier.classify(word: word) else { return }
        let needSwitch = (lang != current && confidence >= SettingsStore.shared.confidenceThreshold)
        DiagnosticLog.log("WORD \"\(word)\" lang=\(lang.short) conf=\(String(format: "%.2f", confidence)) cur=\(current.short) need=\(needSwitch) app=\(frontApp())")

        if needSwitch {
            var corrected = classifier.correct(word: word, targetLayout: lang)

            // The model is overconfident on short out-of-vocabulary garbage; if the
            // result isn't a real word in the target language, a correction would
            // make things worse than leaving the typo alone.
            if word.count <= 4, !isValidWord(corrected, language: lang) {
                DiagnosticLog.log("WORD \"\(word)\" VETO corrected=\"\(corrected)\" not in \(lang.short) dict")
                return
            }

            // Apply ёфикация after the switch too: "tot" → "еще" → "ещё".
            if SettingsStore.shared.smartYo, let yo = yoficator.yoify(corrected) { corrected = yo }
            let slow = focusNeedsSlowInjection()
            logFocusForReplacement()
            // Slow (Spotlight-class) fields: atomic AX edit first, backspaces only if it fails.
            if !(slow && tryAXReplace(original: word, corrected: corrected,
                                      separator: separator, targetLayout: lang)) {
                layoutSwitcher.replaceLastWord(original: word, corrected: corrected,
                                               separator: separator, targetLayout: lang, slowInjection: slow)
            }
            scheduleReplacementVerify()
            lastCorrection = (word, corrected, separator, current, Date(), tap.inputGeneration)
            noteAutoCorrection(original: word, corrected: corrected, from: current, to: lang)
            announceSwitch(lang)
            return
        }

        // Correct layout: ёфикация only (silent).
        if SettingsStore.shared.smartYo, let yo = yoficator.yoify(word) {
            lastCorrection = nil
            layoutSwitcher.replaceLastWord(original: word, corrected: yo,
                                           separator: separator, targetLayout: current)
        }
    }

    private func announceSwitch(_ lang: Language) {
        SettingsStore.shared.incrementSwitchCount()
        updateStatsItem()
        hud.show(lang.hudLabel)
        playSwitchSound()
    }

    /// Records one auto-correction: the menu ring buffer plus persisted statistics.
    /// Called only from the two auto-switch branches, so manual switches and the
    /// silent ёфикация path never inflate the numbers.
    private func noteAutoCorrection(original: String, corrected: String, from: Language, to: Language) {
        recentCorrections.append((original, corrected))
        if recentCorrections.count > Self.maxRecentCorrections {
            recentCorrections.removeFirst(recentCorrections.count - Self.maxRecentCorrections)
        }
        SettingsStore.shared.recordCorrection(from: from, to: to, corrected: corrected)
    }

    @discardableResult
    func eventTap(_ tap: EventTap, didReceiveDoubleShift word: String, separator: Character?) -> String? {
        guard let classifier else { return nil }
        let dt = Date().timeIntervalSince(lastManualSwitchAt)
        // Ignore taps that arrive before the previous replacement has settled.
        guard dt > 0.12 else {
            DiagnosticLog.log("MANUAL \"\(word)\" DEBOUNCED dt=\(String(format: "%.2f", dt))")
            return nil
        }
        lastManualSwitchAt = Date()

        // Right after an auto-correction the manual trigger just undoes it — and
        // teaches the dictionary to leave that word alone next time. generation
        // must still match: any keystroke or click since the correction means the
        // user is acting on new text, not undoing the old one, so fall through to
        // a genuine manual switch of the current word instead.
        if let last = lastCorrection, last.generation == tap.inputGeneration,
           Date().timeIntervalSince(last.at) < 5.0 {
            lastCorrection = nil
            let slow = focusNeedsSlowInjection()
            logFocusForReplacement()
            // Slow (Spotlight-class) fields: atomic AX edit first, backspaces only if it fails.
            if !(slow && tryAXReplace(original: last.corrected, corrected: last.original,
                                      separator: last.separator, targetLayout: last.fromLayout)) {
                layoutSwitcher.replaceLastWord(original: last.corrected, corrected: last.original,
                                               separator: last.separator, targetLayout: last.fromLayout, slowInjection: slow)
            }
            scheduleReplacementVerify()
            if SettingsStore.shared.adaptiveLearning { SettingsStore.shared.learnKeep(last.original) }
            DiagnosticLog.log("MANUAL UNDO \"\(last.corrected)\"→\"\(last.original)\" app=\(frontApp())")
            hud.show(last.fromLayout.hudLabel)
            playSwitchSound()
            return last.original
        }

        // A genuine manual switch. We intentionally do NOT auto-learn a forced
        // layout here: it proved dangerous (one stray switch taught "привет"→en
        // and then forced it every time). Only undo→keep learning remains.
        let targetLayout = layoutSwitcher.currentLayout.opposite
        let corrected = classifier.correct(word: word, targetLayout: targetLayout)
        DiagnosticLog.log("MANUAL \"\(word)\"→\"\(corrected)\" \(targetLayout.short) sep=\(separator.map(String.init) ?? "·") app=\(frontApp())")
        let slow = focusNeedsSlowInjection()
        logFocusForReplacement()
        // Slow (Spotlight-class) fields: atomic AX edit first, backspaces only if it fails.
        if !(slow && tryAXReplace(original: word, corrected: corrected,
                                  separator: separator, targetLayout: targetLayout)) {
            layoutSwitcher.replaceLastWord(original: word, corrected: corrected,
                                           separator: separator, targetLayout: targetLayout, slowInjection: slow)
        }
        scheduleReplacementVerify()
        // Repeated identical manual fixes hint the user wants this word forced —
        // note it (offer, never auto-add; surfaced via the menu).
        if SettingsStore.shared.adaptiveLearning,
           SettingsStore.shared.noteManualSwitch(original: word, layout: targetLayout) {
            DiagnosticLog.log("SUGGEST \"\(word)\" → \(targetLayout.short)")
        }
        SettingsStore.shared.incrementSwitchCount()
        updateStatsItem()
        hud.show(targetLayout.hudLabel)
        playSwitchSound()
        return corrected
    }

    func eventTap(_ tap: EventTap, substituteDeletingLast deleteCount: Int, with text: String) {
        layoutSwitcher.substitute(deleteCount: deleteCount, with: text)
    }

    func eventTapDidRequestConvertSelection(_ tap: EventTap) {
        guard let classifier else { return }
        let flip: (String) -> String = { classifier.flip($0) }

        // A real selection → convert it, exactly as before.
        if let caret = axCaret(), caret.length > 0 {
            convertSelection(transform: flip, hudLabel: "RU/EN", sound: true)
            return
        }

        // No selection → convert the just-typed word(s). Repeated presses within
        // the window extend the span; any keystroke since (changed generation) or a
        // lapsed window starts a fresh single-word run.
        let now = Date()
        let uninterrupted = tap.inputGeneration == convertTypedGeneration
        if uninterrupted, now.timeIntervalSince(lastConvertTypedAt) <= Self.convertTypedWindow {
            convertTypedWordCount += 1
        } else {
            convertTypedWordCount = 1
        }
        lastConvertTypedAt = now
        convertTypedGeneration = tap.inputGeneration

        if axConvertTyped(wordCount: convertTypedWordCount, flip: flip) {
            hud.show("RU/EN")
            playSwitchSound()
            return
        }

        // AX unavailable (e.g. a field that doesn't expose its value): select the
        // last word with ⇧⌥← and run the copy→flip→paste path. Single word only.
        DiagnosticLog.log("CONVERTTYPED fallback")
        convertTypedWordCount = 0  // no extend across the fallback path
        layoutSwitcher.selectWordLeft()
        convertSelection(transform: flip, hudLabel: "RU/EN", sound: true)
    }

    func eventTapDidRequestSmartQuotes(_ tap: EventTap) {
        convertSelection(transform: { self.quotify($0) }, hudLabel: "«»", sound: false)
    }

    /// Copies the selection, applies `transform`, and pastes the result back,
    /// restoring the clipboard afterwards. Does nothing if nothing is selected or
    /// the transform is a no-op.
    private func convertSelection(transform: @escaping (String) -> String, hudLabel: String, sound: Bool) {
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            let saved = pb.string(forType: .string)
            let savedChange = pb.changeCount

            self.layoutSwitcher.sendCommand(keyCode: 0x08)  // ⌘C
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard pb.changeCount != savedChange,
                      let selected = pb.string(forType: .string), !selected.isEmpty else {
                    // ⌘C may have already overwritten the clipboard even though
                    // there was nothing to convert — put the user's data back.
                    if pb.changeCount != savedChange {
                        pb.clearContents()
                        if let saved { pb.setString(saved, forType: .string) }
                    }
                    return
                }
                let converted = transform(selected)
                guard converted != selected else {
                    pb.clearContents()
                    if let saved { pb.setString(saved, forType: .string) }
                    return
                }

                pb.clearContents()
                pb.setString(converted, forType: .string)
                self.layoutSwitcher.sendCommand(keyCode: 0x09)  // ⌘V
                self.hud.show(hudLabel)
                if sound { self.playSwitchSound() }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    pb.clearContents()
                    if let saved { pb.setString(saved, forType: .string) }
                }
            }
        }
    }

    /// Replaces straight double quotes with paired «ёлочки» by context: opening «
    /// after whitespace/start/an opening bracket/a dash, otherwise closing ».
    private func quotify(_ text: String) -> String {
        let chars = Array(text)
        let opensAfter: Set<Character> = ["(", "[", "{", "\u{2014}", "\u{2013}", "-"]
        var out = [Character]()
        out.reserveCapacity(chars.count)
        for (i, ch) in chars.enumerated() {
            guard ch == "\"" else { out.append(ch); continue }
            let prev: Character? = i > 0 ? chars[i - 1] : nil
            let opening = prev.map { $0.isWhitespace || opensAfter.contains($0) } ?? true
            out.append(opening ? "\u{00AB}" : "\u{00BB}")
        }
        return String(out)
    }
}

// MARK: - Diagnostic log

/// Opt-in local log of switching decisions, written off the main thread to
/// ~/Library/Logs/linotype/linotype.log. Used to diagnose real-world issues over
/// time. Never logs secure fields or excluded apps (those paths bail earlier).
enum DiagnosticLog {

    private static let queue = DispatchQueue(label: "com.linotype.diaglog", qos: .utility)
    private static let maxBytes: UInt64 = 12 * 1024 * 1024

    // Kept open across writes (open/seek/close per line is wasteful). Only ever
    // touched on `queue`, so no extra locking; closed and reopened on rotation.
    private static var handle: FileHandle?

    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Logs/linotype", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("linotype.log")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard SettingsStore.shared.diagnosticLogging else { return }
        let now = Date()
        let msg = message()
        queue.async {
            rotateIfNeeded()
            let line = formatter.string(from: now) + " " + msg + "\n"
            guard let data = line.data(using: .utf8) else { return }
            if handle == nil { handle = openHandle() }
            handle?.write(data)
        }
    }

    /// Opens (creating if needed) the log for appending. The log stores every
    /// typed word, so it is kept readable by the owner only.
    private static func openHandle() -> FileHandle? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        } else {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
        guard let h = try? FileHandle(forWritingTo: fileURL) else { return nil }
        h.seekToEndOfFile()
        return h
    }

    /// Blocks until all queued lines hit the file. Only needed at termination,
    /// where pending async writes would otherwise be lost to process exit.
    static func flush() {
        queue.sync {}
    }

    /// Rotates to one .old backup once the log passes the size cap.
    private static func rotateIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? UInt64,
              size > maxBytes else { return }
        try? handle?.close()
        handle = nil
        let backup = fileURL.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
        // Mark the fresh file directly through the new handle — going through
        // log() would re-enter the queue.
        handle = openHandle()
        if let data = (formatter.string(from: Date()) + " LOG rotated\n").data(using: .utf8) {
            handle?.write(data)
        }
    }
}
