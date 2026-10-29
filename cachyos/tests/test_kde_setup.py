"""临时 HOME + 真实 KConfig 读写；替换包管理器、Plasma 和 D-Bus，绝不操作真实桌面。"""
import configparser
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'kde_setup.sh'


@unittest.skipUnless(shutil.which('kwriteconfig6') and shutil.which('kreadconfig6'), '需要 KConfig 6 工具')
class KdeSetupTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='kde-setup-', dir='/tmp')
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / 'test home'
        self.home.mkdir()
        self.config = self.home / 'config'
        self.config.mkdir()
        self.data = self.home / 'data'
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        self.plugins = self.home / 'plugins'
        self.log = self.home / 'actions'
        self.env = dict(os.environ, HOME=str(self.home), PATH=f'{self.bin}:{os.environ["PATH"]}',
                        XDG_CONFIG_HOME=str(self.config), XDG_DATA_HOME=str(self.data),
                        XDG_CONFIG_DIRS=str(self.home/'system-config'),
                        XDG_DATA_DIRS=str(self.home/'system-data'),
                        XDG_STATE_HOME=str(self.home/'state'), XDG_CACHE_HOME=str(self.home/'cache'),
                        XDG_CURRENT_DESKTOP='KDE', KDE_SESSION_VERSION='6', XDG_SESSION_TYPE='wayland',
                        QT_QPA_PLATFORM='offscreen', DBUS_SESSION_BUS_ADDRESS=f'unix:path={self.home}/no-bus')
        self.stub('qtpaths6', 'printf "%s\\n" "$HOME/plugins"')
        self.stub('qdbus6', 'printf "dbus %s\\n" "$*" >> "$HOME/actions"')
        self.stub('sudo', 'exec "$@"')
        self.stub('pacman', 'printf "pacman %s\\n" "$*" >> "$HOME/actions"; exit 99')
        self.stub('paru', 'echo "禁止实际调用 AUR" >&2; exit 99')
        self.stub('yay', 'echo "禁止实际调用 AUR" >&2; exit 99')
        self.stub('plasma-apply-colorscheme', '''
printf 'colors %s\n' "$*" >> "$HOME/actions"
if [ "$1" != --accent-color ]; then
    kwriteconfig6 --file "$XDG_CONFIG_HOME/kdeglobals" --group General --key ColorScheme "$1"
fi
kwriteconfig6 --file "$XDG_CONFIG_HOME/kdeglobals" --group Colors:Window --key BackgroundNormal 24,24,37
''')
        self.stub('plasma-apply-desktoptheme', '''
printf 'desktop %s\n' "$*" >> "$HOME/actions"
kwriteconfig6 --file "$XDG_CONFIG_HOME/plasmarc" --group Theme --key name "$1"
''')
        self.stub('plasma-apply-cursortheme', '''
printf 'cursor %s\n' "$*" >> "$HOME/actions"
kwriteconfig6 --file "$XDG_CONFIG_HOME/kcminputrc" --group Mouse --key cursorTheme "$1"
kwriteconfig6 --file "$XDG_CONFIG_HOME/kcminputrc" --group Mouse --key cursorSize 24
''')
        for path in ('styles/breeze6.so', 'org.kde.kdecoration3/org.kde.breeze.so',
                     'org.kde.kdecoration3/org.kde.klassy.so'):
            self.file(self.plugins/path)
        for path in ('plasma/desktoptheme/default/metadata.json', 'icons/Papirus-Dark/index.theme',
                     'icons/Bibata-Modern-Ice/index.theme', 'icons/Bibata-Modern-Ice/cursors/left_ptr',
                     'color-schemes/CatppuccinMochaPink.colors'):
            self.file(self.data/path)

    def file(self, path, content='fixture\n'):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def stub(self, name, body):
        path = self.bin/name
        path.write_text('#!/bin/sh\nset -e\n' + body + '\n')
        path.chmod(0o755)

    def run_script(self, *args, success=True, input_data=''):
        result = subprocess.run(['bash', str(SCRIPT), *args], env=self.env, text=True,
                                input=input_data, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout+result.stderr)
        return result

    def read(self, file, group, key):
        return subprocess.check_output(['kreadconfig6', '--file', str(self.config/file), '--group', group,
                                        '--key', key], env=self.env, text=True).strip()

    def snapshots(self):
        return {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.config.iterdir() if p.is_file()}

    def test_diagnose_is_read_only(self):
        self.run_script('--diagnose')
        self.assertEqual(list(self.config.iterdir()), [])
        self.assertFalse((self.home/'state').exists())
        self.assertEqual(self.log.read_text().strip(), 'pacman -Q plasma-workspace kdecoration')

    def test_menu_exit_and_empty_input_do_not_change_anything(self):
        for answer in ('0\n', '', '2\n0\n0\n', '2\n1 invalid\n'):
            result = self.run_script(input_data=answer)
            self.assertIn('一键安装并应用全部', result.stdout)
            self.assertEqual(list(self.config.iterdir()), [])
            self.assertFalse((self.home/'state').exists())
            self.assertFalse(self.log.exists())

    def test_menu_one_click_installs_and_applies(self):
        (self.data/'color-schemes/CatppuccinMochaPink.colors').unlink()
        self.run_script(input_data='1\n')
        self.assertIn('[Colors:Window]', (self.data/'color-schemes/CatppuccinMochaPink.colors').read_text())
        self.assertEqual(self.read('kdeglobals', 'General', 'ColorScheme'), 'CatppuccinMochaPink')
        self.assertEqual(self.read('kdeglobals', 'Icons', 'Theme'), 'Papirus-Dark')
        self.assertEqual(self.read('kwinrc', 'org.kde.kdecoration2', 'library'), 'org.kde.klassy')
        self.assertEqual(self.read('kcminputrc', 'Mouse', 'cursorTheme'), 'Bibata-Modern-Ice')

    def test_menu_multiselect_only_applies_selected_components(self):
        original = '[General]\nColorScheme=Keep\nAccentColor=255,0,0\n[KDE]\nwidgetStyle=KeepStyle\n'
        self.file(self.config/'kdeglobals', original)
        self.file(self.config/'plasmarc', '[Theme]\nname=KeepDesktop\n')
        # 未选的组件即使缺失，也不应被安装或阻止执行。
        (self.plugins/'org.kde.kdecoration3/org.kde.klassy.so').unlink()
        (self.data/'color-schemes/CatppuccinMochaPink.colors').unlink()
        result = self.run_script(input_data='2\n4 5 4\n')
        self.assertIn('待安装', result.stdout)
        self.assertEqual(self.read('kdeglobals', 'General', 'ColorScheme'), 'Keep')
        self.assertEqual(self.read('kdeglobals', 'General', 'AccentColor'), '255,0,0')
        self.assertEqual(self.read('kdeglobals', 'KDE', 'widgetStyle'), 'KeepStyle')
        self.assertEqual(self.read('plasmarc', 'Theme', 'name'), 'KeepDesktop')
        self.assertEqual(self.read('kdeglobals', 'Icons', 'Theme'), 'Papirus-Dark')
        self.assertEqual(self.read('kcminputrc', 'Mouse', 'cursorTheme'), 'Bibata-Modern-Ice')
        self.assertFalse((self.config/'kwinrc').exists())
        log = self.log.read_text()
        self.assertNotIn('pacman', log)
        self.assertNotIn('colors', log)
        self.assertNotIn('desktop', log)
        self.assertEqual(log.count('cursor Bibata-Modern-Ice'), 1)

    def test_setup_selected_colors_only_and_rejects_unknown_component(self):
        (self.data/'color-schemes/CatppuccinMochaPink.colors').unlink()
        self.run_script('--setup', 'unknown', success=False)
        self.assertEqual(list(self.config.iterdir()), [])
        self.assertFalse(self.log.exists())
        self.run_script('--setup', 'colors')
        self.assertEqual(self.read('kdeglobals', 'General', 'ColorScheme'), 'CatppuccinMochaPink')
        for filename in ('kwinrc', 'kcminputrc', 'plasmarc'):
            self.assertFalse((self.config/filename).exists())
        self.assertNotIn('pacman', self.log.read_text())

    def test_upgrade_lavender_to_official_pink_then_skip_and_restore(self):
        pink = self.data/'color-schemes/CatppuccinMochaPink.colors'
        pink.unlink()
        lavender = self.data/'color-schemes/CatppuccinMochaLavender.colors'
        old_asset = '[General]\nColorScheme=CatppuccinMochaLavender\n'
        self.file(lavender, old_asset)
        old_config = '[General]\nColorScheme=CatppuccinMochaLavender\nfont=KeepFont,11\n[Icons]\nTheme=KeepIcons\n'
        self.file(self.config/'kdeglobals', old_config)
        self.run_script('--setup', 'colors')
        official = configparser.ConfigParser()
        official.read(pink)
        self.assertEqual(official['General']['ColorScheme'], 'CatppuccinMochaPink')
        self.assertEqual(official['Colors:Selection']['BackgroundNormal'], '245, 194, 231')
        self.assertEqual(self.read('kdeglobals', 'General', 'ColorScheme'), 'CatppuccinMochaPink')
        self.assertEqual(self.read('kdeglobals', 'General', 'font'), 'KeepFont,11')
        self.assertEqual(self.read('kdeglobals', 'Icons', 'Theme'), 'KeepIcons')
        self.assertEqual(lavender.read_text(), old_asset)
        before = self.snapshots()
        pink_mtime = pink.stat().st_mtime_ns
        backups = list((self.home/'state/cachyos-kde/backups').iterdir())
        self.run_script('--setup', 'colors')
        self.assertEqual(self.snapshots(), before)
        self.assertEqual(pink.stat().st_mtime_ns, pink_mtime)
        self.assertEqual(list((self.home/'state/cachyos-kde/backups').iterdir()), backups)
        self.assertEqual(self.log.read_text().count('colors CatppuccinMochaPink'), 1)
        self.assertNotIn('pacman', self.log.read_text())
        self.run_script('--restore')
        self.assertEqual((self.config/'kdeglobals').read_text(), old_config)

    def test_apply_idempotent_and_restore_preserves_snapshot(self):
        originals = {
            'kdeglobals': '[General]\nColorScheme=BreezeDark\nAccentColor=255,0,0\nfont=Sarasa UI SC,11\n'
                          'accentColorFromWallpaper=true\n[KDE]\nwidgetStyle=OtherStyle\n[Icons]\nTheme=Papirus\n',
            'kwinrc': '[Compositing]\nBackend=OpenGL\n[org.kde.kdecoration2]\nlibrary=org.kde.breeze\nNoPlugin=true\n',
            'kcminputrc': '[Mouse]\ncursorSize=48\ncursorTheme=breeze_cursors\n',
            'plasmarc': '[Theme]\nname=custom\n',
        }
        for name, value in originals.items(): self.file(self.config/name, value)
        self.run_script('--apply')
        self.assertEqual(self.read('kdeglobals', 'KDE', 'widgetStyle'), 'Breeze')
        self.assertEqual(self.read('kdeglobals', 'General', 'ColorScheme'), 'CatppuccinMochaPink')
        self.assertEqual(self.read('kdeglobals', 'General', 'font'), 'Sarasa UI SC,11')
        self.assertEqual(self.read('kdeglobals', 'General', 'AccentColor'), '0,0,0,0')
        self.assertEqual(self.read('kdeglobals', 'Icons', 'Theme'), 'Papirus-Dark')
        self.assertEqual(self.read('kwinrc', 'org.kde.kdecoration2', 'library'), 'org.kde.klassy')
        self.assertEqual(self.read('kwinrc', 'org.kde.kdecoration2', 'NoPlugin'), 'false')
        self.assertEqual(self.read('kwinrc', 'Compositing', 'Backend'), 'OpenGL')
        self.assertEqual(self.read('kcminputrc', 'Mouse', 'cursorSize'), '48')
        self.assertEqual(self.read('plasmarc', 'Theme', 'name'), 'default')
        before = self.snapshots()
        log = self.log.read_text()
        backups = list((self.home/'state/cachyos-kde/backups').iterdir())
        self.run_script('--apply')
        self.assertEqual(self.snapshots(), before)
        self.assertEqual(self.log.read_text(), log)
        self.assertEqual(list((self.home/'state/cachyos-kde/backups').iterdir()), backups)
        self.run_script('--restore')
        self.assertEqual({p.name: p.read_text() for p in self.config.iterdir()}, originals)

    def test_absent_files_and_cursor_size_restore(self):
        self.run_script('--apply')
        self.assertEqual(self.read('kcminputrc', 'Mouse', 'cursorSize'), '')
        self.run_script('--restore')
        self.assertEqual(list(self.config.iterdir()), [])

    def test_incompatible_klassy_fails_before_backup(self):
        (self.plugins/'org.kde.kdecoration3/org.kde.klassy.so').unlink()
        self.file(self.plugins/'org.kde.kdecoration2/org.kde.klassy.so')
        result = self.run_script('--apply', success=False)
        self.assertIn('klassy', result.stderr)
        self.assertFalse((self.home/'state').exists())
        self.assertFalse(self.log.exists())

    def test_install_all_present_does_not_invoke_package_manager(self):
        self.run_script('--install')
        self.assertFalse(self.log.exists())
        self.assertFalse((self.home/'state').exists())

    def test_fresh_system_installs_every_missing_component_then_skips(self):
        # 隔离所有主题文件，即使开发机已装 Breeze/Papirus，这里仍必须安装。
        shutil.rmtree(self.data)
        shutil.rmtree(self.plugins)
        self.stub('pacman', '''
printf 'pacman %s\n' "$*" >> "$HOME/actions"
case "$1" in
    -Q) exit 1 ;;
    -Si) case "$2" in breeze|papirus-icon-theme) exit 0 ;; *) exit 1 ;; esac ;;
    -Syu)
        mkdir -p "$HOME/plugins/styles" "$HOME/plugins/org.kde.kdecoration3" \
            "$XDG_DATA_HOME/plasma/desktoptheme/default" "$XDG_DATA_HOME/icons/Papirus-Dark"
        touch "$HOME/plugins/styles/breeze6.so" "$HOME/plugins/org.kde.kdecoration3/org.kde.breeze.so" \
            "$XDG_DATA_HOME/plasma/desktoptheme/default/metadata.json" "$XDG_DATA_HOME/icons/Papirus-Dark/index.theme"
        ;;
    *) exit 99 ;;
esac
''')
        self.stub('paru', '''
printf 'paru %s\n' "$*" >> "$HOME/actions"
mkdir -p "$HOME/plugins/org.kde.kdecoration3" "$XDG_DATA_HOME/icons/Bibata-Modern-Ice/cursors"
touch "$HOME/plugins/org.kde.kdecoration3/org.kde.klassy.so" \
    "$XDG_DATA_HOME/icons/Bibata-Modern-Ice/index.theme" "$XDG_DATA_HOME/icons/Bibata-Modern-Ice/cursors/left_ptr"
''')
        self.run_script('--install')
        first_log = self.log.read_text()
        self.assertIn('pacman -Syu --needed breeze papirus-icon-theme', first_log)
        self.assertIn('paru -Syu --needed klassy bibata-cursor-theme-bin', first_log)
        self.assertIn('[Colors:Window]', (self.data/'color-schemes/CatppuccinMochaPink.colors').read_text())
        self.assertEqual(list(self.config.iterdir()), [])
        self.run_script('--install')
        self.assertEqual(self.log.read_text(), first_log)

    def test_install_only_missing_colors_uses_bundled_file(self):
        color = self.data/'color-schemes/CatppuccinMochaPink.colors'
        color.unlink()
        self.run_script('--install')
        self.assertIn('[Colors:Window]', color.read_text())
        self.assertFalse(self.log.exists())
        before = color.stat().st_mtime_ns
        self.run_script('--install')
        self.assertEqual(color.stat().st_mtime_ns, before)

    def test_symlink_config_refused_before_change(self):
        target = self.home/'dotfile'
        target.write_text('[General]\nfont=Keep\n')
        (self.config/'kdeglobals').symlink_to(target)
        self.run_script('--apply', success=False)
        self.assertEqual(target.read_text(), '[General]\nfont=Keep\n')
        self.assertFalse((self.home/'state').exists())

    def test_native_tool_failure_keeps_recoverable_backup(self):
        original = '[General]\nColorScheme=BreezeDark\nAccentColor=255,0,0\n'
        self.file(self.config/'kdeglobals', original)
        self.stub('plasma-apply-colorscheme', 'exit 42')
        self.run_script('--apply', success=False)
        self.assertTrue((self.home/'state/cachyos-kde/latest').exists())
        self.run_script('--restore')
        self.assertEqual((self.config/'kdeglobals').read_text(), original)

    def test_existing_scheme_with_accent_override_reapplies_palette(self):
        self.file(self.config/'kdeglobals', '[General]\nColorScheme=CatppuccinMochaPink\nAccentColor=255,0,0\n')
        self.run_script('--apply')
        self.assertIn('colors --accent-color transparent', self.log.read_text())

    def test_package_failure_does_not_copy_colors_or_apply(self):
        (self.plugins/'org.kde.kdecoration3/org.kde.klassy.so').unlink()
        color = self.data/'color-schemes/CatppuccinMochaPink.colors'
        color.unlink()
        self.stub('pacman', '''
printf 'pacman %s\n' "$*" >> "$HOME/actions"
case "$1" in -Q) exit 1;; -Si) exit 0;; -Syu) exit 42;; *) exit 99;; esac
''')
        self.run_script('--setup', success=False)
        self.assertIn('pacman -Syu --needed klassy', self.log.read_text())
        self.assertNotIn('papirus-icon-theme', self.log.read_text())
        self.assertFalse(color.exists())
        self.assertFalse((self.home/'state').exists())
        self.assertEqual(list(self.config.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
