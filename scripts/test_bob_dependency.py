from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
from urllib.error import URLError
from urllib.request import ProxyHandler, build_opener

from bob_dependency import build, dependency_server


def read(url):
    with build_opener(ProxyHandler({})).open(url, timeout=2) as response:
        return response.read()


class BobDependencyTests(unittest.TestCase):
    def test_overlapping_servers_keep_their_own_archive(self):
        with TemporaryDirectory() as first, TemporaryDirectory() as second:
            archive = Path(first) / "library.zip"
            other = Path(second) / archive.name
            archive.write_bytes(b"first archive")
            other.write_bytes(b"second archive")
            with dependency_server(other) as other_url:
                with dependency_server(archive) as url:
                    self.assertNotEqual(url, other_url)
                    self.assertEqual(read(url), b"first archive")
                    self.assertEqual(read(other_url), b"second archive")
                with self.assertRaises(URLError):
                    read(url)
                self.assertEqual(read(other_url), b"second archive")

    def test_failed_bind_cannot_use_an_existing_listener(self):
        with TemporaryDirectory() as directory:
            archive = Path(directory) / "library.zip"
            archive.write_bytes(b"foreign archive")
            with dependency_server(archive) as foreign_url:
                with patch("bob_dependency.ThreadingHTTPServer", side_effect=OSError("bind failed")):
                    with patch("bob_dependency.subprocess.run") as bob:
                        with self.assertRaisesRegex(OSError, "bind failed"):
                            build(archive, ["bob"])
                        bob.assert_not_called()
                self.assertEqual(read(foreign_url), b"foreign archive")


if __name__ == "__main__":
    unittest.main(verbosity=2)
