# atlantic-engine

Engine, packaging and compatibility work for **Atlantic Browser** — a WPE
WebKit browser for **Sailfish OS**. The Silica Qt/QML UI lives in the companion
repo `SpecSierra/atlantic-browser`; the two ship together.

| | |
|---|---|
| Sailfish OS target | **5.1.0.11** (Pispala) |
| WPE WebKit | **2.52.6** |
| Atlantic Browser | **1.0.0.stable** |
| Local patches | 39 ([patches/SERIES.md](patches/SERIES.md)) |
| Builds | CI only — push to `master` |
| Packages | `https://specsierra.github.io/atlantic-engine/aarch64/` |

## Documentation

| Doc | Read it when |
|---|---|
| [docs/BUILD.md](docs/BUILD.md) | building, packaging, CI, version pins, bump traps |
| [docs/DEVICE.md](docs/DEVICE.md) | anything on the phone: deploy, launch, screenshots, touch, inspector, `atldbg` |
| [docs/BENCHMARKING.md](docs/BENCHMARKING.md) | measuring a change or running an A/B — read before quoting a number |
| [docs/COMPAT.md](docs/COMPAT.md) | the SFOS shims and sandbox posture |
| [patches/SERIES.md](patches/SERIES.md) | what the patch stack contains, in apply order (generated) |
| [docs/investigations/](docs/investigations/) | why something is the way it is, and which theories are already dead |
| [docs/STREAMLINE-PLAN.md](docs/STREAMLINE-PLAN.md) | the current cleanup plan |

## Layout

| Path | Contents |
|---|---|
| `versions.env` | every version pin and compatibility flag |
| `scripts/` | build entry points, `patches.sh`, CI wrapper, `devtools/` |
| `patches/` | local WebKit and engine patches; apply order set by `scripts/patches.sh` |
| `qt5-plugin/` | self-contained Qt5 WPE bridge, overlaid onto the pinned WebKit |
| `adblock-engine/`, `web-extension/` | Brave/Rust blocker and the WebProcess extension that runs it |
| `deploy/` | runtime env wrapper, helper-process wrappers, systemd units, profiles |
| `shims/compat/` | C shims for the remaining SFOS/hybris gaps |
| `rpm/`, `build-rpms-native.sh` | packaging |

Full layout: [docs/BUILD.md](docs/BUILD.md).

## Working rules

- **Reproduce on device before changing behaviour** — no behaviour change on a theory.
- **Root-cause first**: list plausible causes and the cheapest observation that
  disproves each, run the cheapest few, patch only what survives.
- **Ship optimizations behind an env flag, default OFF**, then a 5×5 interleaved
  on-device A/B. Flip the default only if the delta clears the noise floor; if the
  flag is inert, revert it.
- **A feature touches every layer in one pass** — engine C++, QML/UI, settings
  storage, sailjail/D-Bus permissions. List the layers and confirm the list before
  implementing; engine-only is incomplete, and finish with an on-device check that
  the user-visible behaviour works.
- **Generate patches mechanically**: edit the tree, `git diff > patches/…patch`,
  validate with `git apply --check`. Hand-written hunks have repeatedly been wrong.
- **Commit to `master`**, no feature branches; push only when asked.
- Keep a live `INVESTIGATION.md` (CONFIRMED / RULED OUT / OPEN) while investigating;
  when it concludes, add a status header and move it to `docs/investigations/`.

## License

First-party code: **MPL-2.0** (`LICENSE.txt`), matching `atlantic-browser` and the
Brave/Rust `adblock` engine. Third-party code keeps its original license and is
**not** relicensed:

| Path | License | Origin |
|---|---|---|
| `qt5-plugin/` | LGPL-2.1-or-later | WebKit WPE Qt API (Igalia S.L / Zodiac Inflight Innovations) |
| `patches/webkit/` | per WebKit | LGPL-2.1 / BSD-2-Clause |
| `adblock-engine/` | MPL-2.0 | wraps the MPL-2.0 `adblock` crate (Brave) |

Per-file `SPDX-License-Identifier` headers take precedence over this summary.
