# RuneScape World — macOS screen saver · handoff notes

Everything here is working and installed as of the last session. Use this file to
pick the project up cold.

```
~/Documents/osrs_map_screensaver/
├── repo/          fork of dennisdev/rs-map-viewer + src/ambient/ (the camera engine)
├── macos/         OSRSMapSaver.saver (Swift) + dev harness app
├── install.sh     web build → caches → build + install the .saver
├── preview.sh     same app in a browser, for fast iteration
├── README.md      user-facing docs (params, troubleshooting)
└── HANDOFF.md     this file
```

Installed at `~/Library/Screen Savers/OSRSMapSaver.saver`, shows up in System
Settings as **“RuneScape World”**.

---

## 1. What it does

A `.saver` bundle hosts a `WKWebView` that runs the real OSRS map viewer. The
viewer gets an "ambient" camera engine (`?ambient=1`):

- pick a curated zone (76 of them) → fly there (or fade-cut if it is far away)
- hold a slow `orbit` / `pan` / `drift` / `push` move for `dwell` seconds, or
  follow a wandering NPC
- every few zones, swap the OSRS cache for the Feb-2005 cache (`rs2-295`) —
  restricted to zones that existed then
- repeat forever; the dwell timer only starts when the camera has arrived

Rendering: upstream WebGL2 engine, 320-tile draw distance, 30 fps, ~2 workers.

---

## 2. Build / run / test

```sh
cd ~/Documents/osrs_map_screensaver

./install.sh              # full build + install (~30 s, caches already present)
./preview.sh              # browser at localhost:3200, ?ambient=1&debug=1
./preview.sh "ambient=1&zone=Varrock%20Square&debug=1"

# native bundle + harness (no lock screen needed):
cd repo && npm run build && cd ..
macos/build.sh                    # builds .saver + harness into macos/build
macos/build.sh install            # + copies to ~/Library/Screen Savers
macos/build/OSRSMapSaverHarness.app/Contents/MacOS/OSRSMapSaverHarness \
  "$PWD/macos/build/OSRSMapSaver.saver" --quit-after 120
```

Harness flags: `--fullscreen`, `--quit-after <s>`, `--hide-after <s>`
(orders the window out), `--cover-after <s>` (covers it with an opaque window —
this reproduces the "occluded" bug).

Logs:

- saver inside the extension:
  `~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Logs/saver.log`
  (every HTTP request, page state, and a 5 s heartbeat with zone/phase/camera)
- harness: `~/Library/Containers/org.osrsmapsaver.harness/Data/Library/Logs/saver.log`
  (also mirrored to stderr)

Node 24 + `npx yarn@1.22.22` are used because the repo is a CRA 5 app and yarn
isn't installed globally. `npm run build` works too.

---

## 3. Architecture

```
ScreenSaverEngine  (system)
└── legacyScreenSaver.appex   ← sanboxed host on macOS 26+, launched by wallpaper.agent
    └── OSRSMapSaver.saver
        ├── OSRSMapSaverView : ScreenSaverView, WKNavigationDelegate
        │     ├── PassiveWebView (WKWebView, swallows input)
        │     └── HTTPServer (Network.framework, 127.0.0.1:<ephemeral>)
        │           ├── /         → Contents/Resources/web   (CRA build)
        │           └── /caches/* → ~/Library/Application Support/OSRSMapSaver/caches
        └── (one view + server per display)
```

Why a local HTTP server instead of `file://` or a custom scheme: the viewer needs
a real origin for workers, WASM, `CacheStorage`, `SharedArrayBuffer`
(COOP/COEP headers) and HTTP `Range` requests. `scripts/serve.mjs` is the
zero-dependency twin of the Swift server, used for browser development.

Caches: downloaded once with `node scripts/fetch-cache.mjs` (OSRS 213 MB +
rs2-295 8 MB), served from disk, then cached by WebKit in its container
(`CacheStorage`), so later launches start instantly.

Web app hooks (all opt-in, the normal viewer is unchanged):

| file | change |
| --- | --- |
| `src/mapviewer/MapViewer.ts` | `ambient?: AmbientDirector`, skips camera→URL mirroring |
| `src/mapviewer/MapViewerRenderer.ts` | `handleInput()` delegates to the director |
| `src/mapviewer/MapViewerApp.tsx` | parses ambient options, builds the era switcher |
| `src/mapviewer/MapViewerContainer.tsx` | hides HUD/menus/leva, starts the director |
| `src/components/renderer/Renderer.ts` | rAF watchdog + timer-loop fallback |
| `src/util/DeviceUtil.ts` | `isScreenSaver`, `isLiteMode` |
| `src/mapviewer/MapManager.ts` | `npcs?` on the `MapSquare` interface |

Ambient engine (`src/ambient/`, ~1 700 lines):

| file | role |
| --- | --- |
| `AmbientConfig.ts` | URL query → `AmbientOptions` (all defaults live here) |
| `AmbientDirector.ts` | state machine `black → dwell → (flight │ fade-out) → …`, era switching, prefetch, `window.__ambient` debug handle |
| `scenes.ts` | `zoneLandingPose`, `createScene` (orbit/pan/drift/push/npc), `createFlight`, `flightPoseAt` |
| `cameraMath.ts` | RS angle/yaw/pitch conversions, `PoseSmoother` (low-pass), seeded RNG, easing |
| `NpcFinder.ts` | picks a nearby NPC from loaded map squares, tracks it live |
| `zones.ts` | 76 curated zones + `LEGACY_ZONE_NAMES` (52 of them exist in 2005) |
| `AmbientOverlay.ts` | plain-DOM fade-to-black, zone caption, optional debug HUD |

---

## 4. Two gotchas that cost hours (do not regress)

### 4.1 `NSHomeDirectory()` is the sandbox container

Inside `legacyScreenSaver.appex`, `NSHomeDirectory()` → `~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data`.
Caches live in the **real** home. Use
`getpwuid(getuid()).pw_dir` (`OSRSMapSaverView.realHomeDirectory`).
Logs go to the container (`Library/Logs/saver.log`) because only the container is
writable; the appex has a read-only `/` exception, so reading the real home is fine.

### 4.2 WebKit marks the saver's window "occluded" → black screen

`requestAnimationFrame` fires **once**, all timers throttle to 1 Hz, the page
reports `visibility: hidden`, and you get "cache loads, then black forever".

Fix (both are in place):

1. `_setWindowOcclusionDetectionEnabled:false` on the `WKWebView` — private API,
   called through `unsafeBitCast` after `responds(to:)`. This is what actually
   makes it render. Verified with an A/B test: covered window → 30 fps with the
   fix, frozen at 1 fps without it.
2. `Renderer` watchdog: if rAF starves for >1 s it switches to a `setTimeout`
   loop (still throttled when hidden, but keeps things alive).

`OSRS_SAVER_NO_OCCLUSION_FIX=1` disables fix #1 for testing. Do **not** reparent
the web view into an `NSWindow` of our own — it "works" but renders on the wrong
layer (behind the desktop, black on the lock screen). That was tried and removed.

---

## 5. Native side reference

- Bundle id `org.osrsmapsaver.saver`, principal class `OSRSMapSaverView`,
  `CFBundleDisplayName = "RuneScape World"`, icon `Contents/Resources/AppIcon.icns`.
- Selection is stored by the system in
  `~/Library/Preferences/ByHost/com.apple.screensaver.<UUID>.plist`
  (`moduleName = OSRSMapSaver`, `modulePath = …/OSRSMapSaver.saver`).
- `startAnimation()` → `startWebContent()`: starts the server, builds the URL
  query, creates the web view, loads `http://127.0.0.1:<port>/?…`.
- `stopAnimation()` tears down the server and the web view.
- **Display policy:** one view per display; when an external display exists only
  that one plays and the built-in panel stays black
  (`shouldPlayOnThisDisplay`). `OSRS_SAVER_FORCE_PLAY=1` overrides (harness sets it).
- URL query currently built in `startWebContent()`:
  `ambient=1&saver=1` + `&preview=1` (`isPreview`) + `&debug=1` (if the debug flag
  exists) + optional `&fps=`.
- Debug flag file: `~/Library/Application Support/OSRSMapSaver/debug` → shows the
  state HUD **and** enables the Web Inspector (`isInspectable`).
- `SaverSettings.fpsLimit` is a placeholder — this is the natural place to read
  real preferences (see §7).

`macos/build.sh`: `swiftc -emit-library` universal (arm64 + x86_64) → `.saver`
bundle, copies `build/` into `Contents/Resources/web`, ad-hoc codesigns, builds
the harness app, optional `install` target.

---

## 6. Ambient parameters (current)

Defaults in `repo/src/ambient/AmbientConfig.ts`:

| param | default | range | notes |
| --- | --- | --- | --- |
| `ambient` | – | any | `1` random rotation, or a zone name to pin it |
| `dwell` | 30 | 5–900 | seconds parked; timer starts on arrival |
| `fade` | 1 | 0.1–5 | cross-fade for long jumps |
| `fps` | 30 (20 preview) | 5–120 | renderer cap |
| `distance` | 320 (192 preview) | 64–512 | render distance, tiles |
| `fog` | 96 | 0–256 | fog band at the edge of the draw distance |
| `sky` | 0x000000 | 0–0xffffff | sky/fog colour |
| `npc` | 0.5 | 0–1 | chance a scene follows an NPC |
| `minflight` | 140 | 0–5000 | below this we cut instead of fly |
| `maxflight` | 950 | 0–5000 | above this we cut instead of fly |
| `era` | mixed | latest/legacy/mixed | cache rotation |
| `eraevery` | 4 | 1–50 | zones between era switches |
| `labels` | 1 | bool | zone caption |
| `debug` | 0 | bool | state HUD |
| `seed` | random | int | deterministic rotation |
| `lite` | – | flag | 1 worker (`isLiteMode`) |
| `preview` | – | flag | low-cost preview profile |
| `saver` | – | flag | marks saver mode (`isScreenSaver`) |
| `cache` | latest | cache name | initial cache (existing upstream param) |

Motion tunables that are **not** URL-exposed yet:

- `createFlight()` in `scenes.ts`: cruise speed `range(15, 24)` tiles/s,
  duration clamp `9…34 s`, arc `distance × 0.16`, arrival blends.
- Per-motion ranges in `scenes.ts` (orbit sweep, drift speed, pan sweep, fov).
- `PoseSmoother(0.14)` in `AmbientDirector`, NPC smoothing τ `0.22`.
- `zone.height` / `zone.radius` per zone in `zones.ts`.

**Adding a parameter:** add to `AmbientOptions` → parse in `AmbientConfig.ts` →
consume in the director/scene → append to the saver's query string → expose in the
options UI. Nothing else needed.

---

## 7. NEXT TASK — native "Options…" sheet (very customizable)

Goal: the standard macOS screen saver options sheet (the “Options…” button in
System Settings), from which the user can tune almost everything, including which
cache to use.

### 7.1 The AppKit contract (verified against the macOS 27 SDK)

```swift
// ScreenSaverView.h
@property (readonly) BOOL hasConfigureSheet;
@property (readonly, strong) NSWindow * _Nullable configureSheet;
```

- Override `hasConfigureSheet` → `true`.
- Override `configureSheet` → return a window (build it programmatically or from
  a NIB). The system runs it as a sheet; the window must contain its own
  **Cancel** / **OK** (or "Done") buttons.
- End the modal session yourself, exactly as documented:

```swift
NSApp.endSheet(sheetWindow)          // or beginSheet/endSheet pair
sheetWindow.orderOut(nil)
```

- The host (`legacyScreenSaver.appex`) declares
  `SSEHasConfigureSheet = true` and
  `ScreenSaverConfigurationSheetViewControllerClass = LegacyConfigurationViewController`,
  so legacy sheets are supported in the extension. **Not yet tested on this
  machine** — first thing to validate:

```sh
# quick smoke test without System Settings:
macos/build/OSRSMapSaverHarness.app/Contents/MacOS/OSRSMapSaverHarness "$PWD/macos/build/OSRSMapSaver.saver"
# then: instantiate the view, call view.configureSheet, present it as a sheet
#       from the harness window (add a --show-options flag to Host/main.swift).
```

### 7.2 Where to store the preferences

Use `ScreenSaverDefaults(forModuleWithName: "org.osrsmapsaver.saver")` (a
subclass of `NSUserDefaults` that isolates per-module prefs). Use
`register(defaults:)` for the defaults table so the UI can rely on all keys
existing, then `synchronize()` on save.

Caveat to verify early: inside the sandboxed appex these prefs may be redirected
into the container. If System Settings and the saver end up reading different
domains, fall back to a JSON file in
`~/Library/Application Support/OSRSMapSaver/settings.json` (read in the saver,
written by the sheet) — the appex can read the real home but **cannot write**
there, so such a fallback would have to be written by an installer helper or from
the sheet while running in a writable context. Test `ScreenSaverDefaults` first;
it is the intended API.

### 7.3 Proposed architecture

```
macos/Saver/
├── SaverSettings.swift      # Codable struct + ScreenSaverDefaults load/save,
│                            #   defaults table, sanitising/clamping
├── OptionsWindow.swift      # programmatic NSWindow + NSStackView/NSGridView form
└── (OSRSMapSaverView)      # hasConfigureSheet/configureSheet, builds query from settings
```

- `SaverSettings` becomes a `struct` with every knob (dwell, fps, distance, fog,
  sky, npcChance, era mode, eraEvery, min/max flight, labels, fov jitter,
  default cache, per-display policy, worker count, smoothing τ…), plus
  `static func load() -> SaverSettings` / `func save()`.
- `OSRSMapSaverView.startWebContent()` builds the query from `SaverSettings.load()`
  instead of hard-coded literals.
- `configureSheet` lazily creates `OptionsWindow` (keep it as a stored property so
  the sheet window is retained). On OK: save → if the web view is running, either
  `webView.reload()` with the new query (simplest) or apply live via
  `evaluateJavaScript("window.__ambient?.applyOptions(...)")` (nice, but needs a
  new hook). Reload is fine: the cache lives in CacheStorage, so it is fast.
- Cache list for the dropdown: parse
  `~/Library/Application Support/OSRSMapSaver/caches/caches.json`
  (`name`, `game`, `revision`, `timestamp`, `size`) — exactly what
  `repo/scripts/fetch-cache.mjs` writes. Show “OSRS rev 241 (213 MB)” style
  labels. A “Download another cache…” button could shell out…… **no**, the appex
  cannot spawn processes; instead point users at `node repo/scripts/fetch-cache.mjs …`
  or implement an in-page download later.
- Sheet controls worth including (macOS-native: `NSSlider`, `NSStepper`,
  `NSPopUpButton`, `NSSwitch`/`NSButton(.switch)`, `NSColorWell`,
  `NSLevelIndicator`?):
  - **Cache**: popup (latest / 2005 / specific) + "rotation" `era` (off/mixed)
    and `eraevery`.
  - **Pacing**: `dwell` (5–300 s), `fade` (0.3–3 s).
  - **Camera**: `fps`, `distance`, `fog`, `sky` colour well, `labels` toggle.
  - **Motion**: `npc` chance, `minflight`/`maxflight`, maybe motion weights
    (orbit/pan/drift/push) — needs a new URL param (`weights=3,2,2,1.6`).
  - **Displays**: “play on: external only / all displays / main only” —
    new native setting consumed by `shouldPlayOnThisDisplay`.
  - **Advanced**: worker count, `debug` HUD toggle, “Reset to defaults”.
- Persist on OK, clamp/sanitise every value (the values become a URL query).

### 7.4 Testing plan

1. `--show-options` flag in `Host/main.swift`: instantiate the view, call
   `hasConfigureSheet`/`configureSheet`, present the sheet on the harness window.
   Verify layout and save/load round-trip (`defaults read org.osrsmapsaver.saver`).
2. Manual: System Settings → Screen Saver → RuneScape World → **Options…**.
   Confirm the sheet appears and the saver picks up the new settings after
   previewing again (the engine recreates the view).
3. Add a few “sane” presets (e.g. *Cinematic*, *Chill*, *Low power* → fps 20,
   distance 224, npc 0.7).

---

## 8. Known limitations / possible follow-ups

- True **mirroring across displays is not possible** (one WebGL canvas per
  `WKWebView`). Current policy avoids the cost by playing on one display only.
- First launch in the saver downloads the cache into WebKit's container
  (a few seconds from localhost). Nothing prefetches it for the user.
- Caches live behind a **symlink** to `repo/caches` right now
  (`~/Library/Application Support/OSRSMapSaver/caches`). If the repo moves,
  replace it with a real copy (`rm` + rerun `./install.sh`).
- `legacyScreenSaver` sometimes gets (re)spawned by `wallpaper.agent` and keeps
  the saver running as a wallpaper after unlock — macOS 26 behaviour, not ours.
- Flight/camera tunables are hard-coded; making motion weights and speed
  URL-configurable would let the options sheet expose them.
- `SaverSettings.fpsLimit` is dead code waiting for the options sheet.
- The zone list is hand-curated; adding per-zone `fov`/`motion` preferences would
  improve specific spots.
- Upstream re-sync: the fork is `dennisdev/rs-map-viewer` at `d3c569b`; our work is
  in `15cbda8` (ambient mode) and `5ad5761` (polish). All changed upstream files are
  small, additive and listed in §3 — trivial to rebase.

---

## 9. Commands cheat sheet

```sh
# rebuild everything and install
./install.sh

# just the native bundle (web build must exist)
macos/build.sh install

# run the same bundle in a window (external-display policy bypassed)
macos/build/OSRSMapSaverHarness.app/Contents/MacOS/OSRSMapSaverHarness \
  "$PWD/macos/build/OSRSMapSaver.saver" --quit-after 120

# watch the saver that the system is running
tail -f ~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Logs/saver.log

# reload the installed saver after a rebuild
killall ScreenSaverEngine legacyScreenSaver 2>/dev/null

# download / refresh caches (OSRS + 2005 by default)
cd repo && node scripts/fetch-cache.mjs
node scripts/fetch-cache.mjs osrs-240      # any archive prefix

# type-check the web app
cd repo && npx tsc --noEmit -p tsconfig.json
```
