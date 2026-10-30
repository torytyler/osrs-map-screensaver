import AppKit
import ScreenSaver
import WebKit

/// Non-interactive WKWebView: a screen saver must never show a context menu,
/// a text cursor or react to stray clicks.
final class PassiveWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func rightMouseDown(with event: NSEvent) {}
    override func mouseDown(with event: NSEvent) {}
}

@objc(OSRSMapSaverView)
final class OSRSMapSaverView: ScreenSaverView, WKNavigationDelegate {
    private var server: HTTPServer?
    private var webView: PassiveWebView?
    private var isRunning = false

    private static let logFileName = "saver.log"

    // MARK: - Init

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    // MARK: - Paths

    private var saverBundle: Bundle {
        Bundle(for: OSRSMapSaverView.self)
    }

    /// The screen saver runs inside the sandboxed `legacyScreenSaver` app extension,
    /// where `NSHomeDirectory()` is the extension container - not the user's home.
    /// Caches are installed in the real home, logs go to the (writable) container.
    static var realHomeDirectory: String {
        if let entry = getpwuid(getuid()) {
            return String(cString: entry.pointee.pw_dir)
        }
        return NSHomeDirectory()
    }

    private var supportDirectory: URL {
        URL(fileURLWithPath: Self.realHomeDirectory)
            .appendingPathComponent("Library/Application Support/OSRSMapSaver", isDirectory: true)
    }

    private var logFileURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        let directory = base.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(Self.logFileName)
    }

    /// The system creates one saver view per display. Rendering two full viewers
    /// doubles the GPU work (and the heat), so when an external display is
    /// connected only that one plays; the built-in panel stays black.
    private var shouldPlayOnThisDisplay: Bool {
        if ProcessInfo.processInfo.environment["OSRS_SAVER_FORCE_PLAY"] == "1" {
            return true
        }
        let screens = NSScreen.screens
        guard screens.count > 1 else {
            return true
        }
        guard let screen = self.window?.screen, let identifier = Self.displayID(of: screen) else {
            // Cannot tell which display this view belongs to; better to show the
            // saver than to leave the user with a black screen.
            return true
        }

        if CGDisplayIsBuiltin(identifier) != 0 {
            return false
        }

        let externalIDs = screens.compactMap(Self.displayID(of:)).filter { CGDisplayIsBuiltin($0) == 0 }
        if externalIDs.count > 1 {
            // Several external displays: use the one that is not the main display.
            return identifier != CGMainDisplayID()
        }
        return true
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    private var debugEnabled: Bool {
        let flags = [
            supportDirectory.appendingPathComponent("debug"),
            URL(fileURLWithPath: Self.realHomeDirectory)
                .appendingPathComponent("Documents/osrs_map_screensaver/macos/build/debug"),
        ]
        return flags.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Caches live outside the bundle (they are ~250 MB) so the plugin stays small.
    private func locateCaches() -> URL? {
        let candidates: [URL?] = [
            supportDirectory.appendingPathComponent("caches", isDirectory: true),
            saverBundle.resourceURL?.appendingPathComponent("caches", isDirectory: true),
            URL(fileURLWithPath: Self.realHomeDirectory)
                .appendingPathComponent("Documents/osrs_map_screensaver/repo/caches", isDirectory: true),
        ]

        for candidate in candidates {
            guard let candidate else { continue }
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("caches.json").path) {
                return candidate
            }
        }
        return nil
    }

    private func locateWebRoot() -> URL? {
        let candidates: [URL?] = [
            saverBundle.resourceURL?.appendingPathComponent("web", isDirectory: true),
            URL(fileURLWithPath: Self.realHomeDirectory)
                .appendingPathComponent("Documents/osrs_map_screensaver/repo/build", isDirectory: true),
        ]
        for candidate in candidates {
            guard let candidate else { continue }
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("index.html").path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - ScreenSaverView

    override var hasConfigureSheet: Bool { false }

    override func startAnimation() {
        super.startAnimation()
        guard !isRunning else {
            webView?.isHidden = false
            return
        }
        guard shouldPlayOnThisDisplay else {
            // Leave this display black: another display is showing the saver.
            NSLog("OSRSMapSaver: idle on this display")
            return
        }
        isRunning = true
        startWebContent()
    }

    override func stopAnimation() {
        super.stopAnimation()
        isRunning = false
        webView?.stopLoading()
        webView?.loadHTMLString("<html><body style='background:#000'></body></html>", baseURL: nil)
        webView?.removeFromSuperview()
        webView = nil
        server?.stop()
        server = nil
    }

    override func animateOneFrame() {
        // The web app drives its own animation loop.
    }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
    }

    // MARK: - Web content

    private func startWebContent() {
        guard webView == nil else { return }

        guard let webRoot = locateWebRoot() else {
            NSLog("OSRSMapSaver: web build not found in bundle")
            return
        }

        let caches = locateCaches()
        let server = HTTPServer(webRoot: webRoot, cacheRoot: caches, logFile: logFileURL)
        guard let server, let port = server.start() else {
            NSLog("OSRSMapSaver: failed to start local server")
            return
        }
        self.server = server

        server.log(
            "started port=\(port) main=\(Thread.isMainThread) hostWindow=\(self.window != nil) "
                + "web=\(webRoot.path) caches=\(caches?.path ?? "none") preview=\(isPreview) "
                + "bundle=\(saverBundle.bundlePath)"
        )

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.makeDataStore()
        configuration.suppressesIncrementalRendering = false
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let userContent = WKUserContentController()
        userContent.addUserScript(PassiveWebView.styleScript())
        userContent.addUserScript(Self.diagnosticsScript())
        configuration.userContentController = userContent

        let webView = PassiveWebView(frame: bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        if #available(macOS 13.3, *) {
            webView.isInspectable = debugEnabled
        }

        webView.navigationDelegate = self
        Self.disableOcclusionDetection(webView)
        addSubview(webView)
        self.webView = webView

        var query = "ambient=1&saver=1"
        if isPreview { query += "&preview=1" }
        if debugEnabled { query += "&debug=1" }
        if let quality = SaverSettings.fpsLimit { query += "&fps=\(quality)" }

        if let url = URL(string: "http://127.0.0.1:\(port)/?\(query)") {
            server.log("loading \(url.absoluteString)")
            webView.load(URLRequest(url: url))
        }

        // The host window is reported as occluded inside the extension; verify the
        // WebKit fix took effect and the page is actually animating.
        for delay in [1.5, 6.0, 15.0] {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
                [weak self] in
                guard let self else { return }
                DispatchQueue.main.async { self.logWebViewState(tag: "t\(Int(delay))") }
            }
        }
    }

    private func logWebViewState(tag: String) {
        guard let webView, let server else { return }
        let window = webView.window
        let occlusion = window?.occlusionState.contains(.visible) == true ? "visible" : "occluded"
        server.log(
            "state \(tag) inWindow=\(window != nil) occlusion=\(occlusion) "
                + "visible=\(window?.isVisible ?? false) mini=\(window?.isMiniaturized ?? false) "
                + "level=\(window?.level.rawValue ?? -1) appActive=\(NSApp.isActive) "
                + "view=\(Int(webView.frame.width))x\(Int(webView.frame.height)) screens=\(NSScreen.screens.count)"
        )
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        server?.log("didFinish")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        server?.log("didFail: \(error)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        server?.log("didFailProvisional: \(error)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        server?.log("web content process terminated, reloading")
        webView.reload()
    }

    /// The screen saver runs in a host window that WebKit classifies as occluded,
    /// which stops `requestAnimationFrame`. Turn that heuristic off.
    private static func disableOcclusionDetection(_ webView: WKWebView) {
        if ProcessInfo.processInfo.environment["OSRS_SAVER_NO_OCCLUSION_FIX"] == "1" {
            NSLog("OSRSMapSaver: occlusion fix disabled by environment")
            return
        }
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: selector) else {
            NSLog("OSRSMapSaver: occlusion SPI unavailable")
            return
        }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let implementation = webView.method(for: selector)
        let setter = unsafeBitCast(implementation, to: Setter.self)
        setter(webView, selector, false)
    }

    private static func makeDataStore() -> WKWebsiteDataStore {
        // A named data store keeps the (large) RS cache downloaded once, across
        // screen saver sessions, inside our own container.
        if #available(macOS 14.0, *),
           let identifier = UUID(uuidString: "6E5A3C2B-9F0B-4A0B-9C2F-0B0F1C3D5E7A") {
            return WKWebsiteDataStore(forIdentifier: identifier)
        }
        return .default()
    }
}

// MARK: - Settings

enum SaverSettings {
    /// TODO: read from ScreenSaverDefaults once we add a configure sheet.
    static var fpsLimit: Int? { nil }
}

// MARK: - Injected scripts

extension PassiveWebView {
    static func styleScript() -> WKUserScript {
        let css = """
        html, body { background: #000 !important; margin: 0; overflow: hidden; }
        * { cursor: none !important; user-select: none !important; }
        """
        let script = """
        (function() {
            const style = document.createElement('style');
            style.textContent = `\(css)`;
            document.documentElement.appendChild(style);
        })();
        """
        return WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }
}

extension OSRSMapSaverView {
    /// Telemetry: proves whether WebGL2, workers, SharedArrayBuffer and
    /// CacheStorage work inside the screen saver process, and heartbeats the
    /// ambient director independently of the render loop.
    static func diagnosticsScript() -> WKUserScript {
        let script = """
        (function() {
            const report = (label) => {
                try {
                    const canvas = document.querySelector('canvas');
                    const payload = {
                        label,
                        href: location.href,
                        webgl2: !!document.createElement('canvas').getContext('webgl2'),
                        worker: typeof Worker === 'function',
                        sab: typeof SharedArrayBuffer === 'function',
                        crossOriginIsolated: self.crossOriginIsolated,
                        cacheStorage: typeof caches === 'object',
                        canvas: canvas ? [canvas.width, canvas.height] : null,
                        frames: window.__frames || 0,
                        gl: (() => {
                            const c = document.querySelector('canvas');
                            const gl = c && c.getContext('webgl2');
                            if (!gl) return null;
                            const info = gl.getExtension('WEBGL_debug_renderer_info');
                            return info ? gl.getParameter(info.UNMASKED_RENDERER_WEBGL) : 'unknown';
                        })(),
                    };
                    fetch('/__diag?msg=' + encodeURIComponent(JSON.stringify(payload)));
                } catch (err) {
                    fetch('/__diag?msg=' + encodeURIComponent('report failed: ' + err));
                }
            };

            let frames = 0;
            const tick = () => { frames++; window.__frames = frames; requestAnimationFrame(tick); };
            requestAnimationFrame(tick);

            setTimeout(() => report('t10'), 10000);
            setTimeout(() => report('t30'), 30000);
            setTimeout(() => report('t70'), 70000);

            if (typeof caches === 'object') {
                setTimeout(() => {
                    caches.keys().then((keys) => {
                        fetch('/__diag?msg=' + encodeURIComponent('cacheKeys ' + JSON.stringify(keys)));
                    }).catch(() => {});
                }, 12000);
            }

            setInterval(() => {
                try {
                    const state = window.__ambient ? window.__ambient.state() : null;
                    const canvas = document.querySelector('canvas');
                    fetch('/__diag?msg=' + encodeURIComponent('hb ' + JSON.stringify({
                        state,
                        frames: window.__frames || 0,
                        visibility: document.visibilityState,
                        hidden: document.hidden,
                        canvas: canvas ? [canvas.width, canvas.height, canvas.offsetWidth, canvas.offsetHeight] : null,
                        text: document.body ? document.body.innerText.slice(0, 100) : '',
                    })));
                } catch (err) {
                    fetch('/__diag?msg=' + encodeURIComponent('hb failed ' + err));
                }
            }, 5000);
        })();
        """
        return WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }
}
