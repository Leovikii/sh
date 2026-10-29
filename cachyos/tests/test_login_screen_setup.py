"""隔离测试；替换 sudo、账户和服务查询，仅写入临时目录。"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'login_screen_setup.sh'


@unittest.skipIf(os.geteuid() == 0, '与脚本一样，需要普通用户环境')
class LoginScreenSetupTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.source = self.home / 'kwinoutputconfig.json'
        self.greeter = self.home / 'greeter'
        self.greeter.mkdir()
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        self.stub('sudo', 'exec "$@"')
        self.stub('readlink', 'echo /usr/lib/systemd/system/plasmalogin.service')
        self.stub('getent', 'printf "plasmalogin:x:%s:%s::%s:/usr/bin/nologin\\n" '
                  f'{os.getuid()} {os.getgid()} "{self.greeter}"')
        self.config = [
            {'name': 'outputs', 'data': [
                {'connectorName': 'DP-1', 'mode': {'width': 3840}, 'scale': 1.5},
                {'connectorName': 'DP-2', 'scale': 1},
            ]},
            {'name': 'setups', 'data': [
                {'lidClosed': False, 'outputs': [
                    {'outputIndex': 0, 'enabled': True, 'priority': 1,
                     'position': {'x': 960, 'y': 0}, 'replicationSource': 'old'},
                    {'outputIndex': 1, 'enabled': True, 'priority': 2,
                     'position': {'x': 0, 'y': 0}},
                ]},
                {'outputs': [{'outputIndex': 1, 'enabled': True, 'priority': 0}]},
                {'outputs': [{'outputIndex': 0, 'enabled': True, 'priority': 0}]},
            ]},
        ]

    def stub(self, name, content):
        path = self.bin / name
        path.write_text('#!/bin/sh\nset -eu\n' + content + '\n')
        path.chmod(0o755)

    def run_script(self, *args, action='--preview'):
        self.source.write_text(json.dumps(self.config))
        original = self.source.read_bytes()
        result = subprocess.run(
            ['bash', str(SCRIPT), action, *args], text=True, capture_output=True,
            env=dict(os.environ, HOME=str(self.home), XDG_CONFIG_HOME=str(self.home),
                     PATH=f'{self.bin}:{os.environ["PATH"]}'),
        )
        self.assertEqual(self.source.read_bytes(), original)
        return result

    def test_disable_secondary_preserves_desktop_and_fallback(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        generated = json.loads(result.stdout)
        self.assertEqual(generated[0], self.config[0])
        setups = generated[1]['data']
        self.assertEqual(setups[1], self.config[1]['data'][1])
        self.assertEqual(setups[0]['lidClosed'], False)
        for index in (0, 2):
            active = [output for output in setups[index]['outputs'] if output['enabled']]
            self.assertEqual(len(active), 1)
            self.assertEqual(active[0]['outputIndex'], 0)
            self.assertEqual(active[0]['position'], {'x': 0, 'y': 0})
            self.assertEqual(active[0]['priority'], 1)
            self.assertEqual(active[0]['replicationSource'], '')
        self.assertEqual(setups[0]['outputs'][1]['priority'], 0)
        self.config = generated
        again = self.run_script()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(json.loads(again.stdout), generated)

    def test_explicit_primary_and_missing_connector(self):
        result = self.run_script('--primary', 'DP-2')
        self.assertEqual(result.returncode, 0, result.stderr)
        outputs = json.loads(result.stdout)[1]['data'][0]['outputs']
        self.assertEqual([output['enabled'] for output in outputs], [False, True])
        result = self.run_script('--primary', 'HDMI-A-99')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_ambiguous_primary_and_broken_index_are_rejected(self):
        self.config[1]['data'][1]['outputs'][0]['priority'] = 1
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--primary', result.stderr)
        self.config[1]['data'][0]['outputs'][0]['outputIndex'] = -1
        result = self.run_script('--primary', 'DP-1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_apply_backup_permissions_and_idempotency(self):
        result = self.run_script(action='--apply')
        self.assertEqual(result.returncode, 0, result.stderr)
        directory = self.greeter / '.config'
        target = directory / 'kwinoutputconfig.json'
        first = target.read_bytes()
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        backups = list(directory.glob('login-screen-backup.*'))
        self.assertEqual(len(backups), 1)
        self.assertTrue((backups[0] / 'original-absent').is_file())
        result = self.run_script(action='--apply')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(directory.glob('login-screen-backup.*')), backups)
        result = self.run_script('--primary', 'DP-2', action='--apply')
        self.assertEqual(result.returncode, 0, result.stderr)
        new_backups = set(directory.glob('login-screen-backup.*')) - set(backups)
        self.assertEqual(len(new_backups), 1)
        self.assertEqual((new_backups.pop() / 'kwinoutputconfig.json').read_bytes(), first)
        active = json.loads(target.read_text())[1]['data'][0]['outputs']
        self.assertEqual([output['enabled'] for output in active], [False, True])

    def test_unsupported_manager_and_symlink_do_not_write(self):
        self.stub('readlink', 'echo /usr/lib/systemd/system/sddm.service')
        result = self.run_script(action='--apply')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.greeter.iterdir()), [])
        self.stub('readlink', 'echo /usr/lib/systemd/system/plasmalogin.service')
        (self.greeter / '.config').symlink_to(self.home, target_is_directory=True)
        result = self.run_script(action='--apply')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('符号链接', result.stderr)
        self.assertEqual(list(self.home.glob('login-screen-backup.*')), [])


if __name__ == '__main__':
    unittest.main()
