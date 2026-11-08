# bob-build harness

The CI `bob-build` job packages the working tree, serves its ZIP on a
kernel-assigned loopback port, and writes the bound URL into a private copy
of this consumer project. Bob resolves the dependency and compiles the
`shardpilot.*` modules required by `main/harness.script`.

Run it locally from the repository root (needs OpenJDK 25, `python3`,
`curl`, `zip`, `unzip`):

```bash
./scripts/ci_bob_build.sh
```

Scope honesty: this is a build-time proof only — bob fetches the library
ZIP and compiles the modules. Nothing here starts the engine or checks
runtime behavior.
