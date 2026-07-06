import Foundation

extension Notification.Name {
    /// Posted when settings change and the app needs to re-apply them.
    static let linotypeSettingsChanged = Notification.Name("LinotypeSettingsChanged")
}

/// Persistent app settings, backed by UserDefaults.
final class SettingsStore {

    static let shared = SettingsStore()
    private let d = UserDefaults.standard

    private enum Keys {
        static let autoSwitch = "autoSwitchEnabled"
        static let threshold = "confidenceThreshold"
        static let excludedApps = "excludedBundleIDs"
        static let wordExceptions = "wordExceptions"
        static let switchCount = "switchCount"
        static let showHUD = "showHUD"
        static let smartDashes = "smartDashes"
        static let manualTrigger = "manualTrigger"
        static let switchSound = "switchSound"
        static let smartYo = "smartYo"
        static let adaptiveLearning = "adaptiveLearning"
        static let learnedLayout = "learnedLayout"
        static let diagnosticLogging = "diagnosticLogging"
    }

    /// What triggers a manual switch of the last word.
    enum ManualTrigger: Int {
        case doubleShift = 0
        case doubleOption = 1
        case singleOption = 2
    }

    /// Apps where interception is off by default (terminals, IDEs).
    static let defaultExclusions: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.microsoft.VSCode",
        "com.jetbrains.intellij",
        "com.jetbrains.AppCode",
        "com.sublimetext.4",
        "com.panic.Nova",
        "com.apple.dt.Xcode",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
    ]

    var autoSwitchEnabled: Bool {
        get { d.object(forKey: Keys.autoSwitch) == nil ? true : d.bool(forKey: Keys.autoSwitch) }
        set { d.set(newValue, forKey: Keys.autoSwitch) }
    }

    /// Confidence required for an automatic switch (clamped to 0.70...0.99).
    var confidenceThreshold: Double {
        get {
            let v = d.double(forKey: Keys.threshold)
            return v == 0 ? 0.85 : min(max(v, 0.70), 0.99)
        }
        set { d.set(min(max(newValue, 0.70), 0.99), forKey: Keys.threshold) }
    }

    /// Show the РУ/EN HUD on a switch (default on).
    var showHUD: Bool {
        get { d.object(forKey: Keys.showHUD) == nil ? true : d.bool(forKey: Keys.showHUD) }
        set { d.set(newValue, forKey: Keys.showHUD) }
    }

    /// Smart dashes: digit-digit → en dash, space-hyphen-space → em dash (default off).
    var smartDashes: Bool {
        get { d.bool(forKey: Keys.smartDashes) }
        set { d.set(newValue, forKey: Keys.smartDashes) }
    }

    var manualTrigger: ManualTrigger {
        get { ManualTrigger(rawValue: d.integer(forKey: Keys.manualTrigger)) ?? .doubleShift }
        set { d.set(newValue.rawValue, forKey: Keys.manualTrigger) }
    }

    /// Soft sound on a switch (default off).
    var switchSound: Bool {
        get { d.bool(forKey: Keys.switchSound) }
        set { d.set(newValue, forKey: Keys.switchSound) }
    }

    /// Place ё in unambiguous words (default off).
    var smartYo: Bool {
        get { d.bool(forKey: Keys.smartYo) }
        set { d.set(newValue, forKey: Keys.smartYo) }
    }

    var excludedBundleIDs: Set<String> {
        get {
            if let arr = d.array(forKey: Keys.excludedApps) as? [String] { return Set(arr) }
            return Self.defaultExclusions
        }
        set { d.set(Array(newValue).sorted(), forKey: Keys.excludedApps) }
    }

    /// Words never corrected automatically (stored lowercased).
    var wordExceptions: Set<String> {
        get { Set((d.array(forKey: Keys.wordExceptions) as? [String]) ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: Keys.wordExceptions) }
    }

    func isWordExcluded(_ word: String) -> Bool {
        wordExceptions.contains(word.lowercased())
    }

    func addWordException(_ word: String) {
        let w = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        var s = wordExceptions
        s.insert(w)
        wordExceptions = s
    }

    // MARK: - Personal dictionary (learned from manual corrections)

    /// Learn from the user's manual corrections and undos (default on).
    var adaptiveLearning: Bool {
        get { d.object(forKey: Keys.adaptiveLearning) == nil ? true : d.bool(forKey: Keys.adaptiveLearning) }
        set { d.set(newValue, forKey: Keys.adaptiveLearning) }
    }

    /// Write a local diagnostic log of switching decisions (default off).
    var diagnosticLogging: Bool {
        get { d.bool(forKey: Keys.diagnosticLogging) }
        set { d.set(newValue, forKey: Keys.diagnosticLogging) }
    }

    /// Words the user always wants in a specific layout: lowercased word → "ru"/"en".
    var learnedLayout: [String: String] {
        get { (d.dictionary(forKey: Keys.learnedLayout) as? [String: String]) ?? [:] }
        set { d.set(newValue, forKey: Keys.learnedLayout) }
    }

    func learnedLanguage(for word: String) -> Language? {
        switch learnedLayout[word.lowercased()] {
        case "ru": return .ru
        case "en": return .en
        default: return nil
        }
    }

    /// Remembers that `word` should never be auto-corrected (drops any learned
    /// layout for it).
    func learnKeep(_ word: String) {
        let w = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        addWordException(w)
        if learnedLayout[w] != nil {
            var m = learnedLayout; m[w] = nil; learnedLayout = m
        }
    }

    var switchCount: Int {
        get { d.integer(forKey: Keys.switchCount) }
        set { d.set(newValue, forKey: Keys.switchCount) }
    }

    func incrementSwitchCount() {
        switchCount += 1
    }
}
