"""Integration checks with the actual local findmnt; no system fstab writes."""
import contextlib
import io
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import historical_fstab_transaction as txn


@unittest.skipUnless(shutil.which("findmnt"), "util-linux findmnt unavailable")
class FindmntIntegrationTest(unittest.TestCase):
    def test_candidate_validation_with_real_findmnt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fstab = root / "fstab"
            # Real, temporary mountpoint paths for a fixture; no mounting.
            # Historical targets remain absent, mirroring current host state.
            fstab.write_text("# isolated fixture\n", encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()):
                txn.execute(fstab, "findmnt", True)
            self.assertEqual(fstab.read_text(), "# isolated fixture\n")
            candidate = root / "candidate"
            candidate.write_bytes(txn.validate_entries(fstab.read_bytes()))
            # Some util-linux versions treat absent mountpoints as warnings;
            # capture and report this explicitly instead of assuming success.
            try:
                txn.verify(candidate, "findmnt")
            except txn.UnsafeFstab as exc:
                self.fail("real findmnt rejected candidate: " + str(exc))

    def test_malformed_fixture_rejected_by_findmnt(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate = Path(directory) / "bad-fstab"
            candidate.write_text("invalid-entry\n", encoding="utf-8")
            with self.assertRaises(txn.UnsafeFstab):
                txn.verify(candidate, "findmnt")


if __name__ == "__main__":
    unittest.main()
