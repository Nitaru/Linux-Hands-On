#!/usr/bin/env bash
# Manage the two Multipass VMs and generate the files that point Ansible/ssh at them.
set -euo pipefail
cd "$(dirname "$0")/.."

VMS=(bastion private)
KEY=.keys/fortress_ed25519
STATE=.vm-state

# `multipass list` is answered by the daemon. `multipass info` would ssh into the VM, which the
# private server's firewall (rightly) refuses.
ip_of() {
  multipass list --format json |
    python3 -c 'import json,sys; print(next(v["ipv4"][0] for v in json.load(sys.stdin)["list"] if v["name"] == "'"$1"'"))'
}

up() {
  [[ -f $KEY ]] || ssh-keygen -t ed25519 -N "" -C linux-fortress -f "$KEY" -q
  sed "s|__PUBKEY__|$(cat "$KEY.pub")|" scripts/cloud-init.yml.tpl > .keys/cloud-init.yml
  for vm in "${VMS[@]}"; do
    multipass info "$vm" >/dev/null 2>&1 && { echo "$vm already exists"; continue; }
    multipass launch 24.04 --name "$vm" --cpus 1 --memory 1G --disk 8G --cloud-init .keys/cloud-init.yml &
  done
  wait
  inventory
  sshconfig
}

inventory() {
  mkdir -p "$STATE"
  local b p kh common jump
  b=$(ip_of bastion); p=$(ip_of private)
  kh="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$PWD/$STATE/known_hosts"
  common="$kh"
  jump="$kh -o ProxyCommand=\"ssh -W %h:%p -q -i $PWD/$KEY $kh ubuntu@$b\""
  cat > inventory.ini <<INV
[bastion_servers]
bastion ansible_host=$b

[private_servers]
private ansible_host=$p

[all:vars]
ansible_user=ubuntu
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_private_key_file=$PWD/$KEY
ansible_ssh_common_args='$common'

[private_servers:vars]
ansible_ssh_common_args='$jump'
INV
  echo "inventory.ini: bastion=$b private=$p"
}

sshconfig() {
  local b p
  b=$(ip_of bastion); p=$(ip_of private)
  cat > ssh_config <<CFG
# Use with: ssh -F ssh_config bastion | private
Host *
    IdentityFile $PWD/$KEY
    IdentitiesOnly yes
    UserKnownHostsFile $PWD/$STATE/known_hosts
    StrictHostKeyChecking accept-new
    # One connection per host: the firewall rate-limits new ssh connections (ufw limit).
    ControlMaster auto
    ControlPersist 120
    ControlPath /tmp/fortress-ssh-%C

Host bastion
    HostName $b
    User fortress

Host private
    HostName $p
    User fortress
    ProxyJump bastion
CFG
  echo "ssh_config written"
}

down()    { multipass stop "${VMS[@]}"; }
destroy() { multipass delete --purge "${VMS[@]}" || true; rm -rf "$STATE" inventory.ini ssh_config clients/*.conf; }

case "${1:-}" in
  up) up ;; inventory) inventory ;; sshconfig) sshconfig ;; down) down ;; destroy) destroy ;;
  ips) for vm in "${VMS[@]}"; do echo "$vm $(ip_of "$vm")"; done ;;
  *) echo "usage: $0 up|inventory|sshconfig|ips|down|destroy" >&2; exit 2 ;;
esac
