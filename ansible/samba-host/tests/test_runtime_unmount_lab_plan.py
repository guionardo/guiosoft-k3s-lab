"""Pure unit tests: no Samba, mount, or host modifications."""
import importlib.util
import pathlib
import unittest
from unittest.mock import Mock

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "runtime_unmount_lab_plan.py"
spec = importlib.util.spec_from_file_location("runtime_unmount_lab_plan", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Marker:
    def __init__(self, exists):
        self.exists = exists

    def is_file(self):
        return self.exists

    def __str__(self):
        return "/etc/samba-lab-disposable-vm"


class LabPlanTests(unittest.TestCase):
    def test_missing_marker_refuses_readiness(self):
        report = module.check("linux", Marker(False), tools=lambda name: "/usr/bin/" + name, uid=1000)
        self.assertFalse(report["ready_for_manual_review"])

    def test_missing_smbclient_refuses_readiness(self):
        report = module.check("linux", Marker(True),
                              tools=lambda name: None if name == "smbclient" else "/usr/bin/" + name,
                              uid=1000)
        self.assertFalse(report["ready_for_manual_review"])

    def test_non_linux_refuses_readiness(self):
        report = module.check("darwin", Marker(True), tools=lambda name: "/usr/bin/" + name, uid=1000)
        self.assertFalse(report["ready_for_manual_review"])

    def test_all_present_only_allows_manual_review(self):
        report = module.check("linux", Marker(True), tools=lambda name: "/usr/bin/" + name, uid=1000)
        self.assertTrue(report["ready_for_manual_review"])
        self.assertEqual(report["mode"], "dry-run-only")
        self.assertTrue(all("umount" not in key for key in ("execution", "commands_run")))


if __name__ == "__main__":
    unittest.main()
