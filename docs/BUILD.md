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
| WPE WebKit | `2.54.2` |
| libwpe | `1.17.0` |
| WPEBackend-fdo | `1.17.0` |
| libepoxy | `1.5.11` (patched) |
| Atlantic Browser | `1.7.0` |
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
| `scripts/pgo/` | profile-guided optimisation: instrumented build, headless training, host A/B ([PGO](#pgo-profile-guided-optimisation)) |

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
build starts. WebCore and WebKit build with CMake precompiled headers, which
ccache only caches under `sloppiness=pch_defines,time_macros` (set in
`scripts/common.sh`); without it ~1560 objects show up as "Could not use
precompiled header" and every run recompiles them. Release/iteration tracks the CI run (`RPM_ITERATION=<run>.<attempt>`)
so `zypper up` always sees a newer version.

Artifacts per run: `build.log`, `summary.txt`, `rpms/*.rpm`, a signed
`rpm-repo/aarch64/` tree with `repodata/`, the public signing key, and a
ready-to-use `atlantic-ci.repo`.

Signing secrets: `ATLANTIC_RPM_SIGNING_KEY`, `ATLANTIC_RPM_SIGNING_KEY_ID`,
`ATLANTIC_RPM_SIGNING_PASSPHRASE`.

Successful `master` builds publish the same rpm-md tree to the `gh-pages` branch →
`https://specsierra.github.io/atlantic-engine/aarch64/`. That is how the phone gets
updates ([DEVICE.md](DEVICE.md)).

## PGO (profile-guided optimisation)

The release engine is Clang 18 + ThinLTO at `-O3`. PGO adds what the compiler
cannot guess: which code actually runs. Hot paths get inlined and laid out
together; code that never ran in training is built for size and moved aside.

**Status: opt-in, default OFF.** `Build Atlantic packages` sets `ATLANTIC_PGO=off`.
Flip it to `use` only after the on-device A/B ([BENCHMARKING.md](BENCHMARKING.md)).

| `ATLANTIC_PGO` | Build |
|---|---|
| `off` | no profile involved |
| `generate` | instrumented engine — training on the build host only, never packaged |
| `use` | release build optimised with `ATLANTIC_PGO_PROFILE`; fails if the profile is missing |

The **PGO** workflow (`.github/workflows/pgo.yml`, manual) does the whole loop and
publishes nothing:

| Step | Script | Result |
|---|---|---|
| 1. instrumented build | `scripts/pgo/build-instrumented.sh` | own cache root, `-fprofile-generate` |
| 2. training | `scripts/pgo/train.sh` | `/opt/github-runner/cache/atlantic-pgo/profiles/atlantic.profdata` (+ `.info`) |
| 3. optimised build | `scripts/ci-build.sh` with `ATLANTIC_PGO=use` | unsigned test RPMs in the run's artifact |
| 4. host A/B | `scripts/pgo/bench.sh` | Speedometer 3.1, last published build vs PGO, in the run summary |

```bash
gh workflow run PGO                       # full loop, a few hours cold
gh workflow run PGO -f reuse_profile=true # steps 3-4 only
```

Test RPMs carry release `0.pgo<run>`, below every published build: install with
`zypper in --oldpackage ./*.rpm`; the next `zypper up` returns to the channel.

How training works:

- `scripts/pgo/atl-headless.c` drives the engine with **no display**: WPEBackend-fdo
  in SHM mode, Mesa llvmpipe for GL. It loads each URL of a workload file, scrolls
  it, and moves on. It runs any engine build, so it doubles as the host benchmark.
- `scripts/pgo/workloads/*.txt` is the workload: Speedometer, text pages, news
  front pages, canvas/SVG/WebGL. Each file is one browser session and runs twice,
  with CPU tile painting (Adreno path) and with Skia GPU painting (Mali path).
- `scripts/pgo/pgo-exit-hook.c` is linked into the instrumented binaries and
  flushes the counters every 15 s and on `_exit()`. WebKit helper processes rarely
  reach the `atexit()` handler the LLVM runtime relies on.

Traps:

- **Untrained code gets slower, not just "not faster".** A feature absent from the
  workload (video, WebRTC, a site-specific path) is compiled as cold. Widen the
  workload before blaming PGO for a regression there.
- **The profile describes the build host**, not the phone: llvmpipe instead of
  hybris GL, no gst-droid, a 16-core CPU. DOM/style/layout/JS transfer well;
  compositing and media are the least represented.
- **A profile is tied to the sources.** After a patch or a WebKit bump, functions
  that changed fall back to unprofiled (silently — the warnings are disabled).
  Re-run the PGO workflow after every WebKit bump and after large patches.
- `train.sh` refuses a profile in which too few functions ran (no network, a
  crash at startup): using it would mark the whole engine cold.
- The profile lives only on the build host (and in the workflow artifact for 30
  days). If the host is rebuilt, `ATLANTIC_PGO=use` fails until PGO is re-run.
- **Static functions are keyed by source path** as the compiler sees it. ccache's
  `CCACHE_BASEDIR` turns that into a path relative to the build directory, which
  is why the three trees (release, generate, use) can live under different cache
  roots. Keep `CCACHE_BASEDIR` = the cache root and the layout below it identical,
  or ~10% of the functions silently lose their profile.
- **Known gap:** on the build host, script-heavy front pages (BBC, Guardian, Le
  Monde) intermittently stop producing frames a few seconds in — the WebProcess
  main thread was caught parked in `JSC::Heap::runEndPhase`. Seen on the plain
  release engine too, with either GC increment setting and with the phone's JSC
  thread counts; cause open. Those sites still train their load phase, not their
  scrolling. Check the `left after N frames` lines in `train.log`.
- armv7hl builds with GCC and stays without PGO.

## armv7hl (32-bit) build

Older phones run 32-bit (armv7hl) Sailfish OS. `.github/workflows/build-atlantic-armv7.yml`
builds the same packages for them, **by hand only** (`workflow_dispatch`), on the same
runner. `scripts/armv7/ci-build-armv7.sh` makes a 32-bit Ubuntu 24.04 (armhf) chroot once
(`/opt/github-runner/cache/atlantic-armv7/armhf-noble`) and runs the usual `ci-build.sh`
in it under `setarch linux32`. The host's cores run 32-bit ARM code natively, so this is
a native build, not emulation, against Ubuntu's armhf libraries and the armv7hl SDK
target. Everything that differs per architecture is in `scripts/arch.sh` (`ATL_ARCH`,
library directory `lib` instead of `lib64`, CPU flags, toolchain files
`*-armv7hl.cmake` / `native-meson-armv7hl.ini`). The browser takes the library directory
as `SFOS_LIBDIR` (its `defaults.pri`).

- GCC only: the Clang/ThinLTO toolchain is aarch64-only, and a 32-bit linker has 4 GB.
- Caches, sysroot and ccache live apart under `/opt/github-runner/cache/atlantic-armv7`.
- Not published to GitHub Pages (the aarch64 publish is `force_orphan` and would wipe
  it): the RPMs are the run's artifact, and with `publish_preview` the assets of the
  rolling `armv7hl-preview` pre-release.

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
  2.54.2 = `12 5 11` → `libWPEWebKit-2.0.so.1.11.5` (2.54.1 was `12 4 11` →
  `.so.1.11.4`); the `.so.1` soname that dependents bind to is unchanged, and
  nothing in packaging hardcodes the versioned filename.

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
