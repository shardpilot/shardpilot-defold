#!/usr/bin/env python3
"""The renamed README contracts remain required by the real library check."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
with tempfile.TemporaryDirectory(prefix="library-wire-") as directory:
    fixture = Path(directory)
    for name in filter(None, tracked):
        source = root / name
        if source.is_file():
            target = fixture / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
    def check():
        return subprocess.run(["bash", "scripts/check_library.sh"], cwd=fixture,
                              text=True, capture_output=True)
    complete = check()
    assert complete.returncode == 0, complete.stdout + complete.stderr
    print("complete wire documentation: PASS")
    readme = fixture / "README.md"
    original = readme.read_text()
    for contract, witness in [
        ("POST {crash_url}/api/v1/crashes/ingest", "README missing crash wire contract"),
        ("GET {app_url}/config/v1/{workspace_id}/{environment_id}/{client_id}", "README missing remote-config wire contract"),
    ]:
        assert contract in original
        readme.write_text(original.replace(contract, "synthetic missing route"))
        result = check()
        assert result.returncode == 1 and witness in result.stderr, result.stdout + result.stderr
        print(witness + ": correctly refused")
