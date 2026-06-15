#!/usr/bin/env bash
#
# Verification for the pi-image scripts. Pure bash + coreutils — no shellcheck,
# bats, or any framework the repo doesn't already carry, so it runs anywhere
# (locally and in CI) with zero install.
#
# It does two things:
#   1. syntax-gates every shell file with `bash -n` (the repo's baseline check)
#   2. unit-tests the first-boot hostname logic by SOURCING the real helper and
#      feeding it synthetic /proc/cpuinfo, /etc/hostname, /etc/hosts, ... so the
#      assertions exercise the same code the Pi runs (no logic is re-implemented)
#
# Run:  bash pi-image/test/run.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pi_image="$(cd "$here/.." && pwd)"
HELPER="$pi_image/goprint-firstboot-hostname"

pass=0 fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; }

# eq EXPECTED ACTUAL NAME
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "expected [$1], got [$2]"; fi; }

echo "== 1. bash -n syntax gate =="
for f in "$pi_image/provision.sh" "$HELPER" "$here/run.sh"; do
  if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")"; fi
done

# Source the helper to reach its functions without running main().
export GOPRINT_FIRSTBOOT_SOURCED=1
# shellcheck source=/dev/null
. "$HELPER"

echo "== 2. derive_suffix =="
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A typical Pi serial: leading zeros, last 6 hex are the identity.
printf 'processor\t: 0\nModel\t\t: Raspberry Pi\nSerial\t\t: 0000000012ab34cd\n' > "$work/cpuinfo1"
eq "ab34cd" "$(GOPRINT_CPUINFO=$work/cpuinfo1 derive_suffix)" "serial -> last 6 hex"

# Uppercase hex is normalised to lowercase (DNS labels are case-insensitive but
# lowercase is the convention) and trimmed to the last 6.
printf 'Serial\t\t: 00000000DEADBEEF\n' > "$work/cpuinfo2"
s2="$(GOPRINT_CPUINFO=$work/cpuinfo2 derive_suffix)"
eq "adbeef" "$s2" "uppercase serial -> last 6, lowercased"
if printf '%s' "$s2" | grep -q '[A-F]'; then bad "suffix still has uppercase hex"; else ok "suffix is all-lowercase"; fi

# Short serial (fewer than 6 meaningful digits after zero-strip) -> used as-is,
# still non-empty. Guards the bash-3.2 negative-substring foot-gun.
printf 'Serial\t\t: 00000000000000ab\n' > "$work/cpuinfo3"
eq "ab" "$(GOPRINT_CPUINFO=$work/cpuinfo3 derive_suffix)" "short serial used as-is"

# No Serial line -> fall back to the machine-id tail.
printf 'processor\t: 0\nModel\t\t: Some VM\n' > "$work/cpuinfo4"
printf 'abcdef0123456789feedface\n' > "$work/mid4"
eq "edface" "$(GOPRINT_CPUINFO=$work/cpuinfo4 GOPRINT_MACHINE_ID=$work/mid4 derive_suffix)" "no serial -> machine-id tail"

# Neither source readable -> still non-empty (timestamp last resort).
s="$(GOPRINT_CPUINFO=$work/none GOPRINT_MACHINE_ID=$work/none derive_suffix)"
if [ -n "$s" ]; then ok "no serial + no machine-id -> non-empty fallback"; else bad "fallback empty"; fi

echo "== 3. may_replace_hostname (don't fight an operator/Imager name) =="
if may_replace_hostname "raspberrypi";   then ok "stock 'raspberrypi' replaceable"; else bad "stock not replaceable"; fi
if may_replace_hostname "raspberrypi-2"; then ok "avahi variant 'raspberrypi-2' replaceable"; else bad "avahi variant not replaceable"; fi
if may_replace_hostname "";              then ok "empty hostname replaceable"; else bad "empty not replaceable"; fi
if may_replace_hostname "frontdesk-pi";  then bad "operator name should NOT be replaceable"; else ok "operator 'frontdesk-pi' preserved"; fi
if may_replace_hostname "goprint-ab34cd"; then bad "already-ours name matched stock RE"; else ok "already-ours name not stock (handled separately)"; fi

echo "== 4. rewrite_hosts (127.0.1.1 stays consistent, file never truncated) =="
# Replaces the old name on the 127.0.1.1 line.
printf '127.0.0.1\tlocalhost\n127.0.1.1\traspberrypi\n' > "$work/hosts1"
GOPRINT_HOSTS_FILE="$work/hosts1" rewrite_hosts "raspberrypi" "goprint-ab34cd"
if grep -q '^127\.0\.1\.1[[:space:]]goprint-ab34cd$' "$work/hosts1"; then ok "127.0.1.1 updated to new name"; else bad "127.0.1.1 not updated" "$(cat "$work/hosts1")"; fi
if grep -q '^127\.0\.0\.1[[:space:]]localhost$' "$work/hosts1"; then ok "localhost line preserved"; else bad "localhost line lost"; fi

# No 127.0.1.1 line present -> one is appended.
printf '127.0.0.1\tlocalhost\n' > "$work/hosts2"
GOPRINT_HOSTS_FILE="$work/hosts2" rewrite_hosts "raspberrypi" "goprint-ab34cd"
if grep -q '^127\.0\.1\.1[[:space:]]goprint-ab34cd$' "$work/hosts2"; then ok "127.0.1.1 line appended when absent"; else bad "127.0.1.1 not appended" "$(cat "$work/hosts2")"; fi

# Missing hosts file -> no crash, nothing created.
GOPRINT_HOSTS_FILE="$work/nope" rewrite_hosts "raspberrypi" "goprint-ab34cd"
if [ ! -f "$work/nope" ]; then ok "missing hosts file tolerated"; else bad "created a hosts file it shouldn't"; fi

echo "== 5. end-to-end main() in a sandbox (no root, no real systemd) =="
# Stub the privileged commands so main() runs fully unprivileged and NEVER
# touches a real system path: shadow PATH with no-op
# hostnamectl/hostname/systemctl/logger, and point STAMP at the sandbox.
stub="$work/bin"; mkdir -p "$stub"
for c in hostnamectl hostname systemctl logger; do printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/$c"; chmod +x "$stub/$c"; done

# run_e2e HOSTNAME_FILE HOSTS_FILE STAMP — execute the real script end-to-end.
run_e2e() {
  ( unset GOPRINT_FIRSTBOOT_SOURCED
    PATH="$stub:$PATH" \
    GOPRINT_CPUINFO="$work/cpuinfo1" \
    GOPRINT_HOSTNAME_FILE="$1" \
    GOPRINT_HOSTS_FILE="$2" \
    GOPRINT_STAMP="$3" \
    bash "$HELPER" >/dev/null 2>&1 )
}

# Fresh stock Pi: main() writes the derived name, fixes hosts, stamps done.
printf 'raspberrypi\n' > "$work/e2e_hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\traspberrypi\n' > "$work/e2e_hosts"
run_e2e "$work/e2e_hostname" "$work/e2e_hosts" "$work/e2e_stamp" || true
eq "goprint-ab34cd" "$(cat "$work/e2e_hostname" 2>/dev/null)" "main writes derived hostname"
if grep -q 'goprint-ab34cd' "$work/e2e_hosts"; then ok "main updates /etc/hosts"; else bad "main left hosts stale"; fi
if [ -f "$work/e2e_stamp" ]; then ok "main writes the once-only stamp"; else bad "main did not stamp"; fi

# Second run is a no-op (stamp present): hostname must not change.
printf 'raspberrypi\n' > "$work/e2e_hostname"   # pretend it reverted; stamp should still block
run_e2e "$work/e2e_hostname" "$work/e2e_hosts" "$work/e2e_stamp" || true
eq "raspberrypi" "$(cat "$work/e2e_hostname" 2>/dev/null)" "stamped run is a no-op (idempotent)"

# Operator name survives a fresh run (different sandbox, no stamp).
printf 'frontdesk-pi\n' > "$work/e2e_op_hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\tfrontdesk-pi\n' > "$work/e2e_op_hosts"
run_e2e "$work/e2e_op_hostname" "$work/e2e_op_hosts" "$work/e2e_op_stamp" || true
eq "frontdesk-pi" "$(cat "$work/e2e_op_hostname" 2>/dev/null)" "main preserves operator hostname"

echo "== 6. systemd unit sanity =="
unit="$pi_image/goprint-firstboot-hostname.service"
grep -q '^Type=oneshot'                  "$unit" && ok "unit Type=oneshot"            || bad "unit not oneshot"
grep -q '^RemainAfterExit=yes'           "$unit" && ok "unit RemainAfterExit=yes"     || bad "missing RemainAfterExit"
grep -q '^ConditionPathExists=!'         "$unit" && ok "unit guarded by stamp"        || bad "missing stamp guard"
grep -q '^WantedBy=multi-user.target'    "$unit" && ok "unit WantedBy=multi-user"     || bad "missing WantedBy"
grep -q '^ExecStart=/usr/local/libexec/goprint-firstboot-hostname' "$unit" && ok "unit ExecStart path matches install" || bad "ExecStart path mismatch"

echo "== 7. provision.sh wires it in =="
prov="$pi_image/provision.sh"
grep -q 'install -d /usr/local/libexec' "$prov" && ok "provision creates /usr/local/libexec" || bad "no libexec mkdir"
grep -q '/usr/local/libexec/goprint-firstboot-hostname' "$prov" && ok "provision installs helper" || bad "helper not installed"
grep -q '/etc/systemd/system/goprint-firstboot-hostname.service' "$prov" && ok "provision installs unit" || bad "unit not installed"
grep -q 'multi-user.target.wants/goprint-firstboot-hostname.service' "$prov" && ok "provision enables unit (symlink)" || bad "unit not enabled"

echo
echo "==> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
