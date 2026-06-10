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

# 1. Print backend + mDNS. Debian packaging enables cups/avahi on first boot via
#    deb-systemd-helper (works without a running systemd), so no manual enable.
apt-get update
apt-get install -y --no-install-recommends \
  cups cups-filters avahi-daemon ca-certificates curl
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
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
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

echo "==> GoPrint provisioning complete (agent v$VERSION, brand $BRAND)."
