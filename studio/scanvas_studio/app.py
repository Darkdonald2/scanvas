"""Scanvas Studio window: receive scans from the iPhone over Wi-Fi, or open a raw zip, and process them."""
from __future__ import annotations

import os
import queue
import subprocess
import sys
import threading
import tkinter as tk
import traceback
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

from . import __version__
from .server import Receiver, studio_home

BG = "#16181b"
PANEL = "#202327"
TEXT = "#e8eaed"
MUTED = "#9aa0a6"
ACCENT = "#34c759"


def open_folder(path: Path):
    if sys.platform == "darwin":
        subprocess.Popen(["open", str(path)])
    elif os.name == "nt":
        os.startfile(str(path))  # type: ignore[attr-defined]
    else:
        subprocess.Popen(["xdg-open", str(path)])


class StudioApp:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.events: queue.Queue = queue.Queue()
        self.jobs: queue.Queue = queue.Queue()
        self.busy = False
        root.title("Scanvas Studio")
        root.geometry("760x620")
        root.minsize(640, 520)
        root.configure(bg=BG)
        style = ttk.Style(root)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure(".", background=BG, foreground=TEXT, fieldbackground=PANEL)
        style.configure("TFrame", background=BG)
        style.configure("Panel.TFrame", background=PANEL)
        style.configure("TLabel", background=BG, foreground=TEXT)
        style.configure("Panel.TLabel", background=PANEL, foreground=TEXT)
        style.configure("Muted.TLabel", background=PANEL, foreground=MUTED)
        style.configure("Title.TLabel", background=BG, foreground=TEXT, font=("Helvetica", 22, "bold"))
        style.configure("Code.TLabel", background=PANEL, foreground=ACCENT, font=("Helvetica", 20, "bold"))
        style.configure("TCheckbutton", background=PANEL, foreground=TEXT)
        style.configure("TRadiobutton", background=PANEL, foreground=TEXT)
        for w in ("TCheckbutton", "TRadiobutton"):
            style.map(w, background=[("active", PANEL)], foreground=[("active", TEXT)])
        style.configure("TButton", background="#2c3036", foreground=TEXT, borderwidth=0, padding=(10, 6))
        style.map("TButton", background=[("active", "#3a3f46")], foreground=[("active", TEXT)])
        style.configure("Horizontal.TProgressbar", background=ACCENT, troughcolor=PANEL)

        pad = {"padx": 16, "pady": 6}
        ttk.Label(root, text="Scanvas Studio", style="Title.TLabel").pack(anchor="w", padx=16, pady=(16, 2))
        ttk.Label(root, text="Dense, photo-textured models from Scanvas raw scans.", foreground=MUTED).pack(anchor="w", padx=16)

        # Wi-Fi receiver
        wifi = ttk.Frame(root, style="Panel.TFrame", padding=12)
        wifi.pack(fill="x", **pad)
        ttk.Label(wifi, text="Receive from iPhone over Wi-Fi", style="Panel.TLabel", font=("Helvetica", 13, "bold")).grid(row=0, column=0, sticky="w")
        self.wifi_status = ttk.Label(wifi, text="Starting…", style="Muted.TLabel")
        self.wifi_status.grid(row=1, column=0, sticky="w", pady=(4, 0))
        ttk.Label(wifi, text="Pairing code", style="Muted.TLabel").grid(row=0, column=1, sticky="e", padx=(20, 0))
        self.code_label = ttk.Label(wifi, text="----", style="Code.TLabel")
        self.code_label.grid(row=1, column=1, sticky="e", padx=(20, 0))
        wifi.columnconfigure(0, weight=1)
        ttk.Label(wifi, text="On the iPhone: open the scan, tap ⋯ › Send to computer, type this code and pick this computer.",
                  style="Muted.TLabel", wraplength=680).grid(row=2, column=0, columnspan=2, sticky="w", pady=(6, 0))

        # Settings
        opts = ttk.Frame(root, style="Panel.TFrame", padding=12)
        opts.pack(fill="x", **pad)
        ttk.Label(opts, text="Quality", style="Panel.TLabel", font=("Helvetica", 13, "bold")).grid(row=0, column=0, sticky="w")
        self.quality = tk.StringVar(value="high")
        for i, (key, label) in enumerate([("fast", "Fast · 2 cm detail"), ("high", "High · 1 cm detail"), ("ultra", "Ultra · 6 mm detail (slow)")]):
            ttk.Radiobutton(opts, text=label, value=key, variable=self.quality).grid(row=1, column=i, sticky="w", padx=(0, 16))
        self.refine = tk.BooleanVar(value=True)
        self.smooth = tk.BooleanVar(value=True)
        self.texture = tk.BooleanVar(value=True)
        self.z_up = tk.BooleanVar(value=False)
        self.auto = tk.BooleanVar(value=True)
        checks = [(self.refine, "Refine camera positions"), (self.smooth, "Smooth noise"), (self.texture, "Photo texture"),
                  (self.z_up, "Z up (Revit, AutoCAD, Rhino)"), (self.auto, "Process scans as soon as they arrive")]
        for i, (var, label) in enumerate(checks):
            ttk.Checkbutton(opts, text=label, variable=var).grid(row=2 + i // 3, column=i % 3, sticky="w", pady=(8, 0), padx=(0, 16))

        # Actions
        actions = ttk.Frame(root)
        actions.pack(fill="x", **pad)
        ttk.Button(actions, text="Open raw zip…", command=self.open_zip).pack(side="left")
        ttk.Button(actions, text="Open raw folder…", command=self.open_dir).pack(side="left", padx=8)
        ttk.Button(actions, text="Show results folder", command=lambda: open_folder(studio_home() / "Scans")).pack(side="right")
        self.view_button = ttk.Button(actions, text="View 3D", command=self.view_last, state="disabled")
        self.view_button.pack(side="right", padx=8)
        self.last_out: Path | None = None

        # Progress and log
        self.step = ttk.Label(root, text="Ready.")
        self.step.pack(anchor="w", padx=16, pady=(8, 2))
        self.bar = ttk.Progressbar(root, maximum=1000)
        self.bar.pack(fill="x", padx=16)
        self.log = tk.Text(root, height=12, bg=PANEL, fg=TEXT, insertbackground=TEXT, relief="flat", wrap="word",
                           font=("Menlo" if sys.platform == "darwin" else "Consolas", 10))
        self.log.pack(fill="both", expand=True, padx=16, pady=(8, 16))
        self.say(f"Scanvas Studio {__version__}. Results go to {studio_home() / 'Scans'}.")

        self.receiver = Receiver(on_received=self.received, on_progress=lambda m: self.events.put(("wifi", m)))
        try:
            self.receiver.start()
            self.code_label.configure(text=self.receiver.code)
            self.wifi_status.configure(text=f"Waiting for scans at {self.receiver.address}")
        except Exception as e:  # e.g. port blocked
            self.wifi_status.configure(text=f"Wi-Fi receiving is off: {e}")
        threading.Thread(target=self.worker, daemon=True).start()
        root.after(100, self.pump)
        root.protocol("WM_DELETE_WINDOW", self.quit)

    # ------------------------------------------------------------------ UI helpers
    def say(self, text: str):
        self.log.insert("end", text + "\n")
        self.log.see("end")

    def pump(self):
        try:
            while True:
                kind, value = self.events.get_nowait()
                if kind == "log":
                    self.say(value)
                elif kind == "step":
                    msg, frac = value
                    self.step.configure(text=msg)
                    self.bar["value"] = frac * 1000
                elif kind == "wifi":
                    self.wifi_status.configure(text=value)
                elif kind == "done":
                    folder, log = value
                    self.last_out = folder
                    self.view_button.configure(state="normal")
                    self.say(f"Finished in {log.get('minutes', '?')} min: {', '.join(log.get('files', []))}")
                    if "texture_error" in log:
                        self.say("Texturing failed (" + log["texture_error"] + "); the coloured mesh was still saved.")
                    self.wifi_status.configure(text=f"Waiting for scans at {self.receiver.address}")
                    self.say("Click View 3D to look at it here. Scans sent over Wi-Fi can be fetched on the iPhone: Send to computer › Get processed model.")
                    open_folder(folder)
                elif kind == "error":
                    self.step.configure(text="Something went wrong.")
                    messagebox.showerror("Scanvas Studio", value)
        except queue.Empty:
            pass
        self.root.after(100, self.pump)

    def settings(self):
        from .pipeline import Settings
        return Settings(quality=self.quality.get(), refine_cameras=self.refine.get(), smooth=self.smooth.get(),
                        texture=self.texture.get(), z_up=self.z_up.get())

    # ------------------------------------------------------------------ sources
    def open_zip(self):
        path = filedialog.askopenfilename(title="Open a Scanvas raw zip", filetypes=[("Zip", "*.zip"), ("All files", "*.*")])
        if path:
            self.queue_job(Path(path), Path(path).stem.replace(" raw", ""))

    def open_dir(self):
        path = filedialog.askdirectory(title="Open a Scanvas raw folder")
        if path:
            self.queue_job(Path(path), Path(path).name)

    def view_last(self):
        if not self.last_out:
            return
        target = self.last_out / "model_textured.obj"
        if not target.exists():
            target = self.last_out / "model_dense_colour.ply"
        # A separate process, so the 3D window can't freeze Studio.
        if getattr(sys, "frozen", False):
            cmd = [sys.executable, "--view", str(target)]
        else:
            cmd = [sys.executable, str(Path(__file__).resolve().parent.parent / "run_studio.py"), "--view", str(target)]
        subprocess.Popen(cmd)

    def received(self, folder: Path, name: str, transfer: str = ""):
        self.events.put(("log", f"Received “{name}” from the iPhone."))
        self.events.put(("wifi", f"Received {name}"))
        if self.auto.get():
            self.queue_job(folder, name, transfer)
        else:
            self.events.put(("log", f"Saved to {folder}. Open it with “Open raw folder…” when you're ready."))

    def queue_job(self, path: Path, name: str, transfer: str = ""):
        transfer = transfer or self.receiver.transfer_for(path)
        self.jobs.put((path, name, self.settings(), transfer))
        self.events.put(("log", f"Queued “{name}”."))

    # ------------------------------------------------------------------ processing
    def worker(self):
        from .capture import Capture
        from .pipeline import process
        while True:
            path, name, s, transfer = self.jobs.get()
            cap = None
            try:
                self.events.put(("step", (f"Opening {name}…", 0)))
                cap = Capture.open(path)
                out = studio_home() / "Scans" / f"{cap.name} - model"
                n = 2
                while out.exists():
                    out = out.with_name(f"{cap.name} - model ({n})")
                    n += 1
                self.events.put(("log", f"Processing “{cap.name}”: {len(cap.frames)} photos with depth, {s.quality} quality."))
                self.receiver.set_status(transfer, state="processing", folder=str(out))
                last = [""]

                def report(msg, frac):
                    self.events.put(("step", (msg, frac)))
                    self.receiver.set_status(transfer, step=msg, progress=frac)
                    head = msg.split(" (")[0]
                    if head != last[0]:
                        last[0] = head
                        self.events.put(("log", "  " + head))

                log = process(cap, out, s, report)
                self.receiver.set_status(transfer, state="done", step="Done", progress=1.0)
                self.events.put(("done", (out, log)))
            except MemoryError:
                self.receiver.set_status(transfer, state="failed", step="The computer ran out of memory")
                self.events.put(("error", "The computer ran out of memory. Try Fast quality, or close other apps."))
            except Exception as e:
                self.receiver.set_status(transfer, state="failed", step=str(e))
                self.events.put(("log", traceback.format_exc()))
                self.events.put(("error", str(e)))
            finally:
                if cap:
                    cap.close()

    def quit(self):
        try:
            self.receiver.stop()
        finally:
            self.root.destroy()


def main():
    root = tk.Tk()
    StudioApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
