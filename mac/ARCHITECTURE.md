# Architecture

The Apple Cohesion client is a thin native shell around the Cohesion web UI.
The system as a whole (daemon, protocol, clients) is described in
`docs/architecture.md` in [cohesionhq/cohesion](https://github.com/cohesionhq/cohesion),
and how clients serve the web UI is in its `docs/serving-the-webui.md`.

## The three pieces

| Piece | Where | Owns |
| --- | --- | --- |
| This app | `Cohesion/` | the scene, window style, menus, native overlays, Info.plist, entitlements, icon |
| Its web UI host | `Cohesion/Pairing/`, `Connection/`, `Serving/`, `Views/` | pairing, connections, fetching and serving the bundle, the socket bridge, the pairing form and web view |
| The web UI | `web/` in cohesion | everything inside the page |

The web UI host was the CohesionWebKit package, which the Cohesion menu bar
app (`cohesiond-macos`) still uses; the two copies now change separately. The iPhone app is native and separate.

## Target

One target and scheme, `Cohesion` (`com.hellocohesion.apple.client`). It builds
for iPad and native macOS at 27.0, with no iPhone. `Cohesion/` is a
file-system-synchronized group, so its files build without project edits.
The sandbox, network and other capabilities are build settings.

## Flow

`CohesionApp` (`Cohesion/CohesionApp.swift`) owns a `PairingStore`, and each
window (`CohesionWindow`) owns a `WebUIClient` and shows `CohesionWebUI` for
the route `pairings.remote.map(DaemonRoute.remote)`. Windows share the
pairing and the pages' web storage, but each has its own page, token and
connection. Everything below happens in the web UI host:

1. **Pair.** With no route, or once the server stops trusting the app,
   `CohesionWebUI` shows the pairing form (a sheet on iPad, a view on Mac). The
   setup code registers with the server's `/register`, and the certificate and
   key go in the keychain (`Pairing/`).
2. **Connect.** `DaemonRoute.remote` is a server elsewhere over mutual TLS. On
   a Mac, `.local` reaches this Mac's `cohesiond` over its Unix socket
   (`Connection/`).
3. **Load.** `WebUIClient` fetches the web bundle the server hands out
   (`webBundle`), unpacks it under Caches by hash, and serves it at
   `cohesion://app/` through a URL scheme handler that also answers
   `GET /client` (`Serving/`).
4. **Bridge.** A script replaces the page's `WebSocket` for `/connect` with a
   stand-in that relays text frames through `SocketBridge` to the daemon. The
   token is fresh on each load (`#token=`). Each session the bridge opens
   starts with the server's `hello`; when its `web_bundle_hash` isn't the
   page's build, `WebUIClient` sets `updateAvailable`, and `update()` loads
   again with the newer build.
5. **Lay out.** `WebUIView` lets the page run under the title bar or status
   bar and sets `--titlebar-inset` on `<html>` to the height to keep clear.

What the app adds on top: `.hiddenTitleBar` on Mac, windows titled by their
page, the Cohesion menu's "Update and reload" and "Unpair" (for the
frontmost window), and the update banner (`UpdateOffer`).

## Stable API

The session API (`#token=`, `/client`, `/connect`, the subset of `WebSocket` the page uses)
and `--titlebar-inset` are a contract with `web/` and `cohesion open`. They
change in all three places or not at all.

## Where to look

- A native menu, window or overlay: `Cohesion/CohesionApp.swift`
- The pairing form, errors, spinner, web view: `Cohesion/Views/`
- Bundle fetching, the scheme handler, updates: `Cohesion/Serving/`
- Trust, keychain, setup codes: `Cohesion/Pairing/`
- Anything the page shows: cohesion `web/src/`
