# Release

The ShardPilot Defold SDK is published as the latest release git tag plus a
GitHub Release (currently `v0.9.1` for both). This is an early alpha
pre-release: the API is unstable and may change before v1.

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
