# Storage Layout Redesign — guiosoft-info

**Status:** design proposal — nothing here has been executed.
**Date:** 2026-10-16
**Host:** `guiosoft-info`, Debian 13 (trixie), k3s v1.36.4+k3s1, containerd 2.3.4, kernel 7.1.5-zabbly+, up 34 days.
**Scope:** replacing NTFS with btrfs, and reorganising storage into a layout that supports four downstream consumers.

---

## 1. Intent and why

The host currently carries three generations of storage decisions at once: NTFS partitions inherited from a Windows era, ext4 volumes created ad hoc for K3s, and one NVMe ext4 partition (`/mnt/dev`) being used as a manual staging area for a reorganisation that was started and never finished.

That leaves the machine in a state where nobody can answer simple questions: which copy of a file is authoritative, which partitions are safe to touch, and where new data should go. Four separate projects are all blocked on this — SMB shares, an external file-access layer, a disposable Windows test machine, and Ariadne.

The reorganisation itself was already in progress (`/mnt/dev/working` and `/mnt/dev/hd500`) but its intent was never written down, which is why it stalled halfway.

**The outcome wanted:** one documented layout where every file lives in exactly one place, on a filesystem with checksums and snapshots, organised so that isolation for tenants, customers and disposable test runs is a filesystem primitive rather than an application convention.

---

## 2. Goals, non-goals, anti-goals

### Goals

1. Retire NTFS entirely. Every file currently on NTFS survives on btrfs.
2. One documented location per file. No duplicate copies left behind by the migration.
3. Isolation (per Ariadne tenant, per customer, per disposable VM run) expressed as btrfs subvolumes, with quotas and independent snapshots.
4. A migration that can be executed in phases, where **every phase is independently reversible** and no phase requires more free space than exists at the time it starts.
5. Checksums and snapshots on actively-written data.

### Non-goals

- Redundancy or drive-failure protection. No new disks; parity is out of scope. Failure protection comes from backup (§9).
- Encryption at rest. btrfs does not provide it and this design does not add it. LUKS is a separate decision with a real usability cost.
- Moving K3s. `/mnt/store1` and `/mnt/store2` stay on ext4, untouched (§5, D-003).
- Replacing the backup system. restic → R2 already exists and is extended, not replaced.

### Anti-goals

These would make the project a failure even if every line of it worked:

- **Any data loss.** One byte. The entire existing posture in `ansible/samba-host/` — read-only diagnostics, explicit authorisation per step, rollback rehearsed before application — carries over to this migration and is not relaxed because btrfs has snapshots.
- **Burning the K3s PVs or Immich.** `/var/lib/rancher/k3s`, `/mnt/store1`, `/mnt/store2` and Immich's uploads and PostgreSQL are never in the blast radius. A shrink or partition operation that touches a filesystem hosting K3s local-path PVs requires a separate design, not an improvisation here.
- **Declaring the migration done because files exist in two places.** `du` matching is not verification.

---

## 3. Current state — measured 2026-10-16

### Block devices

| Disk | Model | Size | Current layout | Used / Free |
|---|---|---|---|---|
| `sda` | SanDisk SDSSDA120G | 111.8G | 3× NTFS, label "Windows10". **Not in fstab, unused by Debian** | not measured |
| `sdb` | Kingston SA400S37240G | 223.6G | `sdb1` ext4 `/` (15165af6…), `sdb2` ext4 `/home` (0090b502…) | 75G/30G, 14G/91G |
| `sdc` | WDC WD10SPZX-24Z10 | 931.5G | `sdc1` ext4 "STORAGE-BKP" → `/mnt/store2` (95ba3a02…) | 350G / **521G** |
| `sdd` | Toshiba MQ01ABD100 | 931.5G | `sdd1` ext4 "STORAGE-1" → `/mnt/store1` (563c9d16…) | 300G / **570G** |
| `sde` | WDC WD20EARS-00MVWB0 | 1.8T | 6× NTFS, **none mounted, none in fstab** | see below |
| `sdf` | WDC WD5000AAKX-60U6AA0 | 465.8G | 3× NTFS mounted via ntfs-3g (`nofail`) | 3.5G, 134G, 103G |
| `sdg` | Cruzer Fit | 7.5G | vfat → `/mnt/dr-backup` | empty |
| `nvme0n1` | WD_BLACK SN7100 1TB | 931.5G | `nvme0n1p1` ext4 "dev" → `/mnt/dev` (3ed56e92…). **Partition table is MBR (`PTTYPE="dos"`)** | 235G / **635G** |

**Free space on filesystems that are not being retired: 1,847G** (`/mnt/dev` 635G, `/mnt/store1` 570G, `/mnt/store2` 521G, `/home` 91G, `/` 30G).

### Data on NTFS — measured by mounting read-only and `du`

| Partition | Label | UUID | Partition size | **Data** | Slack |
|---|---|---|---|---|---|
| `sde1` | 2-BACKUP | `964C33BF4C3398C7` | 1000G | **946G** | 54G |
| `sde6` | FOTOS | `8CE4EC1DE4EC0AF2` | 440.7G | **46G** | **395G** |
| `sde3` | 2-DEV-PROJECTS | `DA087AB8087A92ED` | 100G | **16G** | **84G** |
| `sdf2` | 500-Documentos | `01D36FD6673F4300` | 200G | **134G** | 66G |
| `sdf3` | 500-TEMP2 | `1068AFBC68AF9ECA` | 165.8G | **103G** | 63G |
| `sdf1` | 500-DEV-BIN | `01D36FD612953850` | 100G | **3.5G** | 96G |
| | | | **2006.5G** | **1248.5G** | |

**Total to migrate: 1248.5G into 1847G of existing free space.** It fits, with roughly 600G of headroom. No external staging media is required.

### `sdf2` composition (134G)

| Directory | Size | In `/mnt/dev/hd500/sdf2`? |
|---|---|---|
| `User` | 47G | partially |
| `TMP` | 33G | partially |
| `HDMARI` | 32G | partially |
| `Marines` | 13G | **no** |
| `Filmes` | 4.5G | **no** |
| `Clientes` | 3.6G | **no** (duplicated at `working/Clientes`) |
| `GoogleDrive` | 618M | no |
| `OneDriveTemp` | 296M | no |
| `Mídia` | 194M | no |
| `$RECYCLE.BIN` | 140M | no |
| `DiscoD` | 40M | no |
| `Imagens` | 25M | yes |
| `Família` | 6.4M | no |
| `OneDrive` | 0 | broken symlink — `unsupported reparse tag 0x9000701a` |

### `/mnt/dev` — the abandoned reorganisation

```
/mnt/dev/hd500/     166G   staging copies of sdf1 (EMPTY), sdf2 (65G), sdf3 (102G)
/mnt/dev/working/    69G   the new taxonomy, already under way
                          media/  51G
                          docs/   13G
                          Clientes/ 3.6G
                          dev/    1.8G
                          ebooks/ 62M
```

### `working/` overlaps `sdf2` — it is a reorganised copy, not an independent source

Directory listings confirm that `working/` was carved out of `sdf2`, not created independently:

| `working/` | Corresponding `sdf2` content |
|---|---|
| `working/Clientes` (14 folders, 3.6G) | `sdf2/Clientes` — **identical listing, verified duplicate** |
| `working/media/Filmes` | `sdf2/Filmes` (4.5G) |
| `working/media/Logan` | `sdf2/Mídia/Logan` |
| `working/media/Musicas` | probably `sdf2/User/Music` (inside the 47G `User`) — **not yet verified** |
| `working/media/Meninos` | origin unknown — **not yet verified** |
| `working/docs/Família` | `sdf2/Família` (6.4M) |
| `working/docs/Marines` | `sdf2/Marines` (13G) |
| `working/docs/Eu` | origin unknown — **not yet verified** |

Customer folders present in `working/Clientes` and in `sdf2/Clientes`:

> Ana Zipf, Blufisio, BluProVolei, Corporis Pilates, Empério da madeira, FischerSC, FiTRe, guionardofurlan.com.br, Martur, MyHit, Oechsler, Pé-de-moleque, Planetapeia, Santhies, plus `Tur24h.7z`

**Consequence for the migration:** `sdf2` retains the originals for at least part of `working/`, so the safety position is better than a naive read suggests. But it also means Phase 2's mapping table cannot be written from directory names alone — a literal migration of `sdf2` would duplicate content that `working/` already holds, violating goal 2. **A per-directory overlap analysis is a precondition for Phase 2, not a task inside it.**

Items whose origin is unverified (`Meninos`, `Eu`, `Musicas`) must be assumed to exist *only* in `working/` until proven otherwise.

### `sde` remaining partitions

| Partition | Size | State |
|---|---|---|
| `sde2` | 300G | NTFS "2-Discos Virtuais". **Not mounted, contents never inventoried** |
| `sde4` | 1K | NTFS metadata partition, belongs to `sde1` |
| `sde5` | 22.4G | Swap. **Dead** — the host uses `/swapfile` (4G); `sde5` is absent from `/proc/swaps` |

### Host resources

15Gi RAM, 9.8Gi resident (k3s-server 1.2Gi, prometheus 1.0Gi, beam.smp, node processes), **5.7Gi available**. `/dev/kvm` present. `/` is 72% full. `btrfs-progs` **not installed**.

### Backup coverage today

restic → R2 covers `/var/lib/rancher/k3s` and the `local-path` PVs under `/mnt/store1`. It does **not** cover the 1248.5G on NTFS, and does not cover `/mnt/dev/working`.

---

## 4. Constraints

1. No new disks. Disk count is fixed at 8.
2. Physical access to the host is available, so a boot failure is downtime, not a truck roll.
3. K3s and Immich are live and writing. `/mnt/store1`, `/mnt/store2`, `/var/lib/rancher/k3s` are off-limits.
4. 15Gi RAM, ~5.7Gi available. Binding constraint for any VM.
5. No filesystem may be shrunk or resized while hosting K3s local-path PVs without a separate design.
6. The host's partition table on `nvme0n1` is MBR, not GPT.

---

## 5. Target layout

### Decision: two btrfs filesystems, tiered by device — not one

A single btrfs filesystem spanning all disks was considered and rejected. Pooling an NVMe with a 2009-era 5400rpm drive puts filesystem metadata on whichever device the profile places it, and btrfs does not give the fine control over that placement that ZFS does. Mixing them means either slow operations on the NVMe or hand-tuned per-device profiles — complexity with no benefit here, because the isolation primitive (subvolumes) works identically within one filesystem as across two.

Instead, each physical device carries one filesystem, and tiering is expressed by *which data goes where*.

### Filesystem 1 — `dados` (hot tier), on `nvme0n1`

Carries everything actively read or written.

| Subvolume | Contents | Notes |
|---|---|---|
| `@ariadne/<tenant>` | Repositories and knowledge graph per Ariadne tenant | One subvolume per tenant; quota boundary |
| `@clientes/<name>` | Per-customer files | One per customer, mirroring the 14 existing folders |
| `@media` | Working media | Currently 51G under `working/media` |
| `@docs` | Documents | Currently 13G under `working/docs` |
| `@dev` | Checkouts, scratch | Ariadne-managed |
| `@ebooks` | 62M | |
| `@snapshots/<domain>` | Read-only snapshots | One snapshot namespace per domain |

The VM store (`@vms/base` plus one `@vms/<run-id>` per disposable run) is **deliberately not assigned here** — whether it belongs on the hot NVMe tier or in the cold tier alongside `sde2` is open decision §11.4. It is owned by the Windows-machine project; this design only has to not contradict it.

### Filesystem 2 — `arquivo` (cold tier), on `sde`

Carries archives that are read, not written.

| Subvolume | Contents |
|---|---|
| `@fotos` | 46G from `sde6` |
| `@projetos-antigos` | 16G from `sde3` |
| `@backup-antigo` | 946G from `sde1` — see open decision §11 |
| `@vms-discos` | The 300G currently in `sde2`, once inventoried |

### Retired

| Disk | Disposition |
|---|---|
| `sdf` | 240.5G migrated, then wiped. Retired as a device. |
| `sda` | 111.8G Windows 10 install. Windows is no longer used. Wiped and retired. |
| `sdg` | 7.5G USB stick at `/mnt/dr-backup`. Left alone. |

### Untouched

`sdb` (`/`, `/home`), `sdc` (`/mnt/store2`), `sdd` (`/mnt/store1`) all stay ext4. This honours D-003 in `ansible/samba-host/DECISIONS.md`.

---

## 6. Migration phases

Every phase below is a gate. Each ends with an explicit verification step, and no phase starts until the previous one has been verified and authorised. The rollback for every phase is listed, and **must be rehearsed before the phase is executed** — the existing `samba-host` documents record that its rollback was never validated under injected failure, and that gap is not repeated here.

### Phase 0 — Preconditions (no writes to any block device)

1. Install `btrfs-progs`.
2. **Back up `/mnt/dev/working` (69G).** It is in no backup at all today. Part of it is duplicated in `sdf2`, but three of its subtrees (`Musicas`, `Meninos`, `Eu`) have unverified origins and must be assumed unique (§3). This is the single highest-value pre-migration action and it is cheap relative to the data at risk.
3. **Inventory `sde2`** (300G, "2-Discos Virtuais"). Requires root; not yet done. Determine whether libvirt VM images live there and which ones are still in use.
4. Confirm `smartctl` status for every disk participating. Already reported healthy by the operator; re-confirm at execution time and record the output.
5. Confirm `sde5` is truly inactive and can be reclaimed.
6. Save copies of `/etc/fstab`, the current partition tables (`sfdisk -d`, `sgdisk -b`) and the mount output for every disk.
7. Confirm no other process is writing to `/mnt/dev`.

**Rollback:** nothing is modified. None needed.

### Phase 1 — Create `dados` on `nvme0n1`

1. Boot a rescue environment; unmount `/mnt/dev`.
2. `e2fsck -f /dev/nvme0n1p1`.
3. Shrink `nvme0n1p1` with `resize2fs`, leaving ample headroom over the 235G in use. ext4 cannot be shrunk below the largest file, so verify that limit first.
4. Create the second partition in the freed tail and `mkfs.btrfs`.
5. Resolve the MBR question: the disk is currently partitioned with `dos`. Either stay on MBR (which permits four primary partitions, so two is fine) or convert to GPT, which requires care with a mounted/booted disk. Staying on MBR is the lower-risk default and is sufficient here.
6. Mount, create the subvolumes from §5, set `noatime`.
7. Copy `/mnt/dev/working` into the appropriate subvolumes. Verify against §12's standard.
8. **Stop here. Do not delete `nvme0n1p1` in this phase.**

**Why step 8 is a stop, not a continuation.** btrfs can only absorb device space *adjacent to the end of its own range*. Once btrfs occupies the tail of the disk, the space freed by deleting the leading ext4 partition lies *before* it and cannot be reclaimed by `btrfs resize max` — and the partition cannot be moved left either, because the kernel refuses `parted move` on an in-use partition. Reclaiming that head space requires a second `mkfs.btrfs` from a rebuilt partition table.

That second `mkfs` is a genuinely separate and more dangerous operation. Deferring it keeps this phase reversible and costs only the unused head space — and with 1.85T free elsewhere, that capacity is not needed. Reclaiming it later, once the migration is proven, is a low-stakes operation with a known-good backup behind it.

**Rollback:** the ext4 partition is never deleted in this phase. Reverting is deleting the btrfs partition and `resize2fs` back, with the original data untouched throughout.

**Capacity check:** needs ~310G (working 69G + sdf content 240.5G) in the tail region. The device offers 931.5G total; 235G is held by the ext4 partition during this phase. Fits with substantial headroom even before reclaiming that 235G.

### Phase 2 — Migrate `sdf` content (240.5G)

Order matters — migrate the *fat partition / small data* items first, because their slack is what funds the later phases.

| Step | Source | Data | Destination |
|---|---|---|---|
| 2.1 | `sdf1` DevBin | 3.5G | `@dev/tools` |
| 2.2 | `sdf2` `Clientes` | 3.6G | `@clientes/<name>` — already duplicated at `working/Clientes`; confirm identical, keep one, then remove the other |
| 2.3 | `sdf2` `Marines`, `Filmes`, `Família`, `Mídia`, `DiscoD` | ~18G | `@media`, `@docs` |
| 2.4 | `sdf2` `User`, `TMP`, `HDMARI` | 112G | `@media`, `@docs` |
| 2.5 | `sdf3` TEMP2 | 103G | `@media`, `@docs` |
| 2.6 | `$RECYCLE.BIN`, `OneDriveTemp`, `GoogleDrive` | ~1G | Decide: retain or discard explicitly, do not migrate by default |

`/mnt/dev/hd500/` (166G) is staging that duplicates `sdf`. It is removed **only after** each corresponding `sdf` item has been verified present at its destination. Removing it frees 166G.

**Rollback:** source partitions untouched throughout. Delete the destination copy.

### Phase 3 — Wipe `sdf` and `sda`

Only after Phase 2 is verified end to end. `sgdisk --zap-all` / `wipefs -a`, remove the three `sdf` entries from `/etc/fstab` (they are `nofail`, so removal is safe and trivially reversible by restoring the saved fstab). `sda` is wiped outright — Windows is no longer used.

**Rollback:** none for `sda`. For `sdf`, restoring the partition table from the Phase 0 dump recreates the metadata but **not the data** — data on `sdf` must be considered gone once this phase completes. This is the point of no return for `sdf` specifically.

### Phase 4 — Migrate `sde` archives (1008G)

1. `Fotos` (46G) and `ProjetosAntigos` (16G) first — small data, large slack.
2. `BackupAntigo` (946G) last. See open decision §11 — it may not be migrated at all.
3. Convert the retired partitions (`sde1`, `sde3`, `sde6`, and `sde5` if reclaimed) into the `arquivo` filesystem.

**Capacity check:** `sde` partitions available after retiring the archives: 1000G + 440.7G + 100G = 1540.7G, excluding `sde2`. Data to place: 62G (Fotos + ProjetosAntigos) plus whatever §11 decides about BackupAntigo. Comfortable.

**Rollback:** source NTFS untouched until each item is verified. Recovery is re-mounting NTFS read-only — which is exactly why the Phase 0 measurement used that method.

### Phase 5 — VM store

`sde2`'s 300G becomes btrfs carrying `@vms/base` and per-run subvolumes. **Owned by the Windows-machine project, not this one** — recorded here only because it shares the disk.

### Phase 6 — Downstream

Samba shares and the external file-access layer are redefined against the new mount points. Both are separate projects; this design only fixes what they will mount.

---

## 7. Snapshot and quota policy

- **One snapshot namespace per domain**, on a `@snapshots/<domain>` subvolume. Read-only (`btrfs subvolume snapshot -r`).
- **A snapshot before every risky operation**, retained until the operation is verified. This is what retires the hand-rolled `fstab` rollback transaction and its unvalidated-recovery problem.
- **Retention:** last 7 snapshots per namespace, pruned monthly. A prune script is part of the implementation, not an afterthought.
- **Quotas** are set per `@ariadne/<tenant>` and per `@clientes/<name>`. Initially these should be *reporting only* (`btrfs qgroup show`) until the real distribution of tenant and customer sizes is known. Enforcement before measurement is how you discover a quota by hitting it.
- **Never snapshot a running VM's disk in place.** Disposable VMs use `@vms/<run-id>` subvolumes destroyed after the run — no snapshot needed.
- **Quotas and subvolumes are not a backup.** Both vanish with the device.

## 8. Why btrfs, and what was rejected

| | btrfs | ZFS | ext4 + LVM |
|---|---|---|---|
| Data checksums | yes | yes | no |
| Snapshots | yes | yes | LVM only |
| Quotas | per subvolume | per dataset | per LV |
| Parity | no (RAID1/RAID10 only) | RAID-Z | no |
| Memory cost | negligible | significant (ARC) | negligible |
| Grow later | yes | **no — raidz is frozen** | yes |
| Multi-device | awkward with mixed media | first-class | n/a |

Rejected on three concrete grounds:

1. **ZFS ARC vs 5.7Gi available.** ZFS's cache competes directly with k3s, Immich and Prometheus for memory that does not exist. On a 15Gi host already at 9.8Gi resident, this is not a tuning problem.
2. **raidz cannot be extended.** With no new disks, the realistic future is *adding* capacity later. A raidz vdev frozen at its initial geometry is a trap on a home lab.
3. **Nothing needs parity here.** Redundancy is supplied by backup (§9), not by the filesystem.

btrfs multi-device RAID1 was considered and is irrelevant: the only spare is the 111.8G `sda`, and RAID1 mirrors to the size of the smallest member, so it would yield 111G rather than the available capacity.

## 9. Backup

- **Extend restic → R2 to cover everything on the new filesystems.** Today it covers only the K3s tree.
- **`dados` on Standard storage**; restored often, egress is free.
- **`arquivo` on Infrequent Access** — colder data, no free tier, and retrieval is only paid on days you actually restore. Cheaper than Standard for this data.
- **Cost:** verified against Cloudflare's pricing page (updated 2026-10-16). The free tier's 10 GB-month is irrelevant at 1249G. Standard ≈ **$18.58/month**; Infrequent Access ≈ **$12.49/month**. Egress is free and unlimited, so restores cost nothing.
- **A backup is not a backup until a restore has been tested.** Verification by restore, recorded, before the migration declares the archives protected.
- **btrfs `scrub`** scheduled weekly per filesystem, with notification on error. This is the "predict failure" capability that a manual `smartctl` check does not provide — it catches corruption that SMART reports as healthy.

## 10. What this design hands downstream

| Project | What it inherits |
|---|---|
| SMB shares | Stable POSIX mount points with real ownership and ACL semantics — removing the `ntfs-3g` constraint that `access-control.md` flags |
| External file-access layer | One subvolume per customer under `@clientes`, with the 14 existing folders already named and populated |
| Windows test machine | `@vms/base` plus `@vms/<run-id>` — a clean guest in about a second |
| Ariadne | `@ariadne/<tenant>` — tenant isolation at the filesystem layer, with quotas and independent snapshots |
| The migration itself | `ansible/samba-host/`'s safety posture, carried over unchanged |

## 11. Open decisions

Surfaced by a builder review of this document; unresolved. Each changes what gets built. **Ranked by consequence.**

1. **Does a completed off-host backup gate every irreversible step?**
   The most consequential question here. Phases 1, 3 and 4 all contain operations that cannot be undone. If "verified" means *present at the destination on the same host*, then one power event or one failed disk destroys everything, and §8's claim that failure protection comes from backup is false. If instead a completed, restore-verified R2 backup is a **precondition** for any wipe, the phase order changes materially — Phase 3 cannot run until ~1249G has been uploaded, and the project becomes backup-first. This also decides whether Phase 1's deferred head-space reclaim is ever worth doing.

2. **What is `BackupAntigo` (946G) actually a backup of?**
   Any recommendation about it rests on an assumption this document cannot support. If it duplicates the R2 bucket or an existing restic repository, it should stay on NTFS and count as already protected. If it holds the only copy of something, it is the most important data on the machine. This one fact decides whether `arquivo` is a ~540G or a ~1.5T filesystem, changes Phase 4's capacity check, and changes §9's cost figure.
   **Answerable now** by mounting `sde1` read-only and inspecting its top level. Cheapest high-value item in this list.

3. **Do `sdf2/TMP` (33G) and `sdf3/TEMP2` (103G) migrate to the hot tier?**
   Phase 2 currently routes 136G into `@media`/`@docs` on the NVMe unfiltered — roughly 15% of the hot tier, from directories whose names say they are temporary, whose contents nobody has reviewed. They either migrate and compete with `@ariadne` and the VM store, or they are discarded. Needs an explicit call rather than a default.

4. **What uid/gid/mode does each migrated subvolume get?**
   The NTFS mounts are `0777 root:root`; `/mnt/dev` is `0755 guionardo:guionardo`. A plain `rsync -a` carries the NTFS blanket `0777` onto btrfs — producing exactly the outcome §10 promises to eliminate for the SMB and external-access projects. `ntfs-ownership.md` forbids a blanket `chown -R`, so ownership must be set deliberately per subvolume during the copy. This cannot be deferred to a cleanup pass.

5. **What is the canonical host path for each subvolume?**
   §5 fixes names but no paths, yet Phase 6 makes these a contract handed to two downstream projects, and `docs/storage.md` already establishes a `/srv/k3s/...` convention in this repo. Whether `dados` mounts once at, say, `/mnt/dados` with subvolumes as directories, or each bind-mounts individually, drives fstab, the Samba share definitions and the external-storage configuration. D-006 also applies to the `/mnt/hd500/sdf*` paths this change makes stale.

6. **What is the acceptable downtime window?**
   Phase 1 requires a rescue-environment boot, and this is a single-node K3s cluster running Immich and the observability stack. There is no second node. Whether the cluster must stay up, and how long a planned outage is acceptable, decides whether Phase 1 can use a rescue boot at all.

7. **What is the measured upstream bandwidth?**
   Phase 0 step 2 calls a 69G backup cheap, and decision 1 may require ~1249G uploaded before Phase 3 can run. At 20 Mbps that is roughly 7.5 hours and ~5–6 days respectively — making this a week-long phase rather than a step, and changing the order. Related: restic sets storage class per backend, not per path, so Standard and Infrequent Access need two repositories or two buckets.

8. **Where does the VM store live** — btrfs on `sde2`, in `arquivo`, or on the hot tier?

9. **What is in `sde2`?** Uninventoried. Blocks decision 8 and any operation touching `sde`.

10. **`sda`:** wipe entirely, or preserve the Windows 10 install? Windows is not in use, so wiping is the default — but `sda2` is 110.7G and the image may be wanted.

## 12. Left to the builder

- Exact partition boundaries and the `resize2fs` target size for Phase 1.
- Subvolume naming conventions beyond the prefixes chosen here.
- Snapshot pruning implementation and schedule.
- qgroup limit values (deliberately deferred — see §7).
- The restic repository layout and retention policy.
- Whether phases run from Ansible (consistent with the repo) or as documented manual runbooks.

### 12.1 Definition of "verified" — fixed here, tooling is the builder's

Anti-goal 2 forbids declaring success because files exist in two places, so the standard is pinned now even though the implementation is not.

A phase is verified when **all four** hold, per file:

1. **Content identical** — verified by checksum, not by size. `rsync -c` or equivalent.
2. **Path identical** — same relative path, with any name that btrfs cannot represent explicitly enumerated as a known exception.
3. **Timestamps preserved** — mtime carried across, so later incremental syncs and `find -newer` queries behave.
4. **Counts reconciled** — file and directory totals match source to destination, so an omission cannot hide inside a matching total.

Two NTFS-specific conditions must be handled explicitly by the verification tooling, because they are known to bite here:

- **Reparse points do not survive a naive copy.** `sdf2/OneDrive` is already known to fail with `unsupported reparse tag 0x9000701a`. Others likely exist. Each one must be enumerated and classified — copied as a regular file, skipped, or reconstructed — never silently dropped.
- **NTFS is case-insensitive and reserves device names.** btrfs is case-sensitive and has no reserved names, so a name that exists on NTFS may collide or need renaming on btrfs. Collisions must be reported, not resolved by overwriting.

One further caveat applies to every number in §3: `du` over ntfs-3g reports **allocated blocks through FUSE**, not logical file size, and compressed or sparse NTFS files read differently than their logical size. The "it fits, no staging media needed" conclusion rests on those figures. A single `du --apparent-size` pass over the mounted volumes revalidates it before anything is committed.