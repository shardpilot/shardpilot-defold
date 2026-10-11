#!/usr/bin/env python3
"""Run the real library gate against complete and incomplete candidate trees."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
# Copy tracked candidate files, including edits, without repository metadata.
tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
with tempfile.TemporaryDirectory(prefix="library-files-") as directory:
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
    print("complete candidate without revision module: PASS")
    live = fixture / "shardpilot/client.lua"
    live.unlink()
    missing = check()
    assert missing.returncode == 1, missing.stdout + missing.stderr
    assert "missing required file: shardpilot/client.lua" in missing.stderr, missing.stderr
    print("missing live client module refused: PASS")
