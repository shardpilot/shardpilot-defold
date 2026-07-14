# Release

The ShardPilot Defold SDK is published as the latest release git tag
(currently `v0.7.0`) and, for some releases, a GitHub Release (the latest
GitHub Release is `v0.5.0`; `v0.6.0` and `v0.7.0` are tags without a GitHub
Release). The working tree carries `v0.8.0`, which is tagged when it ships.
This is an early alpha pre-release: the API is unstable and may change
before v1.

`scripts/package_release.sh` prepares the reviewable ZIP of the Defold library
project files for a tagged release. Pin the Defold library dependency to the
release archive for the tag — see the README for the exact `game.project`
dependency URL.

Manual Defold/Bob release check:

```bash
java -jar bob.jar resolve build
```

Bob is distributed by Defold through GitHub Releases under `bob/bob.jar`.
Defold 1.12.0 and newer require OpenJDK 25. CI does not hardcode a Bob download
URL in this wave because no deterministic approved Bob version is being
published here.
