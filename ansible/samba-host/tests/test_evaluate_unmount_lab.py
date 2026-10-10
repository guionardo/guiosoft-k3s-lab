"""Offline evidence evaluator tests: no mounts or Samba calls."""
import importlib.util
import pathlib
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "evaluate_unmount_lab.py"
spec = importlib.util.spec_from_file_location("evaluate_unmount_lab", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def evidence():
    return {
        "environment": {
            "vm_disposable": True, "network_isolated": True, "test_volume_verified": True
        },
        "observations": {
            name: {"performed": True, "underlying_exposed": False, "expected_behavior": True}
            for name in module.REQUIRED
        },
    }


class EvidenceTests(unittest.TestCase):
    def test_all_observed_pass(self):
        self.assertEqual(module.evaluate(evidence())["status"], "PASS_OBSERVED")

    def test_exposure_is_failure(self):
        data = evidence()
        data["observations"]["existing_session"]["underlying_exposed"] = True
        self.assertEqual(module.evaluate(data)["status"], "FAIL")

    def test_missing_observation_rejected(self):
        data = evidence()
        del data["observations"]["new_session"]
        with self.assertRaises(ValueError):
            module.evaluate(data)

    def test_not_performed_is_inconclusive(self):
        data = evidence()
        data["observations"]["recovery"]["performed"] = False
        self.assertEqual(module.evaluate(data)["status"], "INCONCLUSIVE")

    def test_missing_isolation_rejected(self):
        data = evidence()
        data["environment"]["network_isolated"] = False
        with self.assertRaises(ValueError):
            module.evaluate(data)

    def test_unknown_exposure_is_inconclusive(self):
        data = evidence()
        data["observations"]["new_session"]["underlying_exposed"] = None
        self.assertEqual(module.evaluate(data)["status"], "INCONCLUSIVE")


if __name__ == "__main__":
    unittest.main()
