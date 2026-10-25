"""在临时 HOME 中验证字体匹配和回退；需要 fontconfig、更纱、Noto CJK/Emoji、KDE 配置工具。
运行：python3 -B -m unittest discover -s cachyos/tests -v
不安装软件，不触碰真实用户配置；fc-cache 在测试中替换为空操作。
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

SCRIPT = Path(__file__).resolve().parents[1] / 'font_setup.sh'


class FontSetupTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='font-setup-test-', dir='/tmp')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.config = self.root / 'config'
        self.config.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, HOME=str(self.root), XDG_CONFIG_HOME=str(self.config),
                        XDG_STATE_HOME=str(self.root / 'state'), XDG_CACHE_HOME=str(self.root / 'cache'),
                        XDG_CURRENT_DESKTOP='KDE', PATH=f'{self.bin}:{os.environ["PATH"]}')
        for key in ('FONTCONFIG_FILE', 'FONTCONFIG_PATH', 'FONTCONFIG_SYSROOT'):
            self.env.pop(key, None)
        self.stub('fc-cache', 'exit 0')
        # 临时 HOME 仍需看到实机安装在用户目录的字体。
        fonts = Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share'))) / 'fonts'
        if fonts.is_dir():
            directory = self.config / 'fontconfig/conf.d'
            directory.mkdir(parents=True, exist_ok=True)
            root = ET.Element('fontconfig')
            ET.SubElement(root, 'dir').text = str(fonts)
            ET.ElementTree(root).write(directory / '00-test-fonts.conf', encoding='unicode')
        self.initial_files = sorted(self.config.rglob('*'))

    def stub(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/sh\n' + body + '\n')
        path.chmod(0o755)

    def run_script(self, *args, success=True):
        result = subprocess.run(['bash', str(SCRIPT), *args], env=self.env,
                                capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def require_fonts(self):
        for family in ('Sarasa UI SC', 'Sarasa Term SC', 'Noto Serif CJK SC', 'Noto Color Emoji'):
            result = subprocess.check_output(['fc-match', '-f', '%{family}', family], env=self.env, text=True)
            if family not in result.split(','):
                self.skipTest(f'需要安装 {family}')

    def match(self, pattern, fmt='%{family}'):
        return subprocess.check_output(['fc-match', '-f', fmt, pattern], env=self.env, text=True)

    def test_default_keeps_sarasa_for_ui_and_code(self):
        root = ET.fromstring(self.run_script('--print-config').stdout)
        aliases = {node.findtext('family'): node.findtext('prefer/family') for node in root.findall('alias')}
        self.assertEqual(aliases['sans-serif'], 'Sarasa UI SC')
        self.assertEqual(aliases['monospace'], 'Sarasa Term SC')
        self.assertEqual(aliases['serif'], 'Noto Serif CJK SC')
        # 即使当前未安装更纱，也能通过真实 Fontconfig 解析验证请求的优先顺序。
        directory = self.config / 'fontconfig/conf.d'
        directory.mkdir(parents=True, exist_ok=True)
        (directory / '60-cachyos-fonts.conf').write_text(self.run_script('--print-config').stdout)
        for pattern, family in (
            ('sans-serif:lang=en', 'Sarasa UI SC'),
            ('sans-serif:lang=zh-cn', 'Sarasa UI SC'),
            ('monospace:lang=en', 'Sarasa Term SC'),
            ('sans-serif:lang=zh-hk', 'Sarasa UI HC'),
            ('monospace:lang=ja', 'Sarasa Term J'),
        ):
            families = subprocess.check_output(['fc-pattern', '-c', '-f', '%{family}', pattern], env=self.env, text=True)
            # 保留系统插入的 Powerline 符号字体，检查正文使用的字体顺序。
            text_families = [name for name in families.split(',') if name != 'PowerlineSymbols']
            self.assertEqual(text_families[0], family)

    def test_locale_matching_explicit_fonts_and_emoji(self):
        self.require_fonts()
        directory = self.config / 'fontconfig/conf.d'
        directory.mkdir(parents=True, exist_ok=True)
        (directory / '60-cachyos-fonts.conf').write_text(self.run_script('--print-config').stdout)
        expected = {
            'sans-serif:lang=en:charset=41': 'Sarasa UI SC',
            'monospace:lang=en:charset=41': 'Sarasa Term SC',
            'sans-serif:lang=zh-cn': 'Sarasa UI SC',
            'serif:lang=zh-cn': 'Noto Serif CJK SC',
            'monospace:lang=zh-cn': 'Sarasa Term SC',
            'sans-serif:lang=zh-tw': 'Sarasa UI TC',
            'sans-serif:lang=zh-hk': 'Sarasa UI HC',
            'sans-serif:lang=ja': 'Sarasa UI J',
            'monospace:lang=ko': 'Sarasa Term K',
            'Noto Sans:lang=ja': 'Noto Sans',
            'emoji:charset=1f600': 'Noto Color Emoji',
        }
        for pattern, family in expected.items():
            with self.subTest(pattern=pattern):
                self.assertIn(family, self.match(pattern).split(','))
        self.assertEqual(self.match('sans-serif:lang=zh-cn', '%{rgba}|%{hintstyle}|%{embeddedbitmap}'), '5|1|False')
        self.assertEqual(self.match('emoji:charset=1f600', '%{embeddedbitmap}'), 'True')
        # 保留度量兼容别名及已安装的显式字体；未安装的 Consolas 可以正常回退。
        (directory / '60-cachyos-fonts.conf').unlink()
        before = {p: self.match(p) for p in ('Arial', 'Times New Roman', 'Noto Sans Mono')}
        (directory / '60-cachyos-fonts.conf').write_text(self.run_script('--print-config').stdout)
        for pattern, family in before.items():
            self.assertIn(family, self.match(pattern).split(','))

    def test_apply_and_restore_existing_files(self):
        self.require_fonts()
        if not shutil.which('kwriteconfig6') or not shutil.which('kreadconfig6'):
            self.skipTest('需要 KDE 配置工具')
        existing = '[General]\nColorScheme=PreserveMe\nfont=Before,10\n'
        kdeglobals = self.config / 'kdeglobals'
        kdeglobals.write_text(existing)
        directory = self.config / 'fontconfig/conf.d'
        directory.mkdir(parents=True, exist_ok=True)
        managed = directory / '60-cachyos-fonts.conf'
        old = '<fontconfig><!-- existing --></fontconfig>\n'
        managed.write_text(old)
        user = self.config / 'fontconfig/fonts.conf'
        user.write_text('<fontconfig><!-- keep user file --></fontconfig>\n')
        self.run_script('--apply')
        self.assertEqual(user.read_text(), '<fontconfig><!-- keep user file --></fontconfig>\n')
        self.assertIn('ColorScheme=PreserveMe', kdeglobals.read_text())
        for key, expected in (('font', 'Sarasa UI SC,11'), ('XftSubPixel', 'none'), ('XftHintStyle', 'hintslight')):
            value = subprocess.check_output(['kreadconfig6', '--file', str(kdeglobals), '--group', 'General', '--key', key], env=self.env, text=True)
            self.assertTrue(value.startswith(expected), value)
        self.run_script('--restore')
        self.assertEqual(kdeglobals.read_text(), existing)
        self.assertEqual(managed.read_text(), old)

    def test_restore_removes_new_files(self):
        self.require_fonts()
        if not shutil.which('kwriteconfig6'):
            self.skipTest('需要 kwriteconfig6')
        self.run_script('--apply')
        self.run_script('--restore')
        self.assertFalse((self.config / 'kdeglobals').exists())
        self.assertFalse((self.config / 'fontconfig/conf.d/60-cachyos-fonts.conf').exists())

    def test_missing_fonts_fail_before_changes(self):
        self.stub('fc-list', 'exit 0')
        result = self.run_script('--apply', success=False)
        self.assertIn('缺少字体', result.stderr)
        self.assertFalse((self.root / 'state').exists())
        self.assertEqual(sorted(self.config.rglob('*')), self.initial_files)

    def test_install_failure_is_not_success(self):
        self.stub('sudo', 'exec "$@"')
        self.stub('pacman', 'printf "%s\\n" "$@" > "$HOME/pacman-args"\nexit 42')
        result = self.run_script('--install', success=False)
        self.assertEqual(result.returncode, 42)
        self.assertNotIn('字体安装完成', result.stdout)
        self.assertIn('-Syu', (self.root / 'pacman-args').read_text())
        self.assertIn('ttf-sarasa-gothic', (self.root / 'pacman-args').read_text())
        self.assertNotIn('--noconfirm', (self.root / 'pacman-args').read_text())

    def test_bad_arguments_and_eof_are_safe(self):
        for args in (('--rgba', 'auto'), ('--size', '1'), ('--size',), ('--apply', '--restore')):
            self.run_script(*args, success=False)
        result = subprocess.run(['bash', str(SCRIPT)], env=self.env, input='', capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(sorted(self.config.rglob('*')), self.initial_files)


if __name__ == '__main__':
    unittest.main()
