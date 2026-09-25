# Hardware video decode on the Jolla Phone 2 — plan

Status: **PLAN** (2026-09-25). Today the Jolla runs software decode, set
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

### 0. Confirm the hypothesis outside the browser (1 day, low risk)
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
