#!/usr/bin/env python3
"""Build-only PaaS reminder-v2 composition with the frozen shared strict patcher.

The shared patcher's default pristine guard is unchanged. This adapter accepts
only the reviewed reminder output and verifies its other runtime dependencies
before using that exact app hash for source reconstruction and receipt checks.
"""
import argparse
import hashlib
from pathlib import Path
import types
import zlib

PROFILE = "paas-reminder-v2-strict-v1"
SHARED_SOURCES = {
    "patch-claude-strict-resume.py": "5636382ae32b644bc9058a65fc82c125da987647d956f2776860b231df895827",
    "claude_strict_resume.py": "91fd87dc1333eb8de22bd291d38e2682db191fef47e668e8be1aab4e22731073",
    "native_strict_bootstrap.py": "16b75a3b1828545e5829c8f87c2e11b892017a1f60025ed33976c880eb004ff6",
    "pi_strict_resume.py": "9ea9bb12498fa0a24e599394179928ad5cae2aecd5e38828a5e5d6c91844ba58",
    "pi_strict_launcher.mjs": "07fb97cfa135dc70a3c2c818e717497939db0f4f979b66357fd11444214a8b56",
    "native_resume.py": "1efe62abf4a3472731d03e5df3c61b4a58ad8dd070212c742b46d916be769ba3",
    "codex_strict_resume.py": "d8c4f62350e314345bfb11ae30beafc1adb470acb9b1d8be140a42701cd1fda8",
}
REMINDER_DEPENDENCIES = {
    "harnesses/claude_native/bridge.py": "ccd7787cf9d4eca61f8a15beb76b41dcce0a9813a2786e99a1e764309ab9840e",
    "_reminder_filter.py": "5963bb4e5113a5e29b2760d7c473e2a40fcce32ac0ce756abf7bd2cdced421f8",
    "server/background_session_titles.py": "7fe2ca0b21e5570dc22772e3a617e74aa9592eef9047d62587cac9ccc139c3d3",
}
PRISTINE_APP = "9dde9dc61b4e8068702657862c298e0dac028e882eea004d177b742fcf3025db"
REMINDER_APP = "c38b016a8145deb6d1ad22b07ca57eaf31d5e64de5030c3c0e933e15ede84e2f"
COMPOSED_APP = "9de5986287e9f87ec665a9cadb322f10445d5c2bc1d7119f80525041113a7ce6"


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def regular_bytes(path):
    if any(p.is_symlink() for p in (path, *path.parents)) or not path.is_file():
        raise ValueError("PAAS_COMPOSITION_UNSAFE_PATH")
    return path.read_bytes()


def patch(site, shared_patcher, *, check=False):
    shared_patcher = Path(shared_patcher).absolute()
    if shared_patcher.name != "patch-claude-strict-resume.py":
        raise ValueError("PAAS_COMPOSITION_SHARED_SOURCE_MISMATCH")
    frozen = {}
    for name, expected in SHARED_SOURCES.items():
        raw = regular_bytes(shared_patcher.with_name(name))
        if digest(raw) != expected:
            raise ValueError("PAAS_COMPOSITION_SHARED_SOURCE_MISMATCH")
        frozen[name] = raw
    package = Path(site).absolute() / "omnigent"
    for name, expected in REMINDER_DEPENDENCIES.items():
        if digest(regular_bytes(package / name)) != expected:
            raise ValueError("PAAS_COMPOSITION_REMINDER_MISMATCH")
    if digest(regular_bytes(package / "runner/app.py")) not in {REMINDER_APP, COMPOSED_APP}:
        raise ValueError("PAAS_COMPOSITION_APP_MISMATCH")

    # Execute the verified source bytes directly, avoiding cached bytecode.
    shared = types.ModuleType("woow_paas_frozen_strict_patcher")
    shared.__file__ = str(shared_patcher)
    exec(compile(frozen[shared_patcher.name], str(shared_patcher), "exec"), shared.__dict__)
    if shared.HASHES["runner/app.py"] != PRISTINE_APP:
        raise ValueError("PAAS_COMPOSITION_SHARED_SOURCE_MISMATCH")
    shared.HASHES = {**shared.HASHES, "runner/app.py": REMINDER_APP}
    result = shared.patch(site, check=check)
    if not check and digest(regular_bytes(package / "runner/app.py")) != COMPOSED_APP:
        raise ValueError("PAAS_COMPOSITION_RESULT_MISMATCH")
    return {**result, "profile": PROFILE}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--site-packages", type=Path, required=True)
    parser.add_argument("--shared-patcher", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        result = patch(args.site_packages, args.shared_patcher, check=args.check)
    except (OSError, ValueError, UnicodeError, SyntaxError, zlib.error):
        raise SystemExit("PAAS_STRICT_COMPOSITION_REFUSED") from None
    print(PROFILE + ": " + result["state"])
