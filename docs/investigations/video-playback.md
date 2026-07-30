> **Status: SHIPPED** — Hardware decode via `droidvdec` is the default; see also `video-fullscreen-choppiness.md` for the compositor-lock fix that landed in build 607.
>
> Archived `video-playback-plan.md` (build host `/root`), 2026-07-30.

# Atlantic Browser — Video Playback: Deep Plan & Status

Goal: smoother, faster, less crashy video. All findings reproduced on-device
(Xperia 10 II, SFOS **5.1.0.7**, build 241).

## Diagnosis (on-device evidence)

The video pipeline today: GStreamer **software** decode (`avdec_h264`, FFmpeg) →
`webkitvideosink` (system-memory BGRA, because `USE_GSTREAMER_GL=OFF`) →
WebProcess Skia compositing → WPEBackend-fdo EGLImage export → Qt5 plugin
(`glEGLImageTargetTexture2DOES`) → QSG texture.

Measured, 1080p H.264 (Big Buck Bunny):
- Software `avdec_h264`: **~27%** of a big core sustained; the bottleneck.
- Hardware `droidvdec` (Venus via droidmedia): **~15%** CPU, **0 dropped/134**,
  `mediaswcodec` idle (= true HW, not Android SW), **no crash on 5.1**.

Key facts:
- HW decode was disabled by `runtime-common.sh` (`droidvdec:0`) for an SFOS-5.0
  hybris-EGL crash that **does not recur on 5.1**.
- `/dev/dri/renderD128` **exists** on 5.1.0.7 — the cmake comment claiming it is
  absent is **stale** (relevant to Phase 3).
- gst-droid exposes only avc/hevc/mp4v → VP8/VP9 auto-fall back to software
  `vpxdec`; ranking droidvdec up cannot break YouTube/VP9.
- Crash handling connected to **`web-process-crashed`** — removed in WebKit 2.20;
  connect failed at runtime (GLib-CRITICAL). Crash detection/recovery was dead.

## Phase 1 — HW decode + safety (DONE, runtime-only, validated)
`atlantic-engine/deploy/runtime-common.sh`:
- Default flipped to **enable `droidvdec` (rank 300)**, `droidvenc` off, software
  as automatic fallback. Kill-switch: `ATLANTIC_DISABLE_HW_DECODER=1`.
- Added `WEBKIT_GST_VIDEO_DECODING_LIMIT=1920x1080@60` — blocks pathological 4K
  *software* VP9 (OOM risk) while leaving HW H.264/H.265 1080p60 in range.

## Phase 2 — Crash resilience (DONE in source, needs CI build)
`atlantic-browser/apps/wpe/WPEWebPage.{cpp,h}`:
- Fixed signal → **`web-process-terminated`** (correct `VOID__ENUM` signature),
  restoring the crash UI, plus a **one-shot auto-reload** (`m_autoRecovered`,
  re-armed on successful load) so transient WebProcess deaths self-heal without
  looping a reload on a deterministically-crashing page.

## Phase 3 — PROPOSED (deferred, higher risk)
Now that `renderD128` exists, revisit `USE_GSTREAMER_GL` / GPU process so decoded
frames stay GPU-side (zero-copy), killing the remaining ~15% colorconvert+upload
CPU and reducing tearing. Must be tested carefully on-device given the
blank-page history (see memory: blank-web-content-issue, bubblewrap-sandbox).
Candidate sub-steps: (a) enable `USE_GSTREAMER_GL` only; (b) DMABUF export path
in WPEQtViewBackend; (c) gate GPU process on a runtime renderD128 probe.

## Rollout
Phase 1 takes effect on next engine RPM rebuild + `zypper up` (or test now by
exporting the two env vars). Phase 2 requires an atlantic-browser rebuild via CI.
Validate after deploy: play 1080p H.264, confirm `droidvdec` plugged + 0 dropped.
