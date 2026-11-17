#!/usr/bin/env bash
# Scripted attacks and proofs. Each one prints what it does, then shows the evidence.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SSH=(ssh -F ssh_config -o BatchMode=yes)
BASTION_IP=$(awk '/Host bastion/{f=1} f&&/HostName/{print $2; exit}' ssh_config)
PRIVATE_IP=$(awk '/Host private/{f=1} f&&/HostName/{print $2; exit}' ssh_config)

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
run() { printf '\033[2m$ %s\033[0m\n' "$*"; "$@"; }

private() {
  say "Direct ssh to the private server is dropped by its firewall (5s timeout)"
  run ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -i .keys/fortress_ed25519 "fortress@$PRIVATE_IP" hostname || echo "-> blocked, as intended"
  say "Through the bastion with ProxyJump it works"
  run "${SSH[@]}" private 'hostname; echo "ssh client address seen by the private server: ${SSH_CLIENT%% *}"'
}

bruteforce() {
  say "Attacker (a shell on the private VM, standing in for an outsider) guesses usernames against the bastion"
  for u in admin root test oracle postgres deploy guest ubnt; do
    "${SSH[@]}" private "ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null $u@$BASTION_IP true" >/dev/null 2>&1
    printf '  tried %-9s -> exit %s\n' "$u" "$?"
  done
  sleep 3
  say "fail2ban on the bastion"
  run "${SSH[@]}" bastion 'sudo fail2ban-client status sshd'
  say "What the attacker sees now (refused: the ban is a firewall rule)"
  "${SSH[@]}" private "ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null admin@$BASTION_IP true" 2>&1 | tail -1
  say "Evidence in fail2ban's log"
  run "${SSH[@]}" bastion 'sudo grep -E "Found|Ban " /var/log/fail2ban.log | tail -5'
  say "Cleaning up: unban so the demo can be repeated"
  run "${SSH[@]}" bastion "sudo fail2ban-client unban --all"
}

tamper() {
  local f=/var/log/fortress/provisioned.log
  say "Baseline is clean"
  run "${SSH[@]}" bastion "sudo integrity-check check $f"
  say "An intruder edits the sealed log to hide their tracks"
  run "${SSH[@]}" bastion "sudo cp $f /root/provisioned.log.orig && echo 'host=bastion provisioned=never' | sudo tee $f >/dev/null"
  say "Manual check reports the change (exit code 1)"
  run "${SSH[@]}" bastion "sudo integrity-check check $f; echo exit=\$?"
  say "The systemd timer unit fails too, so monitoring would see it"
  "${SSH[@]}" bastion "sudo systemctl start integrity-check.service" 2>&1 | tail -1
  run "${SSH[@]}" bastion 'systemctl --failed --no-legend'
  say "And it is in the journal, tagged for alerting"
  run "${SSH[@]}" bastion 'sudo journalctl -t integrity-check --no-pager -n 3 -o cat'
  say "Restoring the original file"
  run "${SSH[@]}" bastion "sudo mv /root/provisioned.log.orig $f && sudo systemctl reset-failed integrity-check.service && sudo integrity-check check $f"
}

vpn() {
  local conf=clients/laptop.conf
  [[ -f $conf ]] || { echo "missing $conf; run: make setup" >&2; exit 1; }
  say "Creating a throwaway client VM"
  multipass launch 24.04 --name vpnclient --cpus 1 --memory 1G --disk 6G >/dev/null
  multipass exec vpnclient -- sudo apt-get update -qq </dev/null >/dev/null
  multipass exec vpnclient -- sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get install -y -qq wireguard-tools curl </dev/null >/dev/null 2>&1
  say "Without the tunnel the private server is unreachable from this machine"
  multipass exec vpnclient -- curl -sS --max-time 4 "http://$PRIVATE_IP/" 2>&1 | tail -1 || true
  say "Bring the tunnel up with the generated client config"
  multipass transfer "$conf" vpnclient:/tmp/laptop.conf
  multipass exec vpnclient -- sudo install -m 600 /tmp/laptop.conf /etc/wireguard/wg0.conf
  multipass exec vpnclient -- sudo wg-quick up wg0 2>&1 | tail -3
  say "Through the tunnel: the bastion's VPN address answers, and so does the private web server"
  multipass exec vpnclient -- ping -c 2 -W 2 10.8.0.1 | tail -2
  multipass exec vpnclient -- curl -fsS --max-time 5 "http://$PRIVATE_IP/" | grep -o '<h1>.*</h1>'
  say "Handshake as seen by the server"
  run "${SSH[@]}" bastion 'sudo wg show wg0 | grep -E "peer|handshake|transfer|endpoint"'
  say "Removing the client VM"
  multipass delete --purge vpnclient
}

case "${1:-}" in
  private) private ;; bruteforce) bruteforce ;; tamper) tamper ;; vpn) vpn ;;
  *) echo "usage: $0 private|bruteforce|tamper|vpn" >&2; exit 2 ;;
esac
