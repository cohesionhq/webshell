# webshell

The webshell clients for Cohesion: thin apps that pair with a `cohesiond`
from [cohesionhq/cohesion](https://github.com/cohesionhq/cohesion) and show
its web UI. Pairing, networking and setup are native; the interface is the
web UI.

| Directory | Client |
| --- | --- |
| `mac/` | The native Apple app, named Cohesion on iPad and Mac. It shows the web UI through [CohesionWebKit](https://github.com/cohesionhq/CohesionWebKit). See `mac/ARCHITECTURE.md`. |
| `gtk/` | The Linux app, in GTK 4 and libadwaita, showing the web UI in WebKitGTK. See `gtk/ARCHITECTURE.md`. |

Future clients will be siblings of these.

## Building the Apple app

The Xcode project uses CohesionWebKit as a local package, so clone it beside
this repo:

```
Developer/
  webshell/
  CohesionWebKit/
```

Then open `mac/cohesion-apple.xcodeproj`, or build from the repo root:

```sh
xcodebuild -project mac/cohesion-apple.xcodeproj -scheme Cohesion -destination 'generic/platform=iOS Simulator' build
xcodebuild -project mac/cohesion-apple.xcodeproj -scheme Cohesion -destination 'platform=macOS' build
```

The project sets no development team, so the Mac build signs to run locally.
To sign with your own team, pass `DEVELOPMENT_TEAM=<your team ID>` to
`xcodebuild`, or pick a team in Xcode without committing that change.

## Building the Linux app

The Linux app uses `cohesion-core` from [cohesionhq/cohesion](https://github.com/cohesionhq/cohesion)
as a path dependency, so clone that beside this repo:

```
Developer/
  webshell/
  cohesion/
```

It needs Rust (edition 2024) and the development packages for GTK 4,
libadwaita 1.6 or later and WebKitGTK 6.0 (on Fedora,
`gtk4-devel libadwaita-devel webkitgtk6.0-devel`; on Debian and Ubuntu,
`libgtk-4-dev libadwaita-1-dev libwebkitgtk-6.0-dev`). Then, from `gtk/`:

```sh
cargo build --release
```

To install it for one user, so it shows in the desktop's launcher, run
`gtk/install.sh`. It builds a release, installs the binary, desktop entry,
icon and AppStream metainfo under `~/.local` (or `PREFIX`), and refreshes the
launcher's caches. `gtk/install.sh --uninstall` removes them again.

On some NVIDIA drivers WebKitGTK draws a blank window; starting it with
`WEBKIT_DISABLE_DMABUF_RENDERER=1` works around that.

## Licence

Copyright © Jackson Zamorano. Licensed under the GNU Affero General Public
License, version 3 only (AGPL-3.0-only). See `LICENSE`.
