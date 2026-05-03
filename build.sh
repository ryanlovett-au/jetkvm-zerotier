#!/bin/bash
# Build and package zt-proxy and (optionally) ZeroTier tarballs for JetKVM.
# Requires: Go 1.22+ for zt-proxy. See README for ZeroTier build requirements.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELEASES_DIR="$SCRIPT_DIR/releases"
ZT_PROXY_VERSION="${ZT_PROXY_VERSION:-v1.0.0}"

mkdir -p "$RELEASES_DIR"

# ---------------------------------------------------------------------------
# zt-proxy
# ---------------------------------------------------------------------------
build_zt_proxy() {
  echo ""
  echo "==> Building zt-proxy $ZT_PROXY_VERSION for ARMv7hf..."
  cd "$SCRIPT_DIR/zt-proxy"
  GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 \
    go build -ldflags="-s -w" -o zt-proxy .
  echo "    Built: $(file zt-proxy)"

  local tarball="$RELEASES_DIR/zt-proxy-${ZT_PROXY_VERSION}-armv7hf.tar.gz"
  echo ""
  echo "==> Packaging $tarball..."
  tar -czf "$tarball" \
    --transform 's|^|zt-proxy/|' \
    -C "$SCRIPT_DIR/zt-proxy" zt-proxy go.mod main.go \
    -C "$SCRIPT_DIR" install-zt-proxy.sh
  echo "    Done: $(ls -lh "$tarball" | awk '{print $5}')"
  cd "$SCRIPT_DIR"
}

# ---------------------------------------------------------------------------
# ZeroTier (requires pre-built binary — see README for cross-compile steps)
# ---------------------------------------------------------------------------
package_zerotier() {
  local zt_bin="${1:-}"
  local zt_version="${2:-}"

  if [ -z "$zt_bin" ] || [ -z "$zt_version" ]; then
    echo ""
    echo "  Skipping ZeroTier packaging (pass ZT_BIN and ZT_VERSION to enable)."
    echo "  Example:"
    echo "    ZT_BIN=/path/to/zerotier-one ZT_VERSION=1.16.0 $0"
    return
  fi

  if [ ! -f "$zt_bin" ]; then
    echo "ERROR: ZT_BIN not found: $zt_bin"
    exit 1
  fi

  local tarball="$RELEASES_DIR/zerotier-one-${zt_version}-armv7hf.tar.gz"
  echo ""
  echo "==> Packaging ZeroTier $zt_version: $tarball..."
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/jetkvm-zerotier"
  cp "$zt_bin" "$tmp/jetkvm-zerotier/zerotier-one"
  cp "$SCRIPT_DIR/install-zerotier.sh" "$tmp/jetkvm-zerotier/install.sh"
  tar -czf "$tarball" -C "$tmp" jetkvm-zerotier
  rm -rf "$tmp"
  echo "    Done: $(ls -lh "$tarball" | awk '{print $5}')"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
build_zt_proxy
package_zerotier "${ZT_BIN:-}" "${ZT_VERSION:-}"

echo ""
echo "Releases:"
ls -lh "$RELEASES_DIR"/*.tar.gz 2>/dev/null || true
echo ""
