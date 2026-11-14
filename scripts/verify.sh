#!/usr/bin/env bash
# Security checklist: everything the Linux Server Setup, Bastion Host, VPN and
# File Integrity projects ask for, checked against the running machines.
set -uo pipefail
cd "$(dirname "$0")/.."

SSH=(ssh -F ssh_config -o BatchMode=yes -o ConnectTimeout=8)
pass=0; fail=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }
check() {   # check "<description>" <host> "<remote command that must exit 0>"
  local desc=$1 host=$2 cmd=$3
  if "${SSH[@]}" "$host" "$cmd" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

BASTION_IP=$(awk '/Host bastion/{f=1} f&&/HostName/{print $2; exit}' ssh_config)
PRIVATE_IP=$(awk '/Host private/{f=1} f&&/HostName/{print $2; exit}' ssh_config)

for h in bastion private; do
  section "$h: Linux Server Setup"
  check "logged in as the non-root admin user (not root)"        $h '[ "$(id -un)" = fortress ]'
  check "admin user is in the sudo group"                         $h 'id -nG | grep -qw sudo'
  check "sshd: root login disabled"                               $h 'sudo sshd -T | grep -qx "permitrootlogin no"'
  check "sshd: password authentication disabled"                  $h 'sudo sshd -T | grep -qx "passwordauthentication no"'
  check "sshd: only public keys allowed"                          $h 'sudo sshd -T | grep -qx "authenticationmethods publickey"'
  check "ufw is active, default deny incoming"                    $h 'sudo ufw status verbose | grep -q "Status: active" && sudo ufw status verbose | grep -q "deny (incoming)"'
  check "unattended-upgrades is enabled"                          $h 'grep -q "Unattended-Upgrade \"1\"" /etc/apt/apt.conf.d/20auto-upgrades && systemctl is-enabled apt-daily-upgrade.timer'
  check "fail2ban is running with the sshd jail"                  $h 'sudo fail2ban-client status sshd'
  check "hostname is fortress-$h"                                 $h '[ "$(hostname)" = fortress-'$h' ]'
  check "timezone is UTC"                                         $h '[ "$(timedatectl show -p Timezone --value)" = UTC ]'
  check "journalctl can read the ssh log"                         $h 'sudo journalctl -u ssh -n 5 --no-pager'
  check "/var/log/auth.log exists"                                $h 'test -f /var/log/auth.log'
  section "$h: File integrity"
  check "integrity baseline is clean"                             $h 'sudo integrity-check check-all'
  check "integrity timer is active"                               $h 'systemctl is-active integrity-check.timer'
  check "baseline is readable by root only"                       $h '[ "$(sudo stat -c %a /var/lib/integrity-check/baseline.sha256)" = 600 ]'
done

section "bastion: Bastion Host + VPN"
check "sshd forwards only to the private server (PermitOpen)"     bastion "sudo sshd -T | grep -qx 'permitopen $PRIVATE_IP:22'"
check "login banner configured"                                   bastion 'sudo sshd -T | grep -q "banner /etc/issue.net"'
check "ip forwarding is on"                                       bastion '[ "$(sysctl -n net.ipv4.ip_forward)" = 1 ]'
check "wg0 is up and listening"                                   bastion 'sudo wg show wg0 listen-port'
check "NAT masquerade rule for the VPN subnet"                    bastion 'sudo iptables -t nat -S POSTROUTING | grep -q MASQUERADE'
check "51820/udp open in ufw"                                     bastion 'sudo ufw status | grep -q "51820/udp"'
check "wg-quick@wg0 enabled at boot"                              bastion 'systemctl is-enabled wg-quick@wg0'

section "private: only reachable through the bastion"
check "ProxyJump through the bastion works"                       private 'true'
if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -i .keys/fortress_ed25519 "fortress@$PRIVATE_IP" true >/dev/null 2>&1; then
  bad "direct ssh from this machine is blocked"
else
  ok "direct ssh from this machine is blocked (timeout)"
fi
check "ufw only allows ssh from the bastion"                      private "sudo ufw status | grep -E '^22/tcp' | grep -q $BASTION_IP"
check "nginx serves the site (via the bastion)"                   bastion "curl -fsS --max-time 5 http://$PRIVATE_IP/ | grep -q linux-fortress"
check "nginx hides its version"                                   private '! curl -sI localhost | grep -qi "server: nginx/"'

section "Result"
printf '  %d passed, %d failed\n\n' "$pass" "$fail"
(( fail == 0 ))
