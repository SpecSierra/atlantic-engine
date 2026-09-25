# Hardware video decode on the Jolla Phone 2 — plan

Status: **FIXED, verified on 712** (2026-09-25): gst-droid drain deadlock on a duplicate STREAM_START from legacy playbin, fixed by `patches/webkit/webkit-gst-droid-dedup-stream-start.patch`. HW decode is on for the Jolla; the Codec2 auto-software fallback has been removed.
automatically by the Codec2-only detection (engine `f5bd9de`, browser `8811ff52`).
The Xperia 10 II must keep working through every step below: it is still a
shipping target.

## What we know (device evidence)

| Fact | Evidence |
|---|---|
| Jolla vendor = Android 16, **Codec2 only** (`c2.mtk.*`; OMX names are only `<Alias>`) | `/vendor/etc/media_codecs_c2.xml` |
| HW decoders available: H.264, HEVC, VP9, AV1 (+ `.secure`) | same file |
| droidmedia uses `android::MediaCodec`, so Codec2 is reachable | `libdroidmedia.so` symbols; `CCodecWatchdog`/`CodecLooper` threads in the WebProcess |
| **Jolla Gallery plays video fine** with the same droidmedia stack | user, 2026-09-25 |
| In Atlantic, droidvdec **hangs**: 0 frames, `HAVE_NOTHING`, all 7 codec threads in `futex_wait`. Without gdb the WebProcess dies ~10 s later | gdb-attached single test; `/tmp/atl-dbg/stuck-threads.txt` |
| ~12 of those crashes in a row wedged the Android media stack → reboot needed | 2026-09-25 |
| No `libI420colorconvert.so` on the Jolla | `ls` of droid-hybris/system/vendor lib64 |

## The difference between Gallery and Atlantic

`gstdroidvdec.c` picks one of two output modes from the downstream caps:

- **Hardware buffers** — the sink accepts `video/x-raw(memory:DroidMediaQueueBuffer)`
  (gst-droid's `droideglsink`, which Gallery uses). droidmedia gives the codec an
  `ANativeWindow`/BufferQueue, and frames stay in gralloc.
- **Copy to system memory** — any other sink, including **WebKit's appsink**.
  gst-droid sets `DROID_MEDIA_CODEC_NO_MEDIA_BUFFER`, droidmedia creates the codec
  with **no surface**, and frames come back through a data callback, converted to
  I420 by `droid_media_convert` (needs `libI420colorconvert.so`) or a per-format
  table keyed by OMX colour constants.

The Xperia (Android 10, OMX Venus) has always run the copy mode. The Jolla ships
without the convert library, and a Codec2 codec with no surface is a path Jolla's
own apps never exercise. **Hypothesis: the no-surface copy mode is what hangs.**

## Phases

### Root cause (2026-09-25)

A gdb snapshot of the hung WebProcess shows a deadlock inside gst-droid:
`multiqueue0:src` is inside droidvdec handling an event from h264parse,
waiting on `state_cond`, and the codec's output thread `droidvdec0:src` is
stuck in `pthread_mutex_lock`. The GStreamer log (GST_DEBUG_FILE via `atldbg
launch --env`) shows `stream-start` → caps (codec created) → a **second
`stream-start`**, which is the SAME event (same pointer, seqnum 60, same
stream-id). GstVideoDecoder drains on STREAM_START with its stream lock held.
`gst_droidvdec_drain()` locks it again, and `gst_droidvdec_finish()` unlocks only
once, then waits for EOS. `data_available()` needs the lock, so it's a deadlock.

- WebKit uses **legacy `playbin`** for regular `<video src>` (playbin3 only for
  MSE/blob/MediaStream or `WEBKIT_GST_USE_PLAYBIN3=1`). Legacy playbin sends the
  duplicate; playbin3 does not.
- Reproduced outside Atlantic: `gst-launch-1.0 playbin uri=file://…` hangs.
  `playbin3` plays.
- `WEBKIT_GST_USE_PLAYBIN3=1` makes HW decode work in Atlantic (575 frames, 0
  dropped) but **breaks HLS** (MEDIA_ERR_SRC_NOT_SUPPORTED, even with software
  decode), so it isn't the fix.
- Fix: a droidvdec sink-pad probe drops a stream-start identical to the stored
  one. Standalone harness (playbin + GMainLoop + the same probe) on the Jolla: no
  probe = hang; probe = EOS, 600/600 frames HW-decoded, clean teardown. The
  harness MUST run a GMainLoop: without one, even playbin3 hangs and teardown
  segfaults in a binder thread (a harness artefact, not a bug).

### 0 — RESULT (2026-09-25): the decoder works in every setup outside Atlantic

1080p H.264 10 s clip from `/tmp`, `gst-launch-1.0` (gstreamer1.0-tools), no hang in any run:

| Run | Result |
|---|---|
| B: `droidvdec ! video/x-raw(memory:DroidMediaQueueBuffer) ! fakesink` | 300 frames in 3.1 s, EOS. `hal_format 0x7f000789` (opaque, so option 2a is a dead end) |
| A: `droidvdec ! video/x-raw,format=I420 ! fakesink` (copy mode, what WebKit gets) | 300 frames in 3.0 s, EOS. Codec reports colour 19 (planar I420), plain memcpy, no convert library needed |
| A + Atlantic's full env (3 LD_PRELOAD shims, wpe-compat LD_LIBRARY_PATH, all exports, Atlantic ranks) | 300 frames in 3.0 s, EOS |
| `playbin3 uri=file://… video-sink="fakesink sync=true"` + Atlantic env/ranks | autoplugs `droidvdec0`, plays in real time (10 s), EOS |

The `mapper.mediatek.so … not accessible` and `libandroidicu` linker warnings show
up in every one of these working runs too, so they're noise.

**So the hang is inside the WebProcess, not in droidvdec/droidmedia/Codec2, the
output mode, the preloads, or playbin3 autoplugging.** What's left: WebKit's
own elements (`webkitwebsrc` HTTP source, WebKit's video sink/appsink and buffer
pool), in-process state (hybris EGL + the Mali driver already live in the process;
the seccomp filter is already ruled out), or the browser's memory cgroup. Phase 2
(native buffers) is therefore **not needed** for correctness, and the real fix is
likely much smaller. Next step: one hang inside Atlantic with gdb, interrupt it
and take `thread apply all bt` of the stuck codec threads (instead of waiting for
the ~10 s crash), then `file://` vs `https://` to split the source.

### 0 (original). Confirm the hypothesis outside the browser (1 day, low risk)
Install `gstreamer1.0-tools` (jolla repo, 335 KB; ask first) and run, one at a
time, with `timeout 20`, a local 10 s H.264 file from `/tmp`:

- A: `filesrc ! qtdemux ! h264parse ! droidvdec ! fakesink` → copy mode; expect the hang.
- B: `… ! droidvdec ! "video/x-raw(memory:DroidMediaQueueBuffer)" ! fakesink` → hardware-buffer mode; expect frames.

Rules: at most one hang per session, check Gallery still plays after each, all
files in `/tmp`. If B also hangs, the bug is in Jolla's port. Report it to Jolla
with the pipeline and stop here.

### 1. Hang-proof fallback (2–3 days, benefits both phones; do it regardless)
A HW decoder that hangs must never kill a tab or wedge the stack again. In the
WebKit GStreamer player (engine patch, env-gated): if the decoder produces no
frame within N s of the first input buffer, tear down that pipeline and rebuild
it with droidvdec ranked 0 (software) for that element only, then log it. Also
covers future vendors we haven't seen. Validate on the Xperia (HW still wins
there) and on the Jolla with detection forced off (`ATLANTIC_DISABLE_HW_DECODER=0`).

### 2. Make WebKit take hardware buffers (the real fix; 2–4 weeks)
If phase 0 confirms B works, WebKit's sink must accept
`memory:DroidMediaQueueBuffer`. Two options, cheapest first:

- **2a. Map and copy.** Lock the gralloc buffer for CPU read in the WebProcess and
  feed WebKit's existing NV12/I420 upload path. Small change. Dead end if MTK
  gralloc hands back a tiled/compressed format (UFO/blk). Check the reported
  `hal_format` first.
- **2b. Zero-copy EGLImage.** Import each buffer as an `EGLImage`
  (`EGL_NATIVE_BUFFER_ANDROID`, as `droideglsink` does through libhybris) and
  sample it as `GL_TEXTURE_EXTERNAL_OES` in the TextureMapper video layer. This is
  the "zero-copy video" item already on the roadmap
  (`video-presentation-decoupling.md` #3, `video-playback.md` phase 3). It also
  removes the Xperia's ~43 % of a core in NV12→RGBA conversion. It is the biggest
  job and also the biggest win on both phones.

Recommend doing 2a first if the format is linear (quick win on the Jolla), then 2b.
Ship each behind a runtime gate, default on only per device after verification.

### 3. Use what the Jolla's hardware can do (after 2)
- Per device: drop the h264ify quirk (`kYouTubeH264`) on the Jolla, since its
  VP9/AV1 are HW-decoded. Keep it on the Xperia.
- Raise `WEBKIT_GST_VIDEO_DECODING_LIMIT` above 1080p on the Jolla only if HW
  handles it (MTK lists the performance points in `media_codecs_performance.xml`).
- Replace the Codec2-only auto-SW detection with "HW unless the hang fallback
  fired".

## Verification each phase
- Jolla: 1080p H.264 + HEVC files, YouTube, an HLS stream, 0 hangs, Gallery
  still plays afterwards.
- Xperia: the same set, no regression vs today's droidvdec numbers (`atldbg
  media -w`), YouTube VP9 still goes to software.
