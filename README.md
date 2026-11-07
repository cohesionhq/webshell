# webshell

The webshell clients for Cohesion: thin apps that pair with a `cohesiond`
from [cohesionhq/cohesion](https://github.com/cohesionhq/cohesion) and show
its web UI. Pairing, networking and setup are native; the interface is the
web UI.

| Directory | Client |
| --- | --- |
| `mac/` | The native Apple app, named Cohesion on iPad and Mac. It shows the web UI through [CohesionWebKit](https://github.com/cohesionhq/CohesionWebKit). See `mac/ARCHITECTURE.md`. |

Future clients will be siblings of `mac/`.

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

## Licence

Copyright © Jackson Zamorano. Licensed under the GNU Affero General Public
License, version 3 only (AGPL-3.0-only). See `LICENSE`.
