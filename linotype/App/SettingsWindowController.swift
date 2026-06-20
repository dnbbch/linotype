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

    // Exception text views, cached so they can be saved on close / section switch.
    private weak var wordsView: NSTextView?
    private weak var appsView: NSTextView?
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
        ])
    }

    private func switchingSection() -> NSView {
        let s = SettingsStore.shared
        let popup = NSPopUpButton()
        popup.addItems(withTitles: ["Двойной Shift", "Двойной Option", "Одиночный Option"])
        popup.selectItem(at: s.manualTrigger.rawValue)
        popup.action = #selector(triggerChanged(_:))
        popup.target = self

        let sens = NSPopUpButton()
        sens.addItems(withTitles: ["Осторожно", "Сбалансированно", "Агрессивно"])
        sens.selectItem(at: s.earlySwitchSensitivity.rawValue)
        sens.action = #selector(earlySensitivityChanged(_:))
        sens.target = self

        let slider = NSSlider(value: s.confidenceThreshold, minValue: 0.70, maxValue: 0.99,
                              target: self, action: #selector(thresholdChanged(_:)))
        slider.trackFillColor = SettingsWindowController.accent  // orange fill (native API)
        slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        thresholdValueLabel.stringValue = String(format: "%.2f", s.confidenceThreshold)

        return verticalStack([
            group("Переключение", [
                controlRow("Ручное переключение слова", popup),
                toggleRow("Раннее переключение (по ходу набора)", s.earlySwitchEnabled) { s.earlySwitchEnabled = $0 },
                controlRow("Чувствительность раннего", sens),
            ], hint: "Раннее переключение реагирует ещё до пробела. «Осторожно» — позже и точнее, «Агрессивно» — раньше, но возможны редкие сбои на коротких словах."),
            group("Точность", [
                controlRow("Порог уверенности", stack([thresholdValueLabel, slider], spacing: 10)),
            ], hint: "Выше порог — меньше ложных срабатываний, но и реже автозамена."),
        ])
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
        let (wordsScroll, words) = makeTextView(height: 130)
        words.string = s.wordExceptions.sorted().joined(separator: "\n")
        wordsView = words

        let (appsScroll, apps) = makeTextView(height: 120)
        apps.string = s.excludedBundleIDs.sorted().joined(separator: "\n")
        appsView = apps

        let addAppBtn = NSButton(title: "Добавить приложение…", target: self, action: #selector(addApp))
        addAppBtn.bezelStyle = .rounded

        return verticalStack([
            groupHeader("Слова, которые не исправлять (по одному в строке)"),
            wordsScroll,
            groupHeader("Приложения, где linotype выключен (bundle ID)"),
            appsScroll,
            addAppBtn,
        ])
    }

    private func statsSection() -> NSView {
        let count = SettingsStore.shared.switchCount
        statsLabel.stringValue = "Переключений: \(count)"
        let reset = NSButton(title: "Сбросить", target: self, action: #selector(resetStats))
        reset.bezelStyle = .rounded
        return verticalStack([
            group("Статистика", [ controlRow("Всего переключений", statsLabel) ]),
            reset,
        ])
    }

    private lazy var statsLabel = NSTextField(labelWithString: "")
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

    private func makeTextView(height: CGFloat) -> (NSScrollView, NSTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        let tv = NSTextView()
        tv.isRichText = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        return (scroll, tv)
    }

    // MARK: - Actions

    @objc private func triggerChanged(_ sender: NSPopUpButton) {
        SettingsStore.shared.manualTrigger =
            SettingsStore.ManualTrigger(rawValue: sender.indexOfSelectedItem) ?? .doubleShift
    }

    @objc private func earlySensitivityChanged(_ sender: NSPopUpButton) {
        SettingsStore.shared.earlySwitchSensitivity =
            SettingsStore.EarlySwitchSensitivity(rawValue: sender.indexOfSelectedItem) ?? .balanced
    }

    @objc private func thresholdChanged(_ sender: NSSlider) {
        SettingsStore.shared.confidenceThreshold = sender.doubleValue
        thresholdValueLabel.stringValue = String(format: "%.2f", sender.doubleValue)
    }

    @objc private func resetStats() {
        SettingsStore.shared.switchCount = 0
        statsLabel.stringValue = "Переключений: 0"
        notifyChanged()
    }

    @objc private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url,
                  let id = Bundle(url: url)?.bundleIdentifier else { return }
            let cur = self?.appsView?.string ?? ""
            self?.appsView?.string = cur.isEmpty ? id : cur + "\n" + id
        }
    }

    private func saveExceptions() {
        if let words = wordsView {
            SettingsStore.shared.wordExceptions = parseLines(words.string)
        }
        if let apps = appsView {
            SettingsStore.shared.excludedBundleIDs = parseLines(apps.string)
        }
        if wordsView != nil || appsView != nil { notifyChanged() }
    }

    private func parseLines(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
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
