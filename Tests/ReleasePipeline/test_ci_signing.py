"""Exercise the CI credential lifecycle without importing a real identity."""
import base64
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SigningTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.runner = self.root / 'runner'
        self.runner.mkdir()
        self.log = self.root / 'commands'
        # Log operation names only; credentials must never appear in test output.
        mock = '''#!/bin/bash
set -eu
name=$(basename "$0")
echo "$name:${1:-}" >> "$MOCK_LOG"
if [[ "$name" == security && "$1" == create-keychain ]]; then
  touch "${@: -1}"
fi
if [[ "$name" == security && "$1" == import ]]; then
  test -f "$2"
  test "$(stat -f %Lp "$2")" = 600
fi
if [[ "$name:$1" == "${MOCK_FAIL:-}" ]]; then exit 42; fi
if [[ "$name" == security && "$1" == delete-keychain ]]; then rm "$2"; fi
if [[ "$name" == xcrun ]]; then
  test "$1" = notarytool
  test "$2" = store-credentials
  test -f "$NOTARY_KEYCHAIN_PATH"
fi
if [[ "$name" == zsh ]]; then
  test -z "${DEVELOPER_ID_P12_BASE64:-}"
  test -z "${DEVELOPER_ID_P12_PASSWORD:-}"
  test -z "${APPLE_APP_SPECIFIC_PASSWORD:-}"
  test -f "$NOTARY_KEYCHAIN_PATH"
  test ! -f "$(dirname "$NOTARY_KEYCHAIN_PATH")/certificate.p12"
  exit "${MOCK_PACKAGE_STATUS:-0}"
fi
'''
        for name in ('security', 'xcrun', 'zsh'):
            path = self.bin / name
            path.write_text(mock)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin',
                        GITHUB_ACTIONS='true', RUNNER_TEMP=str(self.runner), MOCK_LOG=str(self.log),
                        DEVELOPER_ID_APPLICATION='Developer ID Application: Test (TESTTEAM)',
                        DEVELOPER_TEAM_ID='TESTTEAM', APPLE_ID='test@example.invalid',
                        APPLE_APP_SPECIFIC_PASSWORD='fake-notary-password',
                        DEVELOPER_ID_P12_BASE64=base64.b64encode(b'fake-p12').decode(),
                        DEVELOPER_ID_P12_PASSWORD='fake-p12-password')

    def run_script(self):
        result = subprocess.run(['bash', str(ROOT / 'Scripts/ci-package-app.sh')],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(list(self.runner.iterdir()), [], 'Temporary signing material leaked')
        return result

    def test_success_cleans_up_and_does_not_export_secrets_to_build(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.log.read_text().splitlines()
        self.assertTrue(any(line.startswith('zsh:') for line in commands))
        self.assertEqual(commands[-1], 'security:delete-keychain')

    def test_failure_never_packages_and_cleans_up(self):
        for stage in ('security:import', 'xcrun:notarytool'):
            with self.subTest(stage=stage):
                self.log.unlink(missing_ok=True)
                self.env['MOCK_FAIL'] = stage
                result = self.run_script()
                self.assertEqual(result.returncode, 42, result.stderr)
                commands = self.log.read_text()
                self.assertNotIn('zsh:', commands)
                self.assertIn('security:delete-keychain', commands)

    def test_package_failure_propagates_and_cleans_up(self):
        self.env['MOCK_PACKAGE_STATUS'] = '43'
        self.assertEqual(self.run_script().returncode, 43)
        self.assertTrue(self.log.read_text().endswith('security:delete-keychain\n'))

    def test_missing_credentials_fail_before_side_effects(self):
        for key in ('DEVELOPER_ID_APPLICATION', 'DEVELOPER_TEAM_ID', 'APPLE_ID',
                    'APPLE_APP_SPECIFIC_PASSWORD', 'DEVELOPER_ID_P12_BASE64', 'DEVELOPER_ID_P12_PASSWORD'):
            with self.subTest(key=key):
                value = self.env.pop(key)
                self.assertNotEqual(self.run_script().returncode, 0)
                self.assertFalse(self.log.exists())
                self.env[key] = value

    def test_refuses_local_keychain_mutation(self):
        self.env['GITHUB_ACTIONS'] = 'false'
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertFalse(self.log.exists())

    def test_cleanup_failure_blocks_publication(self):
        self.env['MOCK_FAIL'] = 'security:delete-keychain'
        self.assertNotEqual(self.run_script().returncode, 0)


if __name__ == '__main__':
    unittest.main()
