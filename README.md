# linux-fortress

A hardened Linux environment, built from scratch and configured end to end with Ansible.
It merges five [roadmap.sh](https://roadmap.sh/projects) projects into one system:
[Linux Server Setup](https://roadmap.sh/projects/linux-server-setup),
[Bastion Host](https://roadmap.sh/projects/bastion-host),
[VPN Server Setup](https://roadmap.sh/projects/vpn-server-setup),
[File Integrity Checker](https://roadmap.sh/projects/file-integrity-checker) and
[Configuration Management](https://roadmap.sh/projects/configuration-management).

```
 your Mac ──ssh (key only, fail2ban, ufw limit)──▶ bastion ──ProxyJump / PermitOpen──▶ private
     │                                              │ WireGuard :51820/udp               │ nginx :80
     └──────── WireGuard tunnel (10.8.0.0/24) ─────▶│ NAT (iptables MASQUERADE)          │ ufw: only the bastion
                                                    │ integrity-check + systemd timer    │ integrity-check + timer
```

Two real Ubuntu 24.04 VMs (Multipass, systemd and a real kernel, so nothing is faked).
The private server's firewall accepts traffic only from the bastion; the only ways in are
`ssh` through the bastion and the WireGuard tunnel.

## Run it

Needs [Multipass](https://multipass.run) and Ansible (`brew install --cask multipass && brew install ansible`).

```sh
make up        # two VMs, inventory.ini, ssh_config
make setup     # ansible-playbook setup.yml (~5 min the first time)
make verify    # 42-point security checklist
```

Run a single role with tags: `ansible-playbook setup.yml --tags ssh,vpn`.
Tags: `base ssh bastion wireguard vpn nginx app integrity`.
Reach the machines with `ssh -F ssh_config bastion` and `ssh -F ssh_config private`.

## What each project became

| Project | Where | What it does |
|---|---|---|
| Linux Server Setup | `roles/base`, `roles/ssh` | Non-root sudo user, key-only sshd drop-in (no root, no passwords, `AuthenticationMethods publickey`, `MaxAuthTries 3`), UFW default-deny, unattended-upgrades, fail2ban, hostname (kept across reboots against cloud-init), timezone. |
| Bastion Host | `roles/bastion`, `group_vars/*` | `ProxyJump` access. The private server's UFW and fail2ban trust only the bastion. The bastion's sshd has `PermitOpen <private>:22`, so a stolen key cannot turn it into a general pivot. `LogLevel VERBOSE` records key fingerprints, and there is a login banner. |
| VPN Server | `roles/wireguard` | Keys generated on the server and never overwritten (re-runs keep clients working), preshared keys, `net.ipv4.ip_forward` via sysctl.d, NAT and forwarding rules in `PostUp`/`PostDown`, a UFW rule for 51820/udp, split tunnelling, one config per client (`clients/*.conf`, git-ignored). |
| File Integrity Checker | `roles/integrity_check` | `integrity-check init/check/update/check-all/list`, a ~130-line Bash tool using SHA-256 (`sha256sum`). The baseline is root-only (`0700` dir, `0600` file). A systemd timer runs it every 5 minutes with a sandboxed unit (`ProtectSystem=strict`, `NoNewPrivileges`). Tampering fails the unit and logs `auth.crit` to the journal. |
| Configuration Management | `setup.yml`, `inventory.ini` | Roles in sequence, tagged, idempotent: the second run reports `changed=0`. |

Design choice worth knowing: configuration paths are re-baselined by Ansible on every run
(Ansible is the source of truth, and drift is reported first). Sealed logs are baselined once
and only change with an explicit `integrity-check update`.

## See it work

```sh
make demo-private      # direct ssh to the private server times out; via the bastion it works
make demo-bruteforce   # username guessing from inside the network gets the attacker banned
make demo-tamper       # edit a sealed log; the checker, the timer unit and the journal all notice
make demo-vpn          # throwaway VM: private server unreachable, then reachable through WireGuard
```

## Things the build taught me (all hit for real)

- **`ufw limit` rejects, it does not drop.** Six new SSH connections in 30 seconds from one address
  get "Connection refused", and every retry restarts the window. My own verify script locked me out.
  Fix: SSH connection multiplexing (`ControlMaster`) in the generated `ssh_config`.
- **Hardening breaks tooling that assumes access.** `multipass info` and `multipass exec` ssh into
  the VM, which the private server refuses by design. The scripts use `multipass list` and go through
  the bastion instead.
- **Ubuntu 24.04 reads `sshd_config.d` first-match-wins**, so the hardening drop-in is named `10-` to
  beat cloud-init's `50-`. Every sshd change is checked with `sshd -t` before a reload.
- **Never block your own admin path:** UFW rules go in before `ufw enable`, and the private host's
  fail2ban ignores the bastion.

## Layout

```
setup.yml  ansible.cfg  inventory.ini(.example)  Makefile
group_vars/   all, bastion_servers, private_servers
roles/        base ssh bastion wireguard nginx app integrity_check
scripts/      vms.sh (VM lifecycle, inventory, ssh_config)  verify.sh  demo.sh
site/         the static website the `app` role deploys
```

Secrets (`.keys/`, `clients/*.conf`, `inventory.ini`, `ssh_config`) are git-ignored.

## Clean up

`make down` stops the VMs, `make destroy` deletes them and the generated files.
