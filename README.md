# jetkvm-zerotier

Pre-built, up-to-date [ZeroTier](https://www.zerotier.com) binaries for the [JetKVM](https://jetkvm.com), automatically cross-compiled and published via GitHub Actions.

## The problem

The JetKVM runs a minimal Buildroot Linux on an ARMv7 hard-float CPU (Rockchip RV1106G3) with uClibc as its C library. Standard ZeroTier release binaries are linked against glibc and won't run on the device. The firmware provides no package manager, no compiler, and no easy way to build software on-device.

This repo solves that by providing fully static ZeroTier binaries compiled specifically for the JetKVM, with a GitHub Actions workflow that checks for new ZeroTier releases every week and publishes a fresh build automatically.

## Releases

Pre-built tarballs are in [`releases/`](releases/). A [GitHub Actions workflow](.github/workflows/update-zerotier.yml) runs weekly and adds a new build whenever a new ZeroTier version is released upstream.

Each tarball contains the `zerotier-one` static binary and an `install.sh` that sets up the binary and init scripts under `/userdata/` so they survive firmware updates.

---

## Install ZeroTier on JetKVM

> **Note:** The JetKVM has no SFTP. Files must be transferred using a `base64` pipe over SSH.

### Step 1 — Transfer the tarball

```sh
# Find the latest release
ls releases/zerotier-one-*-armv7hf.tar.gz

# Set a variable to the latest (replace X.Y.Z with the version shown above)
ZT_TARBALL=releases/zerotier-one-X.Y.Z-armv7hf.tar.gz

# macOS
base64 -i "$ZT_TARBALL" \
  | ssh -i ~/.ssh/your-key root@<LAN-IP> \
    "base64 -d > /tmp/zerotier-one-armv7hf.tar.gz"

# Linux
# base64 "$ZT_TARBALL" \
#   | ssh -i ~/.ssh/your-key root@<LAN-IP> \
#     "base64 -d > /tmp/zerotier-one-armv7hf.tar.gz"
```

### Step 2 — Install on the device

```sh
ssh -i ~/.ssh/your-key root@<LAN-IP>
cd /tmp
tar -xzf zerotier-one-armv7hf.tar.gz
cd jetkvm-zerotier
sh install.sh
```

### Step 3 — Start ZeroTier and join your network

```sh
/etc/init.d/S50zerotier start

# Confirm it's running
/userdata/bin/zerotier-cli -D/userdata/zerotier-one-data status

# Join your network
/userdata/bin/zerotier-cli -D/userdata/zerotier-one-data join <your-network-id>
```

Authorize the device in your ZeroTier controller ([zerotier.com](https://www.zerotier.com) or self-hosted, e.g. [Wiretier](https://wiretier.cloud)), then confirm the interface is up:

```sh
ip addr show $(ip link | grep -o 'zt[a-z0-9]*' | head -1)
```

You should see an `inet` address assigned by your controller.

---

## Optional: restrict WebUI access to ZeroTier only

By default the JetKVM WebUI is accessible to anyone on your LAN. If you want to lock it down so it's only reachable over ZeroTier, this repo also includes `zt-proxy` — a small static TCP proxy that listens on the ZeroTier interface and forwards to the WebUI on loopback.

The JetKVM firmware has no `iptables` or `nftables` support, so this userspace proxy is the only way to restrict access by interface.

```
Browser (ZeroTier network)
        │
        ▼
zt-proxy  (ZeroTier IP :80)
        │
        ▼
JetKVM WebUI  (127.0.0.1:80, loopback only)
```

### Install zt-proxy

ZeroTier must be running and have an assigned IP before installing.

> ⚠️ **Don't run this unless you have working SSH access independent of the WebUI.** Once installed, the WebUI is unreachable on LAN. If ZeroTier later breaks (e.g. controller deauthorizes the device, network ID changes, interface fails to come up after a firmware update), the only recovery path is SSH — see [Troubleshooting](#troubleshooting) below.

```sh
# Find the latest release
ls releases/zt-proxy-*-armv7hf.tar.gz

# Transfer (replace vX.Y.Z with the version shown above)
ZTP_TARBALL=releases/zt-proxy-vX.Y.Z-armv7hf.tar.gz

# macOS
base64 -i "$ZTP_TARBALL" \
  | ssh -i ~/.ssh/your-key root@<LAN-IP> \
    "base64 -d > /tmp/zt-proxy-armv7hf.tar.gz"

# Linux
# base64 "$ZTP_TARBALL" \
#   | ssh -i ~/.ssh/your-key root@<LAN-IP> \
#     "base64 -d > /tmp/zt-proxy-armv7hf.tar.gz"

# On the device
cd /tmp
tar -xzf zt-proxy-armv7hf.tar.gz
cd zt-proxy
sh install.sh
```

The install script auto-detects your ZeroTier interface and IP, sets `"local_loopback_only": true` in `kvm_config.json`, restarts the JetKVM app, and starts `zt-proxy`. The WebUI will then only be reachable at `http://<your-ZeroTier-IP>`.

---

## After a firmware update

Firmware updates wipe `/etc/init.d/` but leave `/userdata/` intact. Run the reinstall script to restore init scripts and restart services:

```sh
sh /userdata/bin/zt-reinstall.sh
```

---

## Building from source

### ZeroTier

Releases are built automatically by the [GitHub Actions workflow](.github/workflows/update-zerotier.yml). To build manually, you need an x86-64 Linux machine (or WSL/Docker) with the ARM cross-compiler:

```sh
# Ubuntu/Debian
sudo apt install gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf

git clone --depth=1 https://github.com/zerotier/ZeroTierOne.git
cd ZeroTierOne

make -j$(nproc) \
  CC=arm-linux-gnueabihf-gcc \
  CXX=arm-linux-gnueabihf-g++ \
  CFLAGS="-march=armv7-a -mfpu=vfpv3 -mfloat-abi=hard -Os" \
  CXXFLAGS="-march=armv7-a -mfpu=vfpv3 -mfloat-abi=hard -Os" \
  LDFLAGS="-static" \
  ZT_STATIC=1

arm-linux-gnueabihf-strip zerotier-one
```

Then package with `build.sh`:

```sh
ZT_BIN=/path/to/ZeroTierOne/zerotier-one ZT_VERSION=X.Y.Z bash build.sh
```

### zt-proxy

Requires Go 1.22+. No cross-compiler needed.

```sh
ZT_PROXY_VERSION=vX.Y.Z bash build.sh
```

Or build the binary directly:

```sh
cd zt-proxy
GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 \
  go build -ldflags="-s -w" -o zt-proxy .
```

---

## Testing

### zt-proxy unit tests

The Go test suite covers bidirectional forwarding, half-close handling, multiple concurrent connections, and unreachable-target behavior. Run it from the `zt-proxy/` directory on any host with Go 1.22+ — no device or cross-compiler needed:

```sh
cd zt-proxy
go test -v ./...
```

Expected output ends with `PASS` and `ok  zt-proxy`.

To also run `go vet` and a build check:

```sh
cd zt-proxy
go vet ./... && go build ./... && go test ./...
```

### On-device sanity checks (after install)

After running the installers, verify on the device:

```sh
# 1. ZeroTier is running and joined
/userdata/bin/zerotier-cli -D/userdata/zerotier-one-data status
/userdata/bin/zerotier-cli -D/userdata/zerotier-one-data listnetworks

# 2. zt-proxy is running and bound to the ZeroTier IP only
ps | grep zt-proxy
netstat -tln | grep ':80 '
#   Expect:
#     127.0.0.1:80    (jetkvm_app — loopback only)
#     <zt-ip>:80      (zt-proxy)
#   Should NOT see 0.0.0.0:80 anywhere.

# 3. WebUI reachable over ZeroTier, NOT over LAN
#    From a peer on the ZeroTier network:
curl -I http://<zt-ip>/
#    From a host on LAN (should fail / time out):
curl -I --max-time 3 http://<lan-ip>/
```

### Init-script smoke test

Confirm the init scripts start, stop, and restart cleanly:

```sh
/etc/init.d/S50zerotier restart
/etc/init.d/S51zt-proxy restart
```

---

## Device layout (after full install)

```
/userdata/
├── bin/
│   ├── zerotier-one        # ZeroTier daemon + CLI (static binary)
│   ├── zerotier-cli        # symlink → zerotier-one
│   ├── zerotier-idtool     # symlink → zerotier-one
│   ├── zt-proxy            # TCP proxy (static binary, optional)
│   ├── S50zerotier         # persistent copy of ZeroTier init script
│   ├── S51zt-proxy         # persistent copy of zt-proxy init script (optional)
│   └── zt-reinstall.sh     # post-firmware-update restore script
├── zerotier-one-data/      # ZeroTier identity + state
└── kvm_config.json         # local_loopback_only: true (if zt-proxy installed)

/etc/init.d/
├── S50zerotier             # starts ZeroTier on boot
└── S51zt-proxy             # starts zt-proxy on boot (optional)
```

---

## Troubleshooting

**ZeroTier status**

```sh
/userdata/bin/zerotier-cli -D/userdata/zerotier-one-data status
/userdata/bin/zerotier-cli -D/userdata/zerotier-one-data listnetworks
/userdata/bin/zerotier-cli -D/userdata/zerotier-one-data peers
```

**No ZeroTier interface / no IP**

```sh
ip addr show $(ip link | grep -o 'zt[a-z0-9]*' | head -1)
```

If the interface has no `inet` address, the device hasn't been authorized in your controller yet, or ZeroTier is still connecting.

**WebUI unreachable after zt-proxy install**

```sh
ps | grep zt-proxy
/etc/init.d/S51zt-proxy restart
```

**Locked out (zt-proxy installed, ZeroTier down)**

Recover LAN access by temporarily disabling loopback-only mode:

```sh
sed -i 's/"local_loopback_only": true/"local_loopback_only": false/' /userdata/kvm_config.json
killall jetkvm_app 2>/dev/null; start-stop-daemon -S -b -x /userdata/jetkvm/bin/jetkvm_app
```
