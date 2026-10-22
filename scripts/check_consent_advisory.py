#!/usr/bin/env python3
"""Run advisory reference scenes against recorded and counterfactual sources."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

module = Path("shardpilot/consent_policy.lua")
original = module.read_bytes()
baseline = subprocess.check_output([
    "git", "show", "3dff6692f593a4d29878e2742b0b5f77de6d76f7:" + str(module)])
copy = b"decision.advisory = copy_value(plan.advisory, 0)"
validation = b"local refusal = advisory_refusal(plan.advisory)"
assert original.count(copy) == original.count(validation) == 1
variants = [
    ("baseline", baseline, "advisory golden reaches the host"),
    ("fixed", original, None),
    ("inverse", original.replace(copy, b"decision.advisory = nil"), "advisory golden reaches the host"),
    ("validation", original.replace(validation, b"local refusal = nil"), "invalid_response"),
    ("restored", original, None),
]
directory = Path(tempfile.mkdtemp(prefix="consent-reference-"))
for phase, source, cause in variants:
    fixture = directory / (phase + ".lua")
    fixture.write_bytes(source)
    command = ('package.preload["shardpilot.consent_policy"]=function() '
               'return assert(loadfile(' + json.dumps(str(fixture)) + '))() end; '
               'dofile("test/test_consent_policy.lua")')
    run = subprocess.run([sys.argv[1], "-e", command], capture_output=True, text=True)
    output = run.stdout + run.stderr
    assert run.returncode == (1 if cause else 0), (phase, run.returncode, output)
    assert (cause or "shardpilot defold consent-policy tests passed") in output, (phase, output)
    assert "advisory golden reached validation" in run.stdout, (phase, output)
    print(json.dumps({"phase": phase, "interpreter": sys.argv[1], "exit": run.returncode,
                      "source_sha256": hashlib.sha256(source).hexdigest(), "cause": cause}))
    if cause:
        print(run.stderr)
assert module.read_bytes() == original, "checkout source changed during counterfactuals"
