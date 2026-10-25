"""Check defaults and persistence in isolated XDG directories; never start Steam."""

import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "proton_setup.sh"


class ProtonSetupTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.env = dict(os.environ, XDG_CONFIG_HOME=str(root / "config"),
                        XDG_DATA_HOME=str(root / "data"), XDG_STATE_HOME=str(root / "state"))
        self.desktop = root / "data/applications/steam.desktop"
        self.saved_config = root / "config/environment.d/gaming.conf"
        self.state = root / "state/cachyos-proton"
        self.source = root / "system.desktop"
        self.source.write_text("[Desktop Entry]\nName=Steam\nType=Application\n"
                               "Exec=/usr/bin/steam %U\nActions=Library;\n"
                               "[Desktop Action Library]\nName=Library\n"
                               "Exec=/usr/bin/steam steam://open/games\n")

    def action(self, *options, success=True):
        # Source functions to inject a fixture desktop entry, without changing production CLI.
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; DESKTOP_SOURCE="$2"; shift 2; main "$@"',
             "test", str(SCRIPT), str(self.source), *options],
            env=self.env, capture_output=True, text=True,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def test_launcher_environment_arguments_and_idempotency(self):
        self.action("--apply")
        launcher = self.desktop.read_text()
        execs = [line.removeprefix("Exec=") for line in launcher.splitlines()
                 if line.startswith("Exec=")]
        self.assertEqual(len(execs), 2)
        for command, argument in zip(execs, ("%U", "steam://open/games")):
            args = shlex.split(command)
            self.assertEqual(args[-2:], ["/usr/bin/steam", argument])
            # Substitute env as a harmless executable to inspect actual child environment.
            result = subprocess.run(args[:-2] + ["/usr/bin/env"],
                                    env=dict(self.env, LOW_LATENCY_LAYER_REFLEX="1"),
                                    capture_output=True, text=True, check=True)
            values = dict(line.split("=", 1) for line in result.stdout.splitlines())
            self.assertEqual(values["LOW_LATENCY_LAYER"], "1")
            self.assertEqual(values["VKD3D_FRAME_RATE"], "117")
            self.assertNotIn("LOW_LATENCY_LAYER_REFLEX", values)
        backup = (self.state / "latest").read_text()
        self.action("--apply")
        self.assertEqual((self.state / "latest").read_text(), backup)
        self.action("--restore")
        self.assertFalse(self.desktop.exists())
        self.assertFalse(self.saved_config.exists())

    def test_restore_existing_files_and_reject_wrong_data_path(self):
        self.desktop.parent.mkdir(parents=True)
        original = self.desktop.parent / "custom.desktop"
        original.write_text("custom launcher\n")
        self.desktop.symlink_to(original)
        self.saved_config.parent.mkdir(parents=True)
        self.saved_config.write_text("OLD_CONFIG=1\n")
        self.action("--apply")
        self.env["XDG_DATA_HOME"] += "-other"
        self.action("--restore", success=False)
        self.assertIn("LOW_LATENCY_LAYER=1", self.saved_config.read_text())
        self.env["XDG_DATA_HOME"] = str(self.desktop.parents[1])
        self.action("--restore")
        self.assertTrue(self.desktop.is_symlink())
        self.assertEqual(self.desktop.read_text(), "custom launcher\n")
        self.assertEqual(self.saved_config.read_text(), "OLD_CONFIG=1\n")

    def test_opt_out_clears_inherited_layer(self):
        self.action("--apply", "--no-anti-lag-layer")
        command = next(line[5:] for line in self.desktop.read_text().splitlines()
                       if line.startswith("Exec="))
        result = subprocess.run(shlex.split(command)[:-2] + ["/usr/bin/env"],
                                env=dict(self.env, LOW_LATENCY_LAYER="1"),
                                capture_output=True, text=True, check=True)
        self.assertNotIn("LOW_LATENCY_LAYER=", result.stdout)

    def test_upgrade_installs_launcher_when_config_already_matches(self):
        self.saved_config.parent.mkdir(parents=True)
        self.saved_config.write_text(subprocess.check_output(
            ["bash", str(SCRIPT), "--print-config"], text=True))
        self.action("--apply")
        self.assertTrue(self.desktop.is_file())
        self.action("--restore")
        self.assertFalse(self.desktop.exists())
        self.assertIn("LOW_LATENCY_LAYER=1", self.saved_config.read_text())

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
