"""Builds a synthetic Scanvas raw capture of a furnished box room, in exactly the iPhone app's format,
with known geometry, so the pipeline can be tested without a phone."""
import json
import sys
from pathlib import Path

import numpy as np
import open3d as o3d
from PIL import Image


def room():
    parts = []
    # Room 5 x 3 x 4 m, viewed from inside: a box with flipped normals is fine for raycasting.
    parts.append(o3d.geometry.TriangleMesh.create_box(5, 3, 4).translate((-2.5, 0, -2)))
    for size, pos in [((1.2, 0.75, 0.6), (-1.5, 0, -1.7)), ((0.5, 1.8, 0.5), (1.8, 0, 1.2)), ((0.8, 0.45, 0.8), (0.3, 0, 0.2))]:
        parts.append(o3d.geometry.TriangleMesh.create_box(*size).translate(pos))
    sphere = o3d.geometry.TriangleMesh.create_sphere(0.3, 40).translate((-0.8, 1.2, 1.4))
    parts.append(sphere)
    scene = o3d.t.geometry.RaycastingScene()
    for p in parts:
        scene.add_triangles(o3d.t.geometry.TriangleMesh.from_legacy(p))
    return scene, parts


def colour(points):
    """Procedural surface colour: 25 cm checks with fine stripes, so blur and misalignment are visible."""
    c = np.floor(points / 0.25).astype(int).sum(axis=1) % 2
    stripe = (np.sin(points[:, 0] * 60) * np.sin(points[:, 2] * 60) > 0).astype(np.float32)
    base = np.stack([0.85 - 0.5 * c, 0.4 + 0.3 * c, 0.3 + 0.5 * (points[:, 1] / 3)], axis=1)
    return np.clip(base * (0.8 + 0.2 * stripe[:, None]), 0, 1)


def look_at(eye, target):
    f = target - eye
    f /= np.linalg.norm(f)
    right = np.cross(f, [0, 1, 0])
    right /= np.linalg.norm(right)
    up = np.cross(right, f)
    m = np.eye(4)
    m[:3, 0], m[:3, 1], m[:3, 2], m[:3, 3] = right, up, -f, eye   # ARKit: camera looks along -Z
    return m


def main(out: Path, frames=90, noise=0.01, width=960, height=720):
    scene, _ = room()
    for sub in ("images", "depth", "confidence"):
        (out / sub).mkdir(parents=True, exist_ok=True)
    dw, dh = 256, 192
    fx = fy = width * 0.78
    cx, cy = width / 2, height / 2
    rng = np.random.default_rng(1)
    lines = []
    truth = []
    for i in range(frames):
        a = i / frames * 2 * np.pi
        eye = np.array([0.9 * np.cos(a), 1.3 + 0.2 * np.sin(3 * a), 0.7 * np.sin(a)])
        target = np.array([2.5 * np.cos(a + 1.2), 1.0 + 0.8 * np.sin(2 * a), 2.0 * np.sin(a + 1.2)])
        c2w = look_at(eye, target)
        truth.append(c2w)

        def rays(w, h):
            k = w / width
            u, v = np.meshgrid(np.arange(w) + 0.5, np.arange(h) + 0.5)
            x = (u - cx * k) / (fx * k)
            y = -(v - cy * k) / (fy * k)
            d = np.stack([x, y, -np.ones_like(x)], axis=-1)
            world_d = d @ c2w[:3, :3].T
            o = np.broadcast_to(c2w[:3, 3], world_d.shape)
            return np.concatenate([o, world_d], axis=-1).astype(np.float32), d

        r, d = rays(dw, dh)
        hit = scene.cast_rays(o3d.core.Tensor(r))["t_hit"].numpy()
        depth = (hit * 1.0).astype(np.float32)        # -z component is 1 per unit t (d has z = -1)
        depth[~np.isfinite(depth)] = 0
        depth += rng.normal(0, 0.004, depth.shape).astype(np.float32) * (depth > 0)
        r2, _ = rays(width, height)
        t2 = scene.cast_rays(o3d.core.Tensor(r2))["t_hit"].numpy()
        pts = r2[..., :3] + r2[..., 3:] * np.where(np.isfinite(t2), t2, 0)[..., None]
        rgb = (colour(pts.reshape(-1, 3)).reshape(height, width, 3) * 255).astype(np.uint8)
        name = f"{i:06d}"
        Image.fromarray(rgb).save(out / "images" / f"{name}.jpg", quality=92)
        depth.tofile(out / "depth" / f"{name}.bin")
        np.full((dh, dw), 2, np.uint8).tofile(out / "confidence" / f"{name}.bin")
        # Tracking error, as ARKit has: a small drift that grows around the loop plus jitter.
        noisy = c2w.copy()
        noisy[:3, 3] += rng.normal(0, noise, 3) + np.array([1, 0, 0.5]) * noise * np.sin(a)
        lines.append(json.dumps({
            "index": i, "timestamp": i * 0.2, "image": f"images/{name}.jpg", "depth": f"depth/{name}.bin",
            "confidence": f"confidence/{name}.bin", "width": width, "height": height, "depthWidth": dw, "depthHeight": dh,
            "intrinsics": [fx, fy, cx, cy], "cameraToWorld": noisy.T.reshape(-1).tolist(), "anchors": {}}))
    (out / "frames.jsonl").write_text("\n".join(lines) + "\n")
    (out / "anchors.json").write_text("{}")
    (out / "capture.json").write_text(json.dumps({"format": "scanvas-raw", "version": 1, "kind": "space", "frames": frames,
                                                  "imageWidth": width, "imageHeight": height, "depthWidth": dw, "depthHeight": dh}))
    np.save(out / "truth_poses.npy", np.array(truth))
    print("wrote", frames, "frames to", out)


if __name__ == "__main__":
    main(Path(sys.argv[1]), frames=int(sys.argv[2]) if len(sys.argv) > 2 else 90)
