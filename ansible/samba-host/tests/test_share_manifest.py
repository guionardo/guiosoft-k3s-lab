"""Tests for canonical Ansible YAML share manifest."""
import pathlib
import sys
import tempfile
import unittest

SCRIPT_DIR = pathlib.Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPT_DIR))
from share_manifest import load_manifest


class ManifestTests(unittest.TestCase):
    def test_current_defaults_load(self):
        shares = load_manifest()
        self.assertEqual(len(shares), 7)
        self.assertEqual(shares[0]["name"], "Documentos")

    def load_text(self, content):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "defaults.yml"
            path.write_text(content, encoding="utf-8")
            return load_manifest(path)

    def test_duplicate_name_refused(self):
        with self.assertRaises(ValueError):
            self.load_text('samba_shares:\n  - {name: A, path: /mnt/a, uuid: x, fstype: ntfs, readonly: true}\n  - {name: A, path: /mnt/b, uuid: y, fstype: ext4, readonly: false}\n')

    def test_unknown_field_refused(self):
        with self.assertRaises(ValueError):
            self.load_text('samba_shares:\n  - {name: A, path: /mnt/a, uuid: x, fstype: ntfs, readonly: true, extra: bad}\n')

    def test_non_boolean_readonly_refused(self):
        with self.assertRaises(ValueError):
            self.load_text('samba_shares:\n  - {name: A, path: /mnt/a, uuid: x, fstype: ntfs, readonly: "yes"}\n')


if __name__ == "__main__":
    unittest.main()
