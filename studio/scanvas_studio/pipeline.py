"""Scanvas Studio processing: raw iPhone capture -> dense, photo-textured model.

Steps (each reports progress):
  1. Choose photos: drop blurred ones, keep the sharpest in every spot.
  2. Fuse depth: every LiDAR depth map goes into one volume (TSDF), far more detail than the phone's live mesh.
  3. Refine cameras: line each photo's depth up with the phone's own mesh (which has ARKit's corrections in it),
     then with the fused surface (ICP), then fuse again.
  4. Clean: remove floating bits and smooth noise.
  5. Texture: unwrap the mesh and project the best full-resolution photos onto it.
  6. Export: OBJ (textured), GLB, PLY (coloured), point cloud.
"""
from __future__ import annotations

import json
import math
import time
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Callable

import numpy as np
from PIL import Image

from .capture import Capture, Frame
from .texturing import bake, write_glb, write_obj

Report = Callable[[str, float], None]


@dataclass
class Settings:
    quality: str = "high"          # fast, high, ultra
    refine_cameras: bool = True
    smooth: bool = True
    texture: bool = True
    z_up: bool = False             # rotate so Z is up (Revit, AutoCAD, Rhino)
    max_depth: float = 4.5         # metres: LiDAR gets noisy further away
    min_confidence: int = 1        # 0 low, 1 medium, 2 high
    texture_limit: int = 0         # override for the texturing triangle budget (0 = quality default)

    @property
    def voxel(self) -> float:
        return {"fast": 0.02, "high": 0.01, "ultra": 0.006}[self.quality]

    @property
    def fuse_frames(self) -> int:
        return {"fast": 400, "high": 1500, "ultra": 4000}[self.quality]

    @property
    def texture_photos(self) -> int:
        return {"fast": 150, "high": 500, "ultra": 800}[self.quality]

    @property
    def texture_size(self) -> int:
        return {"fast": 4096, "high": 8192, "ultra": 8192}[self.quality]

    @property
    def texture_triangles(self) -> int:
        if self.texture_limit:
            return self.texture_limit
        return {"fast": 200_000, "high": 600_000, "ultra": 1_200_000}[self.quality]


def _o3d():
    import open3d as o3d   # imported late so the window opens fast
    return o3d


# ---------------------------------------------------------------------------------------------- photo choice

def sharpness(path: Path) -> float:
    """Variance of the Laplacian on a small grey copy: low means motion blur."""
    with Image.open(path) as im:
        im.draft("L", (480, 360))
        g = np.asarray(im.convert("L").resize((480, 360)), dtype=np.float32)
    lap = 4 * g[1:-1, 1:-1] - g[:-2, 1:-1] - g[2:, 1:-1] - g[1:-1, :-2] - g[1:-1, 2:]
    return float(lap.var())


def choose_frames(frames: list[Frame], limit: int, report: Report, base: float, span: float) -> list[Frame]:
    for i, f in enumerate(frames):
        f.sharpness = sharpness(f.image)
        if i % 20 == 0:
            report(f"Checking photo sharpness ({i + 1} of {len(frames)})", base + span * i / max(1, len(frames)))
    # Blur is relative: compare each photo with its neighbours in time.
    s = np.array([f.sharpness for f in frames])
    keep = []
    for i, f in enumerate(frames):
        local = np.median(s[max(0, i - 10): i + 11])
        if f.sharpness >= 0.55 * local:
            keep.append(f)
    if len(keep) <= limit:
        return keep
    # Too many: keep the sharpest per small region of camera position and direction.
    cells: dict[tuple, Frame] = {}
    step = 0.15
    while True:
        cells.clear()
        for f in keep:
            p, d = f.position(), f.forward()
            key = tuple(np.floor(p / step).astype(int)) + tuple(np.round(d * 3).astype(int))
            if key not in cells or f.sharpness > cells[key].sharpness:
                cells[key] = f
        if len(cells) <= limit:
            break
        step *= 1.25
    return sorted(cells.values(), key=lambda f: f.timestamp)


def spread_frames(frames: list[Frame], limit: int) -> list[Frame]:
    """Photos for texturing: sharp ones that between them see the space from as many places as possible."""
    if len(frames) <= limit:
        return frames
    order = sorted(frames, key=lambda f: -f.sharpness)
    chosen: list[Frame] = []
    pos = np.array([f.position() for f in order])
    fwd = np.array([f.forward() for f in order])
    best = np.full(len(order), np.inf)
    first = 0
    chosen_idx = [first]
    best = np.linalg.norm(pos - pos[first], axis=1) + 0.6 * (1 - fwd @ fwd[first])
    sharp = np.array([f.sharpness for f in order])
    sharp = sharp / max(1e-6, sharp.max())
    while len(chosen_idx) < limit:
        score = best * (0.5 + 0.5 * sharp)
        score[chosen_idx] = -1
        i = int(np.argmax(score))
        if score[i] <= 0:
            break
        chosen_idx.append(i)
        best = np.minimum(best, np.linalg.norm(pos - pos[i], axis=1) + 0.6 * (1 - fwd @ fwd[i]))
    chosen = [order[i] for i in chosen_idx]
    return sorted(chosen, key=lambda f: f.timestamp)


# ---------------------------------------------------------------------------------------------- fusion

def _device():
    o3d = _o3d()
    try:
        if o3d.core.cuda.is_available():
            return o3d.core.Device("CUDA:0")
    except Exception:
        pass
    return o3d.core.Device("CPU:0")


def fuse(frames: list[Frame], s: Settings, report: Report, base: float, span: float, label: str):
    o3d = _o3d()
    o3c = o3d.core
    device = _device()
    vbg = o3d.t.geometry.VoxelBlockGrid(
        attr_names=("tsdf", "weight", "color"),
        attr_dtypes=(o3c.float32, o3c.float32, o3c.float32),
        attr_channels=((1), (1), (3)),
        voxel_size=s.voxel, block_resolution=8,
        block_count=60_000, device=device)
    for i, f in enumerate(frames):
        if i % 10 == 0:
            report(f"{label} ({i + 1} of {len(frames)})", base + span * i / max(1, len(frames)))
        d = f.load_depth(s.min_confidence, s.max_depth, drop_edges=True)
        if not np.any(d):
            continue
        # Colour at half resolution is plenty for the volume; the texture uses full-resolution photos.
        with Image.open(f.image) as im:
            cw, ch = f.width // 2, f.height // 2
            im.draft("RGB", (cw, ch))
            rgb = np.asarray(im.convert("RGB").resize((cw, ch), Image.BILINEAR), dtype=np.float32) / 255.0
        depth = o3d.t.geometry.Image(o3c.Tensor(d)).to(device)
        color = o3d.t.geometry.Image(o3c.Tensor(np.ascontiguousarray(rgb))).to(device)
        dk = o3c.Tensor(f.depth_intrinsic(), o3c.float64)
        ck = o3c.Tensor(f.intrinsic(cw / f.width), o3c.float64)
        ext = o3c.Tensor(f.extrinsic(), o3c.float64)
        coords = vbg.compute_unique_block_coordinates(depth, dk, ext, 1.0, s.max_depth)
        vbg.integrate(coords, depth, color, dk, ck, ext, 1.0, s.max_depth)
    report(f"{label}: building the surface", base + span)
    mesh = vbg.extract_triangle_mesh(weight_threshold=1.5)
    return mesh.to_legacy()


# ---------------------------------------------------------------------------------------------- camera alignment

def _depth_cloud(f: Frame, max_depth: float, target_points: int = 4000):
    """A frame's reliable LiDAR depth as world points (at the frame's current position)."""
    o3d = _o3d()
    d = f.load_depth(2, max_depth, drop_edges=True)
    if np.count_nonzero(d) < 1500:
        d = f.load_depth(1, max_depth, drop_edges=True)
    v, u = np.nonzero(d)
    if len(u) < 500:
        return None
    sel = np.arange(0, len(u), max(1, len(u) // target_points))
    u, v = u[sel], v[sel]
    z = d[v, u]
    k = f.depth_intrinsic()
    pts = np.stack([(u - k[0, 2]) / k[0, 0] * z, (v - k[1, 2]) / k[1, 1] * z, z], axis=1)
    c2w = np.linalg.inv(f.extrinsic())
    return o3d.geometry.PointCloud(o3d.utility.Vector3dVector(pts @ c2w[:3, :3].T + c2w[:3, 3]))


def align_to_phone_mesh(folder: Path, frames: list[Frame], s: Settings, report: Report, base: float, span: float):
    """Moves each photo to where it fits the phone's own finished mesh, and drops photos that fit nowhere.

    While scanning, ARKit keeps correcting its map, and its mesh is rebuilt to match. The photos keep the
    position they had when they were taken, so early ones can be tens of centimetres off, which fuses every
    wall two or three times. The phone's mesh (arkit_mesh.ply) is coarse but in the corrected map, so it is the
    reference: each photo's depth is slid onto it (point-to-plane ICP, coarse to fine). The fine alignment
    against Studio's own fused surface comes afterwards.
    Returns the photos to use and a few numbers for the log."""
    o3d = _o3d()
    reg = o3d.pipelines.registration
    path = Path(folder) / "arkit_mesh.ply"
    if not path.exists():
        return frames, {}
    mesh = o3d.io.read_triangle_mesh(str(path))
    if len(mesh.triangles) < 500:
        return frames, {}
    n = int(min(1_500_000, max(100_000, mesh.get_surface_area() * 5000)))
    target = mesh.sample_points_uniformly(number_of_points=n, use_triangle_normal=True).voxel_down_sample(0.02)
    target.normalize_normals()
    check = 0.04                                   # a point "fits" when it is within 4 cm of the phone's mesh

    def icp(src, init, ladder):
        T = init
        for dist in ladder:
            r = reg.registration_icp(src, target, dist, T, reg.TransformationEstimationPointToPlane(reg.TukeyLoss(k=dist)),
                                     reg.ICPConvergenceCriteria(max_iteration=30))
            T = r.transformation
        return T, reg.evaluate_registration(src, target, check, T)

    original = [f.camera_to_world.copy() for f in frames]
    previous = np.eye(4)
    keep, shifts = [], []
    moved = dropped = 0
    for i, f in enumerate(frames):
        if i % 10 == 0:
            report(f"Lining photos up with the phone's map ({i + 1} of {len(frames)})", base + span * i / max(1, len(frames)))
        src = _depth_cloud(f, min(s.max_depth, 4.0))
        if src is None:
            keep.append(f)
            continue
        e0 = reg.evaluate_registration(src, target, check, np.eye(4))
        if e0.fitness >= 0.85:
            tries = [icp(src, np.eye(4), (0.06, 0.03))]
        else:
            tries = [icp(src, np.eye(4), (0.5, 0.25, 0.12, 0.06, 0.03))]
            if not np.allclose(previous, np.eye(4)):
                # Drift changes slowly, so the correction the photo before needed is a good place to start.
                tries.append(icp(src, previous, (0.12, 0.06, 0.03)))
        T, e1 = max(tries, key=lambda t: (round(t[1].fitness, 2), -t[1].inlier_rmse))
        shift = float(np.linalg.norm(T[:3, 3] + (T[:3, :3] - np.eye(3)) @ f.position()))     # how far the camera moves
        angle = math.degrees(math.acos(max(-1.0, min(1.0, (np.trace(T[:3, :3]) - 1) / 2))))
        better = e1.fitness >= e0.fitness + 0.02 or (e1.fitness >= e0.fitness and e1.inlier_rmse < e0.inlier_rmse * 0.92)
        if e1.fitness >= 0.45 and better and shift < 1.5 and angle < 20:
            f.camera_to_world = T @ f.camera_to_world
            previous = T
            moved += 1
            shifts.append(shift)
            keep.append(f)
        elif max(e0.fitness, e1.fitness) < 0.25:
            dropped += 1                           # fits the map nowhere nearby: it would only add a ghost surface
        else:
            keep.append(f)
    if dropped > 0.35 * len(frames):
        # The phone's mesh doesn't match this capture well enough to judge by; leave everything as it was.
        for f, m in zip(frames, original):
            f.camera_to_world = m
        return frames, {"alignment_skipped": "the phone's mesh did not match the photos"}
    stats = {"frames_aligned": moved, "frames_dropped": dropped}
    if shifts:
        stats["alignment_shift_cm"] = {"median": round(float(np.median(shifts)) * 100, 1), "largest": round(float(np.max(shifts)) * 100, 1)}
    return keep, stats


# ---------------------------------------------------------------------------------------------- camera refinement

def refine_cameras(frames: list[Frame], mesh, s: Settings, report: Report, base: float, span: float) -> int:
    """Point-to-plane ICP of each photo's depth against the fused surface; small, well-supported corrections only."""
    o3d = _o3d()
    reg = o3d.pipelines.registration
    target = mesh.sample_points_uniformly(number_of_points=min(3_000_000, max(200_000, len(mesh.triangles))))
    target = target.voxel_down_sample(max(0.008, s.voxel))
    target.estimate_normals(o3d.geometry.KDTreeSearchParamHybrid(radius=0.05, max_nn=30))
    changed = 0
    for i, f in enumerate(frames):
        if i % 10 == 0:
            report(f"Refining cameras ({i + 1} of {len(frames)})", base + span * i / max(1, len(frames)))
        d = f.load_depth(2, min(s.max_depth, 4.0), drop_edges=True)
        v, u = np.nonzero(d)
        if len(u) < 500:
            continue
        sel = np.arange(0, len(u), 2)
        u, v = u[sel], v[sel]
        z = d[v, u]
        k = f.depth_intrinsic()
        pts_cv = np.stack([(u - k[0, 2]) / k[0, 0] * z, (v - k[1, 2]) / k[1, 1] * z, z], axis=1)
        cam_to_world_cv = np.linalg.inv(f.extrinsic())
        world = pts_cv @ cam_to_world_cv[:3, :3].T + cam_to_world_cv[:3, 3]
        src = o3d.geometry.PointCloud(o3d.utility.Vector3dVector(world))
        T = np.eye(4)
        ok = True
        for dist in (0.06, 0.03, 0.015):
            r = reg.registration_icp(src, target, dist, T, reg.TransformationEstimationPointToPlane(reg.TukeyLoss(k=dist)),
                                     reg.ICPConvergenceCriteria(max_iteration=20))
            if r.fitness < 0.35:
                ok = False
                break
            T = r.transformation
        if not ok:
            continue
        move = np.linalg.norm(T[:3, 3])
        angle = math.degrees(math.acos(max(-1.0, min(1.0, (np.trace(T[:3, :3]) - 1) / 2))))
        if move < 0.08 and angle < 2.5:
            f.camera_to_world = T @ f.camera_to_world
            changed += 1
    return changed


# ---------------------------------------------------------------------------------------------- cleaning

def clean(mesh, s: Settings, report: Report):
    o3d = _o3d()
    report("Cleaning: removing floating bits", 0)
    mesh.remove_degenerate_triangles()
    mesh.remove_duplicated_triangles()
    mesh.remove_duplicated_vertices()
    mesh.remove_non_manifold_edges()
    if len(mesh.triangles):
        clusters, counts, areas = mesh.cluster_connected_triangles()
        clusters = np.asarray(clusters)
        areas = np.asarray(areas)
        total = areas.sum()
        # A piece is a floater when it is tiny next to the scan (people walking by, reflections, dust).
        small = areas < max(0.02, total * 0.0005)
        mesh.remove_triangles_by_mask(small[clusters])
        mesh.remove_unreferenced_vertices()
    if s.smooth and len(mesh.triangles):
        report("Cleaning: smoothing noise", 0)
        colors = np.asarray(mesh.vertex_colors).copy()
        mesh = mesh.filter_smooth_taubin(number_of_iterations=3)
        if len(colors) == len(mesh.vertices):
            mesh.vertex_colors = o3d.utility.Vector3dVector(colors)
    mesh.compute_vertex_normals()
    return mesh


# ---------------------------------------------------------------------------------------------- texturing

def make_manifold(mesh, rounds: int = 6):
    """Unwrapping needs a clean surface: no edge shared by more than two triangles and no vertex where separate
    sheets touch. Simplifying a big scan creates a few of those; cut them out (a handful of triangles)."""
    for _ in range(rounds):
        mesh.remove_degenerate_triangles()
        mesh.remove_duplicated_triangles()
        mesh.remove_duplicated_vertices()
        mesh.remove_non_manifold_edges()
        bad = np.asarray(mesh.get_non_manifold_vertices())
        if len(bad):
            mesh.remove_vertices_by_index(bad.tolist())
        mesh.remove_unreferenced_vertices()
        if mesh.is_edge_manifold() and mesh.is_vertex_manifold():
            break
    return mesh


def texture(mesh, frames: list[Frame], s: Settings, report: Report, base: float, span: float):
    """Returns a tensor mesh with UVs and an albedo texture, or None when it can't be done."""
    o3d = _o3d()
    o3c = o3d.core
    work = mesh
    if len(work.triangles) > s.texture_triangles:
        report(f"Texturing: simplifying to {s.texture_triangles:,} triangles", base)
        work = work.simplify_quadric_decimation(s.texture_triangles)
        work.remove_unreferenced_vertices()
    work = make_manifold(work)
    work.compute_vertex_normals()
    t = o3d.t.geometry.TriangleMesh.from_legacy(work)
    report("Texturing: unwrapping the surface (this can take a few minutes)", base + span * 0.03)
    try:
        t.compute_uvatlas(size=s.texture_size, gutter=2.0, max_stretch=0.16, parallel_partitions=8, nthreads=0)
    except RuntimeError:
        # Splitting into parallel parts can itself leave a tangled spot; unwrap in one piece instead (slower).
        t = o3d.t.geometry.TriangleMesh.from_legacy(make_manifold(work, 12))
        t.compute_uvatlas(size=s.texture_size, gutter=2.0, max_stretch=0.16, parallel_partitions=1, nthreads=0)
    V = t.vertex.positions.numpy().astype(np.float64)
    F = t.triangle.indices.numpy().astype(np.int64)
    UV = t.triangle.texture_uvs.numpy().astype(np.float64)
    colours = t.vertex.colors.numpy().astype(np.float32) if "colors" in t.vertex else None
    if colours is None or len(colours) != len(V):
        colours = _nearest_colours(mesh, V)
    normals = np.asarray(work.vertex_normals) if len(work.vertex_normals) == len(V) else np.zeros_like(V)
    photos = spread_frames(frames, s.texture_photos)
    image, stats = bake(V, F, UV, colours, photos, s.texture_size, report, base + span * 0.1, span * 0.9)
    return {"V": V, "F": F, "UV": UV, "normals": normals, "image": image, "stats": stats}


def _nearest_colours(mesh, V: np.ndarray):
    """Fused colours for the simplified mesh's vertices, taken from the nearest vertex of the full mesh
    (simplifying can drop them). Used for the few surfaces no photo shows."""
    o3d = _o3d()
    src = np.asarray(mesh.vertex_colors)
    if len(src) != len(mesh.vertices) or not len(src):
        return None
    try:
        import open3d.core as o3c
        nns = o3c.nns.NearestNeighborSearch(o3c.Tensor(np.asarray(mesh.vertices, dtype=np.float32)))
        nns.knn_index()
        idx, _ = nns.knn_search(o3c.Tensor(V.astype(np.float32)), 1)
        return src[idx.numpy().ravel()].astype(np.float32)
    except Exception:
        return None


# ---------------------------------------------------------------------------------------------- export

def _orient(m, z_up: bool):
    if z_up:
        # ARKit is Y up; rotate +90 degrees about X so it becomes Z up.
        R = np.array([[1, 0, 0], [0, 0, -1], [0, 1, 0]], dtype=np.float64)
        m.rotate(R, center=(0, 0, 0))
    return m


def export(out: Path, dense, textured, s: Settings, report: Report) -> list[Path]:
    o3d = _o3d()
    out.mkdir(parents=True, exist_ok=True)
    files = []
    report("Saving files", 0.96)
    dense = _orient(dense, s.z_up)
    p = out / "model_dense_colour.ply"
    o3d.io.write_triangle_mesh(str(p), dense, write_ascii=False, compressed=False)
    files.append(p)
    pc = o3d.geometry.PointCloud(dense.vertices)
    pc.colors = dense.vertex_colors
    pc.normals = dense.vertex_normals
    p = out / "point_cloud.ply"
    o3d.io.write_point_cloud(str(p), pc)
    files.append(p)
    if textured is not None:
        V, N = textured["V"].copy(), textured["normals"].copy()
        if s.z_up:
            R = np.array([[1, 0, 0], [0, 0, -1], [0, 1, 0]], dtype=np.float64)
            V, N = V @ R.T, N @ R.T
        import io
        buf = io.BytesIO()
        Image.fromarray(textured["image"]).save(buf, "JPEG", quality=93, subsampling=0)
        jpeg = buf.getvalue()
        tex = out / "model_textured.jpg"
        tex.write_bytes(jpeg)
        p = out / "model_textured.obj"
        write_obj(p, V, textured["F"], textured["UV"], N, tex.name)
        files += [p, p.with_suffix(".mtl"), tex]
        p = out / "model_textured.glb"
        write_glb(p, V, textured["F"], textured["UV"], N, jpeg)
        files.append(p)
        if s.z_up:
            # The phone works in its own Y-up coordinates, so it gets an unrotated copy.
            p = out / "phone_model.glb"
            write_glb(p, textured["V"], textured["F"], textured["UV"], textured["normals"], jpeg)
            files.append(p)
    else:
        p = out / "model_dense_colour.obj"
        o3d.io.write_triangle_mesh(str(p), dense)
        files.append(p)
    return files


def phone_model(out: Path) -> Path | None:
    """The model to send back to the iPhone (always in the phone's Y-up coordinates)."""
    for name in ("phone_model.glb", "model_textured.glb"):
        if (out / name).exists():
            return out / name
    return None


def view(path: Path):
    """Opens a result in a 3D window (drag to turn, scroll to zoom)."""
    o3d = _o3d()
    obj = path.with_name("model_textured.obj") if path.suffix == ".glb" else path
    if not obj.exists():
        obj = path.with_name("model_dense_colour.ply")
    mesh = o3d.io.read_triangle_mesh(str(obj), enable_post_processing=True)
    mesh.compute_vertex_normals()
    o3d.visualization.draw_geometries([mesh], window_name="Scanvas Studio · " + path.parent.name,
                                      width=1280, height=800, mesh_show_back_face=True)


# ---------------------------------------------------------------------------------------------- whole run

def process(capture: Capture, out: Path, s: Settings, report: Report) -> dict:
    o3d = _o3d()
    start = time.time()
    log: dict = {"name": capture.name, "settings": asdict(s), "frames_in_capture": len(capture.frames)}
    if not capture.frames:
        raise ValueError("The capture has no photos with depth.")
    report("Choosing photos", 0.0)
    frames = choose_frames(capture.frames, s.fuse_frames, report, 0.0, 0.08)
    log["frames_used"] = len(frames)
    if s.refine_cameras:
        frames, aligned = align_to_phone_mesh(capture.folder, frames, s, report, 0.08, 0.07)
        log.update(aligned)
        log["frames_used"] = len(frames)
        mesh = fuse(frames, s if s.quality == "fast" else Settings(**{**asdict(s), "quality": "fast"}),
                    report, 0.15, 0.10, "Fusing depth, first pass")
        mesh.compute_vertex_normals()
        log["cameras_refined"] = refine_cameras(frames, mesh, s, report, 0.25, 0.15)
        del mesh
        mesh = fuse(frames, s, report, 0.40, 0.2, "Fusing depth with refined cameras")
    else:
        mesh = fuse(frames, s, report, 0.08, 0.32, "Fusing depth")
    log["fused_triangles"] = len(mesh.triangles)
    if not len(mesh.triangles):
        raise ValueError("No surface could be built from this capture's depth.")
    mesh = clean(mesh, s, lambda m, _: report(m, 0.62))
    log["clean_triangles"] = len(mesh.triangles)
    textured = None
    if s.texture:
        # If unwrapping fails on a huge or tangled surface, try again with a lighter mesh before giving up.
        budget = s.texture_triangles
        for attempt in range(3):
            try:
                ts = Settings(**{**asdict(s), "texture_limit": budget})
                textured = texture(mesh, frames, ts, report, 0.64, 0.3)
                log.update(textured["stats"])
                log.pop("texture_error", None)
                break
            except Exception as e:   # e.g. out of memory: still deliver the coloured mesh
                log["texture_error"] = str(e)
                textured = None
                budget //= 2
                report(f"Texturing: trying again with {budget:,} triangles", 0.64)
    files = export(out, mesh, textured, s, report)
    log["files"] = [f.name for f in files]
    log["minutes"] = round((time.time() - start) / 60, 1)
    (out / "processing.json").write_text(json.dumps(log, indent=2))
    report("Done", 1.0)
    return log
