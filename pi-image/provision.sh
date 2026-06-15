#!/usr/bin/env bash
#
# provision.sh — turn a stock Raspberry Pi OS Lite image into a GoPrint print
# bridge. Runs INSIDE the image during the CI build (pguyot/arm-runner-action
# emulates the ARM rootfs and execs this as root). Not meant to run on a normal
# machine.
#
# This is intentionally SELF-CONTAINED (no dependency on the private goprint
# source repo) so the image can be built + published entirely from this public
# repo using the workflow's built-in GITHUB_TOKEN — no cross-repo PAT.
#
# The systemd unit below is a copy of goprint/go-agent/deploy/goprint-agent.service.
# If that unit changes materially, update this copy.
#
# Inputs (environment):
#   GOPRINT_VERSION  required — release tag without leading v (e.g. 1.0.0). The
#                    matching agent tarball is pulled from this repo's release.
#   GOPRINT_BRAND    optional — brand label (default: goprint).
#
set -euo pipefail

VERSION="${GOPRINT_VERSION:?GOPRINT_VERSION is required (release tag, no leading v)}"
BRAND="${GOPRINT_BRAND:-goprint}"

echo "==> Provisioning GoPrint image (brand=$BRAND, agent v$VERSION)"
export DEBIAN_FRONTEND=noninteractive

# 1. Print backend + mDNS + label-printer drivers. Debian packaging enables
#    cups/avahi on first boot via deb-systemd-helper (works without a running
#    systemd), so no manual enable.
#
#    Label-printer drivers are bundled at build time so a plugged-in printer is
#    auto-detected OFFLINE — no apt at first boot (goprint#34 T1.4). The set
#    (~13 MB) covers the three families we ship for:
#      - printer-driver-dymo    DYMO LabelWriter (4XL, 400/450 Turbo, …)
#      - printer-driver-ptouch  Brother P-touch / QL label printers
#      - printer-driver-brlaser Brother laser (bonus coverage)
#      - foomatic-db            broad PPD database (many brands)
#    Zebra ZPL/EPL/CPCL PPDs come from the cups `sample.drv` (in `cups` itself).
apt-get update
apt-get install -y --no-install-recommends \
  cups cups-filters avahi-daemon ca-certificates curl jq \
  printer-driver-dymo printer-driver-ptouch printer-driver-brlaser foomatic-db
apt-get clean
rm -rf /var/lib/apt/lists/*

# 2. The headless agent for this release (public download — no auth). The armv6
#    build is the universal 32-bit binary; it runs on every Pi (Zero through 5).
url="https://github.com/orlando-umbrella/goprint-releases/releases/download/v${VERSION}/goprint-pi-armv6.tar.gz"
tmp="$(mktemp -d)"
echo "==> Fetching agent: $url"
curl -fsSL "$url" -o "$tmp/agent.tar.gz"
tar xzf "$tmp/agent.tar.gz" -C "$tmp"   # -> $tmp/goprint-agent
install -o root -g root -m 0755 "$tmp/goprint-agent" /usr/local/bin/goprint-agent

# 2b. Self-update machinery (goprint#29): the release's deploy bundle carries
#     the root-owned updater + its systemd units. Releases older than the
#     bundle (v1.0.0) lack it — tolerate 404 so those images still build,
#     just without self-update.
deploy_url="https://github.com/orlando-umbrella/goprint-releases/releases/download/v${VERSION}/goprint-pi-deploy.tar.gz"
if curl -fsSL "$deploy_url" -o "$tmp/deploy.tar.gz"; then
  echo "==> Installing self-updater from deploy bundle"
  mkdir -p "$tmp/deploy"
  tar xzf "$tmp/deploy.tar.gz" -C "$tmp/deploy"
  install -d /usr/local/libexec
  install -o root -g root -m 0755 "$tmp/deploy/goprint-update" /usr/local/libexec/goprint-update
  for unit in goprint-update.service goprint-update.path goprint-update-check.service goprint-update.timer; do
    install -o root -g root -m 0644 "$tmp/deploy/$unit" "/etc/systemd/system/$unit"
  done
  # Wi-Fi config helper (goprint#26): set Wi-Fi from the app. Tolerate older
  # bundles that predate it.
  if [ -f "$tmp/deploy/goprint-wifi" ]; then
    install -o root -g root -m 0755 "$tmp/deploy/goprint-wifi" /usr/local/libexec/goprint-wifi
    for unit in goprint-wifi.path goprint-wifi-apply.service; do
      install -o root -g root -m 0644 "$tmp/deploy/$unit" "/etc/systemd/system/$unit"
    done
  fi
  # Root-owned feed config (the updater trusts ONLY this, never the agent).
  cat > /etc/default/goprint-update <<EOF
# Root-owned self-update config (consumed by /usr/local/libexec/goprint-update).
# SHA256-verified installs from this feed only. Integrity, not authenticity.
FEED_URL=${GOPRINT_FEED_URL:-https://goprint.dev/updates/latest}
ASSET_KEY=pi_armv6
EOF
  chmod 0644 /etc/default/goprint-update
  # Enable for first boot (no running systemd in this chroot): the WantedBy
  # symlinks `systemctl enable` would create.
  install -d /etc/systemd/system/multi-user.target.wants /etc/systemd/system/timers.target.wants
  ln -sf /etc/systemd/system/goprint-update.path /etc/systemd/system/multi-user.target.wants/goprint-update.path
  ln -sf /etc/systemd/system/goprint-update.timer /etc/systemd/system/timers.target.wants/goprint-update.timer
  [ -f /etc/systemd/system/goprint-wifi.path ] && ln -sf /etc/systemd/system/goprint-wifi.path /etc/systemd/system/multi-user.target.wants/goprint-wifi.path
else
  echo "==> No deploy bundle on v${VERSION} (pre-self-update release); image will not self-update"
fi
rm -rf "$tmp"

# 3. Locked-down service user with CUPS access (mirrors deploy/install.sh).
getent group goprint >/dev/null 2>&1 || groupadd --system goprint
id goprint >/dev/null 2>&1 || useradd --system --gid goprint \
  --home-dir /var/lib/goprint-agent --shell /usr/sbin/nologin \
  --comment "GoPrint edge print agent" goprint
for grp in lpadmin lp; do
  getent group "$grp" >/dev/null 2>&1 && usermod -aG "$grp" goprint || true
done
install -d -o goprint -g goprint -m 0700 /var/lib/goprint-agent

# 4. systemd unit.
cat > /etc/systemd/system/goprint-agent.service <<'UNIT'
[Unit]
Description=GoPrint edge print agent
Documentation=https://github.com/orlando-umbrella/goprint
After=network-online.target cups.service
Wants=network-online.target

[Service]
Type=simple
User=goprint
Group=goprint
SupplementaryGroups=lpadmin lp
StateDirectory=goprint-agent
StateDirectoryMode=0700
Environment=HOME=/var/lib/goprint-agent
Environment=XDG_CONFIG_HOME=/var/lib/goprint-agent
# Appliance default: open LAN management so the desktop app discovers + manages
# this Pi over the network (mDNS announce + LAN-bound API). goprint#18/#24.
Environment=GOPRINT_LAN_MANAGEMENT=1
ExecStart=/usr/local/bin/goprint-agent
Restart=always
RestartSec=3
StartLimitIntervalSec=0
KillSignal=SIGTERM
TimeoutStopSec=30
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
UNIT

# 5. Enable for first boot without a running systemd: write the WantedBy symlink
#    by hand — exactly what `systemctl enable` produces.
install -d /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/goprint-agent.service \
  /etc/systemd/system/multi-user.target.wants/goprint-agent.service

# 6. First-boot unique hostname (goprint#24). The image ships with the stock
#    `raspberrypi` hostname, so multiple flashed Pis collide on
#    raspberrypi.local. We can't derive a per-device name at build time (the Pi
#    serial is per-device), so install a oneshot that runs on the first REAL
#    boot: it sets the hostname to goprint-<serial suffix>, fixes /etc/hosts,
#    makes avahi advertise the new <name>.local, then disables itself. The
#    helper is idempotent and best-effort — it never blocks boot. It also
#    respects an operator hostname set in Pi Imager (only replaces the stock
#    default), and it does NOT fight the agent's device_name (which falls back
#    to the OS hostname, so this just supplies a good collision-free default).
#    These files live next to provision.sh in this repo (pi-image/).
src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install -d /usr/local/libexec
install -o root -g root -m 0755 \
  "$src_dir/goprint-firstboot-hostname" /usr/local/libexec/goprint-firstboot-hostname
install -o root -g root -m 0644 \
  "$src_dir/goprint-firstboot-hostname.service" \
  /etc/systemd/system/goprint-firstboot-hostname.service
ln -sf /etc/systemd/system/goprint-firstboot-hostname.service \
  /etc/systemd/system/multi-user.target.wants/goprint-firstboot-hostname.service

echo "==> GoPrint provisioning complete (agent v$VERSION, brand $BRAND)."
