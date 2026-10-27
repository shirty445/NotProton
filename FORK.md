# NotProtonGPTK

A fork of [NotProton](https://github.com/NotProtonNot/NotProton) that downloads its own Wine instead of
needing CrossOver. It adds a **Wine Manager** pane, modeled on Heroic's, with three tabs:

| Tab | Feed | Notes |
|---|---|---|
| Game-Porting-Toolkit | [Gcenx/game-porting-toolkit](https://github.com/Gcenx/game-porting-toolkit/releases) | Apple's D3DMetal for DX11/DX12 |
| Wine-Crossover | [Heroic-Games-Launcher/wine-crossover](https://github.com/Heroic-Games-Launcher/wine-crossover/releases) | CodeWeavers' open source Wine |
| Wine-Staging-macOS | [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds/releases) | Newest upstream Wine, no D3DMetal |

Each downloaded version becomes its own Steam compatibility tool (`notproton-<id>`). Pinned
CrossOver builds still work as before and stay first in Steam's default order when installed.

## Game Porting Toolkit 4 betas

Apple publishes GPTK 4 only on [developer.apple.com](https://developer.apple.com/download/all/?q=game%20porting%20toolkit)
behind a free Apple ID sign-in, and it may not be redistributed. So it cannot be downloaded
for you. Instead:

1. In **Wine Manager > Game-Porting-Toolkit**, click **Get from Apple…** and download
   *Game Porting Toolkit 4.0 beta 3* (the `.dmg`).
2. Back in NotProton, click **Patch in …** (the DMG in Downloads or on the Desktop is found
   automatically) or **Choose DMG…**.

NotProton downloads the newest stable Gcenx GPTK runtime, mounts Apple's DMG and its nested
*Evaluation environment* image, and merges `redist/lib` into the runtime's `lib`, as Apple's
Read Me describes. The result shows up as e.g. *Game Porting Toolkit 4.0b3 (D3DMetal)*. A
newer beta is patched in the same way.

## Mac versions of games

This is unchanged from NotProton. A game that has a macOS build downloads the macOS build. To
get the Windows build, right click the game > Properties > Compatibility, tick *Force the
use of a specific Steam Play compatibility tool* and pick a NotProton tool. Untick it to go
back to the Mac version. Windows-only games use the first NotProton tool automatically.

## How it differs from CrossOver builds

- **No ntdll patch.** The pinned CrossOver builds get a detour at hardcoded ntdll offsets
  that redirects Valve's `steamclient64.dll` to lsteamclient as it loads. A downloaded Wine
  has no known offsets, so the runner instead carries `forwarders/steamclient(64).dll`: tiny
  DLLs whose every export forwards to `lsteamclient`, generated at install from the bridge's
  lsteamclient. That is how Proton worked before version 9. DRM that inspects
  `steamclient64.dll` on disk sees the forwarder, not Valve's file.
- **Rosetta only.** None of these builds has a FEX flavor.
- **Wine 8 era runtimes** (GPTK 2/3, Wine-Crossover 23.7) have no `lib/wine/x86_64-unix/wine`,
  so the run script falls back to `bin/wine64`.
- **No CrossOver license check** for downloaded runners.
- **Automatic update checks are off**, because the bundled Sparkle key would otherwise accept
  upstream's release and replace this fork. *Check for Updates…* still asks upstream.

## Staying in sync with upstream

New code lives in `app/Sources/NotProtonApp/WineManager/` and
`app/Tests/NotProtonAppTests/WineManagerTests.swift`, which upstream never touches. The
upstream files this fork changes are kept to small, commented hooks (search for
`NotProtonGPTK`):

| File | Change |
|---|---|
| `Model/SupportedRunner.swift` | `all` is `pinned + ManagedRunners.builds()` |
| `Model/CrossOverSource.swift` | `unixLoader(inRoot:)` falls back to `bin/wine64` |
| `Views/RootView.swift`, `App.swift` | the Wine Manager pane, ⌘4 |
| `dylib/feats/compat_run.sh` | loader fallback, forwarders, `verify_runner` skip |
| `app/Info.plist` | `SUEnableAutomaticChecks` false |
| `.github/workflows/app.yml` | runner label and Xcode path from repository variables |

**Automatically:** `.github/workflows/sync-upstream.yml` merges upstream daily. A clean merge is
pushed and the app is rebuilt; a conflict opens an issue listing the files.

**By hand:** `scripts/sync-upstream.sh` merges, then runs the run-script checks. Add `--build`
to build the app too.

## Building

Locally, the same as upstream: Xcode 27, `brew install mingw-w64 bison flex`, then
`make all overlay-shim iconmaker appinfo bridge fonts app-payload app`.

On GitHub, the **app** workflow builds `NotProton.zip` as an artifact. Upstream runs it on a
custom `xcode-27` runner. In a fork, set the repository variables `NOTPROTON_RUNNER` (for example
`macos-26`) and, if that image's Xcode lives elsewhere, `NOTPROTON_XCODE`.
