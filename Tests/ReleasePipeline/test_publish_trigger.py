"""Exercise tag dispatch against a local bare remote, never GitHub."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PublishTriggerTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.checkout = self.root / 'checkout'
        self.checkout.mkdir()
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
                        GIT_AUTHOR_NAME='Test', GIT_AUTHOR_EMAIL='test@example.invalid',
                        GIT_COMMITTER_NAME='Test', GIT_COMMITTER_EMAIL='test@example.invalid')
        self.env.pop('GITHUB_OUTPUT', None)
        self.git('init', '-b', 'main')
        self.git('config', 'core.hooksPath', '/dev/null')
        self.git('init', '--bare', str(self.root / 'remote.git'))
        self.git('remote', 'add', 'origin', str(self.root / 'remote.git'))
        for folder in ('Scripts', 'Packaging', 'Documentation'):
            (self.checkout / folder).mkdir()
        for name in ('publish-release.sh', 'ci-release-metadata.py'):
            shutil.copy(ROOT / 'Scripts' / name, self.checkout / 'Scripts' / name)
        # A publish helper must not run any local packaging or build program.
        (self.checkout / 'Scripts/package-app.sh').write_text('exit 99\n')
        with (self.checkout / 'Packaging/Info.plist').open('wb') as stream:
            plistlib.dump(dict(CFBundleShortVersionString='1.2.3', CFBundleVersion='1',
                               CFBundleIdentifier='app.jingxu.desktop'), stream)
        (self.checkout / 'Documentation/Release-1.2.3.md').write_text('Test release')
        self.git('add', '.')
        self.git('commit', '-m', 'fixture')
        self.git('push', '-u', 'origin', 'main')
        self.commit = self.git('rev-parse', 'HEAD').strip()
        self.env['RELEASE_ACCEPTANCE_COMMIT'] = self.commit

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.checkout, env=self.env,
                                       text=True, stderr=subprocess.PIPE)

    def trigger(self):
        return subprocess.run(['zsh', 'Scripts/publish-release.sh'], cwd=self.checkout,
                              env=self.env, text=True, capture_output=True)

    def test_pushes_only_the_checked_tag_and_rejects_duplicate(self):
        result = self.trigger()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('GitHub Actions', result.stdout)
        remote_commit = self.git('ls-remote', 'origin', 'refs/tags/v1.2.3^{}').split()[0]
        self.assertEqual(remote_commit, self.commit)
        self.assertEqual(self.git('status', '--porcelain'), '')
        self.assertNotEqual(self.trigger().returncode, 0)
        self.assertFalse((self.checkout / 'outputs').exists())

    def test_dirty_tree_does_not_push_tag(self):
        (self.checkout / 'uncommitted.txt').write_text('unfinished')
        self.assertNotEqual(self.trigger().returncode, 0)
        self.assertEqual(self.git('ls-remote', '--tags', 'origin'), '')

    def test_unaccepted_commit_does_not_push_tag(self):
        self.env['RELEASE_ACCEPTANCE_COMMIT'] = '0' * 40
        self.assertNotEqual(self.trigger().returncode, 0)
        self.assertEqual(self.git('ls-remote', '--tags', 'origin'), '')

    def test_remote_lookup_error_does_not_create_local_tag(self):
        real_git = shutil.which('git')
        bin_directory = self.root / 'bin'
        bin_directory.mkdir()
        wrapper = bin_directory / 'git'
        wrapper.write_text('#!/bin/bash\nif [[ "$1" == ls-remote ]]; then exit 42; fi\nexec "$REAL_GIT" "$@"\n')
        wrapper.chmod(0o755)
        self.env['REAL_GIT'] = real_git
        self.env['PATH'] = f"{bin_directory}:{self.env['PATH']}"
        result = self.trigger()
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(self.git('tag', '--list'), '')


if __name__ == '__main__':
    unittest.main()
