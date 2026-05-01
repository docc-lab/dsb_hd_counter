#!/bin/bash
# ===========================================================================
# install-ghz.sh
#
# One-shot installer for ghz (gRPC load tool) used by step1-characterize.sh.
# Downloads a release binary from https://github.com/bojand/ghz and installs
# it into INSTALL_DIR (default /usr/local/bin).
#
# Usage:
#   ./install-ghz.sh                           # install latest pinned version
#   GHZ_VERSION=0.120.0 ./install-ghz.sh       # install specific version
#   INSTALL_DIR=$HOME/.local/bin ./install-ghz.sh
# ===========================================================================

set -e
set -o pipefail

GHZ_VERSION="${GHZ_VERSION:-0.120.0}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"

# Map uname arch to ghz release suffix
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) GHZ_ARCH="linux-x86_64" ;;
    aarch64|arm64) GHZ_ARCH="linux-arm64" ;;
    *)
        echo "ERROR: unsupported architecture: $ARCH" >&2
        exit 1
        ;;
esac

URL="https://github.com/bojand/ghz/releases/download/v${GHZ_VERSION}/ghz-${GHZ_ARCH}.tar.gz"

echo "Installing ghz v${GHZ_VERSION} (${GHZ_ARCH}) -> ${INSTALL_DIR}/ghz"
echo "  source: $URL"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

if ! curl -fsSL "$URL" -o "$TMPDIR/ghz.tar.gz"; then
    echo "ERROR: failed to download ghz release tarball" >&2
    exit 1
fi

tar -xzf "$TMPDIR/ghz.tar.gz" -C "$TMPDIR"

if [[ ! -x "$TMPDIR/ghz" ]]; then
    echo "ERROR: ghz binary not found in tarball" >&2
    ls -la "$TMPDIR"
    exit 1
fi

# Use sudo if INSTALL_DIR is not user-writable
if [[ -w "$INSTALL_DIR" ]]; then
    install -m 0755 "$TMPDIR/ghz" "$INSTALL_DIR/ghz"
else
    sudo install -m 0755 "$TMPDIR/ghz" "$INSTALL_DIR/ghz"
fi

echo ""
echo "Installed: $("$INSTALL_DIR/ghz" --version 2>&1 | head -1)"
echo "Location : $INSTALL_DIR/ghz"
