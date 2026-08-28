# Building and packaging

**Builds run in CI on the build host, never locally.** Pushing to `master`
triggers `.github/workflows/build-atlantic-packages.yml` on the self-hosted
`builder-arm64` runner (labels `self-hosted`, `Linux`, `ARM64`, `atlantic`), which
builds the engine, WebKit, the Qt5 bridge and the UI, then produces signed RPMs.
`workflow_dispatch` runs it manually.

## Version pins

All pins live in `versions.env`; nothing should hard-code a version.

| Item | Pin |
|---|---|
| SFOS sysroot / target | `5.1.0.11` |
| WPE WebKit | `2.52.6` |
| libwpe | `1.17.0` |
| WPEBackend-fdo | `1.17.0` |
| libepoxy | `1.5.11` (patched) |
| Atlantic Browser | `1.3.0` |
| Qt5 plugin source | in-repo `qt5-plugin/` (the `2.52.1` label survives only for RPM tarball naming) |

`versions.env` also holds the compatibility flags ([COMPAT.md](COMPAT.md)) and the
filter-list URLs and hashes.

## Entry points

| Script | Does |
|---|---|
| `build-all.sh` | orchestrator over the split entry points below |
| `scripts/bootstrap-host.sh` | host deps, sysroot download, workspace bootstrap |
| `scripts/build-engine.sh` | libwpe, libepoxy, WPEBackend-fdo |
| `scripts/build-webkit.sh` | WPE WebKit + the `qt5-plugin/` overlay |
| `scripts/build-ui.sh` | Atlantic UI against the staged engine |
| `scripts/patches.sh` | applies the patch stack — order is load-bearing ([patches/SERIES.md](../patches/SERIES.md)) |
| `scripts/verify-patch-stack.sh` | applies the stack to a pristine tree and hashes the result — the cheap bump/consolidation guard, no compiler needed |
| `scripts/package-rpms.sh` → `build-rpms-native.sh` | RPM staging and packaging |
| `scripts/ci-build.sh` | the CI wrapper around all of it |

## Repo layout

| Path | Contents |
|---|---|
| `patches/webkit/`, `patches/engine/` | the local patch stack, applied in `patches.sh` order; each patch carries its own rationale as a header comment |
| `patches/disabled/` | kept but never applied |
| `qt5-plugin/` | self-contained Qt5 WPE bridge (adapted from upstream qt6), overlaid onto the pinned WebKit at build time |
| `adblock-engine/` | Brave/Rust adblock engine: `libatlantic_adblock.so` + the `builder` that compiles lists into `engine.dat` |
| `web-extension/` | WebProcess extension running the Brave engine on every resource request — the only network blocker |
| `data/content-blocker/` | build-time download target for EasyList/EasyPrivacy (gitignored, fetched by `build-rpms-native.sh`) |
| `deploy/` | helper-process wrappers, `runtime-common.sh` (shared runtime env), systemd units, audio/firejail profiles |
| `shims/compat/` | C shims and linker maps for the remaining SFOS gaps |
| `cmake/`, `sfos-toolchain*.cmake`, `native-meson.ini` | toolchains and cache presets shared by the script and spec paths |
| `rpm/`, `setup-rpmbuild.sh` | RPM specs and rpmbuild staging |
| `scripts/devtools/` | device debugging and benchmark harnesses — dev-only, never packaged |

## CI paths

CI builds in isolated paths so it never clobbers the live `/opt/wpe-sfos` tree used
for manual device work:

```
CI_ROOT=/opt/github-runner/builds/<run-id>-<attempt>
WPE_PREFIX=$CI_ROOT/wpe-sfos-prefix
OUT=$CI_ROOT/wpe-sfos-rpms
STAGING=$CI_ROOT/wpe-sfos-stage
```

The WebKit source and install prefix live under a stable cache root
(`/opt/github-runner/cache/atlantic-build`) so ccache sees consistent paths between
runs; the wrapper runs a smoke test that must record a cache hit before the full
build starts. Release/iteration tracks the CI run (`RPM_ITERATION=<run>.<attempt>`)
so `zypper up` always sees a newer version.

Artifacts per run: `build.log`, `summary.txt`, `rpms/*.rpm`, a signed
`rpm-repo/aarch64/` tree with `repodata/`, the public signing key, and a
ready-to-use `atlantic-ci.repo`.

Signing secrets: `ATLANTIC_RPM_SIGNING_KEY`, `ATLANTIC_RPM_SIGNING_KEY_ID`,
`ATLANTIC_RPM_SIGNING_PASSPHRASE`.

Successful `master` builds publish the same rpm-md tree to the `gh-pages` branch →
`https://specsierra.github.io/atlantic-engine/aarch64/`. That is how the phone gets
updates ([DEVICE.md](DEVICE.md)).

## Packaging traps

- **qmake `INSTALLS` never runs** in the native RPM path — browser data files must
  be explicitly `cp`'d in `build-rpms-native.sh`, or they silently ship missing.
- **Sailjail permissions** are declared on the `Permissions` line in
  `build-rpms-native.sh`; a missing one fails silently at runtime (e.g. the file
  picker needed `MediaIndexing`).
- **Feature-flag cmake hashes** force a WebKit rebuild when they change — expect the
  long build, not a cached one.
- **CI `paths-filter`** means a change under `data/**` or a toolchain path may not
  trigger a build. Check the filter before concluding "CI ignored my commit".
- **Version bumps**: see [investigations/](investigations/) and validate the patch
  stack **sequentially** — isolated dry-runs give false failures. Triple-check
  sonames: the triple lives in `Source/cmake/OptionsWPE.cmake`
  (`CALCULATE_LIBRARY_VERSIONS_FROM_LIBTOOL_TRIPLE`, `(current-age).age.revision`).
  2.52.6 = `10 10 9` → `libWPEWebKit-2.0.so.1.9.10`; the `.so.1` soname that
  dependents bind to is unchanged, and nothing in packaging hardcodes the
  versioned filename.

## Open packaging questions

- A fresh install should match the staged tree exactly, with no manual device-side
  fixes. It does not yet.
- Decide whether the older RPM specs beyond the WebKit pair get aligned with the
  native packaging path or retired.

## Tests

```bash
python -m unittest discover -s tests -p 'test_*.py' -v
```

Covers the Python CLI helpers (`scripts/write-runtime-env.py`,
`scripts/write-webkit-feature-flags.py`) and runs in
`.github/workflows/cli-tests.yml`.

## Build philosophy

Maintain this like a browser port: engine updates routine, local patches named and
small, runtime layout explicit, UI thin. If a change makes the next engine bump
easier, it is probably the right change.
