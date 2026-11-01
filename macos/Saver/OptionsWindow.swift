import AppKit

/// The standard macOS screen saver "Options…" sheet, built in code.
///
/// The host runs this window as a sheet (`NSApp.beginSheet`), so it owns its own
/// Cancel / OK buttons and ends the sheet by calling `NSApp.endSheet`.
/// Everything is read back from the controls on OK; nothing is written before.
final class OptionsWindow: NSWindow {
    /// Called when the sheet is dismissed: `true` when the user pressed OK.
    var onFinish: ((Bool) -> Void)?

    private var settings: SaverSettings

    // Pacing / camera / motion controls
    private let dwellRow = SliderRow(min: 5, max: 300, format: { "\(Int($0.rounded())) s" })
    private let fadeRow = SliderRow(min: 0.1, max: 3, format: { String(format: "%.1f s", $0) })
    private let fpsRow = SliderRow(min: 5, max: 60, format: { "\(Int($0.rounded())) fps" })
    private let distanceRow = SliderRow(min: 64, max: 512, format: { "\(Int($0.rounded())) tiles" })
    private let fogRow = SliderRow(min: 0, max: 256, format: { "\(Int($0.rounded())) tiles" })
    private let npcRow = SliderRow(min: 0, max: 1, format: { String(format: "%.0f %%", $0 * 100) })
    private let minFlightRow = SliderRow(min: 0, max: 800, format: { "\(Int($0.rounded())) tiles" })
    private let maxFlightRow = SliderRow(min: 200, max: 5000, format: { "\(Int($0.rounded())) tiles" })
    private let eraEveryRow = SliderRow(min: 1, max: 50, format: { "every \(Int($0.rounded()))" })

    private let cachePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let eraPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let skyWell = NSColorWell(frame: .zero)
    private let labelsSwitch = NSSwitch(frame: .zero)
    private let hideSkySwitch = NSSwitch(frame: .zero)
    private let debugSwitch = NSSwitch(frame: .zero)
    private let footnote = NSTextField(labelWithString: "")

    private var caches: [CacheOption] = []

    // MARK: - Init

    init(settings: SaverSettings, caches: [CacheOption]) {
        self.settings = settings
        self.caches = caches
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        title = "RuneScape World"
        isReleasedWhenClosed = false
        buildInterface()
        apply(settings)
    }

    // MARK: - Interface

    private func buildInterface() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 560))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(section("World"))
        stack.addArrangedSubview(grid(rows: [
            ("Cache", labelled(cachePopUp, width: 260)),
            ("Era rotation", labelled(eraPopUp, width: 260)),
            ("Switch era", eraEveryRow.view),
        ]))

        stack.addArrangedSubview(section("Pacing"))
        stack.addArrangedSubview(grid(rows: [
            ("Scene duration", dwellRow.view),
            ("Jump cross-fade", fadeRow.view),
        ]))

        stack.addArrangedSubview(section("Camera"))
        stack.addArrangedSubview(grid(rows: [
            ("Frame rate", fpsRow.view),
            ("Render distance", distanceRow.view),
            ("Fog", fogRow.view),
            ("Sky colour", labelled(skyWell, width: 60)),
            ("Scene caption", labelled(labelsSwitch, width: 60)),
            ("Hide sky & void", labelled(hideSkySwitch, width: 60)),
        ]))

        stack.addArrangedSubview(section("Motion"))
        stack.addArrangedSubview(grid(rows: [
            ("Follow NPCs", npcRow.view),
            ("Jump cut below", minFlightRow.view),
            ("Jump cut above", maxFlightRow.view),
        ]))

        stack.addArrangedSubview(section("Advanced"))
        stack.addArrangedSubview(grid(rows: [
            ("Debug HUD", labelled(debugSwitch, width: 60)),
        ]))

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.addArrangedSubview(NSView())   // spacer

        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetTapped))
        reset.bezelStyle = .rounded
        buttons.addArrangedSubview(reset)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttons.addArrangedSubview(spacer)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        buttons.addArrangedSubview(cancel)

        let ok = NSButton(title: "OK", target: self, action: #selector(okTapped))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        buttons.addArrangedSubview(ok)

        buttons.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
        stack.addArrangedSubview(buttons)

        footnote.font = .systemFont(ofSize: 10)
        footnote.textColor = .secondaryLabelColor
        footnote.lineBreakMode = .byTruncatingMiddle
        footnote.maximumNumberOfLines = 1
        stack.addArrangedSubview(footnote)

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])

        contentView = content
        content.layoutSubtreeIfNeeded()
        let fitting = stack.fittingSize
        setContentSize(NSSize(width: max(560, fitting.width + 40), height: fitting.height + 40))
    }

    private func section(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func labelled(_ control: NSView, width: CGFloat) -> NSView {
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: width).isActive = true
        return control
    }

    private func grid(rows: [(String, NSView)]) -> NSGridView {
        let views: [[NSView]] = rows.map { title, control in
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            return [label, control]
        }
        let grid = NSGridView(views: views)
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        return grid
    }

    // MARK: - Values

    /// Pull the current values out of the controls into `settings`.
    private func collect() {
        settings.dwell = dwellRow.value
        settings.fade = fadeRow.value
        settings.fps = Int(fpsRow.value.rounded())
        settings.distance = Int(distanceRow.value.rounded())
        settings.fog = Int(fogRow.value.rounded())
        settings.npcChance = npcRow.value
        settings.minFlight = Int(minFlightRow.value.rounded())
        settings.maxFlight = Int(maxFlightRow.value.rounded())
        settings.eraEvery = Int(eraEveryRow.value.rounded())
        settings.labels = labelsSwitch.state == .on
        settings.hideSky = hideSkySwitch.state == .on
        settings.debugHUD = debugSwitch.state == .on
        settings.skyHex = OptionsWindow.hex(from: skyWell.color)

        if let era = eraPopUp.selectedItem?.representedObject as? String,
           let mode = EraMode(rawValue: era) {
            settings.era = mode
        }
        settings.cache = cachePopUp.selectedItem?.representedObject as? String ?? ""
        settings.sanitise()
    }

    /// Re-populates the controls, e.g. when the sheet is reopened by the host.
    func reload(settings: SaverSettings, caches: [CacheOption]) {
        self.caches = caches
        apply(settings)
    }

    /// Push `settings` into the controls.
    private func apply(_ settings: SaverSettings) {
        self.settings = settings

        rebuildCacheMenu(selected: settings.cache)
        rebuildEraMenu(selected: settings.era)

        dwellRow.value = settings.dwell
        fadeRow.value = settings.fade
        fpsRow.value = Double(settings.fps)
        distanceRow.value = Double(settings.distance)
        fogRow.value = Double(settings.fog)
        npcRow.value = settings.npcChance
        minFlightRow.value = Double(settings.minFlight)
        maxFlightRow.value = Double(settings.maxFlight)
        eraEveryRow.value = Double(settings.eraEvery)

        skyWell.color = OptionsWindow.color(fromHex: settings.skyHex)
        labelsSwitch.state = settings.labels ? .on : .off
        hideSkySwitch.state = settings.hideSky ? .on : .off
        debugSwitch.state = settings.debugHUD ? .on : .off

        footnote.stringValue = "Saved in \(SaverSettings.moduleName) "
            + (SaverSettings.usesScreenSaverDefaults ? "(ScreenSaverDefaults)" : "(UserDefaults fallback)")
    }

    private func rebuildCacheMenu(selected: String) {
        cachePopUp.removeAllItems()
        cachePopUp.addItem(withTitle: "Latest downloaded")
        cachePopUp.lastItem?.representedObject = ""

        for cache in caches {
            cachePopUp.addItem(withTitle: cache.label)
            cachePopUp.lastItem?.representedObject = cache.name
        }

        if !selected.isEmpty, !caches.contains(where: { $0.name == selected }) {
            cachePopUp.addItem(withTitle: "\(selected) (not installed)")
            cachePopUp.lastItem?.representedObject = selected
        }

        if let index = cachePopUp.itemArray.firstIndex(where: { ($0.representedObject as? String) == selected }) {
            cachePopUp.selectItem(at: index)
        } else {
            cachePopUp.selectItem(at: 0)
        }
    }

    private func rebuildEraMenu(selected: EraMode) {
        eraPopUp.removeAllItems()
        for mode in EraMode.allCases {
            eraPopUp.addItem(withTitle: mode.label)
            eraPopUp.lastItem?.representedObject = mode.rawValue
        }
        if let index = eraPopUp.itemArray.firstIndex(where: { ($0.representedObject as? String) == selected.rawValue }) {
            eraPopUp.selectItem(at: index)
        }
    }

    // MARK: - Actions

    @objc private func okTapped() { confirmSheet() }
    @objc private func cancelTapped() { cancelSheet() }

    @objc private func resetTapped() {
        SaverSettings.resetToDefaults()
        apply(SaverSettings.load())
    }

    /// Save what is on screen and end the sheet. Objective-C visible so the dev
    /// harness can drive the sheet without knowing the Swift module.
    @objc func confirmSheet() {
        collect()
        settings.save()
        finish(saved: true)
    }

    @objc func cancelSheet() {
        finish(saved: false)
    }

    private func finish(saved: Bool) {
        onFinish?(saved)
    }

    // MARK: - Colours

    static func hex(from color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "000000" }
        let red = Int((rgb.redComponent * 255).rounded())
        let green = Int((rgb.greenComponent * 255).rounded())
        let blue = Int((rgb.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", red, green, blue)
    }

    static func color(fromHex hex: String) -> NSColor {
        guard let normalized = SaverSettings.parseHex(hex), let value = Int(normalized, radix: 16) else {
            return .black
        }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// A slider plus a monospaced readout, so the user sees the actual value.
private final class SliderRow: NSObject {
    let slider = NSSlider()
    private let readout = NSTextField(labelWithString: "")
    private let format: (Double) -> String
    private(set) lazy var view: NSView = makeView()

    init(min: Double, max: Double, format: @escaping (Double) -> String) {
        self.format = format
        super.init()

        slider.minValue = min
        slider.maxValue = max
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)

        readout.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        readout.textColor = .secondaryLabelColor
        readout.alignment = .right
        readout.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    var value: Double {
        get { slider.doubleValue }
        set {
            slider.doubleValue = newValue
            refresh()
        }
    }

    private func makeView() -> NSView {
        let stack = NSStackView(views: [slider, readout])
        stack.orientation = .horizontal
        stack.spacing = 8
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        readout.widthAnchor.constraint(equalToConstant: 76).isActive = true
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 284).isActive = true
        return stack
    }

    @objc private func changed() { refresh() }

    private func refresh() {
        readout.stringValue = format(slider.doubleValue)
    }
}
