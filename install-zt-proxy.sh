#!/bin/sh
# zt-proxy installer for JetKVM
# Restricts WebUI access to ZeroTier interface only.
# Run after ZeroTier is installed, joined, and the ZT interface is up.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROXY_BIN=/userdata/bin/zt-proxy
KVM_CONFIG=/userdata/kvm_config.json

# Detect ZeroTier interface (name is 'zt' followed by 8 hex chars)
ZT_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^zt[a-f0-9]{8}$' | head -1)
ZT_IP=$(ip addr show "$ZT_IFACE" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
if [ -z "$ZT_IP" ]; then
  echo "ERROR: No ZeroTier interface with an IP found."
  echo "       Make sure ZeroTier is running and joined to your network."
  exit 1
fi
echo ""
echo "  Detected ZeroTier IP: $ZT_IP (interface: $ZT_IFACE)"

echo ""
echo "==> [1/4] Installing zt-proxy binary..."
mkdir -p /userdata/bin
cp "$SCRIPT_DIR/zt-proxy" "$PROXY_BIN"
chmod +x "$PROXY_BIN"
echo "    Installed: $PROXY_BIN"

echo ""
echo "==> [2/4] Installing init script..."
cat > /etc/init.d/S51zt-proxy << 'INITEOF'
#!/bin/sh
set -e
PROXY_BIN=/userdata/bin/zt-proxy

case "$1" in
  start)
    echo "Starting zt-proxy..."
    # Wait up to 30s for a ZeroTier interface with an assigned IP
    ZT_IP=""
    for i in $(seq 1 30); do
      ZT_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^zt[a-f0-9]{8}$' | head -1)
      if [ -n "$ZT_IFACE" ]; then
        ZT_IP=$(ip addr show "$ZT_IFACE" | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
        [ -n "$ZT_IP" ] && break
      fi
      sleep 1
    done
    if [ -z "$ZT_IP" ]; then
      echo "zt-proxy: no ZeroTier interface found after 30s, aborting"
      exit 1
    fi
    echo "zt-proxy: binding $ZT_IP:80 -> 127.0.0.1:80"
    start-stop-daemon -S -b -x "$PROXY_BIN" -- -listen "$ZT_IP:80" -target "127.0.0.1:80"
    ;;
  stop)
    echo "Stopping zt-proxy..."
    start-stop-daemon -K -x "$PROXY_BIN" 2>/dev/null || killall zt-proxy 2>/dev/null || true
    ;;
  restart)
    $0 stop; sleep 1; $0 start
    ;;
  *)
    echo "Usage: $0 {start|stop|restart}"
    exit 1
    ;;
esac
INITEOF
chmod +x /etc/init.d/S51zt-proxy
cp /etc/init.d/S51zt-proxy /userdata/bin/S51zt-proxy

echo ""
echo "==> [3/4] Setting JetKVM WebUI to loopback-only..."
if [ ! -f "$KVM_CONFIG" ]; then
  echo "    ERROR: $KVM_CONFIG not found — aborting."
  echo "           Without local_loopback_only=true the WebUI stays exposed on LAN."
  exit 1
fi

# Timestamped backup so re-runs don't clobber the original.
BACKUP="${KVM_CONFIG}.bak.ztproxy.$(date +%Y%m%d-%H%M%S)"
cp "$KVM_CONFIG" "$BACKUP"
echo "    Backup: $BACKUP"

# Handle false-with-any-spacing, true (no-op), and missing-field cases.
if grep -Eq '"local_loopback_only"[[:space:]]*:[[:space:]]*true' "$KVM_CONFIG"; then
  echo "    Already loopback-only — no edit needed."
elif grep -Eq '"local_loopback_only"[[:space:]]*:[[:space:]]*false' "$KVM_CONFIG"; then
  sed -i -E 's/"local_loopback_only"[[:space:]]*:[[:space:]]*false/"local_loopback_only": true/' "$KVM_CONFIG"
else
  # Insert immediately after the opening brace of the root object.
  sed -i 's/^{/{"local_loopback_only": true, /' "$KVM_CONFIG"
fi

# Verify — abort loudly if loopback-only didn't take, since this is the only
# thing keeping the WebUI off the LAN once the proxy is up.
if ! grep -Eq '"local_loopback_only"[[:space:]]*:[[:space:]]*true' "$KVM_CONFIG"; then
  echo "    ERROR: failed to set local_loopback_only=true in $KVM_CONFIG"
  echo "           Restoring backup and aborting."
  cp "$BACKUP" "$KVM_CONFIG"
  exit 1
fi
echo "    Config verified: $(grep -E '"local_loopback_only"[^,}]*' "$KVM_CONFIG")"

echo ""
echo "==> [4/4] Updating /userdata/bin/zt-reinstall.sh to include zt-proxy..."
cat > /userdata/bin/zt-reinstall.sh << 'REINSTALLEOF'
#!/bin/sh
# Run after a firmware update to restore ZeroTier and zt-proxy init scripts.
echo "==> Restoring ZeroTier init script..."
cp /userdata/bin/S50zerotier /etc/init.d/S50zerotier
chmod +x /etc/init.d/S50zerotier

echo "==> Restoring zt-proxy init script..."
cp /userdata/bin/S51zt-proxy /etc/init.d/S51zt-proxy
chmod +x /etc/init.d/S51zt-proxy

echo "==> Starting ZeroTier..."
/etc/init.d/S50zerotier start
sleep 3

echo "==> Starting zt-proxy..."
/etc/init.d/S51zt-proxy start

/userdata/bin/zerotier-cli -D/userdata/zerotier-one-data status
echo "Done."
REINSTALLEOF
chmod +x /userdata/bin/zt-reinstall.sh

echo ""
echo "==> Restarting JetKVM app..."
JETKVM_BIN=/userdata/jetkvm/bin/jetkvm_app
# Stop and wait for the old process to actually exit before starting a new
# one — otherwise both can race to bind 127.0.0.1:80.
start-stop-daemon -K -x "$JETKVM_BIN" 2>/dev/null || killall jetkvm_app 2>/dev/null || true
for i in $(seq 1 10); do
  pidof jetkvm_app >/dev/null 2>&1 || break
  sleep 1
done
if pidof jetkvm_app >/dev/null 2>&1; then
  echo "    WARNING: jetkvm_app still running after 10s — forcing kill"
  killall -9 jetkvm_app 2>/dev/null || true
  sleep 1
fi
start-stop-daemon -S -b -x "$JETKVM_BIN"

echo ""
echo "==> Starting zt-proxy..."
/etc/init.d/S51zt-proxy start
sleep 1

echo ""
echo "=========================================="
echo " Done!"
echo "=========================================="
echo ""
echo "  WebUI is now only accessible via ZeroTier:"
echo "    http://$ZT_IP"
echo ""
echo "  LAN access to port 80 is no longer available."
echo ""
echo "  After a firmware update, restore everything with:"
echo "    sh /userdata/bin/zt-reinstall.sh"
echo ""
