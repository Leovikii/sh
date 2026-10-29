"""Isolated fresh-install tests; no real Steam or user files touched."""
import json
import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'steam_setup.sh'


class SteamSetupTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / 'clean home'
        self.home.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), XDG_CONFIG_HOME=str(self.home/'config'),
                        XDG_DATA_HOME=str(self.home/'data'), XDG_STATE_HOME=str(self.home/'state'),
                        XDG_CURRENT_DESKTOP='test')
        self.config = self.home/'config/environment.d/gaming.conf'
        self.desktop = self.home/'data/applications/steam.desktop'
        self.helper = self.home/'.local/bin/steam-managed'
        self.library = self.home/'data/steam-setup/environment.sh'
        self.kde = self.home/'config/plasma-workspace/env/gaming-env.sh'
        self.targets = [self.config, self.desktop, self.helper, self.library, self.kde]
        self.source = self.home/'system.desktop'
        self.source.write_text('[Desktop Entry]\nName=Steam\nType=Application\nExec=/usr/bin/steam %U\n'
                               'Actions=Library;\n[Desktop Action Library]\nName=Library\n'
                               'Exec=/usr/bin/steam steam://open/games\n')

    def action(self, *args, success=True):
        result = subprocess.run(['bash', '-c', 'source "$1"; DESKTOP_SOURCE="$2"; shift 2; main "$@"',
                                 'test', str(SCRIPT), str(self.source), *args],
                                env=self.env, capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def values(self):
        return dict(x.split('=', 1) for x in self.config.read_text().splitlines()
                    if x and not x.startswith('#'))

    def mock_steam(self):
        script = self.helper.read_text().replace('exec /usr/bin/steam "$@"',
            "exec python3 -c 'import os,sys,json;print(json.dumps(dict(env=dict(os.environ),args=sys.argv[1:])))' \"$@\"")
        self.helper.write_text(script)

    def test_fresh_install_idempotency_and_remove(self):
        self.action('--apply')
        contents = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.targets}
        self.action('--apply')
        self.assertEqual(contents, {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.targets})
        values = self.values()
        self.assertEqual(values['LOW_LATENCY_LAYER'], '1')
        self.assertEqual(values['DXVK_FRAME_RATE'], '117')
        self.assertEqual(values['VKD3D_FRAME_RATE'], '117')
        self.assertNotIn('PROTON_VKD3D_LOWLATENCY', values)
        self.assertNotIn('DXVK_HDR', values)
        self.assertFalse((self.home/'state/steam-setup/backups').exists())
        self.action('--remove')
        self.assertTrue(all(not p.exists() for p in self.targets))
        self.action('--remove')

    def test_launcher_reads_edits_forwards_uri_and_clears_old_environment(self):
        self.action('--apply')
        self.mock_steam()
        self.config.write_text(self.config.read_text().replace('=117', '=113'))
        commands = [shlex.split(x[5:]) for x in self.desktop.read_text().splitlines() if x.startswith('Exec=')]
        self.assertEqual(len(commands), 2)
        self.assertNotIn('PROTON_ENABLE_WAYLAND=', self.desktop.read_text())
        for args, uri in zip(commands, ('steam://rungameid/123', 'steam://open/games')):
            if args[-1]=='%U': args[-1]=uri
            result = subprocess.run(args, env=dict(self.env, LOW_LATENCY_LAYER_REFLEX='1',
                                    PROTON_VKD3D_LOWLATENCY='1', DXVK_HDR='1'),
                                    capture_output=True, text=True, check=True)
            data = json.loads(result.stdout)
            self.assertEqual(data['args'], [uri])
            self.assertEqual(data['env']['DXVK_FRAME_RATE'], '113')
            for key in ('LOW_LATENCY_LAYER_REFLEX','PROTON_VKD3D_LOWLATENCY','DXVK_HDR'):
                self.assertNotIn(key, data['env'])

    def test_kde_and_systemd_read_identical_values(self):
        self.action('--apply')
        result = subprocess.run(['/bin/sh','-c','. "$1"; env','test',str(self.kde)],
                                env=self.env,capture_output=True,text=True,check=True)
        kde = dict(x.split('=',1) for x in result.stdout.splitlines())
        for key, value in self.values().items(): self.assertEqual(kde[key],value)
        generator = '/usr/lib/systemd/user-environment-generators/30-systemd-environment-d-generator'
        if Path(generator).exists():
            result = subprocess.run([generator],env=self.env,capture_output=True,text=True,check=True)
            systemd = dict(x.split('=',1) for x in result.stdout.splitlines() if '=' in x)
            for key,value in self.values().items(): self.assertEqual(shlex.split(systemd[key]),[value])

    def test_reapply_preserves_user_choices(self):
        self.action('--apply','--fps','110','--no-anti-lag-layer')
        self.config.write_text(self.config.read_text()+'# user comment\n')
        self.action('--apply','--cache-size','16G')
        self.assertEqual(self.values()['DXVK_FRAME_RATE'],'110')
        self.assertEqual(self.values()['VKD3D_FRAME_RATE'],'110')
        self.assertEqual(self.values()['MESA_SHADER_CACHE_MAX_SIZE'],'16G')
        self.assertNotIn('LOW_LATENCY_LAYER',self.values())

    def test_rejects_invalid_config_and_command_injection_before_mutating(self):
        self.action('--apply')
        original = self.helper.read_bytes()
        for value in ('DXVK_FRAME_RATE=0','DXVK_FRAME_RATE=00117','VKD3D_FRAME_RATE=1001',
                      'PATH=/tmp','LOW_LATENCY_LAYER=1\nLOW_LATENCY_LAYER=0',
                      'LOW_LATENCY_LAYER=1\nPROTON_VKD3D_LOWLATENCY=1',
                      'SDL_GAMECONTROLLERTYPE=$(touch '+str(self.home/'injected')+')'):
            with self.subTest(value=value):
                self.config.write_text('# Managed by sh/cachyos/steam_setup.sh\n'+value+'\n')
                self.action('--apply',success=False)
                result=subprocess.run([str(self.helper)],env=self.env,capture_output=True)
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(self.helper.read_bytes(),original)
                self.assertFalse((self.home/'injected').exists())

    def test_refuses_custom_file_or_symlink_without_deleting_others(self):
        self.action('--apply')
        self.kde.write_text('export OTHER_USER_SETTING=1\n')
        self.action('--remove',success=False)
        self.assertTrue(self.config.exists())
        self.action('--apply',success=False)
        self.kde.write_text('# Managed by sh/cachyos/steam_setup.sh\n')
        self.helper.unlink()
        external=self.home/'custom'
        external.write_text('custom\n')
        self.helper.symlink_to(external)
        self.action('--apply',success=False)
        self.assertEqual(external.read_text(),'custom\n')

    def test_options_validate_and_do_not_stack_experimental_paths(self):
        for options in (('--dx12-lowlatency','--anti-lag-layer'),('--anti-lag-layer','--dx12-lowlatency'),
                        ('--fps','0'),('--cache-size','nope')):
            self.action('--print-config',*options,success=False)
        self.action('--apply','--dx12-lowlatency')
        self.assertEqual(self.values()['PROTON_VKD3D_LOWLATENCY'],'1')
        self.assertNotIn('LOW_LATENCY_LAYER',self.values())
        self.action('--apply')
        self.assertNotIn('LOW_LATENCY_LAYER',self.values())

    def test_flatpak_env_order_and_forwarded_arguments(self):
        self.action('--apply')
        fake=self.home/'bin';fake.mkdir()
        binary=fake/'flatpak'
        binary.write_text('#!/usr/bin/python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
        binary.chmod(0o755)
        result=subprocess.run([str(self.helper),'--flatpak','steam://open/games'],
                              env=dict(self.env,PATH=str(fake)+':'+os.environ['PATH']),
                              capture_output=True,text=True,check=True)
        args=json.loads(result.stdout)
        self.assertEqual(args[0],'run')
        self.assertLess(args.index('--unset-env=LOW_LATENCY_LAYER'),args.index('--env=LOW_LATENCY_LAYER=1'))
        self.assertEqual(args[-2:],['com.valvesoftware.Steam','steam://open/games'])

    def test_cli_launch_uses_saved_config_and_passes_arguments(self):
        self.action('--apply','--fps','111')
        self.mock_steam()
        fake=self.home/'bin';fake.mkdir()
        pgrep=fake/'pgrep'
        pgrep.write_text('#!/bin/sh\nexit 1\n'); pgrep.chmod(0o755)
        self.env['PATH']=str(fake)+':'+os.environ['PATH']
        result=self.action('--steam','--','steam://open/games','argument with spaces')
        data=json.loads(result.stdout)
        self.assertEqual(data['env']['VKD3D_FRAME_RATE'],'111')
        self.assertEqual(data['args'],['steam://open/games','argument with spaces'])

    def test_refreshes_user_service_and_dbus_environment(self):
        fake=self.home/'bin'; fake.mkdir()
        log=self.home/'sync.jsonl'
        for name in ('systemctl','dbus-update-activation-environment','kbuildsycoca6'):
            command=fake/name
            command.write_text('#!/usr/bin/python3\nimport json,os,sys\n'
                'with open(os.environ["FAKE_STEAM_SYNC_LOG"],"a") as f: f.write(json.dumps(sys.argv)+"\\n")\n')
            command.chmod(0o755)
        self.env.update(PATH=str(fake)+':'+os.environ['PATH'], XDG_CURRENT_DESKTOP='KDE',
                        DBUS_SESSION_BUS_ADDRESS='test', FAKE_STEAM_SYNC_LOG=str(log))
        self.action('--apply')
        calls=[json.loads(x) for x in log.read_text().splitlines()]
        unset=next(x for x in calls if 'unset-environment' in x)
        self.assertIn('PROTON_VKD3D_LOWLATENCY',unset)
        assignments=[key+'='+value for key,value in self.values().items()]
        systemd=next(x for x in calls if 'set-environment' in x)
        dbus=next(x for x in calls if Path(x[0]).name=='dbus-update-activation-environment')
        self.assertEqual(systemd[3:],assignments)
        self.assertEqual(dbus[1:],assignments)
        log.write_text('')
        self.action('--remove')
        self.assertIn('unset-environment',log.read_text())
        self.assertNotIn('"set-environment"',log.read_text())



if __name__ == '__main__': unittest.main()
