# bob-build harness

Minimal Defold consumer project for the CI `bob-build` job. Its
`game.project` declares the ShardPilot library as a normal Defold
dependency, but the dependency URL points at `127.0.0.1:8910`: the lane
driver (`scripts/ci_bob_build.sh`) packages the WORKING TREE with
`scripts/package_release.sh` and serves that ZIP locally, so
`java -jar bob.jar resolve build` proves the current tree — not a
published tag — still resolves and compiles as a real library dependency
(`main/harness.script` requires the `shardpilot.*` modules).

Run it locally from the repository root (needs OpenJDK 25, `python3`,
`curl`, `zip`, `unzip`):

```bash
./scripts/ci_bob_build.sh
```

Scope honesty: this is a build-time proof only — bob fetches the library
ZIP and compiles the modules. Nothing here starts the engine or checks
runtime behavior.
