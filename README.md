# jetkvm-zerotier

Restricts the [JetKVM](https://jetkvm.com) WebUI to a [ZeroTier](https://www.zerotier.com) interface only, so it is only reachable from your ZeroTier network — not from your LAN.

The JetKVM firmware has no iptables/nftables support, so a small static TCP proxy (`zt-proxy`) is used instead: it listens on the ZeroTier IP and forwards to the WebUI on loopback. The WebUI is configured to bind only to `127.0.0.1`, making `zt-proxy` the sole entry point.

Both binaries are fully statically linked for ARMv7 hard-float (the JetKVM's Rockchip RV1106G3). No shared library dependencies; no package manager needed.

---

## How it works

```
Browser (ZeroTier network)
        │
        ▼
zt-proxy  (listens on ZT IP :80)
        │
        ▼
JetKVM WebUI  (127.0.0.1:80, loopback only)
```

`kvm_config.json` is set to `"local_loopback_only": true`, so the WebUI never binds to the LAN interface. `zt-proxy` is the only path in, and only from hosts on your ZeroTier network.

---

## Requirements

- A ZeroTier network ID — create one via [ZeroTier](https://www.zerotier.com) or a self-hosted controller such as [Wiretier](https://wiretier.cloud)
- SSH access to your JetKVM over LAN (`root@<LAN-IP>`)
- A machine to run the transfer commands (any OS with a shell)

> **Note:** The JetKVM has no SFTP. Transfer files using `base64` pipe over SSH (shown below).

---

## Quick start (pre-built binaries)

Pre-built tarballs are in [`releases/`](releases/). The steps below use them directly.

### Step 1 — Transfer and install ZeroTier

```sh
# On your local machine — transfer the tarball
# macOS: base64 requires -i for input file
base64 -i releases/zerotier-one-1.16.0-armv7hf.tar.gz \
  | ssh -i ~/.ssh/your-key root@<LAN-IP> \
    "base64 -d > /tmp/zerotier-one-armv7hf.tar.gz"

# Linux: positional argument works
# base64 releases/zerotier-one-1.16.0-armv7hf.tar.gz \
#   | ssh -i ~/.ssh/your-key root@<LAN-IP> \
#     "base64 -d > /tmp/zerotier-one-armv7hf.tar.gz"

# On the device
ssh -i ~/.ssh/your-key root@<LAN-IP>
cd /tmp
tar -xzf zerotier-one-armv7hf.tar.gz
cd jetkvm-zerotier
sh install.sh
```

### Step 2 — Start ZeroTier and join your network

```sh
/etc/init.d/S50zerotier start

# Check it's running
/userdata/bin/zerotier-cli -D/userdata/zerotier-one-data status

# Join your network
/userdata/bin/zerotier-cli -D/userdata/zerotier-one-data join <your-network-id>
```

Then authorize the device in your ZeroTier controller ([zerotier.com](https://www.zerotier.com) or self-hosted, e.g. [Wiretier](https://wiretier.cloud)) and note the assigned ZeroTier IP (e.g. `10.x.x.x`).

Confirm the interface is up and has an IP:

```sh
ip addr show $(ip link | grep -o 'zt[a-z0-9]*' | head -1)
```

You should see an `inet` address before continuing.

### Step 3 — Transfer and install zt-proxy

```sh
# On your local machine
# macOS: base64 requires -i for input file
base64 -i releases/zt-proxy-v1.0.0-armv7hf.tar.gz \
  | ssh -i ~/.ssh/your-key root@<LAN-IP> \
    "base64 -d > /tmp/zt-proxy-armv7hf.tar.gz"

# Linux: positional argument works
# base64 releases/zt-proxy-v1.0.0-armv7hf.tar.gz \
#   | ssh -i ~/.ssh/your-key root@<LAN-IP> \
#     "base64 -d > /tmp/zt-proxy-armv7hf.tar.gz"

# On the device
cd /tmp
tar -xzf zt-proxy-armv7hf.tar.gz
cd zt-proxy
sh install.sh
```

The install script auto-detects your ZeroTier interface and IP, sets `local_loopback_only: true` in `kvm_config.json`, restarts the JetKVM app, and starts `zt-proxy`.

### Step 4 — Verify

From any machine on your ZeroTier network, open:

```
http://<your-ZeroTier-IP>
```

The WebUI should load. Port 80 on the LAN IP will no longer respond.

---

## After a firmware update

Firmware updates wipe `/etc/init.d/` but leave `/userdata/` intact. Run the reinstall script to restore both init scripts and restart services:

```sh
sh /userdata/bin/zt-reinstall.sh
```

---

## Building from source

### zt-proxy

Requires Go 1.22+. No cross-compiler needed.

```sh
cd zt-proxy
GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 \
  go build -ldflags="-s -w" -o zt-proxy .
```

Or use `build.sh` to compile and package the tarball in one step:

```sh
ZT_PROXY_VERSION=v1.0.0 bash build.sh
```

Output: `releases/zt-proxy-v1.0.0-armv7hf.tar.gz`

### ZeroTier

Requires an x86-64 Linux machine (or WSL/Docker) with the ARM cross-compiler:

```sh
# Ubuntu/Debian
sudo apt install gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf
```

Clone and build:

```sh
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
ZT_BIN=/path/to/ZeroTierOne/zerotier-one \
ZT_VERSION=1.16.0 \
  bash build.sh
```

Output: `releases/zerotier-one-1.16.0-armv7hf.tar.gz`

---

## Device layout (after install)

```
/userdata/
├── bin/
│   ├── zerotier-one        # ZeroTier daemon + CLI (static binary)
│   ├── zerotier-cli        # symlink → zerotier-one
│   ├── zerotier-idtool     # symlink → zerotier-one
│   ├── zt-proxy            # TCP proxy (static binary)
│   ├── S50zerotier         # persistent copy of ZeroTier init script
│   ├── S51zt-proxy         # persistent copy of zt-proxy init script
│   └── zt-reinstall.sh     # post-firmware-update restore script
├── zerotier-one-data/      # ZeroTier identity + state
└── kvm_config.json         # local_loopback_only: true

/etc/init.d/
├── S50zerotier             # starts ZeroTier on boot
└── S51zt-proxy             # starts zt-proxy on boot (waits for ZT interface)
```

---

## Troubleshooting

**zt-proxy won't start / no ZT interface**

ZeroTier must be running and joined before `zt-proxy` can bind. Check:

```sh
/userdata/bin/zerotier-cli -D/userdata/zerotier-one-data status
/userdata/bin/zerotier-cli -D/userdata/zerotier-one-data listnetworks
ip addr show $(ip link | grep -o 'zt[a-z0-9]*' | head -1)
```

**WebUI unreachable after install**

Check zt-proxy is running:

```sh
ps | grep zt-proxy
# or restart it:
/etc/init.d/S51zt-proxy restart
```

**Locked out (can't reach WebUI on LAN or ZeroTier)**

If ZeroTier is down and you've already set `local_loopback_only: true`, you can recover over LAN by temporarily restoring direct access:

```sh
# SSH in on LAN, then:
sed -i 's/"local_loopback_only": true/"local_loopback_only": false/' /userdata/kvm_config.json
killall jetkvm_app 2>/dev/null; start-stop-daemon -S -b -x /userdata/jetkvm/bin/jetkvm_app
```

**ZeroTier CLI usage**

```sh
/userdata/bin/zerotier-cli -D/userdata/zerotier-one-data status
/userdata/bin/zerotier-cli -D/userdata/zerotier-one-data listnetworks
/userdata/bin/zerotier-cli -D/userdata/zerotier-one-data peers
```
