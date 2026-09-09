import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('release_metadata', Path(__file__).resolve().parents[2] / 'Scripts/ci-release-metadata.py')
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
        for ref in ['refs/tags/v1.2.3', 'refs/heads/main']:
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
