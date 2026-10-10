#!/usr/bin/env python3
"""Conservative, testable fstab editor. Does not mount or create directories.

The transaction is file-scoped and refuses symlinks, non-regular files and
concurrent edits. Intended to be called only through a separately authorized
Ansible stage, never through the diagnostic playbook.
"""
import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

MARK_START = "# BEGIN ANSIBLE SAMBA HISTORICAL NTFS"
MARK_END = "# END ANSIBLE SAMBA HISTORICAL NTFS"
HISTORICAL = (
    ("8CE4EC1DE4EC0AF2", "/mnt/fotos"),
    ("964C33BF4C3398C7", "/mnt/backup-antigo"),
    ("DA087AB8087A92ED", "/mnt/projetos-antigos"),
)
OPTIONS = "ro,uid=1000,gid=1000,umask=027,nofail,noauto"


class UnsafeFstab(RuntimeError):
    pass


class CommitDurabilityUncertain(UnsafeFstab):
    """Replacement happened, but directory persistence could not be confirmed."""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def validate_entries(raw):
    text = raw.decode("utf-8")
    lines = text.splitlines()
    begins = [i for i, line in enumerate(lines) if line == MARK_START]
    ends = [i for i, line in enumerate(lines) if line == MARK_END]
    if len(begins) != len(ends) or len(begins) > 1:
        raise UnsafeFstab("unbalanced or repeated managed markers")
    managed = []
    if begins:
        a, b = begins[0], ends[0]
        if a >= b:
            raise UnsafeFstab("invalid marker order")
        managed = lines[a + 1:b]
    unmanaged = [line for i, line in enumerate(lines)
                 if not begins or i < begins[0] or i > ends[0]]
    for line in unmanaged:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        if len(fields) < 2:
            raise UnsafeFstab("malformed existing fstab line")
        source, destination = fields[:2]
        for uuid, path in HISTORICAL:
            if destination == path or source.lower() == ("uuid=" + uuid).lower() or source == "/dev/disk/by-uuid/" + uuid:
                raise UnsafeFstab("unmanaged source or destination conflict: " + path)
    desired = ["UUID=" + uuid + " " + path + " ntfs-3g " + OPTIONS + " 0 0"
               for uuid, path in HISTORICAL]
    if begins and managed != desired:
        raise UnsafeFstab("managed block differs from expected contents; manual review required")
    if begins:
        return raw
    newline = b"" if not raw or raw.endswith(b"\n") else b"\n"
    block = ("\n".join([MARK_START, *desired, MARK_END]) + "\n").encode()
    return raw + newline + block


def verify(path, command):
    result = subprocess.run([command, "--verify", "--tab-file", str(path)],
                            capture_output=True, text=True, check=False)
    if result.returncode:
        raise UnsafeFstab("findmnt validation failed: " + result.stderr.strip())


def inspect_metadata(target):
    """Refuse metadata that atomic replacement cannot safely preserve."""
    st = target.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
        raise UnsafeFstab("target must be a regular file with one hard link")
    if stat.S_IMODE(st.st_mode) & 0o7000:
        raise UnsafeFstab("special permission bits require manual review")
    if hasattr(os, "listxattr"):
        try:
            attrs = os.listxattr(target, follow_symlinks=False)
        except (OSError, TypeError) as exc:
            raise UnsafeFstab("cannot inspect extended attributes: " + str(exc)) from exc
        if attrs:
            raise UnsafeFstab("extended attributes require manual review: " + ", ".join(sorted(attrs)))
    return st


def execute(target, findmnt, dry_run):
    target = Path(target)
    parent = target.parent
    lockpath = parent / ("." + target.name + ".samba.lock")
    if target.is_symlink():
        raise UnsafeFstab("refusing symlink target")
    st = inspect_metadata(target)
    lockfd = os.open(lockpath, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lockfd, fcntl.LOCK_EX)
        st = inspect_metadata(target)
        original = target.read_bytes()
        proposed = validate_entries(original)
        if proposed == original:
            print("UNCHANGED " + digest(original))
            return
        if dry_run:
            print("PLANNED " + digest(original) + " -> " + digest(proposed))
            return
        fd, candidate = tempfile.mkstemp(prefix="." + target.name + ".candidate-", dir=parent)
        backup = None
        committed = False
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(proposed)
                handle.flush()
                os.fsync(handle.fileno())
            verify(candidate, findmnt)
            backup_fd, backup = tempfile.mkstemp(prefix=target.name + ".samba-backup-", dir=parent)
            with os.fdopen(backup_fd, "wb") as handle:
                handle.write(original)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(backup, stat.S_IMODE(st.st_mode))
            os.chown(backup, st.st_uid, st.st_gid)
            current = inspect_metadata(target)
            if (target.read_bytes() != original or current.st_ino != st.st_ino
                    or current.st_uid != st.st_uid or current.st_gid != st.st_gid
                    or stat.S_IMODE(current.st_mode) != stat.S_IMODE(st.st_mode)):
                raise UnsafeFstab("fstab changed concurrently; aborting")
            os.chmod(candidate, stat.S_IMODE(st.st_mode))
            os.chown(candidate, st.st_uid, st.st_gid)
            os.replace(candidate, target)
            committed = True
            try:
                dirfd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(dirfd)
                finally:
                    os.close(dirfd)
            except OSError as exc:
                raise CommitDurabilityUncertain(
                    "APPLIED_DURABILITY_UNCERTAIN backup=" + str(backup)
                    + " sha256=" + digest(proposed)
                    + " reason=" + str(exc)
                    + "; inspect target and backup manually; no automatic rollback"
                ) from exc
            print("UPDATED backup=" + backup + " sha256=" + digest(proposed))
        finally:
            if not committed and backup:
                os.unlink(backup)
            if os.path.exists(candidate):
                os.unlink(candidate)
    finally:
        os.close(lockfd)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--fstab", required=True, help="explicit target path (never inferred)")
    p.add_argument("--findmnt", default="findmnt")
    p.add_argument("--apply", action="store_true", help="write only to explicitly chosen file")
    args = p.parse_args()
    if args.apply and os.path.abspath(args.fstab) == "/etc/fstab":
        print("REFUSED production /etc/fstab writes are not enabled", file=sys.stderr)
        return 2
    try:
        execute(args.fstab, args.findmnt, not args.apply)
    except (OSError, UnicodeError, UnsafeFstab) as exc:
        print("REFUSED " + str(exc), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
