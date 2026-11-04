"""Command line: python -m scanvas_studio <capture.zip or folder> [--out DIR] [--quality fast|high|ultra] ..."""
import argparse
import time
import sys
from pathlib import Path

from .capture import Capture
from .pipeline import Settings, process


def main(argv=None):
    ap = argparse.ArgumentParser(prog="scanvas-studio", description="Process a Scanvas raw capture on this computer.")
    ap.add_argument("capture", nargs="?", help="raw capture .zip or folder (leave out to open the window)")
    ap.add_argument("--out", help="output folder (default: next to the capture)")
    ap.add_argument("--quality", choices=["fast", "high", "ultra"], default="high")
    ap.add_argument("--no-refine", action="store_true", help="skip camera refinement")
    ap.add_argument("--no-smooth", action="store_true")
    ap.add_argument("--no-texture", action="store_true", help="coloured mesh only")
    ap.add_argument("--z-up", action="store_true", help="Z up instead of Y up (Revit, AutoCAD, Rhino)")
    ap.add_argument("--serve", action="store_true", help="receive and process scans from the iPhone over Wi-Fi without a window")
    ap.add_argument("--view", help="open a result (.obj, .glb or results folder) in a 3D window")
    a = ap.parse_args(argv)
    if a.view:
        from .pipeline import view
        p = Path(a.view)
        view(p / "model_textured.obj" if p.is_dir() else p)
        return 0
    if a.serve:
        from .server import run_forever
        run_forever()
        return 0
    if not a.capture:
        from .app import main as gui
        gui()
        return 0
    cap = Capture.open(a.capture)
    src = Path(a.capture)
    out = Path(a.out) if a.out else (src.parent if src.is_file() else src.parent) / f"{cap.name} - Studio"
    s = Settings(quality=a.quality, refine_cameras=not a.no_refine, smooth=not a.no_smooth,
                 texture=not a.no_texture, z_up=a.z_up)
    last = [""]
    t0 = time.time()

    def report(msg, frac):
        if msg != last[0]:
            print(f"[{frac * 100:5.1f}% {time.time() - t0:6.0f}s] {msg}", flush=True)
            last[0] = msg

    try:
        log = process(cap, out, s, report)
    finally:
        cap.close()
    print("Saved to", out)
    for k, v in log.items():
        print(f"  {k}: {v}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
