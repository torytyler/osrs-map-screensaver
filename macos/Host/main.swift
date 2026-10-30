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

    init(fullscreen: Bool, quitAfter: Double?, hideAfter: Double?, coverAfter: Double?) {
        self.fullscreen = fullscreen
        self.quitAfter = quitAfter
        self.hideAfter = hideAfter
        self.coverAfter = coverAfter
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

        if let quitAfter {
            quitTimer = Timer.scheduledTimer(withTimeInterval: quitAfter, repeats: false) { _ in
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        saverView?.stopAnimation()
    }
}

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

let delegate = AppDelegate(
    fullscreen: fullscreen,
    quitAfter: quitAfter,
    hideAfter: hideAfter,
    coverAfter: coverAfter
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
