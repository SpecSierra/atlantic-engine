# Atlantic Browser 1.0.0 Beta 5

A web browser for Sailfish OS 5.1, built on WPE WebKit 2.52.4.

Update with:

```
zypper ref atlantic-ci-v2 && zypper up atlantic-*
```

---

## Scrolling no longer waits for the page

The headline of this release. Scrolling used to be tied to the page's rendering: if a
site was busy doing layout or running JavaScript, the scroll froze with it. Heavy news
sites could lock up for seconds at a time while your finger was still moving.

Scrolling now runs on its own thread with its own clock, completely independent of page
rendering — the same approach Firefox (APZ) and Sailfish's stock browser use. A slow page
stays slow, but the scroll keeps moving.

On franceinfo (our worst-case test site), the gap between frames dropped from **1.4
seconds to 111ms at the 95th percentile** — roughly 13× more consistent. Scroll positions
now update ~29 times a second instead of ~5.

The trade-off is deliberate: while you fling a slow page, newly exposed areas may show
low-resolution or blank tiles for a moment, and scroll-triggered JavaScript (lazy-loaded
images, sticky headers) catches up when the page does. Moving pixels beat a frozen screen.

Related scrolling work:

- **Page-freeze fix.** Sites that update CSS variables on every scroll frame (franceinfo,
  radiofrance) forced a full-page repaint each frame. Worst-case freeze went from 34s to
  3.3s — and independent scrolling now hides most of what's left.
- Composited elements that only move no longer trigger a full repaint.
- Tile uploads are budgeted and drained in the scroll direction, so tiles stop popping in
  late during fast flicks.
- Fixed a phantom hover highlight that appeared under your finger while scrolling.
- Removed the old "fling throttle" workaround — it existed only to keep page work off the
  scroll path, which is now handled properly.

## Images and media

- **AVIF images** are now supported (via dav1d).
- **Faster image decoding, much less RAM.** Images displayed smaller than their real size
  now decode at reduced resolution instead of full size. On an image-heavy page this cut
  memory from 546 MB to 160 MB.
- **Encrypted Media Extensions (ClearKey).** Enables sites that require an EME-capable
  browser. This is ClearKey only — no Widevine, so Netflix and friends still won't play.

## Web compatibility

- **Date, time, and colour input fields work.** `<input type="date">`, `datetime-local`,
  `month`, `week`, `time` and `color` were simply unsupported before. They now open native
  Silica pickers.
- **Cloudflare challenge pages** no longer dead-end: hosts that challenge us get an iPhone
  user-agent automatically. Fixed a related bug where a page's sub-frames could silently
  undo per-site user-agent fixes — which had quietly broken *all* of them, including Google
  Maps.

## Privacy

- **Private tabs are actually private.** They no longer write history, and they run on a
  separate in-memory session that is wiped when the last private tab closes — nothing
  touches disk.
- **Cookie-banner blocking**, on by default, with a settings toggle. Uses DuckDuckGo's
  autoconsent rules plus uBlock Origin's cookie filter list to reject banners rather than
  just hide them.
- Reddit's "Get the app" bottom sheet is gone, along with the scroll lock it imposed.

## Memory

- **Background tabs are discarded under pressure.** Tabs beyond a recently-used limit have
  their web process terminated and reload when you return to them, instead of holding onto
  hundreds of MB of RAM and GPU memory each.

## Fixes

- Downloads no longer stall: per-chunk progress reporting was flooding the session D-Bus
  and wedging the transfer engine. Progress is now throttled.
- The start page's wallpaper fills the screen, so the popup menu no longer reveals a white
  edge.
- The icon-repair pass no longer runs on every flick, only on real taps.

---

## Known issues

- Very heavy pages can still stall for a few seconds in the worst case. The remaining
  cause is page rendering itself (style recalculation and tile painting on the main
  thread), not scrolling — that's the next target.
- ClearKey-only EME: DRM-protected streaming services remain unsupported.

## Disclaimer

Beta software. Expect rough edges. Installs alongside the stock browser, so you can always
fall back to it.
