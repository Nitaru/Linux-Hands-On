#cloud-config
# Bootstrap only: gives Ansible a way in. Everything else is configured by the playbook.
users:
  - name: ubuntu
    ssh_authorized_keys:
      - __PUBKEY__
