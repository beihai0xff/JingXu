#!/usr/bin/env python3
"""Validate the checked-out release; never derive filenames from unchecked refs."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess


def metadata(root: Path, ref: str):
    with (root / 'Packaging/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    version = info['CFBundleShortVersionString']
    build = info['CFBundleVersion']
    if not isinstance(version, str) or not re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', version):
        raise ValueError('Application version must be major.minor.patch')
    if not isinstance(build, str) or not re.fullmatch(r'[1-9]\d*', build):
        raise ValueError('Build number must be a positive integer')
    if ref.startswith('refs/tags/') and ref != f'refs/tags/v{version}':
        raise ValueError(f'Tag must match application version v{version}')
    if not ref.startswith(('refs/tags/', 'refs/heads/')):
        raise ValueError('Unsupported ref')
    if info['CFBundleIdentifier'] != 'app.jingxu.desktop':
        raise ValueError('Do not change the existing catalog application identity')
    notes = (root / f'Documentation/Release-{version}.md').read_text()
    if not notes.strip():
        raise ValueError('Release notes must not be empty')
    return version, build, notes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--ref', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    version, build, notes = metadata(root, args.ref)
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    args.output.mkdir(parents=True, exist_ok=True)
    notice = ('> 安装前先结束后台任务、退出旧应用并备份图库，再拖动替换安装。'
              '首次切换到 Developer ID 签名版本时，可能需要重新授权原容器或照片目录。\n\n')
    (args.output / 'RELEASE.md').write_text(notice + notes + f'\n\n构建 {build} · 源提交 `{commit}`\n')
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write(f'version={version}\ncommit={commit}\n')
    print(f'Validated v{version} (build {build}) at {commit}')


if __name__ == '__main__':
    main()
