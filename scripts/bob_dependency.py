"""Serve a job's dependency and run Bob in a private copy of the fixture."""

from contextlib import contextmanager
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
from threading import Thread


HARNESS = Path(__file__).resolve().parents[1] / "test/bob-harness"


@contextmanager
def dependency_server(archive):
    handler = partial(SimpleHTTPRequestHandler, directory=archive.parent)
    with ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
        worker = Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}/{archive.name}"
        finally:
            server.shutdown()
            worker.join()


def build(archive, command):
    with TemporaryDirectory(prefix="defold-bob-") as directory:
        project = Path(directory)
        for name in ("input", "main"):
            shutil.copytree(HARNESS / name, project / name)
        with dependency_server(archive) as url:
            settings = (HARNESS / "game.project").read_text(encoding="utf-8")
            if settings.count("[project]\n") != 1:
                raise SystemExit("expected one [project] section in the Bob fixture")
            (project / "game.project").write_text(
                settings.replace("[project]\n", f"[project]\ndependencies#0 = {url}\n", 1),
                encoding="utf-8",
            )
            subprocess.run(command, cwd=project, check=True)
        if not any(path.is_file() for path in (project / ".internal/lib").rglob("*.zip")):
            raise SystemExit("bob resolve did not fetch the library ZIP into .internal/lib")
        for output in (
            "main/harness.collectionc", "main/harness.scriptc", "shardpilot/sdk.luac",
            "shardpilot/crash.luac", "shardpilot/remote_config.luac", "game.arcd",
        ):
            if not (project / "build/default" / output).is_file():
                raise SystemExit(f"expected build output missing: build/default/{output}")


if __name__ == "__main__":
    build(Path(sys.argv[1]).resolve(strict=True), sys.argv[2:])
