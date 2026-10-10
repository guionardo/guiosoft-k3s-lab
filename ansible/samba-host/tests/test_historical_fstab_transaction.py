"""Safe local tests: all fixtures live under TemporaryDirectory; no disks or mounts."""
import contextlib
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import historical_fstab_transaction as txn


class TransactionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.fstab = Path(self.tmp.name) / "fstab"
        self.original = b"# local fixture\nUUID=OTHER /mnt/other ext4 defaults 0 2\n"
        self.fstab.write_bytes(self.original)

    def apply(self):
        with patch.object(txn, "verify") as check:
            with contextlib.redirect_stdout(io.StringIO()):
                txn.execute(self.fstab, "findmnt", False)
        return check

    def test_dry_run_does_not_change_anything(self):
        with contextlib.redirect_stdout(io.StringIO()):
            txn.execute(self.fstab, "findmnt", True)
        self.assertEqual(self.fstab.read_bytes(), self.original)

    def test_apply_and_repeat_idempotently(self):
        check = self.apply()
        self.assertEqual(check.call_count, 1)
        first = self.fstab.read_bytes()
        self.assertIn(b"ro,uid=1000,gid=1000,umask=027,nofail,noauto", first)
        self.assertEqual(first.count(txn.MARK_START.encode()), 1)
        check = self.apply()
        self.assertEqual(check.call_count, 0)
        self.assertEqual(self.fstab.read_bytes(), first)
        self.assertEqual(len(list(Path(self.tmp.name).glob("fstab.samba-backup-*"))), 1)

    def test_unmanaged_conflict_rejected(self):
        self.fstab.write_bytes(self.original + b"UUID=8CE4EC1DE4EC0AF2 /mnt/elsewhere ntfs-3g ro 0 0\n")
        with self.assertRaises(txn.UnsafeFstab):
            txn.execute(self.fstab, "findmnt", True)

    def test_destination_conflict_rejected(self):
        self.fstab.write_bytes(self.original + b"/dev/sdz9 /mnt/fotos ext4 defaults 0 0\n")
        with self.assertRaises(txn.UnsafeFstab):
            txn.execute(self.fstab, "findmnt", True)

    def test_partial_managed_block_refused(self):
        self.fstab.write_bytes(self.original + (txn.MARK_START + "\n").encode())
        with self.assertRaises(txn.UnsafeFstab):
            txn.execute(self.fstab, "findmnt", True)

    def test_tampered_managed_block_refused(self):
        self.apply()
        self.fstab.write_bytes(self.fstab.read_bytes().replace(b"nofail,noauto", b"nofail,auto"))
        with self.assertRaises(txn.UnsafeFstab):
            txn.execute(self.fstab, "findmnt", True)

    def test_failed_validator_does_not_touch_target(self):
        with patch.object(txn, "verify", side_effect=txn.UnsafeFstab("injected")):
            with self.assertRaises(txn.UnsafeFstab):
                txn.execute(self.fstab, "findmnt", False)
        self.assertEqual(self.fstab.read_bytes(), self.original)
        self.assertEqual(list(Path(self.tmp.name).glob("fstab.samba-backup-*")), [])

    def test_concurrent_content_change_refused_before_replace(self):
        modified = self.original + b"# concurrent editor\\n"
        def concurrent_edit(_candidate, _command):
            self.fstab.write_bytes(modified)
        with patch.object(txn, "verify", side_effect=concurrent_edit):
            with self.assertRaisesRegex(txn.UnsafeFstab, "changed concurrently"):
                txn.execute(self.fstab, "findmnt", False)
        self.assertEqual(self.fstab.read_bytes(), modified)
        self.assertEqual(list(Path(self.tmp.name).glob("fstab.samba-backup-*")), [])

    def test_concurrent_inode_change_refused_before_replace(self):
        def concurrent_replace(_candidate, _command):
            replacement = Path(self.tmp.name) / "replacement"
            replacement.write_bytes(self.original)
            os.replace(replacement, self.fstab)
        with patch.object(txn, "verify", side_effect=concurrent_replace):
            with self.assertRaisesRegex(txn.UnsafeFstab, "changed concurrently"):
                txn.execute(self.fstab, "findmnt", False)
        self.assertEqual(self.fstab.read_bytes(), self.original)
        self.assertEqual(list(Path(self.tmp.name).glob("fstab.samba-backup-*")), [])

    def test_backup_failure_preserves_original(self):
        original_mkstemp = txn.tempfile.mkstemp
        def fail_backup(*args, **kwargs):
            if str(kwargs.get("prefix", "")).startswith("fstab.samba-backup-"):
                raise OSError("injected backup creation failure")
            return original_mkstemp(*args, **kwargs)
        with patch.object(txn, "verify"), patch.object(txn.tempfile, "mkstemp", side_effect=fail_backup):
            with self.assertRaisesRegex(OSError, "injected backup"):
                txn.execute(self.fstab, "findmnt", False)
        self.assertEqual(self.fstab.read_bytes(), self.original)
        self.assertEqual(list(Path(self.tmp.name).glob("fstab.samba-backup-*")), [])
        self.assertEqual(list(Path(self.tmp.name).glob(".fstab.candidate-*")), [])

    def test_replace_failure_preserves_original_and_removes_backup(self):
        with patch.object(txn, "verify"), patch.object(txn.os, "replace", side_effect=OSError("injected replace failure")):
            with self.assertRaisesRegex(OSError, "injected replace"):
                txn.execute(self.fstab, "findmnt", False)
        self.assertEqual(self.fstab.read_bytes(), self.original)
        self.assertEqual(list(Path(self.tmp.name).glob("fstab.samba-backup-*")), [])
        self.assertEqual(list(Path(self.tmp.name).glob(".fstab.candidate-*")), [])

    def test_directory_fsync_failure_reports_applied_uncertain_and_retains_backup(self):
        original_fsync = txn.os.fsync
        calls = 0

        def fail_directory_sync(fd):
            nonlocal calls
            calls += 1
            if calls == 3:
                raise OSError("injected directory fsync failure")
            return original_fsync(fd)

        with patch.object(txn, "verify"), patch.object(txn.os, "fsync", side_effect=fail_directory_sync):
            with self.assertRaisesRegex(txn.CommitDurabilityUncertain, "APPLIED_DURABILITY_UNCERTAIN"):
                txn.execute(self.fstab, "findmnt", False)
        self.assertIn(txn.MARK_START.encode(), self.fstab.read_bytes())
        backups = list(Path(self.tmp.name).glob("fstab.samba-backup-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), self.original)
        self.assertEqual(list(Path(self.tmp.name).glob(".fstab.candidate-*")), [])

    def test_regular_mode_preserved(self):
        os.chmod(self.fstab, 0o640)
        self.apply()
        self.assertEqual(self.fstab.stat().st_mode & 0o7777, 0o640)

    def test_special_permission_bits_refused(self):
        os.chmod(self.fstab, 0o2640)
        with self.assertRaisesRegex(txn.UnsafeFstab, "special permission"):
            txn.execute(self.fstab, "findmnt", True)

    def test_extended_attributes_refused(self):
        with patch.object(txn.os, "listxattr", return_value=["user.samba-test"], create=True):
            with self.assertRaisesRegex(txn.UnsafeFstab, "extended attributes"):
                txn.execute(self.fstab, "findmnt", True)

    def test_metadata_change_during_validation_refused(self):
        def change_mode(_candidate, _command):
            os.chmod(self.fstab, 0o600)
        os.chmod(self.fstab, 0o640)
        with patch.object(txn, "verify", side_effect=change_mode):
            with self.assertRaisesRegex(txn.UnsafeFstab, "changed concurrently"):
                txn.execute(self.fstab, "findmnt", False)
        self.assertEqual(self.fstab.read_bytes(), self.original)
        self.assertEqual(self.fstab.stat().st_mode & 0o777, 0o600)

    def test_linux_missing_xattr_api_refused(self):
        with patch.object(txn.sys, "platform", "linux"), patch.object(txn.os, "listxattr", None, create=True):
            with self.assertRaisesRegex(txn.UnsafeFstab, "extended attribute inspection unavailable"):
                txn.execute(self.fstab, "findmnt", True)

    def test_noncooperating_editor_during_replace_remains_known_risk(self):
        # A foreign writer can still race after our last check. Simulate one
        # immediately before replacement to document the current limitation.
        actual_replace = os.replace
        foreign = self.original + b"# external write\\n"

        def race_replace(source, destination):
            self.fstab.write_bytes(foreign)
            actual_replace(source, destination)

        with patch.object(txn, "verify"), patch.object(txn.os, "replace", side_effect=race_replace):
            with contextlib.redirect_stdout(io.StringIO()):
                txn.execute(self.fstab, "findmnt", False)
        self.assertNotIn(b"# external write", self.fstab.read_bytes())
        self.assertIn(txn.MARK_START.encode(), self.fstab.read_bytes())

    def test_symlink_refused(self):
        link = Path(self.tmp.name) / "fstab-link"
        link.symlink_to(self.fstab)
        with self.assertRaises(txn.UnsafeFstab):
            txn.execute(link, "findmnt", True)


if __name__ == "__main__":
    unittest.main()
