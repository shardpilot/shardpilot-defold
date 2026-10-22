#!/usr/bin/env python3
"""Run advisory reference scenes against current-source counterfactuals."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

module = Path("shardpilot/consent_policy.lua")
original = module.read_bytes()
copy = b"decision.advisory = copy_value(plan.advisory, 0)"
validation = b"local refusal = advisory_refusal(plan.advisory)"
assert original.count(copy) == original.count(validation) == 1
variants = [
    ("fixed", original, None),
    ("inverse", original.replace(copy, b"decision.advisory = nil"), "advisory golden reaches the host"),
    ("validation", original.replace(validation, b"local refusal = nil"), "invalid_response"),
    ("restored", original, None),
]
directory = Path(tempfile.mkdtemp(prefix="consent-reference-"))
suite = Path("test/test_consent_policy.lua")
# Model an independent earlier test added alongside an unrelated source extension.
earlier_suite = directory / "earlier-suite.lua"
earlier_suite.write_bytes(b'require "shardpilot.consent_policy"\n'
                          b'assert(consent_reference_revision == 2, "earlier independent test")\n'
                          b'print("earlier independent test passed")\n' + suite.read_bytes())
for earlier in (False, True):
    for phase, source, cause in variants:
        if earlier:
            source = b"_G.consent_reference_revision = 2\n" + source
        fixture = directory / (phase + str(earlier) + ".lua")
        fixture.write_bytes(source)
        command = ('package.path="./?.lua;./?/init.lua;"..package.path; '
                   'package.preload["shardpilot.consent_policy"]=function() '
                   'return assert(loadfile(' + json.dumps(str(fixture)) + '))() end; '
                   'dofile(' + json.dumps(str(earlier_suite if earlier else suite)) + ')')
        run = subprocess.run([sys.argv[1], "-e", command], capture_output=True, text=True)
        output = run.stdout + run.stderr
        assert run.returncode == (1 if cause else 0), (phase, earlier, run.returncode, output)
        assert (cause or "shardpilot defold consent-policy tests passed") in output, (phase, output)
        assert "advisory golden reached validation" in run.stdout, (phase, output)
        if earlier:
            assert "earlier independent test passed" in run.stdout, (phase, output)
        print(json.dumps({"phase": phase, "earlier_test": earlier, "interpreter": sys.argv[1],
                          "exit": run.returncode, "source_sha256": hashlib.sha256(source).hexdigest(),
                          "cause": cause}))
        if cause:
            print(run.stderr)
assert module.read_bytes() == original, "checkout source changed during counterfactuals"
