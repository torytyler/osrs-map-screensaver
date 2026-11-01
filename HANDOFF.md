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
- URL query is built by `SaverSettings.queryString(isPreview:debugFileEnabled:)`
  from the saved prefs: `ambient=1&saver=1` + `preview=1` (preview pane, which also
  caps fps at 20 and distance at 192) + `debug=1` (debug flag **or** the sheet's
  HUD toggle) + every knob in §6, plus `cache=` when a specific cache is chosen.
- Debug flag file: `~/Library/Application Support/OSRSMapSaver/debug` → shows the
  state HUD **and** enables the Web Inspector (`isInspectable`).
- Preferences: `ScreenSaverDefaults`, domain `org.osrsmapsaver.saver`, stored in
  the host container (see §7.2). `SaverSettings.load()/save()` clamp everything.

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
| `nosky` | 0 | bool | hide sky/void: tilt down + zoom in until the frame is all map |
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

## 7. DONE — native "Options…" sheet

Implemented and verified end to end (harness **and** the real host). Files:

| file | role |
| --- | --- |
| `macos/Saver/SaverSettings.swift` | `SaverPaths`, `CacheOption` (reads `caches.json`), `EraMode`, `SaverSettings` (14 clamped knobs, tolerant readers for hand-written prefs), the URL query builder, `SaverLog` |
| `macos/Saver/OptionsWindow.swift` | programmatic `NSWindow` sheet: `NSGridView` rows, `NSSlider` + readout, `NSPopUpButton`, `NSColorWell`, `NSSwitch`, Cancel/OK, Reset to Defaults |
| `macos/Saver/OSRSMapSaverView.swift` | `hasConfigureSheet`/`configureSheet`, query from settings, hot restart on save |

### 7.1 What was verified, and how

`SSEHasConfigureSheet => true` is already declared by
`/System/Library/Frameworks/ScreenSaver.framework/PlugIns/legacyScreenSaver.appex`,
so legacy sheets are supported. Confirmed on this machine:

- System Settings → Screen Saver → RuneScape World → **Options…** shows the sheet.
- Sliders/popups/colour well/switch edits reach the viewer: the save logged
  `distance=512&fog=0&sky=35583&era=legacy&cache=rs2-295_2005-02-21`.
- Cancel dismisses without writing; OK saves and reloads the web view (~150 ms,
  map data comes from `CacheStorage`).
- System Settings creates a **fresh view per visit**, so `configureSheet` is built
  again each time (the retained-instance branch rarely runs there).

Harness flags added for this (`macos/Host/main.swift`): `--show-options`,
`--options-edit`, `--options-ok-after <s>`, `--options-cancel-after <s>`,
`--options-screenshot <path>`. `--options-edit` drives the real controls (sliders,
popups, colour well, switch) and then presses OK, which is the end-to-end test.

### 7.2 Where the preferences live (answered)

The old worry — that `ScreenSaverDefaults` might be redirected into the container
and end up in a different domain than the one System Settings writes — does not
happen. Inside the sandbox the domain is still **`org.osrsmapsaver.saver`**, but
it is stored in the *host's* container:

```
~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Preferences/ByHost/org.osrsmapsaver.saver.<UUID>.plist
```

That is persistent and consistent (preview and full-screen runs use the same
appex), so **no `settings.json` fallback is needed**. Note it is a `ByHost`
(machine-specific) domain, so `defaults read org.osrsmapsaver.saver` from a normal
shell will *not* show it — read the plist above, or
`defaults -currentHost read org.osrsmapsaver.saver`.

`SaverSettings.preferenceFiles()` scans the likely plist directories and is logged
whenever the sheet is built or saved, so this stays verifiable.

### 7.3 Gotchas found while wiring it

**The sheet must be able to become key.** Inside `legacyScreenSaver.appex` the
host attaches our window as a sheet and then calls `makeKeyWindow`, which asks the
window `canBecomeKeyWindow`. For a plain `NSWindow` subclass with
`.titled` that should answer YES, but in the appex it answered **NO** on this
machine — and the result is a sheet that is built and attached but never becomes
interactive (System Settings looks like it does nothing; the only trace is one
line in the system log):

```
Warning: -[NSWindow makeKeyWindow] called on <OSRSMapSaver.OptionsWindow>
which returned NO from -[NSWindow canBecomeKeyWindow].
```

`OptionsWindow` now overrides `canBecomeKey -> true` (and `canBecomeMain ->
false`), which fixed it. While debugging this the sheet had also grown past the
host window's height (701pt after adding a row), so `OptionsWindow` now keeps its
content at or below 640pt and clamps to `visibleFrame.height - 120`. If a future
change makes the sheet grow, test **in System Settings**, not just in the
harness — the harness presents sheets happily at sizes the host will not.

Diagnostics for this path are in the `configure sheet built:` log line: thread,
size, `canBecomeKey` and `styleMask`. Check it with

```sh
grep "configure sheet built" \
  ~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Logs/saver.log
```

`configureSheet` also hops to the main thread if the host asks from its extension
queue (building AppKit windows off-main is not supported), and the harness has
`--options-via-app` to present the sheet with `NSApp.beginSheet` the way the host
does.

- End the sheet with `window.sheetParent?.endSheet(window)`, falling back to
  `NSApp.endSheet` — `NSApp.endSheet` is deprecated and does not always have a
  parent to talk to.
- Do not reparent or resize the web view when the sheet opens; the sheet belongs to
  the host window, not to the saver view.
- Store the sheet window in a property, otherwise it is deallocated while on screen.
- In the sandboxed harness, `print()` to a redirected stdout is block-buffered —
  `setvbuf(stdout, nil, _IONBF, 0)` (otherwise diagnostics appear to vanish).

### 7.4 Sky guard (`nosky`)

`src/ambient/SkyGuard.ts` — a toggle ("Hide sky & void" in the sheet) that keeps
unmapped space out of frame. Geometry: for camera height `h` and a top-edge ray at
`tilt - fov/2`, the ground is `h / tan(...)` away; the guard demands that distance
stay inside `safeRadius = renderDistance - fogDepth` (min 96) by tilting down, and
narrows the FOV when the tilt budget (74°) runs out. Then it samples the actual
ground footprint (13 columns x 5 rings, from the bottom of the frame to the top)
against the map's terrain grid (`MapManager.invalidMapIds` + square bounds) and
keeps narrowing *while tightening removes unmapped samples* — a hole underfoot
cannot be framed away, so it stops instead of collapsing the shot.

Three gotchas worth knowing:

- The map manager only queues squares that are **already inside the frustum**, so
  the far edge of a moving shot spends ~1 s as a hole. `SkyGuard.edgePrefetchPoints`
  (the footprint ring, pushed out by 1.12x) is loaded every 6 frames by the director.
- Fog is not "the last N tiles of the draw distance": the shader fades inward from
  the render-distance boundary, so `fogDepth` eats into the visible radius.
- If a spot cannot be framed cleanly (data holes in the 2005 cache), `beginDwell()`
  vetoes the zone and picks another (max 6 tries).

Measured with a magenta sky (`sky=16711935`) so void pixels are countable, sweeping
dwell + flights: **20.0% mean / 36% max out-of-map pixels with the guard off,
0.03% mean / 0.54% max with it on**, every sampled frame `clean`.

### 7.5 Still open

- The sky guard's constants (FOV_MIN 14, TILT_MAX 74, HORIZON_MARGIN 2.5, slew
  rates) are tuned for the default 320/96 camera; they are not URL-exposed.
- Motion/flight tunables are still hard-coded in `scenes.ts` (`createFlight()` cruise
  speed, duration clamp, arc height; per-motion ranges; `PoseSmoother(0.14)`; NPC
  smoothing `0.22`). Exposing them needs new URL params plus sheet controls.
- Worker count / `lite` profile is not in the sheet.
- Display policy ("external only / all / main") is native-only and not user
  configurable yet — it belongs in `SaverSettings` + `shouldPlayOnThisDisplay`.
- Presets (Cinematic / Chill / Low power) would be ~30 lines on top of
  `SaverSettings`.
- Live apply (`window.__ambient.applyOptions(...)`) instead of a reload.

## 8. Known limitations / possible follow-ups

- True **mirroring across displays is not possible** (one WebGL canvas per
  `WKWebView`). Current policy avoids the cost by playing on one display only.
- First launch in the saver downloads the cache into WebKit's container
  (a few seconds from localhost). Nothing prefetches it for the user.
- The support-directory caches used to be a symlink into `repo/caches`; they are
  now a real copy (so deleting/moving the checkout cannot break the saver).
  `repo/caches` still exists for `preview.sh`/`serve.mjs` — two independent copies,
  ~250 MB each.
- Offline snapshots: `scripts/caches-backup.sh create|verify|restore` writes a
  `.tar.zst` (~209 MB, 83% of raw — the Jagex data is already compressed) plus a
  `.sha256` sidecar to `~/Documents/osrs_map_screensaver-offline/`.
  `install.sh --offline <archive>` restores it, and macOS `tar` reads `.tar.zst`
  with no extra tools, so a reinstall needs no Node and no network for the caches.
- The same archive is published as its own release (`tag = caches-YYYY-MM-DD`,
  asset `osrs-caches-YYYY-MM-DD.tar.zst` + `.sha256`). `install.sh` knows it via
  the `CACHE_RELEASE` / `CACHE_ASSET` / `CACHE_MIRROR_URL` constants at the top;
  `--caches-mirror` downloads that instead of hitting OpenRS2. **Bump those three
  constants whenever a new snapshot is published**, otherwise `--caches-mirror`
  keeps serving the old tag.
- `legacyScreenSaver` sometimes gets (re)spawned by `wallpaper.agent` and keeps
  the saver running as a wallpaper after unlock — macOS 26 behaviour, not ours.
- Flight/camera tunables are hard-coded; making motion weights and speed
  URL-configurable would let the options sheet expose them.
- The zone list is hand-curated; adding per-zone `fov`/`motion` preferences would
  improve specific spots.
- Upstream re-sync: the fork is `dennisdev/rs-map-viewer` at `d3c569b`; our work is
  in `15cbda8` (ambient mode) and `5ad5761` (polish). All changed upstream files are
  small, additive and listed in §3 — trivial to rebase.

---

## 9. Publishing

Two public repositories:

| repo | contents |
| --- | --- |
| `torytyler/osrs-map-screensaver` | this directory (native saver, scripts, docs, media) |
| `torytyler/rs-map-viewer` | fork of `dennisdev/rs-map-viewer` with `src/ambient/` |

`repo/` stays gitignored here; `install.sh` clones the viewer fork into `repo/`
when it is missing. `scripts/fetch-caches.py` is a `python3`-stdlib-only port of
`repo/scripts/fetch-cache.mjs`, used by `install.sh --binary` so the prebuilt path
needs no Node.js (verified byte-identical output).

Release asset `OSRSMapSaver.saver.zip` contains the built bundle (web build
included), `fetch-caches.py` and `INSTALL.txt`. Build it with
`scripts/make-release-zip.sh` — **never** with a bare `zip -r` into a path that
already exists: `zip` updates archives instead of replacing them, which once
shipped a 0.2.0 asset mixing the 0.1.0 and 0.2.0 web builds. Those extra files are
not in `_CodeSignature/CodeResources`, so the seal is invalid and the appex fails
at load time. The script wipes the target, then round-trips the zip and checks
`codesign --verify --deep --strict` plus "exactly one `main.*.js`".

One more publishing gotcha: after re-uploading an asset, GitHub's CDN can keep
serving the previous object at the same URL for a few minutes. `curl` the plain
`releases/latest/download/...` URL and compare `shasum -a 256` with your local zip
before believing an install test. The banner in `media/` is a 32:9
crop of `header.mp4` (`crop=1024:288:0:126`, i.e. the laptop screen stays centred):

```sh
# GIF for the README (896x252, 10 fps, palette + lossy, ~3 MB)
ffmpeg -i header.mp4 -vf "crop=1024:288:0:126,hqdn3d=2:2:5:5,scale=896:-2:flags=lanczos,fps=10,\
split[a][b];[a]palettegen=stats_mode=diff:max_colors=96[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  -loop 0 /tmp/b.gif && gifsicle -O3 --lossy=80 /tmp/b.gif -o media/banner.gif
ffmpeg -i header.mp4 -vf "crop=1024:288:0:126" -an -c:v libvpx-vp9 -crf 34 -b:v 0 media/banner.webm
ffmpeg -i header.mp4 -vf "crop=1024:288:0:126" -an -c:v libx264 -crf 20 -pix_fmt yuv420p -movflags +faststart media/banner.mp4
```

## 10. Commands cheat sheet

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
