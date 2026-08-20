# Release

The ShardPilot Defold SDK is published as the latest release git tag plus a
GitHub Release (currently `v0.10.1` for both). This is an early alpha
pre-release: the API is unstable and may change before v1.

**Tag lag is normal, and the version above leads the tag.** In-tree version
claims move in the version-bump commit; the tag and GitHub Release are cut
from that commit's merge, afterwards. So between the merge and the tagging
step the version named here is **pending**, not published, and its archive URL
404s. `git tag -l` on a fresh fetch is the authority on what is actually
published, not this line.

**Do not fall back to an earlier tag.** This paragraph used to name the last
tag that "definitely resolves" as a fallback, and after `v0.10.1` that advice
pointed at an artifact carrying the internal material `v0.10.1` exists to stop
distributing — a runbook sending a reader back to the thing being withdrawn.
Measured across every tag: `v0.8.0`, `v0.8.1`, `v0.9.0`, `v0.9.1` and `v0.10.0`
carry all eight of those files, `v0.6.0` and `v0.7.0` carry two, and `v0.5.0`
and earlier predate them. If the pending tag 404s, WAIT for it.

**`v0.10.1` itself is an exception to the ordering below**, and it is worth
knowing so its tree does not look like a mistake. It was cut as a
deletion-only patch directly on top of `v0.10.0` rather than from a
version-bump merge, so it still declares `M.VERSION = "0.10.0"`. That was
deliberate: the tag's whole purpose was to carry a removal and be verifiable
as carrying only that, which putting a version bump in it would have defeated.

Release ordering: merge the version-bump commit — it moves every in-tree
version claim together, which `./scripts/check_versions.sh` enforces — then
immediately tag that merge commit as `v<version>` and publish the GitHub
Release from it (verify with `./scripts/check_versions.sh --release`, which
asserts the tag exists and points at HEAD).

`scripts/package_release.sh` prepares the reviewable ZIP of the Defold library
project files for a tagged release. Pin the Defold library dependency to the
release archive for the tag — see the README for the exact `game.project`
dependency URL.

Manual Defold/Bob release check:

```bash
java -jar bob.jar resolve build
```

Bob is distributed by Defold through GitHub Releases under `bob/bob.jar` and
through the `d.defold.com` archive addressed by engine sha1. Defold 1.12.0 and
newer require OpenJDK 25.

CI now runs this same resolve+build proof on every PR and push to `main`: the
`bob-build` job calls `scripts/ci_bob_build.sh`, which pins the Defold version,
engine sha1, and `bob.jar` sha256 (bump all three together, deliberately),
packages the working tree with `scripts/package_release.sh`, serves the ZIP
over localhost, and builds `test/bob-harness/` against it as a real library
dependency. That is a build-time proof only — it does not start the engine or
check runtime behavior.
