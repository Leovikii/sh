"""Check low-latency defaults without writing user config or starting Steam."""

import subprocess
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "proton_setup.sh"


class ProtonSetupTest(unittest.TestCase):
    def config(self, *options):
        result = subprocess.run(
            ["bash", str(SCRIPT), "--print-config", *options],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return dict(
            line.split("=", 1)
            for line in result.stdout.splitlines()
            if line and not line.startswith("#")
        )

    def test_default_and_opt_out(self):
        config = self.config()
        self.assertEqual(config["LOW_LATENCY_LAYER"], "1")
        self.assertEqual(config["PROTON_VKD3D_LOWLATENCY"], "0")
        self.assertEqual(config["DXVK_FRAME_RATE"], "117")
        self.assertNotIn("LOW_LATENCY_LAYER", self.config("--no-anti-lag-layer"))
        self.assertEqual(self.config("--anti-lag-layer"), config)

    def test_experimental_branch_does_not_stack_layers(self):
        config = self.config("--dx12-lowlatency")
        self.assertEqual(config["PROTON_VKD3D_LOWLATENCY"], "1")
        self.assertNotIn("LOW_LATENCY_LAYER", config)
        for options in (
            ("--anti-lag-layer", "--dx12-lowlatency"),
            ("--dx12-lowlatency", "--anti-lag-layer"),
        ):
            with self.subTest(options=options):
                result = subprocess.run(
                    ["bash", str(SCRIPT), "--print-config", *options],
                    capture_output=True, text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("不要同时启用", result.stderr)


if __name__ == "__main__":
    unittest.main()
