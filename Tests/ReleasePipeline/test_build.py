"""Run the shared entry point with fake compiler/signing tools and real fixtures."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BuildTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.bin = self.root / 'bin'
        for folder in ('bin', 'Scripts', 'Packaging', 'Documentation', 'Tests/ReleasePipeline'):
            (self.root / folder).mkdir(parents=True, exist_ok=True)
        for name in ('build.sh', 'release-metadata.py'):
            shutil.copy(ROOT / 'Scripts' / name, self.root / 'Scripts' / name)
        (self.root / 'Scripts/build-icon.sh').write_text('exit 0\n')
        for name in ('Info.plist', 'AppIcon.icns', 'Upgrade-zh-Hans.txt', 'TestUpgrade-zh-Hans.txt'):
            shutil.copy(ROOT / 'Packaging' / name, self.root / 'Packaging' / name)
        self.info = plistlib.loads((self.root / 'Packaging/Info.plist').read_bytes())
        self.version = self.info['CFBundleShortVersionString']
        self.build = self.info['CFBundleVersion']
        (self.root / f'Documentation/Release-{self.version}.md').write_text('Fixture release')
        (self.root / 'JingXu.entitlements').write_bytes((ROOT / 'JingXu.entitlements').read_bytes())
        (self.root / 'Tests/ReleasePipeline/test_fixture.py').write_text(
            'import os, unittest\nclass Fixture(unittest.TestCase):\n'
            '    def test_result(self):\n        self.assertNotEqual(os.environ.get("BUILD_FAIL"), "python")\n')
        (self.bin / 'python3').symlink_to(sys.executable)
        self.log = self.root / 'commands.jsonl'
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        BUILD_FIXTURE=str(self.root), BUILD_LOG=str(self.log),
                        DEVELOPER_ID_APPLICATION='Developer ID Application: Fixture (TEAM)',
                        DEVELOPER_TEAM_ID='TEAM', NOTARY_KEYCHAIN_PROFILE='fixture',
                        NOTARY_KEYCHAIN_PATH=str(self.root / 'fixture.keychain-db'))
        self.env.pop('GITHUB_OUTPUT', None)
        mock = '''#!PYTHON
import json, os, pathlib, plistlib, shutil, sys
root = pathlib.Path(os.environ['BUILD_FIXTURE'])
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ['BUILD_LOG'], 'a') as log:
    log.write(json.dumps([name, *args]) + '\\n')
failure = os.environ.get('BUILD_FAIL')
if failure == name: sys.exit(42)
if name == 'git': print('a' * 40)
elif name == 'swift':
    if '--version' in args: print('fixture swift')
    elif '--show-bin-path' in args: print(root / 'compiled')
    else:
        if failure in ('debug', 'release') and args[args.index('-c')+1] == failure: sys.exit(42)
        binaries = root / 'compiled'
        binaries.mkdir(exist_ok=True)
        (binaries / 'JingXuApp').write_text('fixture app')
        (binaries / 'GRDB_GRDB.bundle').mkdir(exist_ok=True)
        (binaries / 'GRDB_GRDB.bundle/PrivacyInfo.xcprivacy').write_text('fixture resource')
        checks = binaries / 'JingXuChecks'
        checks.write_text('#!/bin/sh\\n[ "$BUILD_FAIL" != checks ]\\n')
        checks.chmod(0o755)
elif name == 'security': print('Developer ID Application: Fixture (TEAM)')
elif name == 'codesign' and '-dv' in args: print('TeamIdentifier=TEAM', file=sys.stderr)
elif name == 'xcrun' and args[:2] == ['notarytool', 'submit']:
    is_dmg = args[2].endswith('.dmg')
    rejected = failure == ('dmg-notary' if is_dmg else 'app-notary')
    sys.stdout.buffer.write(plistlib.dumps({'status': 'Invalid' if rejected else 'Accepted'}))
elif name == 'hdiutil' and args[0] == 'create':
    shutil.copytree(args[args.index('-srcfolder')+1], root / 'captured', symlinks=True)
    pathlib.Path(args[-1]).write_text('fixture dmg')
elif name == 'ditto': pathlib.Path(args[-1]).write_text('fixture zip')
'''.replace('PYTHON', sys.executable)
        for name in ('git', 'swift', 'security', 'codesign', 'xcrun', 'hdiutil', 'ditto', 'spctl'):
            path = self.bin / name
            path.write_text(mock)
            path.chmod(0o755)

    def run_build(self, mode):
        return subprocess.run(['zsh', '-f', str(self.root / 'Scripts/build.sh'), mode],
                              # Prove callers need not change into the checkout first.
                              cwd=self.bin, env=self.env, text=True, capture_output=True,
                              umask=0o077, timeout=60)

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_check_and_adhoc_use_identical_compiler_options(self):
        check = self.run_build('check')
        self.assertEqual(check.returncode, 0, check.stderr)
        check_swift = [cmd for cmd in self.commands() if cmd[0] == 'swift']
        self.assertFalse((self.root / 'outputs').exists())
        self.log.unlink()
        adhoc = self.run_build('adhoc')
        self.assertEqual(adhoc.returncode, 0, adhoc.stderr)
        self.assertEqual(check_swift, [cmd for cmd in self.commands() if cmd[0] == 'swift'])
        for cmd in check_swift:
            if cmd[1] == 'build':
                self.assertIn('--disable-automatic-resolution', cmd)
                self.assertEqual(cmd[cmd.index('--arch')+1], 'arm64')
        self.assertFalse(any(cmd[0] in ('security', 'xcrun') for cmd in self.commands()))
        resources = self.root / 'captured/镜序.app/Contents/Resources'
        self.assertEqual((self.root / 'captured/应用程序').readlink(), Path('/Applications'))
        self.assertEqual(resources.stat().st_mode & 0o777, 0o755)
        self.assertTrue((resources / 'GRDB_GRDB.bundle/PrivacyInfo.xcprivacy').exists())
        info = plistlib.loads((self.root / 'captured/镜序.app/Contents/Info.plist').read_bytes())
        self.assertEqual(info['JingXuReleaseChannel'], '未公证测试版')
        self.assertTrue((self.root / f'outputs/JingXu-{self.version}-test.{self.build}-macOS-arm64.dmg.sha256').exists())
        self.assertIn('未经 Apple 公证', (self.root / 'outputs/RELEASE.md').read_text())

    def test_release_validates_app_and_dmg_and_uses_explicit_keychain(self):
        result = self.run_build('release')
        self.assertEqual(result.returncode, 0, result.stderr)
        submits = [cmd for cmd in self.commands() if cmd[1:3] == ['notarytool', 'submit']]
        self.assertEqual(len(submits), 2)
        for cmd in submits:
            self.assertEqual(cmd[cmd.index('--keychain')+1], self.env['NOTARY_KEYCHAIN_PATH'])
        self.assertTrue((self.root / f'outputs/JingXu-{self.version}-macOS-arm64.dmg.sha256').exists())
        info = plistlib.loads((self.root / 'captured/镜序.app/Contents/Info.plist').read_bytes())
        self.assertNotIn('JingXuReleaseChannel', info)
        self.assertIn('使用 Developer ID 签名并经 Apple 公证', (self.root / 'outputs/RELEASE.md').read_text())

    def test_build_or_checks_failure_never_packages(self):
        for stage in ('python', 'debug', 'release', 'checks'):
            with self.subTest(stage=stage):
                self.log.unlink(missing_ok=True)
                self.env['BUILD_FAIL'] = stage
                self.assertNotEqual(self.run_build('adhoc').returncode, 0)
                self.assertFalse((self.root / 'outputs').exists())
                if self.log.exists():
                    self.assertFalse(any(cmd[0] == 'codesign' for cmd in self.commands()))

    def test_notary_rejection_never_publishes_installers(self):
        for stage in ('app-notary', 'dmg-notary'):
            with self.subTest(stage=stage):
                self.env['BUILD_FAIL'] = stage
                self.assertNotEqual(self.run_build('release').returncode, 0)
                self.assertFalse((self.root / 'outputs').exists())

    def test_existing_artifact_is_not_overwritten(self):
        outputs = self.root / 'outputs'
        outputs.mkdir()
        artifact = outputs / f'JingXu-{self.version}-test.{self.build}-macOS-arm64.dmg'
        artifact.write_text('existing')
        self.assertNotEqual(self.run_build('adhoc').returncode, 0)
        self.assertEqual(artifact.read_text(), 'existing')
        self.assertFalse(any(cmd[0] == 'swift' for cmd in self.commands()))

    def test_missing_identity_fails_before_build(self):
        self.env.pop('DEVELOPER_ID_APPLICATION')
        self.assertNotEqual(self.run_build('release').returncode, 0)
        self.assertFalse(any(cmd[0] == 'swift' for cmd in self.commands()))


if __name__ == '__main__':
    unittest.main()
