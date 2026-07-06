import Cocoa
import ServiceManagement

/// Settings window: a flat (non-vibrant) sidebar of sections on the left,
/// grouped outline cards on the right. Orange accent.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    /// Brand accent (orange, matches the icon).
    static let accent = NSColor(red: 0.96, green: 0.51, blue: 0.12, alpha: 1)

    private struct Section { let title: String; let symbol: String; let build: () -> NSView }

    private var sections: [Section] = []
    private var sidebarItems: [SidebarItem] = []
    private var contentScroll: NSScrollView!
    private var selectedIndex = -1

    // Exception table editors, cached so they can be saved on close / section switch.
    private weak var wordsEditor: WordListEditor?
    private weak var appsEditor: AppListEditor?
    private weak var learnedEditor: LearnedEditor?
    private var cachedSections: [Int: NSView] = [:]

    // MARK: - Init

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Настройки linotype"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self

        sections = [
            Section(title: "Общие", symbol: "gearshape", build: { [weak self] in self?.generalSection() ?? NSView() }),
            Section(title: "Переключение", symbol: "keyboard", build: { [weak self] in self?.switchingSection() ?? NSView() }),
            Section(title: "Текст", symbol: "textformat", build: { [weak self] in self?.textSection() ?? NSView() }),
            Section(title: "Исключения", symbol: "nosign", build: { [weak self] in self?.exceptionsSection() ?? NSView() }),
            Section(title: "Статистика", symbol: "chart.bar", build: { [weak self] in self?.statsSection() ?? NSView() }),
        ]
        buildLayout()
        select(0)
        window.center()
    }

    // MARK: - Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        // Flat sidebar — a plain view, no vibrancy.
        let sidebar = NSView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)

        // Thin vertical divider between sidebar and content.
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(divider)

        let sidebarStack = NSStackView()
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 2
        sidebarStack.edgeInsets = NSEdgeInsets(top: 16, left: 10, bottom: 16, right: 10)
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarStack)

        for (i, section) in sections.enumerated() {
            let item = SidebarItem(title: section.title, symbol: section.symbol) { [weak self] in
                self?.select(i)
            }
            sidebarItems.append(item)
            sidebarStack.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor, constant: -20).isActive = true
        }

        // Version label at the bottom of the sidebar.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let footer = NSTextField(labelWithString: "linotype v\(version)")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(footer)

        contentScroll = NSScrollView()
        contentScroll.hasVerticalScroller = true
        contentScroll.drawsBackground = false
        contentScroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(contentScroll)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 200),

            sidebarStack.topAnchor.constraint(equalTo: sidebar.topAnchor),
            sidebarStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),

            footer.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            footer.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -16),

            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: content.topAnchor),
            divider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            contentScroll.topAnchor.constraint(equalTo: content.topAnchor),
            contentScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            contentScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            contentScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            // Deterministic content size: the sidebar and scroll only follow the
            // window height, they don't define it, so without this the window's
            // fitting height is ~0 and it collapses to the title bar.
            contentScroll.widthAnchor.constraint(equalToConstant: 519),
            contentScroll.heightAnchor.constraint(equalToConstant: 520),
        ])
    }

    private func select(_ index: Int) {
        guard index != selectedIndex else { return }
        saveExceptions()  // persist if leaving the exceptions section
        selectedIndex = index
        for (i, item) in sidebarItems.enumerated() { item.isSelected = (i == index) }

        let view = cachedSections[index] ?? sections[index].build()
        cachedSections[index] = view

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: doc.topAnchor, constant: 28),
            view.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 28),
            view.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -28),
            view.bottomAnchor.constraint(lessThanOrEqualTo: doc.bottomAnchor, constant: -28),
        ])
        contentScroll.documentView = doc
        doc.widthAnchor.constraint(equalTo: contentScroll.widthAnchor).isActive = true
    }

    // MARK: - Sections

    private func generalSection() -> NSView {
        let s = SettingsStore.shared
        return verticalStack([
            group("Основное", [
                toggleRow("Автопереключение раскладки", s.autoSwitchEnabled) { s.autoSwitchEnabled = $0; self.notifyChanged() },
                toggleRow("Запускать при входе в систему", loginEnabled()) { self.setLogin($0) },
            ]),
            group("Уведомления", [
                toggleRow("Показывать плашку РУ/EN", s.showHUD) { s.showHUD = $0 },
                toggleRow("Мягкий звук при переключении", s.switchSound) { s.switchSound = $0 },
            ]),
            group("Диагностика", [
                toggleRow("Вести журнал (для отладки)", s.diagnosticLogging) { s.diagnosticLogging = $0 },
                controlRow("Файл журнала", revealLogButton()),
            ], hint: "Журнал записывает набираемые слова и решения переключения — это помогает находить проблемы. Пароли (защищённые поля) и исключённые приложения не записываются. Файл хранится только на этом Mac; журнал можно выключить и удалить в любой момент."),
        ])
    }

    /// Confidence presets: label → threshold. Plain words beat a raw 0.70–0.99
    /// slider whose scale meant nothing to users.
    private static let thresholdPresets: [(title: String, value: Double)] =
        [("Осторожный", 0.95), ("Обычный", 0.85), ("Агрессивный", 0.75)]

    private func switchingSection() -> NSView {
        let s = SettingsStore.shared
        let popup = NSPopUpButton()
        popup.addItems(withTitles: ["Двойной Shift", "Двойной Option", "Одиночный Option"])
        popup.selectItem(at: s.manualTrigger.rawValue)
        popup.action = #selector(triggerChanged(_:))
        popup.target = self

        let presets = NSSegmentedControl(
            labels: Self.thresholdPresets.map { $0.title },
            trackingMode: .selectOne, target: self, action: #selector(thresholdPresetChanged(_:)))
        presets.selectedSegment = nearestPresetIndex(to: s.confidenceThreshold)
        thresholdValueLabel.stringValue = String(format: "%.2f", s.confidenceThreshold)

        return verticalStack([
            group("Переключение", [
                controlRow("Ручное переключение слова", popup),
            ], hint: "Двойной Shift — самый надёжный. Одиночный Option иногда конфликтует с системными сочетаниями."),
            group("Точность", [
                controlRow("Порог уверенности", stack([thresholdValueLabel, presets], spacing: 10)),
            ], hint: "«Осторожный» реже ошибается, «Агрессивный» переключает активнее. Показано текущее значение порога."),
            group("Обучение", [
                toggleRow("Учиться на моих исправлениях", s.adaptiveLearning) { s.adaptiveLearning = $0 },
            ], hint: "Отменяешь автозамену или переключаешь слово вручную — linotype запоминает. Выученное видно и редактируется в разделе «Исключения»."),
        ])
    }

    /// Index of the preset whose value is closest to `threshold`.
    private func nearestPresetIndex(to threshold: Double) -> Int {
        var best = 0, bestDist = Double.greatestFiniteMagnitude
        for (i, preset) in Self.thresholdPresets.enumerated() {
            let dist = abs(preset.value - threshold)
            if dist < bestDist { bestDist = dist; best = i }
        }
        return best
    }

    private func textSection() -> NSView {
        let s = SettingsStore.shared
        return verticalStack([
            group("Автозамена", [
                toggleRow("Умные тире (5-10 → 5–10, « - » → « — »)", s.smartDashes) { s.smartDashes = $0 },
                toggleRow("Ёфикация (ёлка, актёр…)", s.smartYo) { s.smartYo = $0 },
            ], hint: "Ёфикация ставит ё только в однозначных словах; неоднозначные (все/всё) не трогаются."),
            group("Горячие клавиши", [
                shortcutRow("Перекодировать выделенное (ru↔en)", "⌘⌥L"),
                shortcutRow("Кавычки в выделении → «ёлочки»", "⌘⌥'"),
            ], hint: "Выдели текст и нажми сочетание. Прямые \"кавычки\" заменятся на парные «ёлочки»."),
        ])
    }

    private func exceptionsSection() -> NSView {
        let s = SettingsStore.shared
        // Structured table editors — the old raw-text format silently mangled input.
        // Each editor owns its own table + data source and persists via saveExceptions().
        let words = WordListEditor(words: s.wordExceptions.sorted(), onChange: { [weak self] in self?.notifyChanged() })
        wordsEditor = words

        let learned = LearnedEditor(entries: s.learnedLayout.sorted { $0.key < $1.key },
                                    onChange: { [weak self] in self?.notifyChanged() })
        learnedEditor = learned

        let apps = AppListEditor(bundleIDs: s.excludedBundleIDs.sorted(), onChange: { [weak self] in self?.notifyChanged() })
        apps.addAppAction = { [weak self] in self?.addApp() }
        appsEditor = apps

        return verticalStack([
            groupHeader("Слова, которые не исправлять"),
            words,
            groupHeader("Всегда переключать — выучено"),
            learned,
            groupHeader("Приложения, где linotype выключен"),
            apps,
        ])
    }

    private func statsSection() -> NSView {
        let s = SettingsStore.shared
        let ruEn = s.switchesRuToEn
        let enRu = s.switchesEnToRu
        let total = ruEn + enRu
        let maxDir = max(ruEn, enRu, 1)  // bar scale (avoid div-by-zero)

        let reset = NSButton(title: "Сбросить", target: self, action: #selector(resetStats))
        reset.bezelStyle = .rounded

        // Top corrected words, highest count first.
        let top = s.correctedWordCounts.sorted { $0.value > $1.value }.prefix(5)
        let topRows: [NSView] = top.isEmpty
            ? [controlRow("Пока пусто", NSView())]
            : top.map { statValueRow("«\($0.key)»", "\($0.value)") }

        return verticalStack([
            group("Всего исправлений", [
                controlRow("Автозамен", label("\(total)")),
            ]),
            group("По направлениям", [
                barRow(title: "РУ → EN", count: ruEn, max: maxDir),
                barRow(title: "EN → РУ", count: enRu, max: maxDir),
            ]),
            group("Экономия", [
                controlRow("Клавиш не перепечатано", label("≈ \(s.keystrokesSaved)")),
            ], hint: "Оценка: каждое исправленное слово иначе пришлось бы стереть и набрать заново."),
            group("Топ исправляемых слов", topRows),
            reset,
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        l.textColor = .secondaryLabelColor
        return l
    }

    /// A row with a title on the left and a value on the right (like controlRow but
    /// the value is a monospaced count).
    private func statValueRow(_ title: String, _ value: String) -> NSView {
        controlRow(title, label(value))
    }

    /// A direction row: label, a proportional accent bar, and the count.
    private func barRow(title: String, count: Int, max: Int) -> NSView {
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13)
        let bar = BarView(fraction: Double(count) / Double(max))
        bar.widthAnchor.constraint(equalToConstant: 160).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        return controlRow2(name, stack([bar, label("\(count)")], spacing: 10))
    }

    /// Like controlRow but takes a leading view rather than a title string.
    private func controlRow2(_ leading: NSView, _ control: NSView) -> NSView {
        let row = NSView()
        leading.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(leading)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 42),
            leading.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            leading.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private lazy var thresholdValueLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        l.textColor = .secondaryLabelColor
        return l
    }()

    // MARK: - Building blocks

    private func verticalStack(_ views: [NSView]) -> NSView {
        let st = NSStackView(views: views)
        st.orientation = .vertical
        st.alignment = .leading
        st.spacing = 22
        for v in views { v.widthAnchor.constraint(equalTo: st.widthAnchor).isActive = true }
        return st
    }

    private func stack(_ views: [NSView], spacing: CGFloat) -> NSView {
        let st = NSStackView(views: views)
        st.orientation = .horizontal
        st.spacing = spacing
        return st
    }

    /// A group: uppercase header + outline card of rows (+ optional hint below).
    private func group(_ title: String, _ rows: [NSView], hint: String? = nil) -> NSView {
        let header = groupHeader(title)
        let card = card(rows)

        var items: [NSView] = [header, card]
        if let hint = hint { items.append(sectionHint(hint)) }

        let st = NSStackView(views: items)
        st.orientation = .vertical
        st.alignment = .leading
        st.spacing = 7
        card.widthAnchor.constraint(equalTo: st.widthAnchor).isActive = true
        if let hint = items.last, hint !== card {
            hint.widthAnchor.constraint(equalTo: st.widthAnchor).isActive = true
        }
        return st
    }

    /// Outline card: a thin border only, no fill (the window shows through).
    private func card(_ rows: [NSView]) -> NSView {
        let container = CardView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        for (i, row) in rows.enumerated() {
            if i > 0 {
                let sep = NSBox()
                sep.boxType = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(sep)
                sep.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14).isActive = true
                sep.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
            }
            stack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
        return container
    }

    private func toggleRow(_ title: String, _ initial: Bool, _ onChange: @escaping (Bool) -> Void) -> NSView {
        // Native NSSwitch (Liquid Glass on macOS 26). Its on-color comes from the
        // custom AccentColor asset (orange) when the system accent is "Multicolor",
        // otherwise the user's chosen system accent — there is no public API to
        // force an NSSwitch color.
        let sw = NSSwitch()
        sw.state = initial ? .on : .off
        let handler = SwitchHandler(onChange: onChange)
        sw.target = handler
        sw.action = #selector(SwitchHandler.changed(_:))
        objc_setAssociatedObject(sw, &SwitchHandler.key, handler, .OBJC_ASSOCIATION_RETAIN)
        return controlRow(title, sw)
    }

    private func controlRow(_ title: String, _ control: NSView) -> NSView {
        let row = NSView()
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 42),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -12),
        ])
        return row
    }

    private func revealLogButton() -> NSView {
        let b = NSButton(title: "Показать в Finder", target: self, action: #selector(revealLog))
        b.bezelStyle = .rounded
        return b
    }

    @objc private func revealLog() {
        let url = DiagnosticLog.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    /// Shortcut row: description on the left, key combo on the right (monospaced).
    private func shortcutRow(_ title: String, _ keys: String) -> NSView {
        let l = NSTextField(labelWithString: keys)
        l.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        l.textColor = .secondaryLabelColor
        return controlRow(title, l)
    }

    /// Group header — uppercase with light tracking, like System Settings.
    private func groupHeader(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.4,
        ])
        return l
    }

    private func sectionHint(_ text: String) -> NSView {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .tertiaryLabelColor
        l.isEditable = false
        l.isSelectable = false
        l.drawsBackground = false
        l.isBezeled = false
        return l
    }

    // MARK: - Actions

    @objc private func triggerChanged(_ sender: NSPopUpButton) {
        SettingsStore.shared.manualTrigger =
            SettingsStore.ManualTrigger(rawValue: sender.indexOfSelectedItem) ?? .doubleShift
    }

    @objc private func thresholdPresetChanged(_ sender: NSSegmentedControl) {
        let value = Self.thresholdPresets[sender.selectedSegment].value
        SettingsStore.shared.confidenceThreshold = value
        thresholdValueLabel.stringValue = String(format: "%.2f", value)
    }

    @objc private func resetStats() {
        SettingsStore.shared.resetStatistics()
        // Rebuild the stats view so bars/lists reflect the cleared counters.
        cachedSections[4] = nil
        if selectedIndex == 4 { selectedIndex = -1; select(4) }
        notifyChanged()
    }

    @objc private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url,
                  let id = Bundle(url: url)?.bundleIdentifier else { return }
            self?.appsEditor?.addBundleID(id)
        }
    }

    private func saveExceptions() {
        var changed = false
        if let words = wordsEditor {
            SettingsStore.shared.wordExceptions = Set(words.currentWords); changed = true
        }
        if let apps = appsEditor {
            SettingsStore.shared.excludedBundleIDs = Set(apps.currentBundleIDs); changed = true
        }
        if let learned = learnedEditor {
            SettingsStore.shared.learnedLayout = learned.currentEntries; changed = true
        }
        if changed { notifyChanged() }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .linotypeSettingsChanged, object: nil)
    }

    // MARK: - Login item

    private func loginEnabled() -> Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    private func setLogin(_ on: Bool) {
        if #available(macOS 13.0, *) {
            do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { NSSound.beep() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        saveExceptions()
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Sidebar item

private final class SidebarItem: NSView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let onClick: () -> Void
    var isSelected = false { didSet { update() } }

    init(title: String, symbol: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false

        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = title
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon); addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        layer?.backgroundColor = isSelected ? SettingsWindowController.accent.cgColor : NSColor.clear.cgColor
        label.textColor = isSelected ? .white : .labelColor
        icon.contentTintColor = isSelected ? .white : .secondaryLabelColor
    }

    override func mouseDown(with event: NSEvent) { onClick() }
}

// MARK: - Helpers

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Outline settings card: a thin border only, no fill — the window shows
/// through. Re-applies on appearance (light/dark) changes.
private final class CardView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        apply()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    private func apply() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

/// Holds the closure for an NSSwitch (target/action takes no closure directly).
private final class SwitchHandler: NSObject {
    static var key = 0
    let onChange: (Bool) -> Void
    init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }
    @objc func changed(_ sender: NSSwitch) { onChange(sender.state == .on) }
}

/// A thin proportional bar filled with the brand accent. Used for the stats
/// direction breakdown. Re-applies on appearance changes like CardView.
private final class BarView: NSView {
    private let fraction: Double
    init(fraction: Double) {
        self.fraction = max(0, min(1, fraction))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 3
        apply()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() { super.layout(); apply() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); apply() }

    private func apply() {
        layer?.sublayers?.removeAll()
        layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        let fill = CALayer()
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
        fill.cornerRadius = 3
        fill.backgroundColor = SettingsWindowController.accent.cgColor
        layer?.addSublayer(fill)
    }
}

// MARK: - Table editors

/// Shared chrome for the exceptions editors: a bordered table in a scroll view
/// with a ＋/－ segmented control below. Subclasses supply the table columns and
/// data source; edits are surfaced via `onChange`.
private class TableEditor: NSView {
    let table = NSTableView()
    let onChange: () -> Void
    private let scroll = NSScrollView()

    init(height: CGFloat, onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .default
        table.headerView = nil
        table.allowsMultipleSelection = true

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let addRemove = NSSegmentedControl(
            images: [NSImage(systemSymbolName: "plus", accessibilityDescription: "Добавить")!,
                     NSImage(systemSymbolName: "minus", accessibilityDescription: "Удалить")!],
            trackingMode: .momentary, target: self, action: #selector(addRemoveClicked(_:)))
        addRemove.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addRemove)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: height),
            addRemove.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            addRemove.leadingAnchor.constraint(equalTo: leadingAnchor),
            addRemove.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func addRemoveClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { addRow() } else { removeSelectedRows() }
    }

    /// Overridden by subclasses to append a fresh (usually editable) row.
    func addRow() {}

    /// Removes the selected rows from the backing store; subclasses provide it.
    func removeSelectedRows() {}
}

/// Single-column editable list of words never auto-corrected. Words are stored
/// lowercased and trimmed; blank rows are dropped on read.
private final class WordListEditor: TableEditor, NSTableViewDataSource, NSTableViewDelegate {
    private var words: [String]

    var currentWords: [String] {
        words.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    init(words: [String], onChange: @escaping () -> Void) {
        self.words = words
        super.init(height: 120, onChange: onChange)
        let col = NSTableColumn(identifier: .init("word"))
        col.isEditable = true
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func numberOfRows(in tableView: NSTableView) -> Int { words.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = editableField(words[row])
        field.tag = row
        field.target = self
        field.action = #selector(wordEdited(_:))
        return field
    }

    @objc private func wordEdited(_ sender: NSTextField) {
        guard sender.tag < words.count else { return }
        words[sender.tag] = sender.stringValue
        onChange()
    }

    override func addRow() {
        words.append("")
        table.reloadData()
        table.editColumn(0, row: words.count - 1, with: nil, select: true)
    }

    override func removeSelectedRows() {
        for row in table.selectedRowIndexes.sorted(by: >) where row < words.count { words.remove(at: row) }
        table.reloadData()
        onChange()
    }
}

/// Two-column editor for the learned-layout map: word + a РУ/EN segmented control
/// per row. Replaces the fragile "слово ru" text format entirely.
private final class LearnedEditor: TableEditor, NSTableViewDataSource, NSTableViewDelegate {
    private var entries: [(word: String, lang: String)]

    var currentEntries: [String: String] {
        var map = [String: String]()
        for e in entries {
            let w = e.word.lowercased().trimmingCharacters(in: .whitespaces)
            if !w.isEmpty { map[w] = e.lang }
        }
        return map
    }

    init(entries: [(key: String, value: String)], onChange: @escaping () -> Void) {
        self.entries = entries.map { (word: $0.key, lang: $0.value == "en" ? "en" : "ru") }
        super.init(height: 120, onChange: onChange)
        let wordCol = NSTableColumn(identifier: .init("word"))
        wordCol.isEditable = true
        let langCol = NSTableColumn(identifier: .init("lang"))
        langCol.width = 90
        table.addTableColumn(wordCol)
        table.addTableColumn(langCol)
        table.dataSource = self
        table.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableColumn?.identifier.rawValue == "lang" {
            let seg = NSSegmentedControl(labels: ["РУ", "EN"], trackingMode: .selectOne,
                                         target: self, action: #selector(langChanged(_:)))
            seg.selectedSegment = entries[row].lang == "en" ? 1 : 0
            seg.tag = row
            return seg
        }
        let field = editableField(entries[row].word)
        field.tag = row
        field.target = self
        field.action = #selector(wordEdited(_:))
        return field
    }

    @objc private func wordEdited(_ sender: NSTextField) {
        guard sender.tag < entries.count else { return }
        entries[sender.tag].word = sender.stringValue
        onChange()
    }

    @objc private func langChanged(_ sender: NSSegmentedControl) {
        guard sender.tag < entries.count else { return }
        entries[sender.tag].lang = sender.selectedSegment == 1 ? "en" : "ru"
        onChange()
    }

    override func addRow() {
        entries.append((word: "", lang: "ru"))
        table.reloadData()
        table.editColumn(0, row: entries.count - 1, with: nil, select: true)
    }

    override func removeSelectedRows() {
        for row in table.selectedRowIndexes.sorted(by: >) where row < entries.count { entries.remove(at: row) }
        table.reloadData()
        onChange()
    }
}

/// List of excluded bundle IDs. New entries come from the "Добавить приложение…"
/// open panel (which resolves the bundle ID); ＋ triggers that panel too. Each row
/// shows the app's display name (when resolvable) with the bundle ID as subtitle —
/// but the bundle ID stays the source of truth.
private final class AppListEditor: TableEditor, NSTableViewDataSource, NSTableViewDelegate {
    private var bundleIDs: [String]
    var addAppAction: (() -> Void)?

    var currentBundleIDs: [String] { bundleIDs }

    init(bundleIDs: [String], onChange: @escaping () -> Void) {
        self.bundleIDs = bundleIDs
        super.init(height: 120, onChange: onChange)
        let col = NSTableColumn(identifier: .init("app"))
        col.isEditable = false
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func addBundleID(_ id: String) {
        guard !bundleIDs.contains(id) else { return }
        bundleIDs.append(id)
        table.reloadData()
        onChange()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { bundleIDs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = bundleIDs[row]
        let name = appDisplayName(for: id)
        let field = NSTextField(labelWithString: name.map { "\($0)  —  \(id)" } ?? id)
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    /// Best-effort human name for a bundle ID (running app, then a bundle lookup).
    private func appDisplayName(for id: String) -> String? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
           let name = app.localizedName { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
           let bundle = Bundle(url: url) {
            return (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
        }
        return nil
    }

    // ＋ opens the app picker instead of adding a blank row (bundle IDs must resolve).
    override func addRow() { addAppAction?() }

    override func removeSelectedRows() {
        for row in table.selectedRowIndexes.sorted(by: >) where row < bundleIDs.count { bundleIDs.remove(at: row) }
        table.reloadData()
        onChange()
    }
}

/// A borderless editable text field for a table cell.
private func editableField(_ value: String) -> NSTextField {
    let field = NSTextField(string: value)
    field.isBordered = false
    field.drawsBackground = false
    field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    field.isAutomaticTextCompletionEnabled = false
    field.usesSingleLineMode = true
    return field
}
