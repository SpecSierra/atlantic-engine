# Atlantic Browser v1.0.0 Beta 1

A new web browser for Sailfish OS 5.1. Built on the latest **WPE WebKit** — replacing the
stock browser's aging Gecko engine with a modern WebKit stack. Installs alongside the
stock browser so you can use both.

---

## Why Atlantic?

The stock Sailfish browser runs on an old Gecko engine that increasingly struggles
with the modern web. Atlantic swaps that for the latest **WPE WebKit**, patched and tuned
for Sailfish OS on aarch64. Sites that break or render poorly in the stock browser —
pages relying on CSS flexbox, grid, WOFF2 fonts, modern JavaScript — work correctly
in Atlantic.

A custom Qt5 bridge layer connects WebKit's rendering to Sailfish Silica, so the
browser looks and feels native while getting the full benefit of a current engine.

WPE WebKit is the same technology that powers Safari on Apple devices, Amazon's
Kindle web browser, and millions of smart TVs and set-top boxes. It's designed
specifically for ARM devices like your phone — lightweight enough to run well on
constrained hardware, but kept current with modern web standards so sites look and
behave the way they should.

**Built-in ad blocking.** Ships with EasyList + EasyPrivacy — the same filter lists
that power uBlock Origin. Uses Brave's Rust-based adblock engine to compile filter
rules to native code and block ads and trackers at the resource-load level. No
extensions, no setup.

**Frosted‑glass interface.** The toolbar, popup menu, and tab switcher are rendered
as translucent glass that composites your ambience wallpaper through the browser
chrome. Every surface follows your Sailfish theme.

**Sailjail‑sandboxed.** Browsing subprocesses run confined through Firejail with
native sailjaild integration — the same permission model the rest of the OS uses.

**Auto‑updating.** New builds are published by CI to a zypper repo on every push.
`zypper up atlantic-*` gets you the latest.

---

## Installation

```sh
devel-su zypper addrepo https://specsierra.github.io/atlantic-engine/aarch64/ atlantic-ci-v2
devel-su zypper refresh atlantic-ci-v2
devel-su zypper install atlantic-browser
```

---

---

## Disclaimer

Atlantic runs on a mid-range ARM phone with 4 GB of RAM. Heavily scripted sites
(React-heavy web apps, complex JavaScript SPAs) and high-resolution video playback
can push those hardware limits. The stock browser has the same constraints — this
is the device, not Atlantic — but it's worth knowing before you open 15 Google Docs
tabs.

---

Free and open source — MPL 2.0.
