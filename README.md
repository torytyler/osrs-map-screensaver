# RuneScape World — macOS screen saver

An ambient screen saver built on [dennisdev/rs-map-viewer](https://github.com/dennisdev/rs-map-viewer)
(the engine behind <https://osrs.world>). It flies a camera around the real
RuneScape world: it lands in a random zone, slowly orbits/pans/pushes in (or
follows a wandering NPC), then flies to the next zone and does it again.

```
osrs_map_screensaver/
├── repo/                 fork of rs-map-viewer (web app + ambient mode)
│   ├── src/ambient/      the screen saver camera engine (new)
│   └── scripts/          fetch-cache.mjs, serve.mjs (local static + cache server)
├── macos/
│   ├── Saver/            ScreenSaverView + WKWebView + embedded HTTP server
│   ├── Host/             dev harness app (runs the .saver in a window)
│   └── build.sh          builds OSRSMapSaver.saver, installs it
├── install.sh            full install (web build → caches → .saver)
└── preview.sh            run the same thing in a browser for fast iteration
```

Picking this up cold? Read **[HANDOFF.md](HANDOFF.md)** — file map, the two
macOS gotchas that cost the most time, every tunable, and the plan for the native
Options sheet.

## How it works

macOS still supports legacy `.saver` bundles, but on modern macOS they are
loaded into `ScreenSaver.framework/PlugIns/legacyScreenSaver.appex` — a
**sandboxed** app extension. That sandbox allows reading anywhere, listening on
a local port and WebKit, which is exactly what this design needs.

```
ScreenSaverEngine
└── legacyScreenSaver.appex  (sandboxed)
    └── OSRSMapSaver.saver
        ├── ScreenSaverView → WKWebView
        └── HTTPServer (Network.framework, 127.0.0.1:<random>)
              ├── /          → Contents/Resources/web (the React build)
              └── /caches/*  → ~/Library/Application Support/OSRSMapSaver/caches
```

A local HTTP server is used instead of `file://` because the viewer needs a real
origin for workers, WASM, `CacheStorage`, `SharedArrayBuffer` (COOP/COEP) and
HTTP `Range` requests. The RS cache (~213 MB for current OSRS) is downloaded once
and then cached inside WebKit's container, so later launches start immediately.

The renderer itself is the upstream WebGL2 engine: it parses the actual Jagex
cache and streams map squares in web workers.

## Install

```sh
./install.sh
```

Then System Settings → Screen Saver → **RuneScape World**.

## Dev loop

```sh
./preview.sh                                  # browser, hot-reloadable build
./preview.sh "ambient=1&zone=Varrock%20Square&debug=1"
```

Screen saver bundle without the real screen saver:

```sh
(cd repo && npm run build)
macos/build.sh                 # build .saver + harness
open macos/build/OSRSMapSaverHarness.app --args "$PWD/macos/build/OSRSMapSaver.saver" --quit-after 120
```

Logs: `~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Logs/OSRSMapSaver.log`
(or `/tmp/osrs-preview.log` when using `preview.sh`).

## Ambient URL parameters

| param | default | meaning |
| --- | --- | --- |
| `ambient` | – | `1` enables; a zone name pins that zone (`?ambient=Lumbridge`) |
| `dwell` | `30` | seconds parked in a scene (timer starts on arrival) |
| `fade` | `1` | cross-fade seconds for long jumps |
| `fps` | `30` | frame cap |
| `distance` | `320` | render distance in tiles (`192` in the preview pane) |
| `fog` | `96` | fog band at the edge of the render distance |
| `sky` | `0x000000` | sky/fog colour |
| `npc` | `0.5` | chance a scene follows a wandering NPC |
| `era` | `mixed` | `latest`, `legacy` (2005 cache) or `mixed` (switch every few zones) |
| `eraevery` | `4` | zones between era switches |
| `lite` | – | low-cost profile (1 worker) |
| `minflight` / `maxflight` | `140` / `950` | distance window where we fly instead of cut |
| `labels` | `1` | zone name caption |
| `debug` | `0` | state/FPS overlay |
| `seed` | random | deterministic zone rotation |

## The ambient camera engine

`repo/src/ambient/`:

- `zones.ts` — ~75 hand-picked places with a radius and preferred camera height.
- `scenes.ts` — motion models (`orbit`, `pan`, `drift`, `push`, `npc`) that are
  pure functions of time, so nothing drifts; plus the flight path and landing
  pose. Every scene starts exactly on the pose a flight lands on.
- `NpcFinder.ts` — picks a nearby NPC from the loaded map squares and tracks it
  live (NPCs wander and animate in the upstream engine).
- Era rotation swaps the OSRS cache for the Feb-2005 cache (`rs2-295`) every few
  zones, restricted to the zones that existed back then.
- `AmbientDirector.ts` — the state machine: `black → dwell → (flight | fade-out)
  → …`, scene selection, prefetching along the flight path, debug state.
- `AmbientOverlay.ts` — fade-to-black, zone caption, debug HUD (plain DOM, no
  React re-renders).

Hooks into the upstream app are small and opt-in (`?ambient=…`), so the normal
map viewer keeps working unchanged:

- `MapViewer.ambient` disables camera→URL mirroring.
- `MapViewerRenderer.handleInput()` delegates to the director instead of input.
- `MapViewerContainer` hides the HUD/menus and skips React state churn.

## Troubleshooting

The interesting one: on macOS 26+ legacy savers are hosted by the sandboxed
`legacyScreenSaver` app extension, whose window WebKit classifies as **occluded**.
That silently stops `requestAnimationFrame` and throttles timers to 1 Hz, which
looks exactly like a black screen while the cache loads fine. The saver disables
that heuristic with WebKit's private `_setWindowOcclusionDetectionEnabled:` and
`Renderer` additionally falls back to a timer loop if rAF ever starves.

Diagnostics land in
`~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Logs/saver.log`
(every request, page state, a 5 s heartbeat with the camera/zone/phase).
`?debug=1` (or a `debug` file in `~/Library/Application Support/OSRSMapSaver/`)
shows the state overlay and enables the Web Inspector. `OSRS_SAVER_NO_OCCLUSION_FIX=1`
disables the fix for A/B testing.

The system creates one saver view per display, and each view is a full WebGL
viewer. Rendering two of them doubles the GPU work and the heat, so when an
external display is connected **only that display plays** and the built-in panel
stays black (`shouldPlayOnThisDisplay` in `OSRSMapSaverView.swift`). With a single
display, it plays there. `OSRS_SAVER_FORCE_PLAY=1` overrides this for the dev
harness.

Flights cruise at 15-24 tiles/s (9-34 s), every pose is low-passed through
`PoseSmoother` so map hitches and NPC tile steps never show as jitter, and the
followed NPC's position is smoothed separately.

## Notes / next steps

- First launch in the screen saver downloads the cache into WebKit's container
  (from localhost, a few seconds). Later launches are instant.
- Two displays = two independent savers with different seeds, each with its own
  server and renderer.
- Values worth tweaking: `dwell`, `fog`, `sky`, `distance`, `npc`, and in
  `zones.ts` the per-zone `height`/`radius`.

## Credits

- dennisdev/rs-map-viewer (MIT) — the viewer/renderer this is based on.
- Jagex, RuneLite, OpenRS2 Archive, 2004scape, 2009scape and the OSRS Wiki for
  the data and caches.
- RuneScape content © Jagex Ltd.
