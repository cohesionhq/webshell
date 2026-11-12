# CLAUDE.md

The webshell clients: thin apps that pair with `cohesiond` and show its web
UI. There are two:

- `mac/`, the Apple Cohesion client (the app named Cohesion on iPad and Mac).
  It pairs, serves the web UI and bridges its socket itself, in
  `mac/Cohesion/`. `mac/ARCHITECTURE.md` gives the one-page map.
- `gtk/`, the Linux client, in Rust with GTK 4, libadwaita and WebKitGTK. It
  holds its own copy of what `mac/` does, and takes setup codes,
  certificates and the protocol's envelope from `cohesion-rs`.
  `gtk/ARCHITECTURE.md` gives the one-page map.

The whole client is Apache-2.0; the daemon is AGPL-3.0-only.

Almost everything either shows is the web UI from
[cohesionhq/cohesion](https://github.com/cohesionhq/cohesion), so a change
usually belongs there, not here.

## Layout

Each client is a top-level directory; new ones are siblings of `mac/` and
`gtk/`. `gtk/` builds against cohesionhq/cohesion as a local checkout beside
this repo (`../../cohesion/cohesion-rs`), so clone it there (see
`README.md`). Run the commands below from the repo root.

## Design principles

- **Keep the shell thin.** UI lives in the web UI. The shell does only what
  the page can't: pairing, serving, the socket bridge, and what is a
  platform's own, such as the scene and the safe area. `mac/` and `gtk/` do
  it the same way, and a change to one is made to the other
  (`gtk/src/bridge.js` is `mac/`'s `SocketBridge` script, unchanged).
- **No speculative generality.** Build what the task needs.

## Decide, then report

Work without stopping to ask. When a design or copy question is open, take
the conservative option and keep going:

- Make the smaller change. Don't add a dependency, target or capability.
- Write UI strings by "Copy" in cohesionhq/cohesion's `web/README.md`.

List every such choice in the report so the maintainer can push back. Stop only when
truly blocked, before something destructive, or when the next step needs
credentials or pairing with a real daemon.

## Working rules

- Work on `master` in this checkout. Use a worktree only if the work truly
  needs isolation.
- The checkout often has the maintainer's uncommitted work. Never revert,
  stash or commit it. Stage and commit only your own files or hunks.
- Run the checks before reporting, then push to `master`. Never deploy,
  archive or upload unless told.

Skills in `.claude/skills/`: `change-the-app` (where a change belongs and the
gotchas), `verify-change` (the builds), `run-the-app` (simulator and Mac),
`finish-task` (commit, push, report).

## Report

Brief, in this order: what changed · commits (hashes) · checks run and
results · caveats · choices made without asking · what the maintainer should check
by eye or by hand.

## The page's side is a stable API

`mac/` and `gtk/` set `--titlebar-inset` on `<html>` to
the top safe area after each load, and the page relies on the session API they
provide.
Change them together with `cohesion open` and `web/` in cohesionhq/cohesion,
or not at all ("The page's side is a stable API" in its
`docs/serving-the-webui.md`).

## Building

```sh
xcodebuild -project mac/CohesionWebHarness.xcodeproj -scheme Cohesion -destination 'generic/platform=iOS Simulator' build
xcodebuild -project mac/CohesionWebHarness.xcodeproj -scheme Cohesion -destination 'platform=macOS' build
```

For the Linux app, from `gtk/`:

```sh
cargo fmt --check && cargo clippy -- -D warnings && cargo build
```

There are no tests. The builds passing is the check (see `verify-change`).
