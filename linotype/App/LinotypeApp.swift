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

    // Last auto-correction, so a manual trigger right after can undo it.
    private var lastCorrection: (original: String, corrected: String,
                                 separator: Character?, fromLayout: Language, at: Date)?

    // MARK: - Lifecycle

    static func main() {
        let app = NSApplication.shared
        let delegate = LinotypeApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // no Dock icon
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupComponents()
        ensureAccessibilityAndStart()
        setupLoginItem()

        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: .linotypeSettingsChanged, object: nil)
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

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Запускать при входе", action: #selector(toggleLaunchAtLogin), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit linotype", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        hud.statusItem = statusItem
        updateStatsItem()
    }

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
        guard let menu = statusItem.menu, let toggleItem = menu.item(withTag: 1) else { return }
        toggleItem.state = isEnabled ? .on : .off
        // Dim the icon while disabled or waiting for permission.
        let active = isEnabled && (eventTap?.isRunning == true)
        statusItem.button?.alphaValue = active ? 1.0 : 0.4
        updateStatsItem()
    }

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        if isEnabled { ensureAccessibilityAndStart() } else { eventTap?.stop() }
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
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)

        tryStartTap()
        guard eventTap?.isRunning != true else { return }

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.tryStartTap()
            if self.eventTap?.isRunning == true {
                timer.invalidate()
                self.permissionTimer = nil
            }
            self.updateMenuState()
        }
    }

    private func tryStartTap() {
        guard isEnabled, eventTap?.isRunning == false else { return }
        try? eventTap?.start()
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

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - EventTapDelegate

extension LinotypeApp: EventTapDelegate {

    // The delegate runs on the main run loop (the tap source is on main). CoreML
    // inference is fast (<1 ms) and TIS APIs (layout) MUST run on main — so all of
    // this stays synchronous here; nothing is dispatched off-main.

    func eventTap(_ tap: EventTap, didCompleteWord word: String, separator: Character,
                  precededBy preceding: (word: String, separator: Character)?) {
        guard isEnabled, let classifier else { return }
        if SettingsStore.shared.isWordExcluded(word) { return }

        guard let (lang, confidence) = try? classifier.classify(word: word) else { return }
        let current = layoutSwitcher.currentLayout
        let confident = confidence >= SettingsStore.shared.confidenceThreshold
        let needSwitch = (lang != current && confident)

        // A single-letter word right before this one, typed in the same layout as
        // `word`, switches together with it — e.g. "d ljvt" → "в доме". Also covers
        // the case where `word` was already early-switched (needSwitch is false then,
        // but the leftover single letter still needs fixing).
        var prevFix: (sep: Character, fixed: String)?
        if let prev = preceding, prev.word.count == 1, confident {
            let pf = classifier.correct(word: prev.word, targetLayout: lang)
            if pf != prev.word { prevFix = (prev.separator, pf) }
        }

        if needSwitch {
            var corrected = classifier.correct(word: word, targetLayout: lang)
            // Apply ёфикация after the switch too: "tot" → "еще" → "ещё".
            if SettingsStore.shared.smartYo, let yo = yoficator.yoify(corrected) { corrected = yo }

            if let pv = prevFix {
                replaceWithPreceding(word, corrected, separator, pv, targetLayout: lang)
            } else {
                layoutSwitcher.replaceLastWord(original: word, corrected: corrected,
                                               separator: separator, targetLayout: lang)
                lastCorrection = (word, corrected, separator, current, Date())
            }
            announceSwitch(lang)
            return
        }

        // `word` itself is fine, but a single letter left over from an early switch
        // may still need fixing.
        if let pv = prevFix {
            var keep = word
            if SettingsStore.shared.smartYo, let yo = yoficator.yoify(keep) { keep = yo }
            replaceWithPreceding(word, keep, separator, pv, targetLayout: lang)
            announceSwitch(lang)
            return
        }

        // ёфикация only.
        if SettingsStore.shared.smartYo, let yo = yoficator.yoify(word) {
            lastCorrection = nil
            layoutSwitcher.replaceLastWord(original: word, corrected: yo,
                                           separator: separator, targetLayout: current)
        }
    }

    /// Replaces a single-letter preceding word together with the current one.
    private func replaceWithPreceding(_ word: String, _ corrected: String, _ separator: Character,
                                      _ prev: (sep: Character, fixed: String), targetLayout: Language) {
        let deleteCount = 1 + 1 + word.count + 1  // prev letter + its sep + word + sep
        let combined = prev.fixed + String(prev.sep) + corrected + String(separator)
        layoutSwitcher.replaceWordImmediately(deleteCount: deleteCount, corrected: combined, targetLayout: targetLayout)
        lastCorrection = nil
    }

    private func announceSwitch(_ lang: Language) {
        SettingsStore.shared.incrementSwitchCount()
        updateStatsItem()
        hud.show(lang.hudLabel)
        playSwitchSound()
    }

    func eventTap(_ tap: EventTap, earlyCheckpoint word: String) -> String? {
        guard isEnabled, let classifier else { return nil }
        if SettingsStore.shared.isWordExcluded(word) { return nil }

        guard let (lang, confidence) = try? classifier.classify(word: word) else { return nil }
        let current = layoutSwitcher.currentLayout
        // High bar (per sensitivity): only switch mid-word when confident enough.
        guard lang != current, confidence >= SettingsStore.shared.earlySwitchSensitivity.confidence else { return nil }

        var corrected = classifier.correct(word: word, targetLayout: lang)
        if SettingsStore.shared.smartYo, let yo = yoficator.yoify(corrected) { corrected = yo }
        // Synchronous + tight HID injection so the layout flips and the prefix is
        // rewritten before the next keystroke lands (avoids mid-word garbage).
        layoutSwitcher.replaceWordImmediately(deleteCount: word.count, corrected: corrected,
                                              targetLayout: lang, tight: true)
        lastCorrection = (word, corrected, nil, current, Date())
        SettingsStore.shared.incrementSwitchCount()
        updateStatsItem()
        hud.show(lang.hudLabel)
        playSwitchSound()
        return corrected
    }

    func eventTap(_ tap: EventTap, didReceiveDoubleShift word: String, separator: Character?) {
        guard let classifier else { return }

        // Right after an auto-correction the manual trigger just undoes it.
        if let last = lastCorrection, Date().timeIntervalSince(last.at) < 5.0 {
            lastCorrection = nil
            layoutSwitcher.replaceLastWord(original: last.corrected, corrected: last.original,
                                           separator: last.separator, targetLayout: last.fromLayout)
            hud.show(last.fromLayout.hudLabel)
            playSwitchSound()
            return
        }

        let targetLayout = layoutSwitcher.currentLayout.opposite
        let corrected = classifier.correct(word: word, targetLayout: targetLayout)
        layoutSwitcher.replaceLastWord(original: word, corrected: corrected,
                                       separator: separator, targetLayout: targetLayout)
        SettingsStore.shared.incrementSwitchCount()
        updateStatsItem()
        hud.show(targetLayout.hudLabel)
        playSwitchSound()
    }

    func eventTap(_ tap: EventTap, substituteDeletingLast deleteCount: Int, with text: String) {
        layoutSwitcher.substitute(deleteCount: deleteCount, with: text)
    }

    func eventTapDidRequestConvertSelection(_ tap: EventTap) {
        guard let classifier else { return }
        convertSelection(transform: { classifier.flip($0) }, hudLabel: "RU/EN", sound: true)
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
                      let selected = pb.string(forType: .string), !selected.isEmpty else { return }
                let converted = transform(selected)
                guard converted != selected else { return }

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
