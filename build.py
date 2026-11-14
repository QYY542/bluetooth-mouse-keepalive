#!/usr/bin/env python3
"""Build the same universal app for installation and redistribution."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import zipfile

STAMP = '1114-1823'
VERSION = '1.1'
ROOT = Path(__file__).resolve().parent
APP = 'Bluetooth Mouse Keepalive.app'
EXECUTABLE = 'MouseKeepalive'

def run(*args):
    subprocess.run([str(a) for a in args], check=True)

def manifest(folder):
    return {str(p.relative_to(folder)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(folder.rglob('*')) if p.is_file()}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    package = out / f'Bluetooth-Mouse-Keepalive-{VERSION}'
    if package.exists():
        raise SystemExit('输出目录已有文件，请使用一个新的输出目录。')
    app = package / APP
    macos = app / 'Contents' / 'MacOS'
    macos.mkdir(parents=True)
    source = ROOT / 'MouseKeepalive.swift'
    binaries = []
    for arch in ('arm64', 'x86_64'):
        binary = out / f'MouseKeepalive-{arch}'
        run('xcrun', 'swiftc', source, '-target', f'{arch}-apple-macos13.0',
            '-framework', 'AppKit', '-framework', 'IOKit', '-framework', 'CoreGraphics',
            '-framework', 'CoreBluetooth', '-o', binary)
        binaries.append(binary)
    executable = macos / EXECUTABLE
    run('lipo', '-create', *binaries, '-output', executable)
    executable.chmod(0o755)
    info = {
        'CFBundleExecutable': EXECUTABLE, 'CFBundleIdentifier': 'local.bluetoothmouse.keepalive',
        'CFBundleName': 'Bluetooth Mouse Keepalive', 'CFBundleDisplayName': 'Bluetooth Mouse Keepalive',
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': VERSION,
        'CFBundleVersion': '202611141823', 'LSMinimumSystemVersion': '13.0', 'LSUIElement': True,
        'NSBluetoothAlwaysUsageDescription': '读取所选蓝牙鼠标的标准设备状态，尝试减少闲置休眠。',
    }
    with (app / 'Contents' / 'Info.plist').open('wb') as f:
        plistlib.dump(info, f)
    run('codesign', '--force', '--sign', '-', app)
    run('codesign', '--verify', '--strict', app)
    run('lipo', executable, '-verify_arch', 'arm64', 'x86_64')
    run(executable, '--self-test')
    run(executable, '--worker-self-test')
    for name in ['README.md', 'Install.command', 'build.py', source.name]:
        shutil.copy2(ROOT / name, package / name)
    (package / 'Install.command').chmod(0o755)
    (package / 'build.py').chmod(0o755)
    archive = out / f'Bluetooth-Mouse-Keepalive-{VERSION}-macOS.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for path in sorted(package.rglob('*')):
            if path.is_file():
                z.write(path, path.relative_to(out))
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
        assert all(i.flag_bits & 0x800 for i in z.infolist() if any(ord(c) > 127 for c in i.filename))
    verification = {'version': VERSION, 'build': STAMP, 'archive': archive.name,
                    'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
                    'app_files': manifest(app), 'architectures': ['arm64', 'x86_64'],
                    'checks': ['codesign', 'universal', 'offline_policy', 'worker_recovery', 'zip_integrity', 'utf8_names'],
                    'hardware_idle_test': 'not performed for this release'}
    (out / 'build-verification.json').write_text(json.dumps(verification, ensure_ascii=False, indent=2) + '\n')
    print(archive)

if __name__ == '__main__':
    main()
