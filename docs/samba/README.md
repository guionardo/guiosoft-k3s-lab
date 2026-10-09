# Samba LAN shares — staged design (NOT deployed)

Target: Debian 13 host `guiosoft-info`, outside Kubernetes, LAN only `192.168.88.0/24`.
The seven requested shares and observed UUIDs are in [shares.yml](../../ansible/samba/shares.yml).

## Safety contract

- No production changes in this stage. The only playbook, `samba-preflight.yml`, is read-only.
- Do not share `/mnt/store1` (active K3s PVs), `/mnt/store2` (backups), `/home` or `/`.
- Verify filesystem UUID and actual mount source before ever enabling a share; a directory that exists on the root filesystem is NOT proof that its dedicated disk is mounted.
- Existing NTFS volumes `sde1`, `sde3`, `sde6` are not mounted. Inspect NTFS health, Windows fast startup/hibernation state, existing data and desired access mode before deciding mount options. Never force a dirty NTFS volume into read-write mode.
- No recursive ownership or permissions changes. For NTFS, plan explicit UID/GID and masks; for ext4, grant access using dedicated groups/ACLs only after reviewing current ownership.
- Authenticated named users only; no guest, no SMB1. Passwords must not be committed to Git or printed in Ansible logs. Provision Samba credentials through an approved protected secret workflow.
- Reuse the existing nftables host firewall policy. Explicitly permit TCP 445 only from LAN on the verified interface, retaining existing K3s and SSH rules. Do not create a competing base chain with a blanket accept. No Cloudflare Tunnel route for SMB.
- For unavailable mounts, fail closed: share activation must be gated by `findmnt --mountpoint` and exact UUID; do not publish empty mountpoint directories.
- Reboot, mount failure, NTFS permissions, user authentication, LAN reachability, denial from other networks and rollback all require acceptance tests.

## Read-only discovery

From repository root, on the production host or via the configured inventory:

```bash
ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" \
ansible-playbook -i ansible/inventory/production.yml \
  ansible/playbooks/samba-preflight.yml --check --diff
```

The production inventory uses a local connection. Do not run it from another computer unless using an appropriately configured inventory pointing at `guiosoft-info`. `--check` is optional because the playbook contains only read operations.

## Next implementation stage (requires separate approval)

1. Review read-only audit and inspect `/etc/samba/smb.conf`, `/etc/nftables.d`, and actual share contents/permissions.
2. Decide read-only versus read-write for each share and Samba account/group mapping.
3. Add dedicated Samba Ansible role, templated `smb.conf`, mount units/fstab entries by UUID, strict mountpoint guards, authenticated accounts, and tests.
4. Integrate TCP 445 into the existing host firewall role, stage and syntax-check it, then use its existing rollback-protected trial procedure.
5. Apply only after explicit authorization, with backups of replaced configuration and a documented rollback.

This staged work does not modify disks, files, services, users, or the live firewall.
