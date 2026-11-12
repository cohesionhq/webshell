# Architecture

The Linux Cohesion client is a thin GTK 4 and libadwaita shell around the
Cohesion web UI, shown in a WebKitGTK 6.0 web view. It is the Linux copy of
`mac/`: the same flow, the same bridge script and
the same stable API, in Rust. The system as a whole is described in
`docs/architecture.md` in [cohesionhq/cohesion](https://github.com/cohesionhq/cohesion).

## The three pieces

| Piece | Where | Owns |
| --- | --- | --- |
| This app | `gtk/` | pairing, connections, fetching and serving the bundle, the socket bridge, the windows, menus and preferences |
| cohesion-rs | `../../cohesion/cohesion-rs` (path dependency, MIT) | setup codes, the self-signed certificate, `key_fingerprint`, the protocol's envelope |
| The web UI | `web/` in cohesion | everything inside the page |

The wire's types come from cohesion's client crate, which the daemon's tests
check against its own frames, so a change to `Hello`, `WebBundle` or the reply
frame fails a build rather than the app.

## Flow

`main.rs` starts an `adw::Application` (`com.hellocohesion.Cohesion`) and a
tokio runtime for networking. GTK keeps the main thread: networking runs on
`RUNTIME`, and the main thread awaits it with `glib::spawn_future_local`.
It prefers GTK's GL renderer (`GSK_RENDERER=ngl`, unless the environment
sets one): GTK's Vulkan renderer can't import the web view's frames on
NVIDIA's driver, and copies each one back through GL on the main thread.

1. **Pair** (`pairing.rs`, `pairing_page.rs`). Each pairing is an account,
   and each window is on one. A window with no account, or whose server
   stops trusting the app, shows the pairing page. The setup code registers
   a new key and certificate at the server's `/register`. The pairings
   (address, server key fingerprint, certificate and key, and the account
   name, if one was given) go in `$XDG_CONFIG_HOME/cohesion-gtk/pairings.json`,
   readable by this user alone, as the CLI keeps its identity. A pairing is
   known by its server's fingerprint, so pairing with the same server again
   replaces it. An older `pairing.json`, holding one, becomes the first.
2. **Connect** (`connection.rs`). A session is a WebSocket to `/connect` over
   mutual TLS: it presents the pairing's certificate and trusts only the
   server whose key matches the fingerprint (`pairing/tls.rs`, as
   `client_tls.rs` in the CLI). A 403 means the server no longer trusts the
   app. Relayed sessions are pinged every 15 seconds.
3. **Load** (`assets.rs`, `window.rs`). A window fetches the bundle
   (`webBundle`), unless `hello`'s hash matches the copy unpacked under
   `$XDG_CACHE_HOME/cohesion-gtk/WebUI/<hash>/`, and tries again a second
   apart, 30 times, while the server can't be reached.
4. **Serve** (`serving.rs`, `session.rs`). Each load gets a web context of
   its own, with the `cohesion` URI scheme registered as secure and
   CORS-enabled, answering files at `cohesion://app/` and `GET /client` for
   that page's token alone. The token is fresh on each load (`#token=`).
   The web views of one account's windows share a `NetworkSession` (under
   `$XDG_DATA_HOME/cohesion-gtk/accounts/<fingerprint>`), and so the pages'
   storage, which no other account's pages see.
5. **Bridge** (`bridge.rs`, `bridge.js`). `bridge.js` is `mac/`'s
   `SocketBridge` script unchanged: it replaces the page's `WebSocket` for
   `/connect` with a stand-in that posts to the `cohesionSocket` script
   message handler. The bridge opens a session for each socket and relays
   text frames both ways. It also reads each session's `hello`, and offers
   an update when it names another build.
6. **Lay out** (`window.rs`). The page runs up under a transparent header
   bar, which keeps only the account switcher, the main menu and the window
   controls, and
   `--titlebar-inset` is set on `<html>` to the header bar's height after
   each load.

Links to other origins, and `window.open`, go to the default browser
(`gtk::UriLauncher`). WebKitGTK answers `<input type="file">` with the
desktop's file chooser itself. WebKitGTK hands the page the mouse's back
and forward buttons (GDK's 8 and 9) as a left button, so a capture-phase
`EventControllerLegacy` on the window (`history_buttons` in `window.rs`) reads
them from the raw event before WebKit does, keeps them from it, and on the
press dispatches the `mousedown` and `mouseup` a browser sends for them
(`button` 3 and 4), on which the web UI steps its own history.

What the app adds on top: several windows (`Shift+Ctrl+N`, on the frontmost
window's account), each with its own page, token and connections; an account
switcher in the header bar, as multi-account GNOME apps have, which puts the
window on another account or, with "Add account…", on the pairing page;
windows titled by their page; "Install update…" in the main menu and
"Update and reload" on a toast once a newer build is served; and Preferences (`Ctrl+,`), which shows
the window's account and unpairs it.

## Stable API

The session API (`#token=`, `/client`, `/connect`, the subset of `WebSocket`
the page uses) and `--titlebar-inset` are a contract with `web/` and
`cohesion open`. They change in all three places or not at all, and
`bridge.js` changes with `mac/`'s copy.

## Where to look

- The window, its account, its states, the menu and the update toast: `src/window.rs`
- The pairing page: `src/pairing_page.rs`; Preferences: `src/preferences.rs`
- App actions, shortcuts, the accounts and their storage: `src/shell.rs`
- Trust and the pairings file: `src/pairing.rs`, `src/pairing/tls.rs`
- Bundle fetching and the cache: `src/assets.rs`
- The URI scheme: `src/serving.rs`; the bridge: `src/bridge.rs`, `src/bridge.js`
- The desktop file, AppStream metainfo and icon: `data/`; installing them: `install.sh`
