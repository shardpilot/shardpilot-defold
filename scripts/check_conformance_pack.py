#!/usr/bin/env python3
"""Prove test/conformance/v1 is the published corpus: digests, manifest, roster and source record.
test/test_conformance.lua reads the corpus without hashing it."""
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else "test/conformance")
corpus = root / "v1"
source = json.loads((root / "source.json").read_text())
manifest = json.loads((corpus / "manifest.json").read_text())
roster = json.loads((corpus / "roster.json").read_text())
failures = []

# The documented recipe: sha256sum bodies/* | LC_ALL=C sort | sha256sum, run inside v1/.
bodies = sorted((corpus / "bodies").iterdir(), key=lambda path: path.name.encode())
lines = sorted(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  bodies/{p.name}\n".encode() for p in bodies)
digest = hashlib.sha256(b"".join(lines)).hexdigest()
for name, value in (("manifest", manifest["corpus_sha256"]), ("source record", source["corpus_sha256"])):
    if value != digest:
        failures.append(f"corpus_sha256 {digest} does not match the {name} ({value})")
if source.get("carrier") != "shardpilot/developers" or len(source.get("commit", "")) != 40:
    failures.append("source.json must name the carrier repository and a full documentation commit")

listed = set()
for case in manifest["cases"]:
    for side in ("request", "response"):
        entry = case[side]
        if entry.get("file") is None:
            continue
        listed.add(entry["file"])
        if not (corpus / entry["file"]).is_file():
            continue  # reported below as missing on disk
        data = (corpus / entry["file"]).read_bytes()
        if len(data) != entry["bytes"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
            failures.append(f"{case['id']} {side}: bytes or sha256 differ from the manifest")
on_disk = {f"bodies/{p.name}" for p in bodies}
failures += [f"body file not in the manifest: {name}" for name in sorted(on_disk - listed)]
failures += [f"manifest file missing on disk: {name}" for name in sorted(listed - on_disk)]

rostered = [case_id for group in roster["cases"] for case_id in group[3]]
manifest_ids = [case["id"] for case in manifest["cases"]]
if sorted(rostered) != sorted(manifest_ids) or len(set(rostered)) != len(rostered):
    failures.append("roster case ids differ from the manifest's")
if roster["corpus"] != manifest["corpus"] or roster["version"] != manifest["version"]:
    failures.append("roster and manifest name different corpora")

for failure in failures:
    print("FAIL", failure)
print(f"conformance corpus {manifest['version']}: {len(manifest_ids)} cases, {len(on_disk)} bodies, sha256 {digest}")
sys.exit(1 if failures else 0)
