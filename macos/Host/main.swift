// Development harness: loads the built .saver bundle, instantiates its
// ScreenSaverView and shows it in a window. Lets us iterate on the screen saver
// without waiting for the real idle timeout (or locking the screen).
//
//   osrs-saver-host path/to/OSRSMapSaver.saver [--fullscreen] [--quit-after 30]
import AppKit
import ScreenSaver

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var saverView: ScreenSaverView?
    private var quitTimer: Timer?
    private var coverWindow: NSWindow?
    private let fullscreen: Bool
    private let quitAfter: Double?
    private let hideAfter: Double?
    private let coverAfter: Double?
    private let showOptions: Bool
    private let optionsOkAfter: Double?
    private let optionsScreenshot: String?
    private let optionsEdit: Bool
    private let viaAppBeginSheet: Bool
    private let optionsCancelAfter: Double?

    init(
        fullscreen: Bool,
        quitAfter: Double?,
        hideAfter: Double?,
        coverAfter: Double?,
        showOptions: Bool,
        optionsOkAfter: Double?,
        optionsScreenshot: String?,
        optionsEdit: Bool,
        viaAppBeginSheet: Bool,
        optionsCancelAfter: Double?
    ) {
        self.fullscreen = fullscreen
        self.quitAfter = quitAfter
        self.hideAfter = hideAfter
        self.coverAfter = coverAfter
        self.showOptions = showOptions
        self.optionsOkAfter = optionsOkAfter
        self.optionsScreenshot = optionsScreenshot
        self.optionsEdit = optionsEdit
        self.viaAppBeginSheet = viaAppBeginSheet
        self.optionsCancelAfter = optionsCancelAfter
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else {
            print("usage: osrs-saver-host <path to .saver> [--fullscreen] [--quit-after seconds]")
            NSApp.terminate(nil)
            return
        }

        // The harness is a dev tool: ignore the "external display only" policy.
        setenv("OSRS_SAVER_FORCE_PLAY", "1", 1)

        let bundleURL = URL(fileURLWithPath: arguments[1] as String)
        guard let bundle = Bundle(url: bundleURL) else {
            print("error: cannot load bundle at \(bundleURL.path)")
            NSApp.terminate(nil)
            return
        }
        guard let principalName = bundle.infoDictionary?["NSPrincipalClass"] as? String,
              let principalClass = bundle.classNamed(principalName) as? ScreenSaverView.Type
        else {
            print("error: no NSPrincipalClass \(bundle.infoDictionary?["NSPrincipalClass"] ?? "?")")
            NSApp.terminate(nil)
            return
        }

        let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        guard let view = principalClass.init(frame: frame, isPreview: false) else {
            print("error: could not instantiate ScreenSaverView")
            NSApp.terminate(nil)
            return
        }

        saverView = view

        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RuneScape World — saver harness"
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.center()
        NSApp.activate(ignoringOtherApps: true)

        view.startAnimation()

        if fullscreen {
            window.toggleFullScreen(nil)
        }

        if let hideAfter {
            // Reproduces the screen saver case: the view stays "on screen" for the
            // web page, but the window is not actually visible to the window server.
            Timer.scheduledTimer(withTimeInterval: hideAfter, repeats: false) { _ in
                self.window.orderOut(nil)
            }
        }

        if let coverAfter {
            // Another opaque window on top: the host window stays "visible" but its
            // occlusion state goes false, which is what the screen saver host does.
            Timer.scheduledTimer(withTimeInterval: coverAfter, repeats: false) { _ in
                let cover = NSWindow(
                    contentRect: self.window.frame,
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                cover.backgroundColor = .systemPink
                cover.isOpaque = true
                cover.level = .normal
                cover.orderFront(nil)
                self.coverWindow = cover
                print("cover window shown")
            }
        }

        if showOptions {
            // Present the configure sheet exactly like the screen saver host does.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.presentOptions() }
        }

        if let quitAfter {
            quitTimer = Timer.scheduledTimer(withTimeInterval: quitAfter, repeats: false) { _ in
                // Terminating with a sheet on screen can stall; close it first.
                if let sheet = NSApp.keyWindow, sheet.isSheet {
                    sheet.sheetParent?.endSheet(sheet)
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// Drives `hasConfigureSheet` / `configureSheet` and sheets the window, which
    /// is what System Settings does when the user presses “Options…”
    private func presentOptions() {
        guard let view = saverView else { return }
        print("hasConfigureSheet = \(view.hasConfigureSheet)")

        guard view.hasConfigureSheet else {
            print("FAIL: saver does not offer a configure sheet")
            NSApp.terminate(nil)
            return
        }
        guard let sheet = view.configureSheet else {
            print("FAIL: configureSheet returned nil")
            NSApp.terminate(nil)
            return
        }

        print("sheet title=\(sheet.title) frame=\(sheet.frame) styleMask=\(sheet.styleMask.rawValue)")
        print("sheet canBecomeKey=\(sheet.canBecomeKey) canBecomeMain=\(sheet.canBecomeMain) "
            + "contentView=\(sheet.contentView != nil) releasedWhenClosed=\(sheet.isReleasedWhenClosed)")
        print("sheet buttons: \(buttonTitles(in: sheet.contentView))")
        print("sheet labels: \(labelTexts(in: sheet.contentView))")

        if viaAppBeginSheet {
            NSApp.beginSheet(sheet, modalFor: window, modalDelegate: nil, didEnd: nil, contextInfo: nil)
        } else {
            window.beginSheet(sheet) { response in
                print("sheet dismissed: response=\(response.rawValue)")
            }
        }
        print("sheet presented = \(sheet.isSheet) isVisible = \(sheet.isVisible) key = \(sheet.isKeyWindow)")

        if let path = optionsScreenshot {
            // A short delay lets AppKit finish its first layout pass.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.saveSnapshot(of: sheet, to: path)
            }
        }

        if optionsEdit {
            editControls(in: sheet)
        }

        if let optionsOkAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + optionsOkAfter) {
                print("pressing OK…")
                _ = sheet.perform(NSSelectorFromString("confirmSheet"))
            }
        }

        if let optionsCancelAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + optionsCancelAfter) {
                print("pressing Cancel…")
                _ = sheet.perform(NSSelectorFromString("cancelSheet"))
                print("sheet still visible after cancel = \(sheet.isVisible)")
            }
        }
    }

    /// Exercises the sheet end to end: move controls, then let OK save them.
    private func editControls(in sheet: NSWindow) {
        let sliders = descendants(of: NSSlider.self, in: sheet.contentView)
        print("sliders: \(sliders.map { "\($0.minValue)…\($0.maxValue)=\($0.doubleValue)" })")

        // Order matches the rows in OptionsWindow: eraEvery, dwell, fade, fps,
        // distance, fog, npc, minFlight, maxFlight.
        func setSlider(_ index: Int, _ value: Double) {
            guard sliders.indices.contains(index) else { return }
            sliders[index].doubleValue = value
            sliders[index].sendAction(sliders[index].action, to: sliders[index].target)
        }
        setSlider(1, 45)    // scene duration
        setSlider(3, 45)    // frame rate
        setSlider(4, 400)   // render distance
        setSlider(6, 0.8)   // follow NPCs

        let popUps = descendants(of: NSPopUpButton.self, in: sheet.contentView)
        print("popups: \(popUps.map { $0.itemArray.map(\.title) })")
        if popUps.count > 1, popUps[1].numberOfItems > 2 {
            popUps[1].selectItem(at: 2)   // era: 2005 only
        }
        if popUps.count > 0, popUps[0].numberOfItems > 2 {
            popUps[0].selectItem(at: 2)   // cache: the 2005 cache
        }

        if let well = descendants(of: NSColorWell.self, in: sheet.contentView).first {
            well.color = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.18, alpha: 1)
        }

        let switches = descendants(of: NSSwitch.self, in: sheet.contentView)
        if let caption = switches.first {
            caption.state = caption.state == .on ? .off : .on
        }
        // Second switch is "Hide sky & void"; turn it on to prove the nosky param.
        if switches.count > 1 {
            switches[1].state = .on
        }
        print("edited the sheet")
    }

    /// Renders the window into a PNG without needing screen recording access.
    private func saveSnapshot(of window: NSWindow, to path: String) {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("sheet snapshot: \(path) (\(Int(view.bounds.width))x\(Int(view.bounds.height)))")
        } catch {
            print("sheet snapshot failed: \(error)")
        }
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for subview in view.subviews {
            found.append(contentsOf: descendants(of: type, in: subview))
        }
        return found
    }

    private func buttonTitles(in view: NSView?) -> [String] {
        guard let view else { return [] }
        var titles: [String] = []
        if let button = view as? NSButton {
            titles.append(button.title)
        }
        for subview in view.subviews {
            titles.append(contentsOf: buttonTitles(in: subview))
        }
        return titles
    }

    private func labelTexts(in view: NSView?) -> [String] {
        guard let view else { return [] }
        var texts: [String] = []
        if let field = view as? NSTextField, !(view is NSButton), !field.stringValue.isEmpty {
            texts.append(field.stringValue)
        }
        for subview in view.subviews {
            texts.append(contentsOf: labelTexts(in: subview))
        }
        return texts
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        saverView?.stopAnimation()
    }
}

// Unbuffered so diagnostics appear immediately even when stdout is a file.
setvbuf(stdout, nil, _IONBF, 0)

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let args = CommandLine.arguments
let fullscreen = args.contains("--fullscreen")
var quitAfter: Double?
if let index = args.firstIndex(of: "--quit-after"), index + 1 < args.count {
    quitAfter = Double(args[index + 1])
}

var hideAfter: Double?
if let index = args.firstIndex(of: "--hide-after"), index + 1 < args.count {
    hideAfter = Double(args[index + 1])
}

var coverAfter: Double?
if let index = args.firstIndex(of: "--cover-after"), index + 1 < args.count {
    coverAfter = Double(args[index + 1])
}

var optionsOkAfter: Double?
if let index = args.firstIndex(of: "--options-ok-after"), index + 1 < args.count {
    optionsOkAfter = Double(args[index + 1])
}

var optionsCancelAfter: Double?
if let index = args.firstIndex(of: "--options-cancel-after"), index + 1 < args.count {
    optionsCancelAfter = Double(args[index + 1])
}

var optionsScreenshot: String?
if let index = args.firstIndex(of: "--options-screenshot"), index + 1 < args.count {
    optionsScreenshot = args[index + 1]
}

let delegate = AppDelegate(
    fullscreen: fullscreen,
    quitAfter: quitAfter,
    hideAfter: hideAfter,
    coverAfter: coverAfter,
    showOptions: args.contains("--show-options"),
    optionsOkAfter: optionsOkAfter,
    optionsScreenshot: optionsScreenshot,
    optionsEdit: args.contains("--options-edit"),
    viaAppBeginSheet: args.contains("--options-via-app"),
    optionsCancelAfter: optionsCancelAfter
)
app.delegate = delegate

let menu = NSMenu()
let appMenuItem = NSMenuItem()
menu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu
app.mainMenu = menu

app.run()
