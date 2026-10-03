#!/usr/bin/env bash
# Kvotar — build the `kvotar` CLI and refresh the ~/.local/bin symlink (STEP_54).
#
# The CLI is a SwiftPM executable (separate from the Xcode app build), so its binary lives in the
# package's .build dir. This script builds it and points ~/.local/bin/kvotar at the freshly
# built binary — a user-owned dir (no sudo) refreshed every run so the symlink never serves a
# stale binary (memory: run the correct build).
#
# Usage: scripts/cli.sh [swift-build-args...]   (e.g. -c release)
#   Day-zero fallback without the symlink:  swift run --package-path Packages/KvotarCLI kvotar ...
#
# The in-.app "Install command-line tool" installer is deferred to distribution/packaging.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="$REPO_ROOT/Packages/KvotarCLI"
BIN_DIR="$HOME/.local/bin"
LINK="$BIN_DIR/kvotar"

echo "Building kvotar CLI ($PKG_DIR)…"
swift build --package-path "$PKG_DIR" "$@"

BIN_PATH="$(swift build --package-path "$PKG_DIR" "$@" --show-bin-path)/kvotar"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "error: built binary not found at $BIN_PATH" >&2
  exit 1
fi

mkdir -p "$BIN_DIR"
ln -sf "$BIN_PATH" "$LINK"
echo "Linked $LINK -> $BIN_PATH"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: $BIN_DIR is not on your PATH — add it to use \`kvotar\` directly." ;;
esac
