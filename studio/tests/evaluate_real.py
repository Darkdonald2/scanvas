"""Measures a Studio result against the capture it came from. No ground truth is needed:

  geometry  the model, seen from each photo's position, should be at the depth the LiDAR measured there
            (median difference; share of pixels where the model has something well in front of what the
            LiDAR saw = floating or doubled surfaces; share where the model has nothing = holes)
  texture   the textured model rendered from a photo's position should look like the photo

Uses the camera positions Studio saved (cameras.json); photos it dropped are skipped.

  python tests/evaluate_real.py <results folder> <raw capture folder> [--images DIR] [--every N]
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from scanvas_studio.capture import Capture  # noqa: E402

Image.MAX_IMAGE_PIXELS = None


def load_obj(path: Path):
    v, vt, f, ft, mats, cur = [], [], [], [], [], 0
    names = {}
    for line in open(path):
        if line.startswith("v "):
            v.append(line[2:].split())
        elif line.startswith("vt "):
            vt.append(line[3:].split())
        elif line.startswith("usemtl "):
            cur = names.setdefault(line.split()[1], len(names))
        elif line.startswith("f "):
            p = [q.split("/") for q in line[2:].split()]
            f.append([int(q[0]) for q in p])
            ft.append([int(q[1]) if len(q) > 1 and q[1] else 0 for q in p])
            mats.append(cur)
    V = np.array(v, np.float32)
    F = np.array(f, np.int64) - 1
    VT = np.array(vt, np.float32) if vt else np.zeros((1, 2), np.float32)
    UV = VT[np.array(ft, np.int64) - 1] if vt else None
    # texture file per material, from the .mtl
    tex = {}
    mtl = path.with_suffix(".mtl")
    if mtl.exists():
        name = None
        for line in open(mtl):
            if line.startswith("newmtl "):
                name = line.split()[1]
            elif line.startswith("map_Kd ") and name is not None:
                tex[names.get(name, 0)] = path.parent / line.split(None, 1)[1].strip()
    return V, F, UV, np.array(mats, np.int32), tex


class Renderer:
    def __init__(self, V, F, UV=None, mats=None, textures=None):
        import open3d as o3d
        self.o3d = o3d
        self.scene = o3d.t.geometry.RaycastingScene()
        self.scene.add_triangles(o3d.core.Tensor(V.astype(np.float32)), o3d.core.Tensor(F.astype(np.uint32)))
        self.V, self.F, self.UV, self.mats = V, F, UV, mats
        self.tex = {k: np.asarray(Image.open(p).convert("RGB")) for k, p in (textures or {}).items()}
        a, b, c = V[F[:, 0]], V[F[:, 1]], V[F[:, 2]]
        n = np.cross(b - a, c - a)
        self.N = n / np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-12)

    def cast(self, c2w_cv, k, w, h):
        u, v = np.meshgrid(np.arange(w, dtype=np.float64), np.arange(h, dtype=np.float64))
        d = np.stack([(u - k[0, 2]) / k[0, 0], (v - k[1, 2]) / k[1, 1], np.ones_like(u)], axis=-1)
        rays = np.concatenate([np.broadcast_to(c2w_cv[:3, 3], d.shape), d @ c2w_cv[:3, :3].T], axis=-1).astype(np.float32)
        return self.scene.cast_rays(self.o3d.core.Tensor(rays)), rays

    def depth(self, c2w_cv, k, w, h):
        return self.cast(c2w_cv, k, w, h)[0]["t_hit"].numpy()

    def colour(self, c2w_cv, k, w, h, shade_only=False):
        hit, rays = self.cast(c2w_cv, k, w, h)
        t = hit["t_hit"].numpy()
        ids = hit["primitive_ids"].numpy().astype(np.int64)
        ok = np.isfinite(t)
        img = np.zeros((h, w, 3), np.uint8)
        tri = ids[ok]
        if shade_only or self.UV is None or not self.tex:
            # Grey, lit from the camera: shows the shape.
            dirs = rays[..., 3:][ok]
            dirs = dirs / np.linalg.norm(dirs, axis=1, keepdims=True)
            s = np.abs(np.einsum("ij,ij->i", self.N[tri], dirs))
            img[ok] = (60 + 180 * s)[:, None].astype(np.uint8)
            return img, ok
        b = hit["primitive_uvs"].numpy()[ok]
        uv = self.UV[tri]
        p = uv[:, 0] * (1 - b[:, :1] - b[:, 1:2]) + uv[:, 1] * b[:, :1] + uv[:, 2] * b[:, 1:2]
        out = np.zeros((len(tri), 3), np.uint8)
        for m, tex in self.tex.items():
            sel = self.mats[tri] == m
            th, tw = tex.shape[:2]
            x = np.clip((p[sel, 0] * tw).astype(np.int64), 0, tw - 1)
            y = np.clip(((1 - p[sel, 1]) * th).astype(np.int64), 0, th - 1)
            out[sel] = tex[y, x]
        img[ok] = out
        return img, ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("result")
    ap.add_argument("capture")
    ap.add_argument("--images", help="save side-by-side pictures here")
    ap.add_argument("--every", type=int, default=6)
    ap.add_argument("--width", type=int, default=640)
    ap.add_argument("--geometry", help="score this mesh file's shape only (no texture), e.g. model_dense_colour.ply")
    ap.add_argument("--cameras", help="cameras.json to use instead of the one in the results folder")
    a = ap.parse_args()
    out = Path(a.result)
    cap = Capture.open(a.capture)
    cams_path = Path(a.cameras) if a.cameras else out / "cameras.json"
    poses = None
    if cams_path.exists():
        poses = {int(k): np.array(v, np.float64).reshape(4, 4) for k, v in json.loads(cams_path.read_text())["cameraToWorld"].items()}
    if a.geometry:
        import open3d as o3d
        g = o3d.io.read_triangle_mesh(a.geometry)
        V, F = np.asarray(g.vertices, np.float32), np.asarray(g.triangles, np.int64)
        r = Renderer(V, F)
    else:
        V, F, UV, mats, tex = load_obj(out / "model_textured.obj")
        r = Renderer(V, F, UV, mats, tex)
    flip = np.diag([1.0, -1.0, -1.0, 1.0])
    geo, front, holes, photo = [], [], [], []
    shown = 0
    if a.images:
        Path(a.images).mkdir(parents=True, exist_ok=True)
    for f in cap.frames[::a.every]:
        if poses is not None:
            if f.index not in poses:
                continue
            f.camera_to_world = poses[f.index]
        c2w = np.linalg.inv(f.extrinsic())
        # geometry, at the LiDAR's own resolution
        d = f.load_depth(2, 4.0, drop_edges=True)
        m = d > 0
        if m.sum() > 500:
            t = r.depth(c2w, f.depth_intrinsic(), f.depth_width, f.depth_height)
            hit = np.isfinite(t)
            diff = (t - d)[m & hit]
            geo.append(np.median(np.abs(diff)))
            front.append(float((diff < -(0.05 + 0.02 * d[m & hit])).mean()))
            holes.append(float((m & ~hit).sum() / m.sum()))
        # texture
        w = a.width
        h = round(w * f.height / f.width)
        img, ok = r.colour(c2w, f.intrinsic(w / f.width), w, h)
        with Image.open(f.image) as im:
            ph = np.asarray(im.convert("RGB").resize((w, h), Image.BILINEAR))
        if ok.mean() > 0.3 and not a.geometry:
            x, y = img[ok].astype(np.float32), ph[ok].astype(np.float32)
            g = y.mean(0) / np.maximum(x.mean(0), 1)          # overall brightness doesn't count
            photo.append(float(np.abs(np.clip(x * g, 0, 255) - y).mean()))
        if a.images and shown < 14 and (cap.frames.index(f) // a.every) % max(1, len(cap.frames) // a.every // 14) == 0:
            shade, _ = r.colour(c2w, f.intrinsic(w / f.width), w, h, shade_only=True)
            row = np.concatenate([np.rot90(z, -1) for z in (ph, img, shade)], 1)
            Image.fromarray(row).save(Path(a.images) / f"view_{f.index:04d}.jpg", quality=88)
            shown += 1
    res = {
        "frames_checked": len(geo),
        "depth_error_mm_median": round(float(np.median(geo)) * 1000, 1),
        "depth_error_mm_worst10pct": round(float(np.percentile(geo, 90)) * 1000, 1),
        "in_front_of_lidar_pct": round(float(np.mean(front)) * 100, 2),
        "holes_pct": round(float(np.mean(holes)) * 100, 2),
        "photo_difference": round(float(np.mean(photo)), 2) if photo else None,
        "photo_difference_worst10pct": round(float(np.percentile(photo, 90)), 2) if photo else None,
        "triangles": int(len(F)),
    }
    print(json.dumps(res, indent=2))


if __name__ == "__main__":
    main()
