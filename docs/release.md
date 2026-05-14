# Release

This repository currently contains public-preview source only. No GitHub
Release, tag, package registry artifact, or release ZIP is published in this
wave.

`scripts/package_release.sh` prepares a future reviewable ZIP containing the
Defold library project files when a later explicit release prompt authorizes a
release. It does not publish tags, GitHub Releases, package registry artifacts,
websites, DNS, TLS, or production infrastructure.

Manual Defold/Bob release check:

```bash
java -jar bob.jar resolve build
```

Bob is distributed by Defold through GitHub Releases under `bob/bob.jar`.
Defold 1.12.0 and newer require OpenJDK 25. CI does not hardcode a Bob download
URL in this wave because no deterministic approved Bob version is being
published here.
