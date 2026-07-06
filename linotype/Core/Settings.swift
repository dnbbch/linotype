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
        static let manualSwitchCounts = "manualSwitchCounts"
        static let pendingSuggestions = "pendingSuggestions"
        static let dismissedSuggestions = "dismissedSuggestions"
        static let didOnboard = "didOnboard"
        static let switchesRuToEn = "switchesRuToEn"
        static let switchesEnToRu = "switchesEnToRu"
        static let keystrokesSaved = "keystrokesSaved"
        static let correctedWordCounts = "correctedWordCounts"
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

    // MARK: - Re-learning suggestions

    /// Number of manual switches needed before we offer to remember a word.
    private static let suggestThreshold = 3
    /// Cap on pending suggestions surfaced in the menu (keep it unobtrusive).
    private static let maxPendingSuggestions = 5

    /// How many times each "<word>|<ru|en>" was manually switched, so a repeated
    /// intent can be recognized. Never a decision on its own — only a nudge.
    private var manualSwitchCounts: [String: Int] {
        get { (d.dictionary(forKey: Keys.manualSwitchCounts) as? [String: Int]) ?? [:] }
        set { d.set(newValue, forKey: Keys.manualSwitchCounts) }
    }

    /// Words we're offering to add to the dictionary: lowercased word → "ru"/"en".
    var pendingSuggestions: [String: String] {
        get { (d.dictionary(forKey: Keys.pendingSuggestions) as? [String: String]) ?? [:] }
        set { d.set(newValue, forKey: Keys.pendingSuggestions) }
    }

    /// Words the user rejected, so we don't nag with the same suggestion again.
    private var dismissedSuggestions: Set<String> {
        get { Set((d.array(forKey: Keys.dismissedSuggestions) as? [String]) ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: Keys.dismissedSuggestions) }
    }

    /// Records a manual switch of `original` to `layout`. Returns true only on the
    /// press that crosses the threshold and queues a fresh suggestion — the caller
    /// logs it. Words already learned, excluded, or previously dismissed are never
    /// suggested. The key is the RAW typed word: that's what didCompleteWord looks
    /// up in learnedLayout, so accepting a suggestion must force that exact form.
    @discardableResult
    func noteManualSwitch(original: String, layout: Language) -> Bool {
        let word = original.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return false }
        if learnedLayout[word] != nil || wordExceptions.contains(word)
            || dismissedSuggestions.contains(word) { return false }

        let key = "\(word)|\(layout.short)"
        var counts = manualSwitchCounts
        let n = (counts[key] ?? 0) + 1
        counts[key] = n
        manualSwitchCounts = counts
        guard n >= Self.suggestThreshold else { return false }

        var pending = pendingSuggestions
        if pending[word] == layout.short { return false }  // already queued
        pending[word] = layout.short
        // Keep only the most recent handful — drop the lexicographically-first
        // extras deterministically once over the cap.
        while pending.count > Self.maxPendingSuggestions {
            if let drop = pending.keys.sorted().first { pending[drop] = nil } else { break }
        }
        pendingSuggestions = pending
        return true
    }

    /// Accepts a pending suggestion: forces that word's layout and clears its
    /// counter so it won't re-trip.
    func acceptSuggestion(_ word: String) {
        let w = word.lowercased()
        guard let lang = pendingSuggestions[w] else { return }
        var m = learnedLayout; m[w] = lang; learnedLayout = m
        clearSuggestion(w)
    }

    /// Dismisses a pending suggestion without adding it, remembering the rejection.
    func dismissSuggestion(_ word: String) {
        let w = word.lowercased()
        var dismissed = dismissedSuggestions; dismissed.insert(w); dismissedSuggestions = dismissed
        clearSuggestion(w)
    }

    private func clearSuggestion(_ word: String) {
        var pending = pendingSuggestions; pending[word] = nil; pendingSuggestions = pending
        var counts = manualSwitchCounts
        counts["\(word)|ru"] = nil
        counts["\(word)|en"] = nil
        manualSwitchCounts = counts
    }

    // MARK: - Onboarding

    /// Whether the first-run Accessibility onboarding has been shown.
    var didOnboard: Bool {
        get { d.bool(forKey: Keys.didOnboard) }
        set { d.set(newValue, forKey: Keys.didOnboard) }
    }

    var switchCount: Int {
        get { d.integer(forKey: Keys.switchCount) }
        set { d.set(newValue, forKey: Keys.switchCount) }
    }

    func incrementSwitchCount() {
        switchCount += 1
    }

    // MARK: - Statistics

    /// Cap on the corrected-word histogram so it can't grow unbounded.
    private static let maxCorrectedWords = 50

    var switchesRuToEn: Int { get { d.integer(forKey: Keys.switchesRuToEn) } set { d.set(newValue, forKey: Keys.switchesRuToEn) } }
    var switchesEnToRu: Int { get { d.integer(forKey: Keys.switchesEnToRu) } set { d.set(newValue, forKey: Keys.switchesEnToRu) } }

    /// Rough count of keystrokes the user didn't have to redo — one corrected word
    /// would otherwise have been deleted and retyped, so its length is the saving.
    var keystrokesSaved: Int { get { d.integer(forKey: Keys.keystrokesSaved) } set { d.set(newValue, forKey: Keys.keystrokesSaved) } }

    /// How often each corrected result appeared, for a "top fixed words" list.
    var correctedWordCounts: [String: Int] {
        get { (d.dictionary(forKey: Keys.correctedWordCounts) as? [String: Int]) ?? [:] }
        set { d.set(newValue, forKey: Keys.correctedWordCounts) }
    }

    /// Records one automatic correction: direction, keystrokes saved, and the word.
    /// Auto-corrections only — manual switches and silent ёфикация stay out so the
    /// numbers reflect what the model did unprompted.
    func recordCorrection(from: Language, to: Language, corrected: String) {
        if from == .ru && to == .en { switchesRuToEn += 1 }
        else if from == .en && to == .ru { switchesEnToRu += 1 }

        keystrokesSaved += corrected.count

        let word = corrected.lowercased()
        var counts = correctedWordCounts
        counts[word, default: 0] += 1
        // Prune to the top N by count so the map stays bounded.
        if counts.count > Self.maxCorrectedWords {
            let keep = counts.sorted { $0.value > $1.value }.prefix(Self.maxCorrectedWords)
            counts = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        correctedWordCounts = counts
    }

    /// Clears every statistic, including the plain switch counter.
    func resetStatistics() {
        switchCount = 0
        switchesRuToEn = 0
        switchesEnToRu = 0
        keystrokesSaved = 0
        correctedWordCounts = [:]
    }
}
