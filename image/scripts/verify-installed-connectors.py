"""Verify fresh user-store connector files against the image's checked VSIXs."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import sys
import zipfile


def verify(bundle_dir, extensions_dir, expected):
    entries = json.loads((bundle_dir / 'manifest.json').read_text())
    if not isinstance(entries, list):
        entries = entries['extensions']
    assert len(entries) == len(expected), 'Unexpected bundled connector count'
    assert {entry['id'] for entry in entries} == set(expected), 'Unexpected bundled connector IDs'
    verified = []
    for entry in entries:
        identifier, version = entry['id'], entry['version']
        assert version == expected[identifier], 'Bundled connector version differs from source'
        assert Path(entry['file']).name == entry['file'], 'Unsafe VSIX filename'
        artifact = bundle_dir / entry['file']
        assert hashlib.sha256(artifact.read_bytes()).hexdigest() == entry['sha256'], 'VSIX checksum mismatch'
        candidates = []
        for directory in extensions_dir.iterdir():
            package_file = directory / 'package.json'
            if not directory.is_dir() or not package_file.is_file():
                continue
            package = json.loads(package_file.read_text())
            if f"{package.get('publisher')}.{package.get('name')}" == identifier and package.get('version') == version:
                assert not directory.is_symlink(), 'Installed extension must not be a symlink'
                candidates.append((directory, package))
        assert len(candidates) == 1, f'Expected one installed user-store copy: {identifier}@{version}'
        directory, installed_package = candidates[0]
        files = 0
        with zipfile.ZipFile(artifact) as archive:
            packaged = json.loads(archive.read('extension/package.json'))
            # VS Code adds __metadata to the installed package, leaving its source fields intact.
            source_fields = lambda p: {k: v for k, v in p.items() if k != '__metadata'}
            assert source_fields(installed_package) == source_fields(packaged), 'Installed package differs from VSIX'
            assert packaged.get('main'), 'Connector entrypoint missing'
            assert (directory / packaged['main']).is_file(), 'Installed connector entrypoint missing'
            for member in archive.infolist():
                if member.is_dir() or not member.filename.startswith('extension/'):
                    continue
                relative = PurePosixPath(member.filename[len('extension/'):])
                assert not relative.is_absolute() and '..' not in relative.parts, 'Unsafe VSIX member'
                if str(relative) == 'package.json':
                    continue
                installed = directory / str(relative)
                assert not installed.is_symlink(), 'Installed source must not be a symlink'
                assert installed.read_bytes() == archive.read(member), f'Installed source differs: {identifier}/{relative}'
                files += 1
        assert files > 0, 'VSIX contains no installed source files'
        verified.append({'id': identifier, 'version': version, 'verifiedFiles': files})
    return verified


if __name__ == '__main__':
    pins = dict(argument.split('=', 1) for argument in sys.argv[1:])
    assert set(pins) == {'woowtech.paseo', 'woowtech.omnigent'}, 'Both connector pins are required'
    print(json.dumps(verify(Path('/opt/woow-connector-vsix'),
                            Path('/home/coder/.local/share/code-server/extensions'), pins)))
