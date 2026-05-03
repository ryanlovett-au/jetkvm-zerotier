#!/bin/sh
# ZeroTier installer for JetKVM (ARMv7 hard-float, static binary)
# Idempotent — safe to re-run after firmware updates.
# Run from the directory containing this script and the zerotier-one binary.

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ZT_BIN_SRC="$SCRIPT_DIR/zerotier-one"
ZT_INSTALL=/userdata/bin/zerotier-one
ZT_HOME=/userdata/zerotier-one-data

echo ""
echo "==> [1/5] Stopping any running ZeroTier..."
start-stop-daemon -K -x "$ZT_INSTALL" 2>/dev/null || killall zerotier-one 2>/dev/null || true
sleep 1

echo ""
echo "==> [2/5] Installing binary..."
mkdir -p /userdata/bin
cp "$ZT_BIN_SRC" "$ZT_INSTALL"
chmod +x "$ZT_INSTALL"
ln -sf "$ZT_INSTALL" /userdata/bin/zerotier-cli
ln -sf "$ZT_INSTALL" /userdata/bin/zerotier-idtool
echo "    Installed: $ZT_INSTALL ($(ls -lh "$ZT_INSTALL" | awk '{print $5}'))"

echo ""
echo "==> [3/5] Creating data directory..."
mkdir -p "$ZT_HOME"

echo ""
echo "==> [4/5] Ensuring TUN is available..."
modprobe tun 2>/dev/null || true
ls /sys/module/tun > /dev/null 2>&1 && echo "    TUN: OK" || echo "    WARNING: TUN module not loaded!"

echo ""
echo "==> [5/5] Installing init script..."

cat > /etc/init.d/S50zerotier << 'INITEOF'
#!/bin/sh
set -e
ZT_HOME=/userdata/zerotier-one-data
ZT_BIN=/userdata/bin/zerotier-one

case "$1" in
  start)
    echo "Starting ZeroTier..."
    modprobe tun 2>/dev/null || true
    start-stop-daemon -S -b -x "$ZT_BIN" -- "$ZT_HOME"
    ;;
  stop)
    echo "Stopping ZeroTier..."
    start-stop-daemon -K -x "$ZT_BIN" 2>/dev/null || killall zerotier-one 2>/dev/null || true
    ;;
  restart)
    $0 stop
    sleep 1
    $0 start
    ;;
  status)
    /userdata/bin/zerotier-cli -D/userdata/zerotier-one-data status
    /userdata/bin/zerotier-cli -D/userdata/zerotier-one-data listnetworks
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}"
    exit 1
    ;;
esac
INITEOF
chmod +x /etc/init.d/S50zerotier

# Persistent copy survives firmware updates
cp /etc/init.d/S50zerotier /userdata/bin/S50zerotier
chmod +x /userdata/bin/S50zerotier

echo ""
echo "    Writing /userdata/bin/zt-reinstall.sh..."
cat > /userdata/bin/zt-reinstall.sh << 'REINSTALLEOF'
#!/bin/sh
# Run after a firmware update to restore ZeroTier (and zt-proxy if installed).
echo "==> Restoring ZeroTier init script..."
cp /userdata/bin/S50zerotier /etc/init.d/S50zerotier
chmod +x /etc/init.d/S50zerotier

if [ -f /userdata/bin/S51zt-proxy ]; then
  echo "==> Restoring zt-proxy init script..."
  cp /userdata/bin/S51zt-proxy /etc/init.d/S51zt-proxy
  chmod +x /etc/init.d/S51zt-proxy
fi

echo "==> Starting ZeroTier..."
/etc/init.d/S50zerotier start
sleep 3

if [ -f /etc/init.d/S51zt-proxy ]; then
  echo "==> Starting zt-proxy..."
  /etc/init.d/S51zt-proxy start
fi

/userdata/bin/zerotier-cli -D/userdata/zerotier-one-data status
echo "Done."
REINSTALLEOF
chmod +x /userdata/bin/zt-reinstall.sh

echo ""
echo "=========================================="
echo " Done! Next steps:"
echo "=========================================="
echo ""
echo "  1. Start ZeroTier:"
echo "       /etc/init.d/S50zerotier start"
echo ""
echo "  2. Check status:"
echo "       /userdata/bin/zerotier-cli -D$ZT_HOME status"
echo ""
echo "  3. Join your network:"
echo "       /userdata/bin/zerotier-cli -D$ZT_HOME join <network-id>"
echo ""
echo "  4. Authorize in your ZeroTier controller (zerotier.com or self-hosted)"
echo "     Note your assigned ZeroTier IP — you'll need it for install-zt-proxy.sh"
echo ""
echo "  After a firmware update, restore with:"
echo "       sh /userdata/bin/zt-reinstall.sh"
echo ""
