"""Contract tests for partial eligibility reporting, with mocked volume inspection."""
import contextlib
import importlib.util
import io
import json
import pathlib
import sys
import unittest
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "check_share_mounts.py"
sys.path.insert(0, str(SCRIPT.parent))
spec = importlib.util.spec_from_file_location("check_share_mounts_eligibility", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class EligibilityTests(unittest.TestCase):
    def invoke(self, inspected):
        output = io.StringIO()
        with patch.object(module, "inspect_one", side_effect=inspected), \
             patch.object(module.sys, "platform", "linux"), \
             patch.object(sys, "argv", ["check_share_mounts.py", "--eligible-json"]), \
             contextlib.redirect_stdout(output):
            code = module.main()
        return code, json.loads(output.getvalue())

    def test_partial_report_preserves_independent_healthy_shares(self):
        inspected = [
            {"share": name, "ok": name not in ("Fotos", "BackupAntigo", "ProjetosAntigos"),
             "issues": [] if name not in ("Fotos", "BackupAntigo", "ProjetosAntigos") else ["mountpoint ausente"]}
            for name, *_ in module.EXPECTED
        ]
        code, report = self.invoke(inspected)
        self.assertEqual(code, 1)
        self.assertEqual(report["eligible"], ["Documentos", "Desenvolvimento", "Temporarios", "DevBin"])
        self.assertEqual([item["share"] for item in report["blocked"]],
                         ["Fotos", "BackupAntigo", "ProjetosAntigos"])

    def test_all_eligible_exit_zero(self):
        inspected = [{"share": name, "ok": True, "issues": []} for name, *_ in module.EXPECTED]
        code, report = self.invoke(inspected)
        self.assertEqual(code, 0)
        self.assertEqual(len(report["eligible"]), len(module.EXPECTED))
        self.assertEqual(report["blocked"], [])

    def test_all_blocked_fail_closed(self):
        inspected = [{"share": name, "ok": False, "issues": ["UUID divergente"]}
                     for name, *_ in module.EXPECTED]
        code, report = self.invoke(inspected)
        self.assertEqual(code, 1)
        self.assertEqual(report["eligible"], [])
        self.assertEqual(len(report["blocked"]), len(module.EXPECTED))


if __name__ == "__main__":
    unittest.main()
