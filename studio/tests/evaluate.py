"""Scores a Studio result against the synthetic room: surface error, and how close renders of the textured
model are to the true colours from a few camera positions."""
import sys
from pathlib import Path

import numpy as np
import open3d as o3d
from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
from make_synthetic import room, colour, look_at  # noqa: E402


def main(out: Path, synth: Path, max_mean_mm: float = 0.0):
    scene, _ = room()
    dense = o3d.io.read_triangle_mesh(str(out / "model_dense_colour.ply"))
    v = np.asarray(dense.vertices, dtype=np.float32)
    dist = scene.compute_distance(o3d.core.Tensor(v)).numpy()
    print(f"surface error: mean {dist.mean() * 1000:.1f} mm, 95% {np.percentile(dist, 95) * 1000:.1f} mm, vertices {len(v):,}")
    if max_mean_mm and dist.mean() * 1000 > max_mean_mm:
        sys.exit(f"FAILED: mean surface error is above {max_mean_mm} mm")

    obj = out / "model_textured.obj"
    if not obj.exists():
        return
    tm = o3d.t.io.read_triangle_mesh(str(obj))
    tex = np.asarray(Image.open(out / "model_textured.jpg").convert("RGB"), dtype=np.float32) / 255
    uvs = tm.triangle["texture_uvs"].numpy()                    # (T, 3, 2)
    rs = o3d.t.geometry.RaycastingScene()
    rs.add_triangles(o3d.t.geometry.TriangleMesh(tm.vertex.positions, tm.triangle.indices))
    W, H = 320, 240
    f = W * 0.78
    errs = []
    views = []
    for k, (eye, target) in enumerate([((0, 1.4, 0), (2.5, 1, 0)), ((0.3, 1.5, 0.2), (-2.5, 0.8, -1.5)), ((0, 1.6, -0.3), (0.5, 0.6, 2))]):
        c2w = look_at(np.array(eye, float), np.array(target, float))
        u, vv = np.meshgrid(np.arange(W) + 0.5, np.arange(H) + 0.5)
        d = np.stack([(u - W / 2) / f, -(vv - H / 2) / f, -np.ones_like(u)], -1) @ c2w[:3, :3].T
        rays = np.concatenate([np.broadcast_to(c2w[:3, 3], d.shape), d], -1).astype(np.float32)
        truth_hit = scene.cast_rays(o3d.core.Tensor(rays))["t_hit"].numpy()
        truth = colour((rays[..., :3] + rays[..., 3:] * truth_hit[..., None]).reshape(-1, 3)).reshape(H, W, 3)
        ans = rs.cast_rays(o3d.core.Tensor(rays))
        ids = ans["primitive_ids"].numpy()
        bary = ans["primitive_uvs"].numpy()
        ok = ids != o3d.t.geometry.RaycastingScene.INVALID_ID
        img = np.zeros((H, W, 3), np.float32)
        tri = uvs[ids[ok]]
        a, b = bary[ok][:, 0:1], bary[ok][:, 1:2]
        uv = tri[:, 0] * (1 - a - b) + tri[:, 1] * a + tri[:, 2] * b
        px = np.clip((uv[:, 0] * tex.shape[1]).astype(int), 0, tex.shape[1] - 1)
        py = np.clip(((1 - uv[:, 1]) * tex.shape[0]).astype(int), 0, tex.shape[0] - 1)
        img[ok] = tex[py, px]
        e = np.abs(img[ok] - truth[ok]).mean() * 255
        errs.append(e)
        views.append(np.concatenate([truth, img], 1))
        print(f"view {k}: mean colour error {e:.1f} / 255, coverage {ok.mean() * 100:.0f}%")
    Image.fromarray((np.concatenate(views, 0) * 255).clip(0, 255).astype(np.uint8)).save(out / "eval_views.jpg")


if __name__ == "__main__":
    main(Path(sys.argv[1]), Path(sys.argv[2]), float(sys.argv[3]) if len(sys.argv) > 3 else 0.0)
