import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('verify', Path(__file__).resolve().parents[1] / 'scripts/verify-installed-connectors.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class InstalledConnectors(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.bundle, self.store = root/'bundle', root/'extensions'
        self.bundle.mkdir(); self.store.mkdir()
        self.package = {'name': 'paseo', 'publisher': 'woowtech', 'version': '0.1.4', 'main': './out/extension.cjs'}
        self.installed = self.store/'woowtech.paseo-0.1.4'
        (self.installed/'out').mkdir(parents=True)
        files = {'package.json': json.dumps(self.package).encode(), 'out/extension.cjs': b'require("./controller.cjs");',
                 'out/controller.cjs': b'module.exports = {};'}
        self.artifact = self.bundle/'woowtech.paseo-0.1.4.vsix'
        with zipfile.ZipFile(self.artifact, 'w') as archive:
            for name, data in files.items():
                archive.writestr('extension/'+name, data)
                (self.installed/name).write_bytes(data)
        entry = {'id':'woowtech.paseo', 'version':'0.1.4', 'file':self.artifact.name,
                 'sha256':hashlib.sha256(self.artifact.read_bytes()).hexdigest()}
        (self.bundle/'manifest.json').write_text(json.dumps([entry]))
        self.pins = {'woowtech.paseo':'0.1.4'}

    def verify(self):
        return module.verify(self.bundle, self.store, self.pins)

    def test_installer_metadata_is_allowed_with_exact_source(self):
        package = dict(self.package, __metadata={'installedTimestamp':123})
        (self.installed/'package.json').write_text(json.dumps(package))
        self.assertEqual(self.verify()[0]['verifiedFiles'], 2)

    def test_tampered_controller_fails_even_with_matching_entrypoint(self):
        (self.installed/'out/controller.cjs').write_text('changed')
        with self.assertRaisesRegex(AssertionError, 'Installed source differs'):
            self.verify()

    def test_missing_installed_copy_fails(self):
        (self.installed/'package.json').unlink()
        with self.assertRaisesRegex(AssertionError, 'one installed user-store copy'):
            self.verify()

    def test_installed_configuration_change_fails(self):
        (self.installed/'package.json').write_text(json.dumps(dict(self.package, contributes={})))
        with self.assertRaisesRegex(AssertionError, 'Installed package differs'):
            self.verify()

    def test_wrong_source_version_fails(self):
        self.pins['woowtech.paseo'] = '0.1.5'
        with self.assertRaisesRegex(AssertionError, 'version differs from source'):
            self.verify()

    def test_tampered_vsix_fails(self):
        with self.artifact.open('ab') as stream:
            stream.write(b'changed')
        with self.assertRaisesRegex(AssertionError, 'VSIX checksum mismatch'):
            self.verify()


if __name__ == '__main__':
    unittest.main()
