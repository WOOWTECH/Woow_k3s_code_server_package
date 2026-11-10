"""PaaS's real patch sequence on the hash-locked, pristine 0.16 SDK fixture."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
import zlib

SOURCE = Path(__file__).resolve().parents[1]
KIT = SOURCE / "connectors/omnigent"
if not KIT.is_dir():
    KIT = Path("/opt/woow-connectors/omnigent")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


adapter = load("paas_composition", SOURCE / "omnigent-reminder-patch/patch-strict-composition.py")
reminder = load("paas_reminder", SOURCE / "omnigent-reminder-patch/omnigent-reminder-patch.py")
shared = load("paas_shared", KIT / "patch-runtime.py")
native = load("paas_native", KIT / "patch-native-resume.py")
strict = load("paas_strict", KIT / "patch-claude-strict-resume.py")


class Composition(unittest.TestCase):
    def setUp(self):
        fixture = Path(os.environ["OMNIGENT_TEST_SITE_PACKAGES"])
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.site = Path(self.temp.name) / "site"
        self.package = self.site / "omnigent"
        paths = set(shared.HASHES) | set(native.HASHES) | set(strict.HASHES)
        paths |= {"version.py", "harnesses/claude_native/bridge.py", "server/background_session_titles.py"}
        for name in paths:
            target = self.package / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(fixture / "omnigent" / name, target)
        metadata = self.site / "omnigent-0.16.0.dist-info/METADATA"
        metadata.parent.mkdir()
        shutil.copyfile(fixture / "omnigent-0.16.0.dist-info/METADATA", metadata)
        self.patcher = KIT / "patch-claude-strict-resume.py"

    def before_strict(self):
        self.assertEqual(reminder.apply(self.package, SOURCE / "omnigent-reminder-patch"), 0)
        shared.patch(self.site)
        native.patch(self.site)

    def apply(self, **kwargs):
        return adapter.patch(self.site, self.patcher, **kwargs)

    def snapshot(self):
        return {str(p.relative_to(self.site)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in self.site.rglob("*") if p.is_file() and "__pycache__" not in p.parts}

    def refused(self, error="MISMATCH"):
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, error):
            self.apply()
        self.assertEqual(before, self.snapshot(), "refusal must not write any SDK files")

    def test_real_recipe_and_complete_final_composition_idempotence(self):
        self.before_strict()
        self.assertEqual(self.apply()["state"], "applied")
        first = self.snapshot()
        self.before_strict()
        self.assertEqual(self.apply()["state"], "already-applied")
        self.assertEqual(self.snapshot(), first)
        self.assertEqual(self.apply(check=True)["state"], "already-applied")
        self.assertEqual(self.snapshot(), first)
        app = (self.package / "runner/app.py").read_text()
        self.assertEqual(hashlib.sha256(app.encode()).hexdigest(), adapter.COMPOSED_APP)
        self.assertIn("_reminder_filter.title_source_text(body.prompt)", app)
        self.assertIn("woow_native_strict_bootstrap", app)

    def test_default_strict_guard_rejects_reminder_input(self):
        self.before_strict()
        with self.assertRaisesRegex(ValueError, "STRICT_PATCH_SOURCE_MISMATCH"):
            strict.patch(self.site)

    def test_default_strict_guard_rejects_profile_receipt(self):
        self.before_strict()
        self.apply()
        with self.assertRaisesRegex(ValueError, "STRICT_PATCH_SOURCE_MISMATCH"):
            strict.patch(self.site)

    def test_pristine_app_is_not_the_paas_profile(self):
        self.before_strict()
        original = self.package / "runner/app.py.orig"
        (self.package / "runner/app.py").write_bytes(original.read_bytes())
        self.refused("PAAS_COMPOSITION_APP_MISMATCH")

    def test_each_reminder_dependency_tamper_before_and_after_patch(self):
        self.before_strict()
        for applied in (False, True):
            if applied:
                self.apply()
            for name in adapter.REMINDER_DEPENDENCIES:
                with self.subTest(applied=applied, dependency=name):
                    path = self.package / name
                    original = path.read_bytes()
                    path.write_bytes(original + b"\n# tampered\n")
                    self.refused("PAAS_COMPOSITION_REMINDER_MISMATCH")
                    path.write_bytes(original)

    def test_final_app_tamper_rejected_even_with_matching_receipt_digest(self):
        self.before_strict()
        self.apply()
        app = self.package / "runner/app.py"
        app.write_bytes(app.read_bytes() + b"\n# altered\n")
        receipt = self.package / strict.RECEIPT
        data = json.loads(receipt.read_text())
        data["targets"]["runner/app.py"]["patched"] = hashlib.sha256(app.read_bytes()).hexdigest()
        receipt.write_text(json.dumps(data))
        self.refused("PAAS_COMPOSITION_APP_MISMATCH")

    def test_forged_receipt_source_cannot_bless_a_different_original(self):
        self.before_strict()
        self.apply()
        receipt = self.package / strict.RECEIPT
        data = json.loads(receipt.read_text())
        data["targets"]["runner/app.py"]["sourceZlib"] = base64.b64encode(zlib.compress(b"wrong source")).decode()
        receipt.write_text(json.dumps(data))
        self.refused("STRICT_PATCH_SOURCE_MISMATCH")

    def test_changed_orchestration_still_uses_default_exact_guard(self):
        self.before_strict()
        path = self.package / "runner/native/orchestration.py"
        path.write_bytes(path.read_bytes() + b"\n# altered\n")
        self.refused("STRICT_PATCH_SOURCE_MISMATCH")

    def test_changed_shared_patcher_is_refused_before_execution(self):
        self.before_strict()
        directory = Path(self.temp.name) / "shared"
        directory.mkdir()
        for name in adapter.SHARED_SOURCES:
            shutil.copyfile(KIT / name, directory / name)
        self.patcher = directory / self.patcher.name
        self.patcher.write_text("raise RuntimeError('must never execute')\n")
        self.refused("PAAS_COMPOSITION_SHARED_SOURCE_MISMATCH")

    def test_changed_shared_helper_is_refused(self):
        self.before_strict()
        directory = Path(self.temp.name) / "shared"
        directory.mkdir()
        for name in adapter.SHARED_SOURCES:
            shutil.copyfile(KIT / name, directory / name)
        self.patcher = directory / self.patcher.name
        (directory / "codex_strict_resume.py").write_text("# changed\n")
        self.refused("PAAS_COMPOSITION_SHARED_SOURCE_MISMATCH")

    def test_missing_reminder_dependency_is_refused(self):
        self.before_strict()
        (self.package / "server/background_session_titles.py").unlink()
        self.refused("PAAS_COMPOSITION_UNSAFE_PATH")

    def test_reminder_dependency_symlink_is_refused(self):
        self.before_strict()
        path = self.package / "_reminder_filter.py"
        target = Path(self.temp.name) / "filter.py"
        path.rename(target)
        path.symlink_to(target)
        self.refused("PAAS_COMPOSITION_UNSAFE_PATH")

    def test_check_validates_without_writing(self):
        self.before_strict()
        before = self.snapshot()
        self.assertEqual(self.apply(check=True)["state"], "verified")
        self.assertEqual(before, self.snapshot())


if __name__ == "__main__":
    unittest.main(verbosity=2)
