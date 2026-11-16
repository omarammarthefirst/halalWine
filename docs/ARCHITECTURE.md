# Architecture

```
┌──────────── HalalWine (SwiftUI app) ────────────┐      halalwine (CLI)
│ Setup assistant · Library · Launch verification  │          │
│ Settings · D3DMetal import · Diagnostics         │          │
└──────────────────────┬───────────────────────────┘          │
                       ▼                                      ▼
┌──────────────────── HalalWineCore (no UI, builds on Linux) ─────────────────┐
│ Inspect   PEParser, PEResources (icon, product name), GodotPackReader,      │
│           GameInspector (main .exe, engine, graphics API, red flags, store) │
│ Plan      RuleSet (rules.json, updatable remotely) → LaunchPlanner          │
│ Runtime   RuntimeStore (manifest, download, sha256, install),               │
│           InstalledRuntime (backend variants), BackendSetup (DLL overrides) │
│ Run       PrefixManager (template + APFS clones), LaunchCommandBuilder,     │
│           WineSession (process + wineserver -w), LogDoctor,                 │
│           DependencyInstaller                                               │
│ Library   GameLibrary (JSON), GameImporter (clone into library, unzip)      │
└──────────────────────────────────────────────────────────────────────────────┘
```

## Data on disk

`~/Library/Application Support/halalWine/` (override with `HALALWINE_HOME`):

| Folder | Contents |
|---|---|
| `Runtimes/<version>/wine` | Wine for macOS |
| `Runtimes/<version>/components/{dxmt,dxvk}` | Graphics layers as shipped |
| `Runtimes/<version>/variants/{dxmt,d3dmetal}` | Copy-on-write clones of `wine/` with DXMT or D3DMetal installed as built-ins |
| `Templates/<version>` | A prefix created once with `wineboot --init` |
| `Prefixes/<game id>` | Each game's prefix, cloned from the template |
| `Games/` | Games cloned into the library ("keep games inside halalWine") |
| `Logs/`, `Icons/`, `Cache/`, `library.json` | |

## Why backend variants?

DXMT's release ships as Wine *built-in* DLLs (its guide puts `d3d11.dll`,
`dxgi.dll` and `winemetal.so` inside Wine's own `lib/wine`). D3DMetal is
installed the same way from Apple's `redist/lib`. Installing either replaces
WineD3D, which we still want as a fallback. So each one gets its own clone of
the Wine tree. On APFS, `clonefile` makes this instant and almost free. DXVK
uses classic native DLLs copied into the prefix with `n,b` overrides.

## Launch loop (app)

For each configuration from the planner, best first:

1. Prepare the backend variant and DLLs, then build the command (environment, overrides, windowed arguments).
2. Start `wine game.exe …` and stream its output through `LogDoctor`:
   - **renderer failed** → next configuration;
   - **missing VC++/DirectX/XNA** → install it, then retry;
   - **illegal instruction** → enable `ROSETTA_ADVERTISE_AVX`, then retry.
3. Watch for a window owned by a process under the runtime folder. Optionally
   sample it with ScreenCaptureKit to detect a black screen.
4. Ask the player "Is it working?". Playing for more than a minute also counts as yes.
5. Remember the result in `LaunchHistory`. The working configuration goes first next time; failed ones go last.

## Updating launch knowledge

Edit `Sources/HalalWineCore/Resources/rules.json` and bump `version`. Installed
apps download it from the repository on launch and use it if it is newer than
their bundled copy. Rules match on engine, engine version range, Godot
rendering method, primary graphics API and .NET; the first matching rule wins.
