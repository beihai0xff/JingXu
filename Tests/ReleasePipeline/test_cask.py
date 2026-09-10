import base64
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("update_cask", ROOT / "Scripts/update-cask.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CaskTests(unittest.TestCase):
    def setUp(self):
        self.current = {"sha": "file-revision", "content": base64.b64encode(
            ('cask "jingxu" do\n  version "0.2.5"\n  sha256 "' + 'a' * 64 + '"\nend\n').encode()).decode()}
        self.release = {"tag_name": "v0.2.6", "draft": False, "prerelease": False, "assets": [{
            "name": "JingXu-0.2.6-macOS-arm64.dmg", "digest": "sha256:" + "b" * 64,
            "browser_download_url": "https://github.com/beihai0xff/JingXu/releases/download/v0.2.6/JingXu-0.2.6-macOS-arm64.dmg"}]}

    def test_update_preserves_cas_and_renders_signed_cask(self):
        result = module.payload(self.release, self.current)
        self.assertEqual(result["sha"], "file-revision")
        self.assertEqual(result["branch"], "main")
        body = base64.b64decode(result["content"]).decode()
        self.assertIn('version "0.2.6"', body)
        self.assertIn('sha256 "' + 'b' * 64 + '"', body)
        self.assertIn('Developer ID signed and notarized by Apple', body)
        self.assertIn('releases/download/v#{version}/JingXu-0.2.6-macOS-arm64.dmg', body)
        self.assertNotIn('ad-hoc', body)

    def test_prerelease_uses_test_artifact_and_truthful_signature_notice(self):
        self.release['prerelease'] = True
        asset = self.release['assets'][0]
        asset['name'] = 'JingXu-0.2.6-test.15-macOS-arm64.dmg'
        asset['browser_download_url'] = 'https://github.com/beihai0xff/JingXu/releases/download/v0.2.6/' + asset['name']
        result = module.payload(self.release, self.current)
        body = base64.b64decode(result['content']).decode()
        self.assertIn(asset['name'], body)
        self.assertIn('ad-hoc signed and not notarized by Apple', body)
        self.assertNotIn('Developer ID signed', body)
        self.assertIsNone(module.payload(self.release, result))
        self.release['prerelease'] = False
        with self.assertRaises(ValueError):
            module.payload(self.release, self.current)

    def test_prerelease_rejects_wrong_version_or_invalid_build(self):
        self.release['prerelease'] = True
        for name in ['JingXu-0.2.5-test.15-macOS-arm64.dmg',
                     'JingXu-0.2.6-test.0-macOS-arm64.dmg',
                     'JingXu-0.2.6-test.01-macOS-arm64.dmg']:
            with self.subTest(name=name):
                self.release['assets'][0]['name'] = name
                with self.assertRaises(ValueError):
                    module.payload(self.release, self.current)

    def test_idempotence_and_same_version_mutation(self):
        updated = module.payload(self.release, self.current)
        self.assertIsNone(module.payload(self.release, updated))
        self.release["assets"][0]["digest"] = "sha256:" + "c" * 64
        with self.assertRaises(ValueError):
            module.payload(self.release, updated)

    def test_downgrade(self):
        self.current["content"] = base64.b64encode(base64.b64decode(
            self.current["content"]).replace(b'0.2.5', b'0.2.10')).decode()
        with self.assertRaises(ValueError):
            module.payload(self.release, self.current)

    def test_invalid_assets_fail_closed(self):
        for field, value in [("digest", None), ("digest", "sha256:invalid"),
                             ("browser_download_url", "https://example.com/file.dmg")]:
            with self.subTest(field=field, value=value):
                original = self.release["assets"][0][field]
                self.release["assets"][0][field] = value
                with self.assertRaises((ValueError, TypeError)):
                    module.payload(self.release, self.current)
                self.release["assets"][0][field] = original

    def test_draft_and_non_version_rejected(self):
        self.release["draft"] = True
        with self.assertRaises(ValueError):
            module.payload(self.release, self.current)
        self.release["draft"] = False
        self.release["prerelease"] = True
        with self.assertRaises(ValueError):
            module.payload(self.release, self.current)
        self.release["prerelease"] = False
        self.release["tag_name"] = "v0.2.6-test.1"
        with self.assertRaises(ValueError):
            module.payload(self.release, self.current)

    def test_missing_and_duplicate_assets(self):
        asset = self.release["assets"][0]
        for assets in [[], [asset, asset]]:
            self.release["assets"] = assets
            with self.assertRaises(ValueError):
                module.payload(self.release, self.current)


if __name__ == "__main__":
    unittest.main()
