# Documentation index

| Doc | Read it when |
|---|---|
| [BUILD.md](BUILD.md) | building, packaging, CI, version bumps |
| [DEVICE.md](DEVICE.md) | anything on the phone: deploy, launch, screenshots, touch, inspector, `atldbg` |
| [BENCHMARKING.md](BENCHMARKING.md) | measuring a change, running an A/B, before quoting any number |
| [COMPAT.md](COMPAT.md) | the SFOS compatibility shims and what still justifies each one |
| [../patches/SERIES.md](../patches/SERIES.md) | what the patch stack contains and in what order (generated) |
| [STREAMLINE-PLAN.md](STREAMLINE-PLAN.md) | the current cleanup plan for patches, config, docs |
| [investigations/](investigations/) | why a thing is the way it is, and which theories are already dead |

Working rules that apply to all of it:

- **Reproduce on device before changing behaviour.** No UI or engine behaviour
  change lands on a theory.
- **Root-cause before patching.** List every plausible cause and the cheapest
  observation that would disprove it, run the cheapest few, then patch what
  survives.
- **A feature touches every layer in one pass** — engine C++, QML/UI, settings
  storage, sailjail/D-Bus permissions. An engine-only runtime pref with no UI is
  incomplete.
- **Generate patches mechanically**: edit the tree, `git diff > patches/NNNN-name.patch`,
  validate with `git apply --check`. Hand-written hunks have repeatedly had wrong
  line counts.
- **Commit to `master`**; no feature branches. Push only when asked. Builds happen
  in CI, never locally.
