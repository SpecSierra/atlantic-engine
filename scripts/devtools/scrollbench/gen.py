#!/usr/bin/env python3
"""Generate the scroll-tier bench pages.

Three pages that separate the two factors the current px/s trigger conflates:

  light.html  cheap tiles,     idle main thread   -> low-res should NOT engage
  heavy.html  expensive tiles, idle main thread   -> low-res SHOULD engage
  stall.html  cheap tiles,     stalled main thread-> exercises the dt<0.2 gate

All three are the same pixel height and the same scrollable length so scroll
geometry (px/s, tiles exposed per second) is identical across them.  The ONLY
thing that varies is raster cost per tile and main-thread availability -- which
is exactly the axis the current trigger is blind to.
"""
import pathlib

OUT = pathlib.Path(__file__).parent
N = 220  # paragraphs -> ~26k px tall at ~120px each

LOREM = ("Atlantic renders this paragraph to measure per-tile raster cost. "
         "The quick brown fox jumps over the lazy dog while the compositor "
         "uploads freshly exposed tiles from the prepaint cushion. ") * 2

HEAD = """<meta name="viewport" content="width=device-width,initial-scale=1">
<title>%s</title>
<style>
  * { box-sizing: border-box; }
  body { margin:0; font: 16px/1.5 sans-serif; background:#fff; color:#111; }
  .row { padding: 14px 16px; min-height: 104px; }
  h2 { font-size: 15px; margin: 0 0 6px; }
  #hud { position: fixed; top:0; left:0; z-index:9999; background:#000; color:#0f0;
         font: 11px monospace; padding:2px 5px; }
</style>
"""

# Cheap: flat background, plain text.  Nothing per-pixel beyond glyphs.
LIGHT_CSS = """
  .row { background:#fff; border-bottom:1px solid #eee; }
"""

# Expensive: every row costs the rasterizer real work -- a multi-stop gradient,
# a large-radius box-shadow (a blur pass), rounded clipping, and a text-shadow.
# No JS, no layout churn: identical geometry, ~10-40x the per-tile raster cost.
HEAVY_CSS = """
  .row {
    margin: 6px 10px;
    border-radius: 14px;
    background: linear-gradient(135deg,#fdfbfb 0%,#ebedee 35%,#dfe9f3 70%,#fff 100%);
    box-shadow: 0 6px 18px rgba(30,40,80,.28), 0 1px 3px rgba(0,0,0,.18),
                inset 0 0 0 1px rgba(255,255,255,.6);
    text-shadow: 0 1px 2px rgba(0,0,0,.22);
    border: 1px solid rgba(120,130,160,.35);
  }
  .row h2 { text-shadow: 0 2px 5px rgba(20,30,70,.35); }
  .tag { display:inline-block; padding:2px 8px; margin-right:6px; border-radius:9px;
         background: radial-gradient(circle at 30% 30%, #fff, #c9d6e8);
         box-shadow: 0 2px 6px rgba(0,0,0,.25); }
"""

# Main-thread stall: cheap tiles, but a long synchronous task every frame-ish.
# This starves the layer-flush cadence WITHOUT changing raster cost, so it
# isolates the dt<0.2 sampling gate from the cost question.
STALL_JS = """
<script>
(function(){
  var BUSY_MS = 45;              // long task, > one frame
  var PERIOD  = 60;              // fires ~16x/s -> flush cadence collapses
  function burn(ms){ var t=performance.now(); var x=0;
    while(performance.now()-t < ms){ x += Math.sqrt(x+1)|0; } return x; }
  setInterval(function(){ burn(BUSY_MS); }, PERIOD);
})();
</script>
"""

# Reports the real scroll velocity the page actually experienced, so a bench run
# can prove which tier it was in instead of assuming.
HUD_JS = """
<script>
(function(){
  var last = window.scrollY, lastT = performance.now(), samples = [];
  window.__bench = { samples: samples, reset: function(){ samples.length = 0; } };
  function tick(){
    var y = window.scrollY, t = performance.now(), dt = (t-lastT)/1000;
    if (dt > 0) { samples.push({dy: y-last, dt: dt, v: Math.abs(y-last)/dt}); }
    last = y; lastT = t; requestAnimationFrame(tick);
  }
  requestAnimationFrame(tick);
})();
</script>
"""


def page(name, css, extra_js=""):
    rows = []
    for i in range(N):
        rows.append(
            f'<div class="row"><h2><span class="tag">#{i}</span>Section {i}</h2>'
            f'<p>{LOREM}</p></div>')
    html = ("<!doctype html><html><head>" + (HEAD % name) +
            "<style>" + css + "</style></head><body>" +
            "\n".join(rows) + HUD_JS + extra_js + "</body></html>")
    (OUT / f"{name}.html").write_text(html)
    return len(html)


if __name__ == "__main__":
    for n, c, j in (("light", LIGHT_CSS, ""),
                    ("heavy", HEAVY_CSS, ""),
                    ("stall", LIGHT_CSS, STALL_JS)):
        print(f"{n}.html  {page(n, c, j)/1024:.0f} KB")
