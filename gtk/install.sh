#!/usr/bin/env bash
# Builds the Linux app and installs it for this user, so it shows in the
# desktop's launcher: the binary, its desktop entry, icon and AppStream
# metainfo, under PREFIX (~/.local unless set).
#
#   ./install.sh              build and install
#   ./install.sh --uninstall  remove what it installed
#   PREFIX=/usr/local sudo -E ./install.sh   install for everyone
set -euo pipefail

APP_ID=com.hellocohesion.Cohesion
PREFIX="${PREFIX:-$HOME/.local}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN="$PREFIX/bin/cohesion-gtk"
DESKTOP="$PREFIX/share/applications/$APP_ID.desktop"
ICON="$PREFIX/share/icons/hicolor/scalable/apps/$APP_ID.svg"
METAINFO="$PREFIX/share/metainfo/$APP_ID.metainfo.xml"

# Lets launchers see what changed, where the tools exist.
refresh() {
    command -v update-desktop-database >/dev/null && update-desktop-database -q "$PREFIX/share/applications" || true
    command -v kbuildsycoca6 >/dev/null && kbuildsycoca6 >/dev/null 2>&1 || true
}

if [[ "${1:-}" == "--uninstall" ]]; then
    rm -f "$BIN" "$DESKTOP" "$ICON" "$METAINFO"
    refresh
    echo "Removed Cohesion from $PREFIX."
    exit 0
elif [[ $# -gt 0 ]]; then
    echo "usage: $0 [--uninstall]" >&2
    exit 2
fi

if [[ ! -d "$HERE/../../cohesion/cohesion-core" ]]; then
    echo "cohesionhq/cohesion must be cloned beside webshell (see README.md)." >&2
    exit 1
fi

(cd "$HERE" && cargo build --release)

install -Dm755 "$HERE/target/release/cohesion-gtk" "$BIN"
# The entry names the binary by its full path, so it starts whether or not
# PREFIX/bin is on the launcher's PATH.
install -d "$(dirname "$DESKTOP")"
sed "s|^Exec=.*|Exec=$BIN|" "$HERE/data/$APP_ID.desktop" > "$DESKTOP"
chmod 644 "$DESKTOP"
install -Dm644 "$HERE/data/$APP_ID.svg" "$ICON"
install -Dm644 "$HERE/data/$APP_ID.metainfo.xml" "$METAINFO"
refresh

echo "Installed Cohesion in $PREFIX. Open it from your launcher, or run $BIN."
