# The patch stack as a whole

Per-patch rationale now lives **inside each patch file**, as a header comment
above the first diff line (`patch` ignores leading text, so it costs nothing and
cannot drift from the diff it explains). `SERIES.md` is generated and indexes
them. This file covers what is true of the stack rather than of one patch.

## Shape of the stack

39 patches in two classes:

| Class | Count | What it is |
|---|---|---|
| Portability / build | 4 | Makes 2.52.x compile on the Ubuntu 24.04 runner against the SFOS sysroot. Behaviour-neutral. |
| Behaviour | 35 | Everything the browser actually needs the engine to do differently on this device. |

The four portability patches are one class of problem — a header that is not
self-sufficient, a missing `<cstdint>`/`<cstddef>`/`<span>`, a file using
`ENABLE()`/`USE()`/`WTF_EXPORT_PRIVATE` without including the header that owns
it — and together they are ~14k of the stack's diff lines and ~1,100 of its
1,308 touched files. They are also what breaks on every WPE bump.

**Do not hand-fix them on a bump: regenerate.** Apply, build, and re-derive the
insertions from the compile errors. The intended end state is to delete them
entirely in favour of a force-included prelude —
[../docs/STREAMLINE-PLAN.md](../docs/STREAMLINE-PLAN.md) A1.

## Rules that keep it maintainable

- **One patch per subsystem, not per idea.** Nine patches editing
  `CoordinatedBackingStoreProxy.cpp` meant nine ordering constraints replayed on
  every bump. A patch is split out only while its default is still OFF or
  unverified — that property, not authorship order, is what justifies isolation.
  Once it ships default-ON and device-validated, fold it into its subsystem
  patch.
- **Rationale goes in the patch header**, including the dead ends. Several
  headers exist mainly to stop a disproven theory being retried
  (`webkit-composite-scroll-sync`, `webkit-repaint-scope`).
- **Device numbers or it did not happen.** Headers quote build numbers and
  measurements; a patch whose A/B never cleared the noise floor gets reverted,
  not kept on faith.
- **`patches/disabled/`** holds patches deliberately not applied but worth
  keeping. They are never in the apply list.

## Still-provisional patches

These remain standalone precisely because they are not settled — default OFF or
shipped but not yet folded in. Check `deploy/runtime-common.sh` for what a build
actually enables.

| Patch | Why still separate |
|---|---|
| `webkit-damage-limited-composite-env` | default OFF, never A/B'd on device |
| `webkit-tile-buffer-skip-zero-env` | default OFF, A/B pending |
| `webkit-drop-tiles-when-hidden-env` | default OFF; frees ~1 GB of GPU tiles but needs a forced composite to land while hidden, i.e. the deadlock-prone area |
| `webkit-composite-skip-locked-layers-env` | the video-judder fix; verified in a 5×5 A/B on build 607 |
| `webkit-frame-trace-env` | pure tooling, kept separate because other patches call `atlFrameTrace()` |
| `webkit-glfence-disable-env` | escape hatch for the libhybris fence gap, not a feature |
| `webkit-clipboard-qt-hook` | inert until the qt5 plugin registers the hook |

## Retired

| Was | What happened |
|---|---|
| 40 portability / build patches | merged into `webkit-build-cmake-fixes` + `webkit-portability-{wtf-pal,jsc,webcore}` (2026-07-30). Byte-identical result. |
| 53 behaviour patches in 15 families | merged one per subsystem: scroll-degradation, tile-upload, composite-scroll-sync, kinetic-fling, scrollbar, image-subsampling, gst-media, svg, independent-scroll, repaint-scope, jsc-arm64-tuning, load-responsiveness, http-cache, texture-pool, memory-pressure (2026-07-30). Byte-identical result. |
| `webkit-style-smart-reconstruct` | dropped 2026-07-30. Device A/B proved it **inert** on cnn.com — byte-identical stylesheet-update decisions on and off — because the late `<style>` appends there are authoritative, so the PoC downgrade never fires. The real lever is running `analyzeStyleSheetChange` for authoritative append-only Contents updates; see memory `smart-reconstruct-inert-on-authoritative`. |
| `webkit-style-reconstruct-source-attr` | dropped with it: it was the diagnostic that produced that verdict, and the verdict is recorded. |
| `webkit-video-composite-tile-gate-env` | dropped 2026-07-30. Its own `schedupd` marker disproved it on device (`wt=0` — the compositor was not gated at the Idle-branch tile gate), and the real cause of the fullscreen-video stalls was the layer-lock contention that `webkit-composite-skip-locked-layers-env` fixes. |
| `patches/qt-bridge/*` | baked into the in-repo `qt5-plugin/` source; patch files deleted (see git history) |
| `patches/historical/BubblewrapLauncher-sfos-sandbox.patch` | was the prose source for `webkit-bubblewrap-sfos-sandbox`; rationale now in that patch's header, [../docs/COMPAT.md](../docs/COMPAT.md) and [../docs/investigations/sandbox-bubblewrap.md](../docs/investigations/sandbox-bubblewrap.md) |

Anything retired is recoverable from git history — that is the archive, not a
directory of dead files.

## Verifying a consolidation

Any future merge or removal should be proven, not argued —
`scripts/verify-patch-stack.sh` does it in minutes with no compiler:

1. Extract the pristine upstream tarball.
2. Copy out only the files the stack touches (~24 MB, not 1.5 GB).
3. Apply the stack in `patches.sh` order; hash the pristine→patched diff (hashing
   the *diff* rather than the tree keeps the value comparable when the
   touched-file list itself changes).
4. A merge is correct iff the hash is unchanged:
   `scripts/verify-patch-stack.sh <hash>` exits non-zero otherwise.
5. For a *removal*, re-apply the removed patches on top of the new tree and check
   the hash returns to the old one — that proves the delta is exactly the
   intended patches and nothing else.

Current stack hash (39 patches, 2.52.5):
`fe537d25f73cdddaa6e2117664152ef4e7ffe668c5397670c30f1703831e582f`

Cheap (minutes, no compiler) and it catches every ordering and context mistake
that would otherwise surface as a CI build failure or, worse, as a silently
dropped hunk. It found one during this consolidation: a hand-written hunk header
with an inflated line count silently swallowed the next file's section.
