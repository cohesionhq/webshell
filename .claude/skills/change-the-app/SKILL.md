---
name: change-the-app
description: How to make a feature or fix in the Apple Cohesion client: deciding whether it belongs in this repo or the web UI, and the project's gotchas (synchronized folders, build-setting entitlements, both platforms, copy rules, the stable page API). Use before writing code for any task in this repo.
---

# Change the app

Read `mac/ARCHITECTURE.md` first if you haven't. It's one page. For the Linux
app, read `gtk/ARCHITECTURE.md` instead: everything it does is in `gtk/`, and
the table below maps `mac/`'s parts to its files.

## Where the change belongs

| The change is about… | It goes in |
| --- | --- |
| Anything inside the page: screens, layout, the web UI's copy | `../cohesion/web/` (cohesionhq/cohesion) |
| Pairing, the bundle, serving, the socket bridge, `CohesionWebUI`/`WebUIView`/`PairingForm` | here, `mac/Cohesion/` (`Pairing/`, `Connection/`, `Serving/`, `Views/`) |
| The scene, window style, menus/commands, native overlays, Info.plist, entitlements, the icon | here, `mac/Cohesion/CohesionApp.swift` and the project |
| Any of the above on Linux | here, `gtk/src/` (pairing, bundle, scheme and bridge included) |

A change to pairing, serving or the bridge in `mac/` is made in `gtk/` too,
the same way, and the reverse; say in the report if one side is left for
later.

If it's the web UI, it's a different repo with its own
checks. Do it there only if the task covers it, and otherwise report that it
belongs there.

## Gotchas

- **New files need no project edit.** `mac/Cohesion/` is a file-system-synchronized
  group, so a `.swift` file dropped in builds. Don't hand-edit
  `project.pbxproj` for it.
- **One target, two platforms.** `Cohesion` builds for iPad
  (`TARGETED_DEVICE_FAMILY = 2`, no iPhone) and native macOS, with deployment
  27.0. Guard Mac-only API with `#if os(macOS)`, as `.windowStyle(.hiddenTitleBar)`
  is, and build both.
- **Info keys and entitlements are build settings.** Use `INFOPLIST_KEY_*` and
  `ENABLE_*` (sandbox, hardened runtime, network, resource access) in the
  target's Debug *and* Release configs, which already differ. Edit both
  identically. `mac/Cohesion/Info.plist` holds only what has no build setting
  (ATS).
- **Don't bump `CURRENT_PROJECT_VERSION` or `MARKETING_VERSION`** unless asked.
  The maintainer does that for releases.
- **New capabilities, targets or dependencies:** take the conservative default
  (don't add them). If the task can't be done without one, stop and report.
- **The page's side is a stable API.** `--titlebar-inset` (set by `WebUIView`) and the session API (`#token=`, `/client`, `/connect`, the
  `WebSocket` subset) change only together with `cohesion open` and `web/`.
  See `docs/serving-the-webui.md` in cohesion.
- **Swift style:** SwiftUI, `@State` owning `@Observable` types,
  small `private` views and `ViewModifier`s in the same file until a file gets
  long, and `///` doc comments on types saying what they show. Match the
  surrounding comment density.
- **Copy:** native strings ("Unpair", "Update and reload", "A new version of
  Cohesion is ready.") follow "Copy" in `../cohesion/web/README.md`: sentence
  case, buttons that say what they do, no "daemon" or `cohesiond`, curly
  apostrophes, no "please" or exclamation marks. Pick the wording yourself
  and list it under choices in the report.
- **Mac menus:** app commands go in `.commands { CommandGroup(after: .appSettings) { … } }`,
  which shows them in the Cohesion menu, each `.disabled(…)` when it can't act.
