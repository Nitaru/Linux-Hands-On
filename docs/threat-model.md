# Threat model

What this environment protects, what the hardening covers, and what it does **not**. Every statement below
comes from the roles and scripts in this repo; the "how it is checked" column says whether a control is only
configured, or also proven by `make verify` / `make demo-*` on the running VMs.

## Scope and assumptions

- Two Ubuntu 24.04 VMs on a local Multipass network: a **bastion** (public entry) and a **private** server (nginx).
- The admin's Mac is the **control machine**. It holds the SSH key (`.keys/fortress_ed25519`) and the WireGuard
  client configs (`clients/*.conf`). Both are git-ignored.
- This is a lab. The VMs are on a host-only network, so exposure to the real internet was never tested.
- Out of scope: the hypervisor and the Mac itself, physical access, denial of service, and the kernel's own bugs.

## What is protected

| Asset | Why it matters |
|---|---|
| Admin access (SSH key, `sudo`) on both VMs | Root on either machine |
| The private server and its web content | The thing the bastion exists to shield |
| WireGuard keys and client configs | A client config is a network credential |
| Config files and audit logs | Evidence and settings an attacker would want to change |

## Trust boundaries

```
internet ─ 22/tcp, 51820/udp ─▶ bastion ─ 22/tcp, 80/tcp (only from the bastion) ─▶ private
control machine (holds the SSH key and VPN configs) ─────────────────────────────────▶ both
```

## What the hardening covers

| Threat | Control in this repo | How it is checked |
|---|---|---|
| Password guessing on SSH | No password logins, `AuthenticationMethods publickey`, `MaxAuthTries 3`, `LoginGraceTime 20`; `ufw limit` on the bastion | Config: `verify.sh` reads `sshd -T`. Not tested: an actual failed password attempt |
| Username guessing / scanning | fail2ban `sshd` jail in `aggressive` mode (4 tries in 10 min, 1 h ban) | Behaviour: `make demo-bruteforce` shows the ban |
| Reaching the private server directly | UFW on the private host accepts SSH and HTTP only from the bastion | Behaviour: `verify.sh` and `make demo-private` show the direct connection time out |
| A stolen key turning the bastion into a general pivot | `PermitOpen <private>:22`, no agent forwarding, no X11 | Config only: `verify.sh` checks `sshd -T`. A forwarding request to another host is **not** tried |
| Logging in as root or as an unknown user | `PermitRootLogin no`, `AllowUsers` | Config: `verify.sh` |
| Silent changes to SSH, fail2ban or WireGuard config, or to the sealed logs | `integrity-check` SHA-256 baselines, root-only (`0700`/`0600`), run every 5 minutes by a sandboxed systemd unit; a mismatch fails the unit and logs `auth.crit` | Behaviour: `make demo-tamper` edits a log and shows the checker, the unit and the journal all notice |
| Known-vulnerability exposure from unpatched packages | `unattended-upgrades` and the apt timers enabled | Config: `verify.sh`. Not tested: that a security update was actually installed |
| Information leaks from the web server | `server_tokens off`, `X-Content-Type-Options`, `X-Frame-Options` | `verify.sh` checks the version header only; the other two headers are not checked |
| An attacker on the VPN reaching the wrong network | Split tunnel (`wg_client_allowed_ips`), preshared key per client, keys `0600` in a `0700` directory | Behaviour: `make demo-vpn`. See the VPN limit below |

## What it does NOT cover (known gaps, worst first)

1. **One unencrypted SSH key unlocks everything.** `scripts/vms.sh` creates it with `-N ""` (no passphrase), the
   same key goes to the bootstrap `ubuntu` user and the `fortress` admin, and the admin has `NOPASSWD` sudo.
   Anyone who copies `.keys/fortress_ed25519` from the Mac gets root on both VMs. No passphrase, no hardware key,
   no short-lived certificates, no second factor, and no key rotation.
2. **The bootstrap `ubuntu` account stays allowed.** `ssh_allow_users` is `["ubuntu", "fortress"]`; `ubuntu` is
   needed for the first Ansible run and is never removed afterwards.
3. **A VPN client config is a bearer credential.** The server forwards and NATs everything from the VPN subnet
   (`iptables -I FORWARD 1 -i wg0 -j ACCEPT` plus `MASQUERADE`), and the private server trusts the bastion's
   address, so a stolen `laptop.conf` or `phone.conf` reaches the private server's SSH and HTTP ports and
   anything else the bastion can reach. Keys are generated once and never rotated, and there is no per-client
   revoke other than editing the server config by hand.
4. **Tamper detection, not prevention, and it is local.** An attacker with root can edit the baseline, stop the
   timer or replace `/usr/local/sbin/integrity-check`. None of those are baselined. Alerts go only to the local
   journal: nobody is notified, and logs are not shipped anywhere, so the same root access can erase the evidence.
   Detection latency is up to 5 minutes.
5. **The baseline covers a short list of paths.** The SSH and fail2ban drop-ins, `wg0.conf` on the bastion, and
   `/var/log/fortress`. Not covered: `/etc/passwd`, `/etc/sudoers.d`, `authorized_keys`, nginx config, systemd
   units, and system binaries.
6. **Almost no audit trail.** The bastion logs key fingerprints (`LogLevel VERBOSE`), but only to local `auth.log`.
   No `auditd`, no session recording, no central logging.
7. **Patching is only half automatic.** The role enables the periodic jobs and sets no automatic reboot, so
   kernel updates wait for someone to reboot. There is no vulnerability scan, and I did not check which origins
   the Ubuntu default allows.
8. **First connection is trusted on first use.** The generated `ssh_config` uses `StrictHostKeyChecking
   accept-new`, so the first host key seen is accepted without comparison.
9. **No TLS and no web hardening beyond two headers.** nginx serves plain HTTP on port 80, with no CSP and no
   rate limiting. It is reachable only from the bastion, which limits the exposure.
10. **No supply-chain pinning.** Ansible collections (`community.general`, `ansible.posix`) and packages come
    from the current versions of their sources, and `base` runs `apt upgrade dist` on every run.
11. **No baseline benchmark.** No CIS or similar scoring, no kernel hardening beyond `ip_forward` for WireGuard,
    and AppArmor is whatever Ubuntu ships by default.

## What `make verify` does not prove

- It reads configuration (`sshd -T`, `ufw status`) far more often than it tries the forbidden thing. Behaviour is
  proven only for: direct SSH to the private server timing out, the fail2ban ban, the tamper detection, and the
  VPN reaching the private server.
- It checks the baseline file's mode (`0600`), not the directory's.
- It cannot run in CI. GitHub's runners have no VMs, so CI only lints (`yamllint`, `ansible-lint`, `shellcheck`,
  `--syntax-check`).

## Cheapest fixes, in order of value

1. Put a passphrase on the key (or use a hardware-backed key) and remove `ubuntu` from `ssh_allow_users` once
   `fortress` works. This closes gaps 1 and 2 at almost no cost.
2. Add per-client firewall rules on the bastion so a VPN client can reach only what it needs, and add a
   `make rotate-wg-client` that regenerates one client's keys. This closes most of gap 3.
3. Baseline `/usr/local/sbin/integrity-check`, the two systemd units, `/etc/sudoers.d` and `authorized_keys`,
   and ship the journal's `auth.crit` events off the machine. This closes most of gaps 4 to 6.
4. Add behaviour checks to `verify.sh`: try a forbidden port forward through the bastion, and confirm that a
   password attempt is refused.
