---
created: 2026-10-16T17:28:12.415Z
title: Disposable Windows 10/11 test VM on guiosoft-info
area: infrastructure
severity: major
files:
  - ansible/roles/
  - ansible/playbooks/
  - ansible/inventory/group_vars/prod.yml
  - Makefile
  - docs/current-state.md
---

## Problem

There is currently no way to run Windows-targeted tests (SMB/CIFS client behaviour, Windows-native tooling, PowerShell/Pester, NTLM/SMB signing and dialect quirks) from this lab. Every such test has to be done manually on a personal machine, which is not reproducible and cannot be scripted or destroyed safely.

`guiosoft-info` (Debian 13, `192.168.88.9`) already runs K3s and the lab's storage/backup stack, and is managed declaratively by Ansible in this repo. The missing capability is a **throwaway Windows 10/11 machine**: light enough to spin up and throw away, provisioned reproducibly, and reachable over SSH so it can be driven from a terminal or CI without a GUI/RDP session.

## Goal

A disposable Windows 10/11 test VM hosted on `guiosoft-info` that can be:

- created from scratch by a single command;
- minimal/lighweight (stripped install, no bloat, small disk footprint);
- reached over SSH from the LAN for scripted tests;
- destroyed and recreated cheaply and idempotently, with no risk to production data.

## Solution (hints — design not yet decided)

- **Hosting:** KVM/libvirt on `guiosoft-info` is the most likely fit (the host is Debian 13 and already Ansible-managed). Confirm whether nested virtualization / `/dev/kvm` is available before committing to it; fall back to `qemu` TCG only if performance is acceptable for tests.
- **Image:** official Microsoft eval ISO (Windows 10 Enterprise LTSC / Windows 11 Enterprise Evaluation) rather than a Windows licence. Unattended install via `autounattend.xml` so the VM boots to an SSH-capable state with no interaction.
- **Remote access:** Windows 11 and recent Windows 10 builds ship OpenSSH as an optional capability — install `OpenSSH.Server` in the autounattend answer file, enable the `sshd` service, `firewall` rule on port 22, and pre-seed `authorized_keys` for passwordless login. Validate the Win32-OpenSSH package behaviour on the chosen build before relying on it.
- **Automation:** a new Ansible role (e.g. `ansible/roles/win_test_vm/`) plus a playbook (e.g. `ansible/playbooks/win-test-vm.yml`) handling define/start/provision, and Makefile targets alongside the existing `storage-test*` family (`win-vm-up`, `win-vm-destroy`, `win-vm-reset`, `win-vm-ssh`) so the lifecycle matches repo conventions.
- **Isolation:** the VM must stay inside `192.168.88.0/24` with no inbound exposure to the internet and no access to k3s data paths (`/var/lib/rancher/k3s`, `/srv/k3s`) or NTFS data volumes (`/dev/sde1`, `/dev/sde3`, `/dev/sde6` referenced in `ansible/samba-host/`).
- **Isolation / namespace:** a dedicated libvirt network or a firewall-restricted bridge so SMB traffic from the VM cannot reach production shares unintentionally.
- **Disposable image:** disk on a separate qcow2 overlay on non-critical storage, `snapshot=on` so reset is instant; snapshot dir must not collide with the Samba/`local-path` volumes.

## Open questions

1. KVM available on `guiosoft-info`, or TCG software emulation only?
2. Windows 10 LTSC or Windows 11 — which target matters more for the tests being planned?
3. Is the intent to expose the VM to CI (GitHub Actions self-hosted runner) or only manual scripted use from the LAN?
4. Which tests is this actually for — is it SMB-specific (dialect/signing), or general Windows runtime?