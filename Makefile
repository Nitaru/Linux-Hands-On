.PHONY: up setup verify check ssh-bastion ssh-private demo-bruteforce demo-tamper demo-private demo-vpn down destroy

SSH = ssh -F ssh_config

up:                ## create the two VMs and generate inventory + ssh_config
	scripts/vms.sh up

setup:             ## configure everything (ansible-playbook setup.yml)
	ansible-playbook setup.yml

check:             ## syntax check only
	ansible-playbook setup.yml --syntax-check

verify:            ## run the security checklist against both servers
	scripts/verify.sh

ssh-bastion:
	$(SSH) bastion
ssh-private:       ## goes through the bastion with ProxyJump
	$(SSH) private

demo-private:      ## prove the private server is not directly reachable
	scripts/demo.sh private
demo-bruteforce:   ## attack the bastion's sshd and watch fail2ban ban the attacker
	scripts/demo.sh bruteforce
demo-tamper:       ## modify a sealed log and watch integrity-check catch it
	scripts/demo.sh tamper
demo-vpn:          ## reach the private server through a WireGuard tunnel
	scripts/demo.sh vpn

down:
	scripts/vms.sh down
destroy:
	scripts/vms.sh destroy
