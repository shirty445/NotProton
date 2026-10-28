# NotProtonGPTK

A fork of [NotProton](https://github.com/NotProtonNot/NotProton) that downloads its own Wine instead of
needing CrossOver. It adds a **Wine Manager** pane, modeled on Heroic's, with two tabs:

| Tab | Feed | Notes |
|---|---|---|
| NotProton Wine | this fork's `wine-*` releases | CrossOver 26.3's open source Wine 11, built by `wine/build.sh`; GPTK 4's D3DMetal is patched onto it |
| Wine-Staging-macOS | [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds/releases) | Newest upstream Wine, no D3DMetal |

## Why NotProton Wine

The bridge's `lsteamclient` is built against Wine 11 (`bridge/setup-wine-tree.sh`), and its
Windows and macOS halves only work with a matching Wine. Gcenx's Game Porting Toolkit runtime is
Wine 7.7 and Heroic's Wine-Crossover 23.7 is Wine 8: on them a game dies with
`steamclient_init: Access violation`, and Steam's 32 bit install scripts crash under Wine 8's
experimental WoW64. Those two feeds are no longer offered. Runners installed from them stay
listed, marked, so they can be removed.

`.github/workflows/wine.yml` (run by hand) builds CodeWeavers' published CrossOver 26.3 tree,
which is Wine 11.0 with CrossOver's D3DMetal hooks in `winemac.drv` and `ntdll`, plus msync. It
smoke tests a prefix with 64 and 32 bit programs and publishes
`notproton-wine-cx<version>-<revision>.tar.xz` as a `wine-cx<version>-<revision>` release, which
the Wine Manager lists. Nothing of Apple's is in it. Bump the `revision` input to publish a
changed build.

Each downloaded version becomes its own Steam compatibility tool (`notproton-<id>`). Pinned
CrossOver builds still work as before and stay first in Steam's default order when installed.

## Game Porting Toolkit 4 betas

Apple publishes GPTK 4 only on [developer.apple.com](https://developer.apple.com/download/all/?q=game%20porting%20toolkit)
behind a free Apple ID sign-in, and it may not be redistributed. So it cannot be downloaded
for you. Instead:

1. In **Wine Manager > NotProton Wine**, click **Get from Apple…** and download
   *Game Porting Toolkit 4.0 beta 3* (the `.dmg`).
2. Back in NotProton, click **Patch in …** (the DMG in Downloads or on the Desktop is found
   automatically) or **Choose DMG…**.

NotProton downloads the newest NotProton Wine, mounts Apple's DMG and its nested
*Evaluation environment* image, and merges `redist/lib` into the runtime's `lib`, as Apple's
Read Me describes. `lib64/apple_gptk/external` is linked to it, as in CrossOver, so the run
script hands `libd3dshared` to Wine for Rosetta. The result shows up as e.g. *NotProton Wine
cx26.3.0-1 + D3DMetal 4.0b3*. A newer beta is patched in the same way.

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
  so the run script falls back to `bin/wine64`. They still cannot run Steam games (see above).
- **No CrossOver license check** for downloaded runners.
- **English only.** The Wine Manager's text uses its own `WineManager` string table, so
  upstream's `Localizable.xcstrings` and its translation check never see it.
- **Automatic update checks are off**, because the bundled Sparkle key would otherwise accept
  upstream's release and replace this fork. *Check for Updates…* still asks upstream.

## Staying in sync with upstream

New code lives in `wine/`, `.github/workflows/wine.yml`, `app/Sources/NotProtonApp/WineManager/` and
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

On GitHub, the **app** workflow builds `NotProton.zip` as an artifact on GitHub's hosted
`xcode-27` preview runner, so it works in a fork as is. The repository variables
`NOTPROTON_RUNNER` and `NOTPROTON_XCODE` can point it at another runner if that label goes away.
