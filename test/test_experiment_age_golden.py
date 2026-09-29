"""Pin the approved projection bytes, not merely the scanner's line locations."""
import hashlib
from pathlib import Path
import sys

EXPECTED = {
    "adult.json": "84669986d3c1ead97db9fc23587c41324928cfa66d3670923960e7aa81c94052",
    "undeclared.json": "d870fcfacf2bee1cd17dc1a501cbcd0edf90a01e9f0823c067b5171a7aa5e2e8",
    "unknown.json": "d870fcfacf2bee1cd17dc1a501cbcd0edf90a01e9f0823c067b5171a7aa5e2e8",
    "under_threshold.json": "b5dd88dc6b4bea663e5612b5ca95a874c29995439eb85ce6b8381a0b67192761",
}
root = Path(__file__).parent / "fixtures" / "experiment-age"
failed = []
for name, expected in EXPECTED.items():
    if hashlib.sha256((root / name).read_bytes()).hexdigest() != expected:
        failed.append(name)
if failed:
    print("FAIL golden SHA-256: " + ", ".join(failed))
    sys.exit(1)
print("PASS golden SHA-256: 4/4 approved projections")
