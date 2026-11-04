"""Photo texturing for Scanvas Studio.

Each triangle takes its pixels from the single photo that saw it best: close, head-on, sharp, near the middle of
the frame and not blocked by anything in front (checked by casting a ray to it). Neighbouring triangles then
follow each other's photo where that photo also sees them well, which keeps patches large and seams few.
Photos are brightness-matched to each other, and every texel is sampled from the full-resolution photo.
"""
from __future__ import annotations

import math
from typing import Callable

import numpy as np
from PIL import Image, ImageDraw

from .capture import Frame

Report = Callable[[str, float], None]
K = 6     # candidate photos remembered per triangle


def _load(frame: Frame) -> np.ndarray:
    with Image.open(frame.image) as im:
        return np.asarray(im.convert("RGB"))


def _bilinear(img: np.ndarray, x: np.ndarray, y: np.ndarray) -> np.ndarray:
    h, w = img.shape[:2]
    x = np.clip(x, 0, w - 1.001)
    y = np.clip(y, 0, h - 1.001)
    x0 = x.astype(np.int32)
    y0 = y.astype(np.int32)
    fx = (x - x0)[:, None]
    fy = (y - y0)[:, None]
    a = img[y0, x0].astype(np.float32)
    b = img[y0, x0 + 1].astype(np.float32)
    c = img[y0 + 1, x0].astype(np.float32)
    d = img[y0 + 1, x0 + 1].astype(np.float32)
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def _project(frame: Frame, pts: np.ndarray, width: int):
    """Pixel coordinates (in a photo `width` wide) and camera depth of world points."""
    E = frame.extrinsic()
    pc = pts @ E[:3, :3].T + E[:3, 3]
    z = pc[:, 2]
    k = frame.intrinsic(width / frame.width)
    with np.errstate(divide="ignore", invalid="ignore"):
        u = k[0, 0] * pc[:, 0] / z + k[0, 2]
        v = k[1, 1] * pc[:, 1] / z + k[1, 2]
    return u, v, z


def _neighbours(F: np.ndarray) -> np.ndarray:
    """(T, 3) neighbouring triangle across each edge, -1 where there is none."""
    T = len(F)
    a = np.concatenate([F[:, 0], F[:, 1], F[:, 2]]).astype(np.int64)
    b = np.concatenate([F[:, 1], F[:, 2], F[:, 0]]).astype(np.int64)
    key = np.minimum(a, b) << 32 | np.maximum(a, b)
    tri = np.tile(np.arange(T), 3)
    order = np.argsort(key, kind="stable")
    key, tri = key[order], tri[order]
    nb = np.full((T, 3), -1, np.int64)
    same = np.nonzero(key[1:] == key[:-1])[0]
    x = np.concatenate([tri[same], tri[same + 1]])
    y = np.concatenate([tri[same + 1], tri[same]])
    o = np.argsort(x, kind="stable")
    x, y = x[o], y[o]
    # Slot = position within each triangle's run of neighbours.
    start = np.r_[0, np.nonzero(np.diff(x))[0] + 1]
    run = np.repeat(start, np.diff(np.r_[start, len(x)]))
    slot = np.arange(len(x)) - run
    ok = slot < 3
    nb[x[ok], slot[ok]] = y[ok]
    return nb


def bake(V: np.ndarray, F: np.ndarray, UV: np.ndarray, vertex_colors: np.ndarray | None,
         frames: list[Frame], size: int, report: Report, base: float, span: float) -> tuple[np.ndarray, dict]:
    """Returns the texture image (size x size x 3, row 0 = top, v = 1) and stats."""
    import open3d as o3d
    T = len(F)
    a, b, c = V[F[:, 0]], V[F[:, 1]], V[F[:, 2]]
    cent = (a + b + c) / 3
    n = np.cross(b - a, c - a)
    n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-12)

    scene = o3d.t.geometry.RaycastingScene()
    scene.add_triangles(o3d.core.Tensor(V.astype(np.float32)), o3d.core.Tensor(F.astype(np.uint32)))

    sharp = np.array([max(f.sharpness, 1.0) for f in frames])
    sharp_w = np.clip(np.sqrt(sharp / np.median(sharp)), 0.4, 1.5)
    bestL = np.full((T, K), -1, np.int32)
    bestS = np.zeros((T, K), np.float32)

    # 1. Score every photo for every triangle it can see.
    for pi, f in enumerate(frames):
        if pi % 10 == 0:
            report(f"Texturing: checking which photos see each surface ({pi + 1} of {len(frames)})", base + span * 0.25 * pi / len(frames))
        u, v, z = _project(f, cent, f.width)
        cam = f.position()
        to_cam = cam - cent
        dist = np.linalg.norm(to_cam, axis=1)
        facing = np.abs(np.einsum("ij,ij->i", n, to_cam)) / np.maximum(dist, 1e-6)
        m = (z > 0.15) & (z < 6) & (u > 4) & (v > 4) & (u < f.width - 5) & (v < f.height - 5) & (facing > 0.3)
        idx = np.nonzero(m)[0]
        if not len(idx):
            continue
        # Blocked? Cast a ray from the camera to the triangle; it must reach (almost) the triangle itself.
        d = cent[idx] - cam
        rays = np.concatenate([np.broadcast_to(cam, d.shape), d], axis=1).astype(np.float32)
        hit = scene.cast_rays(o3d.core.Tensor(rays))["t_hit"].numpy()
        vis = hit >= 1.0 - 0.015 / np.maximum(dist[idx], 0.1)
        idx = idx[vis]
        if not len(idx):
            continue
        cu = u[idx] / f.width - 0.5
        cv = v[idx] / f.height - 0.5
        centred = 1 - 0.8 * (cu * cu + cv * cv)
        s = (facing[idx] ** 3 * centred * sharp_w[pi] / (0.3 + z[idx]) ** 2).astype(np.float32)
        col = np.argmin(bestS[idx], axis=1)
        better = s > bestS[idx, col]
        idx, col, s = idx[better], col[better], s[better]
        bestL[idx, col] = pi
        bestS[idx, col] = s

    label = bestL[np.arange(T), np.argmax(bestS, axis=1)]
    label[bestS.max(axis=1) <= 0] = -1
    top = bestS.max(axis=1)

    # 2. Follow the neighbours' photo where it also sees the triangle well: bigger patches, fewer seams.
    report("Texturing: joining patches", base + span * 0.3)
    nb = _neighbours(F)
    for _ in range(10):
        nl = np.where(nb >= 0, label[np.maximum(nb, 0)], -1)
        cand = np.where((nl[:, 0] == nl[:, 1]) | (nl[:, 0] == nl[:, 2]), nl[:, 0],
                        np.where(nl[:, 1] == nl[:, 2], nl[:, 1], -1))
        score = np.where(bestL == cand[:, None], bestS, 0).max(axis=1)
        switch = (cand >= 0) & (cand != label) & (score >= 0.35 * top)
        if not switch.any():
            break
        label[switch] = cand[switch]

    # 3. Brightness: one gain per photo that brings its view of shared surfaces to the average of all views.
    report("Texturing: matching photo brightness", base + span * 0.35)
    gains = _exposure_gains(frames, cent, bestL, bestS, report, base + span * 0.35, span * 0.15)

    # 4. Which texel belongs to which triangle.
    report("Texturing: laying out the texture", base + span * 0.5)
    px = UV.copy()
    px[..., 0] *= size
    px[..., 1] = (1 - px[..., 1]) * size
    ids = Image.new("I", (size, size), 0)
    draw = ImageDraw.Draw(ids)
    for t in range(T):
        p = px[t]
        pts = [(float(p[0, 0]), float(p[0, 1])), (float(p[1, 0]), float(p[1, 1])), (float(p[2, 0]), float(p[2, 1]))]
        draw.polygon(pts, fill=t + 1, outline=t + 1)
    idmap = np.asarray(ids, dtype=np.int32)
    del ids, draw

    tex = np.zeros((size, size, 3), np.uint8)
    filled = np.flatnonzero(idmap).astype(np.int32)
    tri_of = idmap.ravel()[filled] - 1
    del idmap
    lab = label[tri_of]

    # Barycentric coordinates of each texel centre in its triangle (clamped for the 1-texel border).
    def bary(sel):
        t = tri_of[sel]
        x = (filled[sel] % size).astype(np.float64) + 0.5
        y = (filled[sel] // size).astype(np.float64) + 0.5
        p0, p1, p2 = px[t, 0], px[t, 1], px[t, 2]
        v0, v1 = p1 - p0, p2 - p0
        v2x, v2y = x - p0[:, 0], y - p0[:, 1]
        den = v0[:, 0] * v1[:, 1] - v1[:, 0] * v0[:, 1]
        den = np.where(np.abs(den) < 1e-12, 1e-12, den)
        l1 = (v2x * v1[:, 1] - v1[:, 0] * v2y) / den
        l2 = (v0[:, 0] * v2y - v2x * v0[:, 1]) / den
        l1, l2 = np.clip(l1, 0, 1), np.clip(l2, 0, 1)
        over = l1 + l2 > 1
        s = l1[over] + l2[over]
        l1[over] /= s
        l2[over] /= s
        l0 = 1 - l1 - l2
        return t, l0[:, None], l1[:, None], l2[:, None]

    # Texels no photo saw: the fused colour, so nothing is left black.
    none = np.nonzero(lab < 0)[0]
    if len(none) and vertex_colors is not None and len(vertex_colors) == len(V):
        t, l0, l1, l2 = bary(none)
        col = vertex_colors[F[t, 0]] * l0 + vertex_colors[F[t, 1]] * l1 + vertex_colors[F[t, 2]] * l2
        tex.reshape(-1, 3)[filled[none]] = np.clip(col * 255, 0, 255).astype(np.uint8)

    # 5. Sample every texel from its photo at full resolution, a few photos at a time to keep memory modest.
    order = np.argsort(lab, kind="stable")
    lab_sorted = lab[order]
    used = np.unique(lab_sorted[lab_sorted >= 0])
    flat = tex.reshape(-1, 3)
    for i, pi in enumerate(used):
        if i % 5 == 0:
            report(f"Texturing: painting from photos ({i + 1} of {len(used)})", base + span * (0.55 + 0.45 * i / len(used)))
        lo, hi = np.searchsorted(lab_sorted, [pi, pi + 1])
        sel = order[lo:hi]
        f = frames[pi]
        img = _load(f)
        t, l0, l1, l2 = bary(sel)
        P = V[F[t, 0]] * l0 + V[F[t, 1]] * l1 + V[F[t, 2]] * l2
        u, v, _ = _project(f, P, img.shape[1])
        col = _bilinear(img, u, v) * gains[pi]
        flat[filled[sel]] = np.clip(col, 0, 255).astype(np.uint8)
        del img

    stats = {"texture_photos": int(len(used)), "untextured_triangles": int((label < 0).sum()),
             "triangles": int(T), "texture_size": size}
    return tex, stats


def _exposure_gains(frames, cent, bestL, bestS, report, base, span) -> np.ndarray:
    T = len(cent)
    rng = np.random.default_rng(0)
    sample = rng.choice(T, size=min(T, 40000), replace=False)
    L = bestL[sample]
    S = bestS[sample]
    colours = np.full(L.shape + (3,), np.nan, np.float32)
    photos = np.unique(L[L >= 0])
    for i, pi in enumerate(photos):
        if i % 20 == 0:
            report(f"Texturing: matching photo brightness ({i + 1} of {len(photos)})", base + span * i / max(1, len(photos)))
        rows, cols = np.nonzero(L == pi)
        f = frames[pi]
        with Image.open(f.image) as im:
            w = f.width // 4
            im.draft("RGB", (w, f.height // 4))
            img = np.asarray(im.convert("RGB").resize((w, f.height // 4)))
        u, v, _ = _project(f, cent[sample[rows]], img.shape[1])
        colours[rows, cols] = _bilinear(img, u, v)
    valid = ~np.isnan(colours[..., 0]) & (S > 0)
    # Ignore clipped and near-black samples; they say nothing about exposure.
    br = np.nan_to_num(colours.max(axis=-1))
    dk = np.nan_to_num(colours.min(axis=-1))
    valid &= (br < 245) & (dk > 8)
    count = valid.sum(axis=1)
    mean = np.where(valid[..., None], np.nan_to_num(colours), 0).sum(axis=1) / np.maximum(count, 1)[:, None]
    num = np.zeros((len(frames), 3))
    den = np.zeros((len(frames), 3))
    for k in range(L.shape[1]):
        m = valid[:, k] & (count >= 2)
        np.add.at(num, L[m, k], mean[m])
        np.add.at(den, L[m, k], colours[m, k])
    g = np.where(den > 0, num / np.maximum(den, 1e-6), 1.0)
    return np.clip(g, 0.6, 1.6).astype(np.float32)


# ---------------------------------------------------------------------------------------------- writers

def write_obj(path, V, F, UV, normals, texture_name: str):
    mtl = path.with_suffix(".mtl")
    mtl.write_text(f"newmtl scan\nKa 1 1 1\nKd 1 1 1\nKs 0 0 0\nillum 1\nmap_Kd {texture_name}\n")
    T = len(F)
    with open(path, "w", newline="\n") as fh:
        fh.write(f"# Scanvas Studio\nmtllib {mtl.name}\nusemtl scan\n")
        fh.write("".join(f"v {x:.5f} {y:.5f} {z:.5f}\n" for x, y, z in V))
        fh.write("".join(f"vn {x:.4f} {y:.4f} {z:.4f}\n" for x, y, z in normals))
        uv = UV.reshape(-1, 2)
        fh.write("".join(f"vt {u:.6f} {v:.6f}\n" for u, v in uv))
        f1 = F + 1
        t1 = np.arange(T * 3).reshape(T, 3) + 1
        fh.write("".join(f"f {a}/{ta}/{a} {b}/{tb}/{b} {c}/{tc}/{c}\n"
                         for (a, b, c), (ta, tb, tc) in zip(f1.tolist(), t1.tolist())))


def write_glb(path, V, F, UV, normals, jpeg: bytes):
    """Binary glTF with the photo texture embedded; unlit, because the photos already hold the room's lighting."""
    import json
    import struct
    pos = V[F].reshape(-1, 3).astype(np.float32)
    nor = normals[F].reshape(-1, 3).astype(np.float32)
    uv = UV.reshape(-1, 2).astype(np.float32).copy()
    uv[:, 1] = 1 - uv[:, 1]        # glTF texture coordinates start at the top
    idx = np.arange(len(pos), dtype=np.uint32)
    blobs = [pos.tobytes(), nor.tobytes(), uv.tobytes(), idx.tobytes(), jpeg]
    views, offset = [], 0
    data = b""
    for i, blob in enumerate(blobs):
        pad = (-len(blob)) % 4
        views.append({"buffer": 0, "byteOffset": offset, "byteLength": len(blob), **({"target": 34962} if i < 3 else {"target": 34963} if i == 3 else {})})
        data += blob + b"\0" * pad
        offset += len(blob) + pad
    gltf = {
        "asset": {"version": "2.0", "generator": "Scanvas Studio"},
        "extensionsUsed": ["KHR_materials_unlit"],
        "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0, "name": "Scan"}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2}, "indices": 3, "material": 0}]}],
        "materials": [{"pbrMetallicRoughness": {"baseColorTexture": {"index": 0}, "metallicFactor": 0, "roughnessFactor": 1},
                       "extensions": {"KHR_materials_unlit": {}}, "doubleSided": True}],
        "textures": [{"source": 0, "sampler": 0}], "samplers": [{"magFilter": 9729, "minFilter": 9987}],
        "images": [{"bufferView": 4, "mimeType": "image/jpeg"}],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": len(pos), "type": "VEC3", "min": pos.min(0).tolist(), "max": pos.max(0).tolist()},
            {"bufferView": 1, "componentType": 5126, "count": len(nor), "type": "VEC3"},
            {"bufferView": 2, "componentType": 5126, "count": len(uv), "type": "VEC2"},
            {"bufferView": 3, "componentType": 5125, "count": len(idx), "type": "SCALAR"},
        ],
        "buffers": [{"byteLength": len(data)}],
    }
    js = json.dumps(gltf, separators=(",", ":")).encode()
    js += b" " * ((-len(js)) % 4)
    total = 12 + 8 + len(js) + 8 + len(data)
    with open(path, "wb") as fh:
        fh.write(struct.pack("<III", 0x46546C67, 2, total))
        fh.write(struct.pack("<II", len(js), 0x4E4F534A) + js)
        fh.write(struct.pack("<II", len(data), 0x004E4942) + data)
