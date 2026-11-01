import Foundation
import ScreenSaver

// MARK: - Paths

/// Where the saver reads its data from.
///
/// The screen saver runs inside the sandboxed `legacyScreenSaver` app extension,
/// where `NSHomeDirectory()` is the extension container - not the user's home.
/// Caches live in the real home, logs go to the (writable) container.
enum SaverPaths {
    static var realHome: String {
        if let entry = getpwuid(getuid()) {
            return String(cString: entry.pointee.pw_dir)
        }
        return NSHomeDirectory()
    }

    static var supportDirectory: URL {
        URL(fileURLWithPath: SaverPaths.realHome)
            .appendingPathComponent("Library/Application Support/OSRSMapSaver", isDirectory: true)
    }

    static var logFileURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        let directory = base.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("saver.log")
    }

    /// Caches live outside the bundle (they are ~250 MB) so the plugin stays small.
    static func cachesDirectory(bundle: Bundle) -> URL? {
        let candidates: [URL?] = [
            supportDirectory.appendingPathComponent("caches", isDirectory: true),
            bundle.resourceURL?.appendingPathComponent("caches", isDirectory: true),
            URL(fileURLWithPath: SaverPaths.realHome)
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

    static func webRoot(bundle: Bundle) -> URL? {
        let candidates: [URL?] = [
            bundle.resourceURL?.appendingPathComponent("web", isDirectory: true),
            URL(fileURLWithPath: SaverPaths.realHome)
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
}

// MARK: - Log

/// Appends to the same `saver.log` the HTTP server writes to. `NSLog` from an
/// app extension is awkward to find, this file is easy to `tail -f`.
enum SaverLog {
    private static let lock = NSLock()

    static func append(_ message: String) {
        let line = "[\(timestamp())] \(message)\n"
        NSLog("OSRSMapSaver: \(message)")

        lock.lock()
        defer { lock.unlock() }

        let url = SaverPaths.logFileURL
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static func timestamp() -> String {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: now)
    }
}

// MARK: - Cache list

/// One entry of `caches/caches.json`, written by `repo/scripts/fetch-cache.mjs`.
struct CacheOption: Equatable {
    let name: String
    let label: String

    /// The viewer picks the 2005 cache by `name.hasPrefix("rs2-295")`.
    var isLegacy: Bool { name.hasPrefix("rs2-295") }

    static func load(bundle: Bundle) -> [CacheOption] {
        guard let directory = SaverPaths.cachesDirectory(bundle: bundle),
              let data = try? Data(contentsOf: directory.appendingPathComponent("caches.json")),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }

        let options: [(timestamp: String, option: CacheOption)] = raw.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let revision = (entry["revision"] as? NSNumber)?.intValue
            let size = (entry["size"] as? NSNumber)?.doubleValue
            let game = entry["game"] as? String ?? ""

            var parts: [String] = []
            if name.hasPrefix("rs2-") {
                parts.append("2005 cache")
            } else {
                parts.append(game == "oldschool" ? "OSRS" : game.capitalized)
            }
            if let revision { parts.append("rev \(revision)") }
            if let size { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }

            return (
                timestamp: entry["timestamp"] as? String ?? "",
                option: CacheOption(name: name, label: parts.joined(separator: " · "))
            )
        }

        return options
            .sorted { $0.timestamp > $1.timestamp }
            .map(\.option)
    }
}

// MARK: - Era

enum EraMode: String, CaseIterable {
    case mixed
    case latest
    case legacy

    var label: String {
        switch self {
        case .mixed: return "Rotate: current + 2005"
        case .latest: return "Current world only"
        case .legacy: return "2005 world only"
        }
    }
}

// MARK: - Settings

/// Every knob the configure sheet can write. Values are clamped on load *and*
/// before they are put in the URL query - they end up in a query string.
struct SaverSettings: Equatable {
    var dwell: Double = 30          // seconds parked per scene
    var fade: Double = 1            // cross-fade for long jumps
    var fps: Int = 30               // renderer cap
    var distance: Int = 320         // render distance, tiles
    var fog: Int = 96               // fog band, tiles
    var skyHex: String = "000000"   // sky / fog colour
    var npcChance: Double = 0.5     // chance a scene follows an NPC
    var era: EraMode = .mixed
    var eraEvery: Int = 4           // zones between era switches
    var minFlight: Int = 140        // below this distance we cut instead of fly
    var maxFlight: Int = 950        // above this distance we cut instead of fly
    var labels: Bool = true         // zone caption
    var hideSky: Bool = false       // never show sky / void: tilt down + zoom in
    var debugHUD: Bool = false      // state HUD on top of the viewer
    var cache: String = ""          // "" = whatever the viewer calls latest

    // MARK: Defaults storage

    /// `ScreenSaverDefaults` isolates preferences per saver module. Inside the
    /// sandboxed appex this may resolve into the extension container; `source`
    /// is shown in the sheet so the behaviour can be verified on device.
    static let moduleName = "org.osrsmapsaver.saver"

    static var store: UserDefaults {
        ScreenSaverDefaults(forModuleWithName: moduleName) ?? .standard
    }

    static var usesScreenSaverDefaults: Bool {
        store is ScreenSaverDefaults
    }

    /// Empirical answer to "where did the prefs actually go": scan the plist
    /// directories that matter for this process and report matching files.
    static func preferenceFiles() -> [String] {
        let directories = [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Preferences"),
            URL(fileURLWithPath: SaverPaths.realHome).appendingPathComponent("Library/Preferences"),
            URL(fileURLWithPath: SaverPaths.realHome).appendingPathComponent(
                "Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Preferences"
            ),
            URL(fileURLWithPath: SaverPaths.realHome).appendingPathComponent(
                "Library/Containers/org.osrsmapsaver.harness/Data/Library/Preferences"
            ),
        ]

        var found: [String] = []
        for directory in Array(Set(directories)).sorted(by: { $0.path < $1.path }) {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? []
            for file in files.sorted(by: { $0.path < $1.path }) {
                let name = file.lastPathComponent.lowercased()
                guard name.hasSuffix(".plist"), name.contains("osrsmapsaver") || name.contains("screensaver") else {
                    continue
                }
                found.append(file.path)
            }
            // ByHost variants (machine specific prefs)
            let byHost = directory.appendingPathComponent("ByHost")
            let hostFiles = (try? FileManager.default.contentsOfDirectory(
                at: byHost,
                includingPropertiesForKeys: nil
            )) ?? []
            for file in hostFiles.sorted(by: { $0.path < $1.path }) {
                let name = file.lastPathComponent.lowercased()
                guard name.contains("osrsmapsaver") else { continue }
                found.append(file.path)
            }
        }
        return Array(NSOrderedSet(array: found)) as? [String] ?? found
    }

    private enum Key {
        static let dwell = "dwell"
        static let fade = "fade"
        static let fps = "fps"
        static let distance = "distance"
        static let fog = "fog"
        static let sky = "sky"
        static let npcChance = "npcChance"
        static let era = "era"
        static let eraEvery = "eraEvery"
        static let minFlight = "minFlight"
        static let maxFlight = "maxFlight"
        static let labels = "labels"
        static let hideSky = "hideSky"
        static let debugHUD = "debugHUD"
        static let cache = "cache"
    }

    // MARK: Load / save

    static func load() -> SaverSettings {
        let store = SaverSettings.store
        var settings = SaverSettings()
        let defaults = SaverSettings()

        if let value = number(store, Key.dwell) {
            settings.dwell = min(max(value, 5), 900)
        }
        if let value = number(store, Key.fade) {
            settings.fade = min(max(value, 0.1), 5)
        }
        if let value = number(store, Key.fps) {
            settings.fps = Int(min(max(value.rounded(), 5), 120))
        }
        if let value = number(store, Key.distance) {
            settings.distance = Int(min(max(value.rounded(), 64), 512))
        }
        if let value = number(store, Key.fog) {
            settings.fog = Int(min(max(value.rounded(), 0), 256))
        }
        if let value = string(store, Key.sky), let parsed = SaverSettings.parseHex(value) {
            settings.skyHex = parsed
        }
        if let value = number(store, Key.npcChance) {
            settings.npcChance = min(max(value, 0), 1)
        }
        if let value = string(store, Key.era), let era = EraMode(rawValue: value) {
            settings.era = era
        }
        if let value = number(store, Key.eraEvery) {
            settings.eraEvery = Int(min(max(value.rounded(), 1), 50))
        }
        if let value = number(store, Key.minFlight) {
            settings.minFlight = Int(min(max(value.rounded(), 0), 5000))
        }
        if let value = number(store, Key.maxFlight) {
            settings.maxFlight = Int(min(max(value.rounded(), 0), 5000))
        }
        if let value = boolean(store, Key.labels) {
            settings.labels = value
        }
        if let value = boolean(store, Key.hideSky) {
            settings.hideSky = value
        }
        if let value = boolean(store, Key.debugHUD) {
            settings.debugHUD = value
        }
        if let value = string(store, Key.cache) {
            settings.cache = value
        }

        settings.sanitise(basedOn: defaults)
        return settings
    }

    func save() {
        let store = SaverSettings.store
        store.set(dwell, forKey: Key.dwell)
        store.set(fade, forKey: Key.fade)
        store.set(fps, forKey: Key.fps)
        store.set(distance, forKey: Key.distance)
        store.set(fog, forKey: Key.fog)
        store.set(skyHex, forKey: Key.sky)
        store.set(npcChance, forKey: Key.npcChance)
        store.set(era.rawValue, forKey: Key.era)
        store.set(eraEvery, forKey: Key.eraEvery)
        store.set(minFlight, forKey: Key.minFlight)
        store.set(maxFlight, forKey: Key.maxFlight)
        store.set(labels, forKey: Key.labels)
        store.set(hideSky, forKey: Key.hideSky)
        store.set(debugHUD, forKey: Key.debugHUD)
        store.set(cache, forKey: Key.cache)
        store.synchronize()
    }

    static func resetToDefaults() {
        let store = SaverSettings.store
        for key in [
            Key.dwell, Key.fade, Key.fps, Key.distance, Key.fog, Key.sky,
            Key.npcChance, Key.era, Key.eraEvery, Key.minFlight, Key.maxFlight,
            Key.labels, Key.hideSky, Key.debugHUD, Key.cache,
        ] {
            store.removeObject(forKey: key)
        }
        store.synchronize()
    }

    /// Keeps `minFlight <= maxFlight` and a sane sky colour.
    mutating func sanitise(basedOn defaults: SaverSettings = SaverSettings()) {
        dwell = min(max(dwell, 5), 900)
        fade = min(max(fade, 0.1), 5)
        fps = min(max(fps, 5), 120)
        distance = min(max(distance, 64), 512)
        fog = min(max(fog, 0), 256)
        npcChance = min(max(npcChance, 0), 1)
        eraEvery = min(max(eraEvery, 1), 50)
        minFlight = min(max(minFlight, 0), 5000)
        maxFlight = min(max(maxFlight, 0), 5000)
        if minFlight > maxFlight {
            swap(&minFlight, &maxFlight)
        }
        if SaverSettings.parseHex(skyHex) == nil {
            skyHex = defaults.skyHex
        }
    }

    // MARK: URL query

    /// Everything the web app reads. `preview` keeps the System Settings pane cheap.
    func queryString(isPreview: Bool, debugFileEnabled: Bool) -> String {
        var query = "ambient=1&saver=1"
        if isPreview { query += "&preview=1" }
        if debugFileEnabled || debugHUD { query += "&debug=1" }

        let effectiveFPS = isPreview ? min(fps, 20) : fps
        let effectiveDistance = isPreview ? min(distance, 192) : distance

        query += "&fps=\(effectiveFPS)"
        query += "&distance=\(effectiveDistance)"
        query += "&dwell=\(Self.format(dwell))"
        query += "&fade=\(Self.format(fade))"
        query += "&fog=\(fog)"
        query += "&sky=\(hexValue)"
        query += "&npc=\(Self.format(npcChance, decimals: 2))"
        query += "&era=\(era.rawValue)"
        query += "&eraevery=\(eraEvery)"
        query += "&minflight=\(minFlight)"
        query += "&maxflight=\(maxFlight)"
        query += "&labels=\(labels ? 1 : 0)"
        if hideSky { query += "&nosky=1" }

        if !cache.isEmpty, cache != "latest" {
            query += "&cache=\(cache.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cache)"
        }
        return query
    }

    /// `0xRRGGBB` as a plain integer, which is what the viewer parses.
    var hexValue: Int {
        Int(skyHex, radix: 16) ?? 0
    }

    static func parseHex(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("0x") { text.removeFirst(2) }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count <= 6, !text.isEmpty,
              text.allSatisfy({ $0.isHexDigit }),
              Int(text, radix: 16) != nil
        else {
            return nil
        }
        return String(repeating: "0", count: 6 - text.count) + text
    }

    private static func format(_ value: Double, decimals: Int = 2) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        var text = String(format: "%.\(decimals)f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    // MARK: Tolerant readers

    /// Values may be written by hand (`defaults write`), so accept strings too.
    private static func number(_ store: UserDefaults, _ key: String) -> Double? {
        if let value = store.object(forKey: key) as? NSNumber { return value.doubleValue }
        if let value = store.object(forKey: key) as? String {
            return Double(value.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func boolean(_ store: UserDefaults, _ key: String) -> Bool? {
        if let value = store.object(forKey: key) as? NSNumber { return value.boolValue }
        if let value = store.object(forKey: key) as? String {
            switch value.trimmingCharacters(in: .whitespaces).lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: return nil
            }
        }
        return nil
    }

    private static func string(_ store: UserDefaults, _ key: String) -> String? {
        if let value = store.object(forKey: key) as? String { return value }
        if let value = store.object(forKey: key) as? NSNumber { return value.stringValue }
        return nil
    }
}
