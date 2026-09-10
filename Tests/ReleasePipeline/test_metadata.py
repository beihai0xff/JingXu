import importlib.util
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release_metadata', Path(__file__).resolve().parents[2] / 'Scripts/release-metadata.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class MetadataTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / 'Packaging').mkdir()
        (self.root / 'Documentation').mkdir()
        self.info = dict(CFBundleShortVersionString='1.2.3', CFBundleVersion='14', CFBundleIdentifier='app.jingxu.desktop')
        self.write_info()
        (self.root / 'Documentation/Release-1.2.3.md').write_text('Release notes')

    def write_info(self):
        with (self.root / 'Packaging/Info.plist').open('wb') as stream:
            plistlib.dump(self.info, stream)

    def test_matching_tag_and_branch(self):
        for ref in [None, 'refs/tags/v1.2.3', 'refs/heads/main']:
            self.assertEqual(module.metadata(self.root, ref)[:2], ('1.2.3', '14'))

    def test_mismatched_or_unsafe_tags(self):
        for tag in ['v1.2.4', 'v1.2.3-test', 'v1.2.3;echo bad', '../escape']:
            with self.assertRaises(ValueError):
                module.metadata(self.root, 'refs/tags/' + tag)

    def test_invalid_versions_and_builds(self):
        for key, value in [('CFBundleShortVersionString', '../escape'), ('CFBundleVersion', '0'), ('CFBundleIdentifier', 'other')]:
            original = self.info[key]
            self.info[key] = value
            self.write_info()
            with self.assertRaises(ValueError):
                module.metadata(self.root, 'refs/heads/main')
            self.info[key] = original

    def test_missing_notes(self):
        (self.root / 'Documentation/Release-1.2.3.md').unlink()
        with self.assertRaises(FileNotFoundError):
            module.metadata(self.root, 'refs/tags/v1.2.3')

    def test_channel_metadata_matches_artifact_and_release_notice(self):
        for mode, suffix, prerelease, notice in [
            ('adhoc', '-test.14', 'true', '未经 Apple 公证'),
            ('release', '', 'false', '使用 Developer ID 签名并经 Apple 公证'),
        ]:
            with self.subTest(mode=mode):
                output = self.root / mode
                github_output = self.root / f'{mode}.outputs'
                with patch.object(module, '__file__', str(self.root / 'Scripts/release-metadata.py')), \
                     patch.object(sys, 'argv', ['release-metadata.py', '--mode', mode, '--ref', 'refs/tags/v1.2.3', '--output', str(output)]), \
                     patch.object(module.subprocess, 'check_output', return_value='a' * 40), \
                     patch.dict(os.environ, GITHUB_OUTPUT=str(github_output)):
                    module.main()
                fields = dict(line.split('=', 1) for line in github_output.read_text().splitlines())
                self.assertEqual(fields['dmg'], f'JingXu-1.2.3{suffix}-macOS-arm64.dmg')
                self.assertEqual(fields['prerelease'], prerelease)
                self.assertEqual(fields['commit'], 'a' * 40)
                self.assertIn(notice, (output / 'RELEASE.md').read_text())
