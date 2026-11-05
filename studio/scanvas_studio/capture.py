"""Reading a Scanvas raw capture (format "scanvas-raw", version 1) from a folder or a zip."""
from __future__ import annotations

import json
import os
import shutil
import tempfile
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

# ARKit cameras look along -Z with +Y up; OpenCV / Open3D cameras look along +Z with +Y down.
ARKIT_TO_CV = np.diag([1.0, -1.0, -1.0, 1.0])


@dataclass
class Frame:
    index: int
    timestamp: float
    image: Path
    depth: Path
    confidence: Path | None
    width: int
    height: int
    depth_width: int
    depth_height: int
    fx: float
    fy: float
    cx: float
    cy: float
    camera_to_world: np.ndarray            # 4x4, ARKit convention, drift-corrected once loaded
    exposure: float = 0.0
    anchors: dict = field(default_factory=dict)
    pose_anchors: dict = field(default_factory=dict)      # anchors the app dropped along the path (newer captures)
    sharpness: float = 0.0

    def intrinsic(self, scale: float = 1.0) -> np.ndarray:
        """3x3 pinhole matrix for the image scaled by `scale` (pixel centres kept consistent)."""
        return np.array([[self.fx * scale, 0, (self.cx + 0.5) * scale - 0.5],
                         [0, self.fy * scale, (self.cy + 0.5) * scale - 0.5],
                         [0, 0, 1]], dtype=np.float64)

    def depth_intrinsic(self) -> np.ndarray:
        return self.intrinsic(self.depth_width / self.width)

    def extrinsic(self) -> np.ndarray:
        """World-to-camera in the OpenCV / Open3D convention."""
        return ARKIT_TO_CV @ np.linalg.inv(self.camera_to_world)

    def position(self) -> np.ndarray:
        return self.camera_to_world[:3, 3]

    def forward(self) -> np.ndarray:
        return -self.camera_to_world[:3, 2]

    def load_depth(self, min_confidence: int = 1, max_depth: float = 5.0, drop_edges: bool = False) -> np.ndarray:
        """Depth in metres, 0 where unusable. `drop_edges` also removes the pixels along the outline of things:
        there the sensor blends the near and the far surface into depths that belong to neither, which would
        otherwise become thin sheets of surface hanging off the edges of furniture and people."""
        d = np.fromfile(self.depth, dtype=np.float32).reshape(self.depth_height, self.depth_width).copy()
        if self.confidence is not None and self.confidence.exists():
            c = np.fromfile(self.confidence, dtype=np.uint8).reshape(self.depth_height, self.depth_width)
            d[c < min_confidence] = 0
        d[~np.isfinite(d)] = 0
        d[(d < 0.2) | (d > max_depth)] = 0
        if drop_edges:
            d[depth_edges(d)] = 0
        return d


def depth_edges(d: np.ndarray) -> np.ndarray:
    """True where depth jumps. A flat surface, however steeply it is seen, changes depth evenly from pixel to
    pixel, so the test is how far a pixel is from the middle of its two neighbours (across and down)."""
    limit = 0.015 + 0.02 * d
    bend = np.zeros(d.shape, np.float32)
    h = np.abs(d[:, :-2] + d[:, 2:] - 2 * d[:, 1:-1])
    h[(d[:, :-2] == 0) | (d[:, 2:] == 0)] = 0
    v = np.abs(d[:-2] + d[2:] - 2 * d[1:-1])
    v[(d[:-2] == 0) | (d[2:] == 0)] = 0
    bend[:, 1:-1] = h
    bend[1:-1] = np.maximum(bend[1:-1], v)
    edge = (bend > limit) & (d > 0)
    # One pixel either side as well: the blended depths spread a little beyond the jump itself.
    grown = edge.copy()
    grown[:, 1:] |= edge[:, :-1]
    grown[:, :-1] |= edge[:, 1:]
    grown[1:] |= edge[:-1]
    grown[:-1] |= edge[1:]
    return grown


def _matrix(values) -> np.ndarray:
    """4x4 from 16 column-major values."""
    return np.array(values, dtype=np.float64).reshape(4, 4).T


class Capture:
    def __init__(self, folder: Path, temp: Path | None = None):
        self.folder = folder
        self._temp = temp
        info_path = folder / "capture.json"
        if not info_path.exists():
            raise ValueError("This isn't a Scanvas raw capture (capture.json is missing).")
        self.info = json.loads(info_path.read_text())
        if self.info.get("format") != "scanvas-raw":
            raise ValueError("This isn't a Scanvas raw capture.")
        self.name = self.info.get("name") or folder.name
        project = folder / "project.json"
        if project.exists():
            try:
                self.name = json.loads(project.read_text()).get("name") or self.name
            except (ValueError, OSError):
                pass
        anchors_path = folder / "anchors.json"
        self.final_anchors = {k: _matrix(v) for k, v in json.loads(anchors_path.read_text()).items()} if anchors_path.exists() else {}
        pose_path = folder / "pose_anchors.json"
        try:
            self.final_pose_anchors = {k: _matrix(v) for k, v in json.loads(pose_path.read_text()).items()} if pose_path.exists() else {}
        except (ValueError, OSError):
            self.final_pose_anchors = {}
        self.frames: list[Frame] = []
        with open(folder / "frames.jsonl") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    j = json.loads(line)
                except ValueError:
                    continue     # a frame cut short when the app was closed
                fx, fy, cx, cy = j["intrinsics"]
                f = Frame(index=j["index"], timestamp=j["timestamp"], image=folder / j["image"], depth=folder / j["depth"],
                          confidence=folder / j["confidence"] if j.get("confidence") else None,
                          width=j["width"], height=j["height"], depth_width=j["depthWidth"], depth_height=j["depthHeight"],
                          fx=fx, fy=fy, cx=cx, cy=cy, camera_to_world=_matrix(j["cameraToWorld"]),
                          exposure=j.get("exposureDuration", 0.0),
                          anchors={k: _matrix(v) for k, v in j.get("anchors", {}).items()},
                          pose_anchors={k: _matrix(v) for k, v in j.get("poseAnchors", {}).items()})
                if f.image.exists() and f.depth.exists():
                    self.frames.append(f)
        self.frames.sort(key=lambda f: f.timestamp)
        self._correct_drift()

    @staticmethod
    def open(path: str | os.PathLike) -> "Capture":
        p = Path(path)
        if p.is_dir():
            # Accept the folder itself or a folder that holds it (e.g. an unzipped "Raw" folder inside another).
            if (p / "capture.json").exists():
                return Capture(p)
            for sub in p.rglob("capture.json"):
                return Capture(sub.parent)
            raise ValueError("No Scanvas raw capture found in this folder.")
        if zipfile.is_zipfile(p):
            temp = Path(tempfile.mkdtemp(prefix="scanvas-"))
            with zipfile.ZipFile(p) as z:
                for member in z.infolist():
                    target = (temp / member.filename).resolve()
                    if not str(target).startswith(str(temp.resolve())):
                        continue     # never write outside the temporary folder
                    z.extract(member, temp)
            for sub in temp.rglob("capture.json"):
                cap = Capture(sub.parent, temp)
                if cap.name == sub.parent.name:
                    cap.name = p.stem.replace(" raw", "")
                return cap
            shutil.rmtree(temp, ignore_errors=True)
            raise ValueError("No Scanvas raw capture found in this zip.")
        raise ValueError("Open a Scanvas raw capture: a .zip from the iPhone app or its folder.")

    def close(self):
        if self._temp:
            shutil.rmtree(self._temp, ignore_errors=True)
            self._temp = None

    def _correct_drift(self):
        """ARKit keeps moving mesh anchors as it learns the space. Each frame stored the anchors near what it looked
        at; move its camera by how much the nearest of those has moved since (as the phone does)."""
        for f in self.frames:
            # Newer captures drop an anchor on the camera's path every second or so. ARKit moves those when it
            # corrects its map, so the nearest one says directly how far this photo's position has shifted.
            best, best_d = None, 1e9
            for key, then in f.pose_anchors.items():
                if key in self.final_pose_anchors:
                    d = np.linalg.norm(then[:3, 3] - f.position())
                    if d < best_d:
                        best, best_d = key, d
            if best is not None:
                f.camera_to_world = self.final_pose_anchors[best] @ np.linalg.inv(f.pose_anchors[best]) @ f.camera_to_world
                continue
            if not self.final_anchors:
                continue
            target = f.position() + f.forward() * 1.5
            best, best_d = None, 1e9
            for key in f.anchors:
                now = self.final_anchors.get(key)
                if now is None:
                    continue
                d = np.linalg.norm(now[:3, 3] - target)
                if d < best_d:
                    best, best_d = key, d
            if best is None:
                continue
            correction = self.final_anchors[best] @ np.linalg.inv(f.anchors[best])
            f.camera_to_world = correction @ f.camera_to_world
