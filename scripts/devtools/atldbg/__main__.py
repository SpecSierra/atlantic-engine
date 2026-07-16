"""atldbg CLI entry point.

Usage:  python3 -m atldbg <command> [options]      (or the ./atldbg wrapper)

Commands
  doctor                 one-shot health snapshot across every subsystem
  bug      [-s SEC] [-e] live console errors / JS exceptions / failed loads
  cpu      [-s SEC]      per-thread native CPU sampling (what is executing)
  profile  [-s SEC]      JS self-time profiler (slow timers/rAF/handlers)
  media    [-w SEC]      video/audio state + decode quality + GStreamer info
  render   [-s SEC] [--scroll]  frame pacing / jank + render-thread CPU + shot
  eval     "<js>"        evaluate JS on the page, print the result
  launch   [url]         (re)start the browser with the inspector enabled
  open     <url>         navigate the running browser
  shot     [path]        screenshot the device screen
  ps                     list browser processes
  log      [-n N]        tail the browser log
"""
from __future__ import annotations

import argparse
import sys

from . import __version__
from .commands import bug, cpu, doctor, media, misc, profile, render


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="atldbg",
        description="Atlantic Browser debugger — find bugs, exec usage, slow "
                    "functions, and debug media/render on the SFOS dev device.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("--version", action="version", version=f"atldbg {__version__}")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("doctor", help="one-shot health snapshot")
    sp.set_defaults(func=doctor.run)

    sp = sub.add_parser("bug", help="live console errors / exceptions / net failures")
    sp.add_argument("-s", "--seconds", type=float, default=20)
    sp.add_argument("-e", "--errors", action="store_true", help="errors only")
    sp.add_argument("--tab", help="pick tab by URL substring (default: visible tab)")
    sp.set_defaults(func=bug.run)

    sp = sub.add_parser("cpu", help="per-thread native CPU sampling")
    sp.add_argument("-s", "--seconds", type=float, default=5)
    sp.add_argument("-n", "--top", type=int, default=20, help="rows to show")
    sp.add_argument("-t", "--threshold", type=float, default=1.0, help="min CPU%%")
    sp.set_defaults(func=cpu.run)

    sp = sub.add_parser("profile", help="JS self-time profiler")
    sp.add_argument("-s", "--seconds", type=float, default=15)
    sp.add_argument("-n", "--top", type=int, default=25)
    sp.add_argument("--tab", help="pick tab by URL substring (default: visible tab)")
    sp.set_defaults(func=profile.run)

    sp = sub.add_parser("media", help="video/audio + decode + GStreamer debug")
    sp.add_argument("-w", "--watch", type=float, default=0,
                    help="watch decode quality for N seconds")
    sp.add_argument("--tab", help="pick tab by URL substring (default: visible tab)")
    sp.set_defaults(func=media.run)

    sp = sub.add_parser("render", help="frame pacing / jank / render threads")
    sp.add_argument("-s", "--seconds", type=float, default=6)
    sp.add_argument("--scroll", action="store_true", help="auto-scroll while measuring")
    sp.add_argument("--shot", default="/tmp/atldbg-render.png")
    sp.add_argument("--no-shot", action="store_true")
    sp.add_argument("--tab", help="pick tab by URL substring (default: visible tab)")
    sp.set_defaults(func=render.run)

    sp = sub.add_parser("eval", help="evaluate JS on the page")
    sp.add_argument("js")
    sp.add_argument("--gesture", action="store_true", help="emulate a user gesture")
    sp.add_argument("--tab", help="pick tab by URL substring (default: visible tab)")
    sp.set_defaults(func=misc.eval_js)

    sp = sub.add_parser("tabs", help="list inspectable tabs")
    sp.set_defaults(func=misc.tabs)

    sp = sub.add_parser("launch", help="(re)start the browser with the inspector")
    sp.add_argument("url", nargs="?")
    sp.add_argument("--no-inspector", action="store_true")
    sp.add_argument("--gst-debug", help="GST_DEBUG spec, e.g. 'webkit*:4,droid*:5'")
    sp.add_argument("--env", action="append", metavar="KEY=VAL",
                    help="extra engine env, repeatable "
                         "(e.g. --env WEBKIT_INDEPENDENT_SCROLL=1)")
    sp.set_defaults(func=misc.launch)

    sp = sub.add_parser("open", help="navigate the running browser")
    sp.add_argument("url")
    sp.set_defaults(func=misc.open_url)

    sp = sub.add_parser("shot", help="screenshot the device")
    sp.add_argument("path", nargs="?", default="/tmp/atldbg-shot.png")
    sp.set_defaults(func=misc.shot)

    sp = sub.add_parser("ps", help="list browser processes")
    sp.set_defaults(func=misc.ps)

    sp = sub.add_parser("log", help="tail the browser log")
    sp.add_argument("-n", type=int, default=60)
    sp.set_defaults(func=misc.log)

    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args) or 0
    except KeyboardInterrupt:
        print("\n(interrupted)")
        return 130


if __name__ == "__main__":
    sys.exit(main())
