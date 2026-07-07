#!/usr/bin/env bash
# Build the todokase CLI as a universal (arm64 + x86_64) release binary,
# tar it, and print the sha256 for the Homebrew formula.
#
#   packaging/build-cli-release.sh [version]   # default version: 0.38.0
#
# Output: dist/todokase-<version>-macos-universal.tar.gz  + its sha256.
set -euo pipefail

VERSION="${1:-0.38.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DERIVED="$ROOT/build/cli-release"
echo "==> Building todokase (Release, universal)…"
xcodebuild \
  -project todarchy.xcodeproj \
  -scheme todokase \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  ONLY_ACTIVE_ARCH=NO \
  build >/dev/null

BIN="$DERIVED/Build/Products/Release/todokase"
[ -f "$BIN" ] || { echo "error: binary not found at $BIN" >&2; exit 1; }

echo "==> Architectures:"
lipo -archs "$BIN"

DIST="$ROOT/dist"
mkdir -p "$DIST"
TAR="$DIST/todokase-${VERSION}-macos-universal.tar.gz"
tar -C "$(dirname "$BIN")" -czf "$TAR" todokase

echo
echo "==> Packaged: $TAR"
echo "==> sha256 (paste into the formula):"
shasum -a 256 "$TAR" | awk '{print $1}'
