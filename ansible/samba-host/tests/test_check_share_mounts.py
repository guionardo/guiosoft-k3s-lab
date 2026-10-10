"""Pure mocked tests: no mounts, blkid calls or Samba changes."""
import importlib.util
import pathlib
import sys
import subprocess
import unittest
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "check_share_mounts.py"
sys.path.insert(0, str(SCRIPT.parent))
spec = importlib.util.spec_from_file_location("check_share_mounts", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def result(stdout="", returncode=0):
    return subprocess.CompletedProcess([], returncode, stdout, "")


class MountPreflightTests(unittest.TestCase):
    def inspect(self, *, mounted=True, source="/dev/sde6", options="ro,relatime",
                uuid="8CE4EC1DE4EC0AF2", fstype="ntfs", blkid_ok=True):
        def fake_run(*args):
            if args[0] == "findmnt":
                if not mounted:
                    return result(returncode=1)
                column = args[-1]
                return result({"SOURCE,FSTYPE,OPTIONS": f"{source} fuseblk {options}",
                               "SOURCE": source, "OPTIONS": options}[column] + "\n")
            if args[0] == "blkid":
                return result(f"UUID={uuid}\nTYPE={fstype}\n", 0 if blkid_ok else 2)
            raise AssertionError(args)
        with patch.object(module, "run", side_effect=fake_run):
            return module.inspect_one("Fotos", "/mnt/fotos", "8CE4EC1DE4EC0AF2", "ntfs", True)

    def test_valid_historical_ro(self):
        self.assertTrue(self.inspect()["ok"])

    def test_missing_mount(self):
        self.assertIn("mountpoint ausente", self.inspect(mounted=False)["issues"])

    def test_wrong_uuid(self):
        self.assertIn("UUID divergente", self.inspect(uuid="WRONG")["issues"])

    def test_wrong_filesystem(self):
        self.assertIn("tipo divergente", self.inspect(fstype="ext4")["issues"])

    def test_historical_rw(self):
        self.assertIn("historico nao esta somente leitura", self.inspect(options="rw")["issues"])

    def test_missing_blkid_access(self):
        self.assertIn("blkid nao conseguiu identificar origem", self.inspect(blkid_ok=False)["issues"])

    def test_non_block_source(self):
        self.assertIn("origem nao e dispositivo de bloco", self.inspect(source="tmpfs")["issues"])


if __name__ == "__main__":
    unittest.main()
