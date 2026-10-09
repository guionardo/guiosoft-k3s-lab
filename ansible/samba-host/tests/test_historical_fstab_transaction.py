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

    def test_symlink_refused(self):
        link = Path(self.tmp.name) / "fstab-link"
        link.symlink_to(self.fstab)
        with self.assertRaises(txn.UnsafeFstab):
            txn.execute(link, "findmnt", True)


if __name__ == "__main__":
    unittest.main()
