"""Entry point for the packaged app and the launch scripts."""
import multiprocessing
import os
import sys

if __name__ == "__main__":
    multiprocessing.freeze_support()
    # A packaged windowed app has no console: give print() somewhere to go.
    if sys.stdout is None:
        sys.stdout = open(os.devnull, "w")
    if sys.stderr is None:
        sys.stderr = open(os.devnull, "w")
    from scanvas_studio.cli import main
    sys.exit(main([a for a in sys.argv[1:] if not a.startswith("-psn_")]))
