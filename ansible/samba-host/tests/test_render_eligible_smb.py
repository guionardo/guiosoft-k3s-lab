"""Offline-only tests for selective Samba candidate rendering."""
import importlib.util
import pathlib
import sys
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "render_eligible_smb.py"
sys.path.insert(0, str(SCRIPT.parent))
spec = importlib.util.spec_from_file_location("render_eligible_smb", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RenderTests(unittest.TestCase):
    def report(self, eligible):
        return {
            "eligible": eligible,
            "blocked": [{"share": name, "issues": ["mountpoint ausente"]}
                        for name, *_ in module.SHARES if name not in eligible],
        }

    def test_partial_renders_only_eligible(self):
        config = module.render(self.report(["Documentos", "Desenvolvimento", "Temporarios", "DevBin"]))
        self.assertIn("[Documentos]", config)
        self.assertIn("[DevBin]", config)
        self.assertNotIn("[Fotos]", config)
        self.assertNotIn("[BackupAntigo]", config)
        self.assertNotIn("[ProjetosAntigos]", config)

    def test_all_blocked_global_only(self):
        config = module.render(self.report([]))
        self.assertIn("[global]", config)
        for name, *_ in module.SHARES:
            self.assertNotIn(f"[{name}]", config)

    def test_unknown_share_refused(self):
        with self.assertRaises(ValueError):
            module.render({"eligible": ["Invasor"], "blocked": []})

    def test_duplicate_refused(self):
        report = self.report(["Documentos"])
        report["eligible"].append("Documentos")
        with self.assertRaises(ValueError):
            module.render(report)

    def test_missing_entry_refused(self):
        report = self.report(["Documentos"])
        report["blocked"].pop()
        with self.assertRaises(ValueError):
            module.render(report)

    def test_missing_reason_refused(self):
        report = self.report([])
        report["blocked"][0]["issues"] = []
        with self.assertRaises(ValueError):
            module.render(report)


if __name__ == "__main__":
    unittest.main()
