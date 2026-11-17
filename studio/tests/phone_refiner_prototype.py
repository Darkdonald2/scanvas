"""Prototype of the phone's new camera refiner (to be ported to Swift line by line), run on a raw capture.
Target = triangle centres + normals of the phone's own mesh. Search uses a KD-tree here; the phone uses grids."""
import sys, time, json
import numpy as np
from scipy.spatial import cKDTree
sys.path.insert(0, "/home/claude/scanvas/studio")
from scanvas_studio.capture import Capture
import open3d as o3d

raw = sys.argv[1]; every = int(sys.argv[2]) if len(sys.argv) > 2 else 5
cap = Capture.open(raw)
m = o3d.io.read_triangle_mesh(raw + "/arkit_mesh.ply")
V = np.asarray(m.vertices); F = np.asarray(m.triangles)
a, b, c = V[F[:, 0]], V[F[:, 1]], V[F[:, 2]]
n = np.cross(b - a, c - a); ln = np.linalg.norm(n, axis=1); ok = ln > 1e-8
C = ((a + b + c) / 3)[ok]; N = (n[ok] / ln[ok, None])
tree = cKDTree(C)
print("target centres", len(C))

def samples(f):
    d = f.load_depth(1, 4.0)
    h, w = d.shape
    vs, us = np.mgrid[4:h - 4:4, 4:w - 4:4]
    z = d[vs, us]
    n1, n2, n3, n4 = d[vs, us - 2], d[vs, us + 2], d[vs - 2, us], d[vs + 2, us]
    jump = np.max(np.abs(np.stack([n1, n2, n3, n4]) - z), axis=0)
    good = (z > 0.3) & (z < 4.0) & (jump < 0.04 * z + 0.02) & (n1 > 0) & (n2 > 0) & (n3 > 0) & (n4 > 0)
    k = f.depth_intrinsic()
    z = z[good]; u = us[good]; v = vs[good]
    return np.stack([(u - k[0, 2]) / k[0, 0] * z, -(v - k[1, 2]) / k[1, 1] * z, -z], 1)

def fitness(S, pose):
    p = S @ pose[:3, :3].T + pose[:3, 3]
    d, j = tree.query(p, distance_upper_bound=0.08)
    hit = np.isfinite(d)
    r = np.abs(np.einsum("ij,ij->i", N[j[hit]], p[hit] - C[j[hit]]))
    inl = r < 0.04
    return inl.sum() / len(S), (r[inl].mean() if inl.any() else 1.0)

LADDER = [(0.5, 5), (0.25, 5), (0.12, 5), (0.06, 6), (0.03, 6)]
FINE = [(0.06, 6), (0.03, 6)]

def icp(S, pose, ladder):
    pose = pose.copy()
    for maxd, iters in ladder:
        for _ in range(iters):
            p = S @ pose[:3, :3].T + pose[:3, 3]
            d, j = tree.query(p, distance_upper_bound=maxd)
            hit = np.isfinite(d)
            if hit.sum() < 120: return None
            ph, nh = p[hit], N[j[hit]]
            r = np.einsum("ij,ij->i", nh, ph - C[j[hit]])
            delta = max(0.015, maxd / 8)
            w = np.where(np.abs(r) < delta, 1.0, delta / np.maximum(np.abs(r), 1e-9))
            centre = pose[:3, 3]
            J = np.concatenate([np.cross(ph - centre, nh), nh], 1)
            A = (J * w[:, None]).T @ J; g = -(J * w[:, None]).T @ r
            # Damping, separately for turning and moving, so directions the depth doesn't pin down stay put.
            tr_r = np.trace(A[:3, :3]) / 3; tr_t = np.trace(A[3:, 3:]) / 3
            A[:3, :3] += np.eye(3) * 0.02 * tr_r; A[3:, 3:] += np.eye(3) * 0.02 * tr_t
            try: x = np.linalg.solve(A, g)
            except np.linalg.LinAlgError: return None
            om, t = x[:3], x[3:]
            tl = np.linalg.norm(t); tmax = maxd / 2
            if tl > tmax: t *= tmax / tl
            ol = np.linalg.norm(om); omax = 0.06 if maxd > 0.1 else 0.02
            if ol > omax: om *= omax / ol
            ang = np.linalg.norm(om)
            R = np.eye(3)
            if ang > 1e-9:
                k = om / ang; K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]])
                R = np.eye(3) + np.sin(ang) * K + (1 - np.cos(ang)) * K @ K
            D = np.eye(4); D[:3, :3] = R; D[:3, 3] = centre + t - R @ centre
            pose = D @ pose
            if ang < 1e-4 and np.linalg.norm(t) < 1e-4: break
    return pose

def accept(p0, p1, f0, f1):
    if p1 is None: return False
    moved = np.linalg.norm(p1[:3, 3] - p0[:3, 3])
    cosang = (np.trace(p1[:3, :3] @ p0[:3, :3].T) - 1) / 2
    ang = np.degrees(np.arccos(np.clip(cosang, -1, 1)))
    better = f1[0] >= f0[0] + 0.02 or (f1[0] >= f0[0] and f1[1] < f0[1] * 0.95)
    return f1[0] >= 0.45 and better and moved < 1.5 and ang < 20

frames = cap.frames[::every]
t0 = time.time()
S = [samples(f) for f in frames]
orig = [f.camera_to_world.copy() for f in frames]
pose = [p.copy() for p in orig]
fit0 = []; fit = []; corrected = [False] * len(frames)
for i, f in enumerate(frames):
    if len(S[i]) < 200: fit0.append((0, 1)); fit.append((0, 1)); continue
    f0 = fitness(S[i], orig[i]); fit0.append(f0)
    p1 = icp(S[i], orig[i], FINE if f0[0] >= 0.85 else LADDER)
    f1 = fitness(S[i], p1) if p1 is not None else (0, 1)
    if accept(orig[i], p1, f0, f1): pose[i] = p1; fit.append(f1); corrected[i] = True
    else: fit.append(f0)
print("pass 1 seconds", round(time.time() - t0, 1))
for rnd in range(2):
    typical = np.median([x[0] for x in fit if x[0] > 0])
    poor = [i for i in range(len(frames)) if 0 < fit[i][0] < 0.8 * typical or (fit[i][0] == 0 and len(S[i]) >= 200)]
    for i in poor:
        near = sorted((j for j in range(len(frames)) if j != i and corrected[j] and fit[j][0] >= 0.8 * typical), key=lambda j: abs(j - i))[:4]
        best = None
        for j in near:
            init = pose[j] @ np.linalg.inv(orig[j]) @ orig[i]
            p1 = icp(S[i], init, LADDER[1:])
            if p1 is None: continue
            f1 = fitness(S[i], p1)
            if best is None or f1[0] > best[1][0]: best = (p1, f1)
        if best and best[1][0] > fit[i][0] and accept(orig[i], best[0], fit0[i], best[1]):
            pose[i], fit[i], corrected[i] = best[0], best[1], True
    print("round", rnd, "poor", len(poor))
typical = np.median([x[0] for x in fit if x[0] > 0])
drop = [0 < x[0] < max(0.25, 0.6 * typical) or x[0] == 0 for x in fit]
print("seconds", round(time.time() - t0, 1), "typical fitness", round(typical, 2), "dropped", sum(drop), "of", len(frames))
np.set_printoptions(precision=2, suppress=True)
B = max(1, len(frames) // 12)
for lo in range(0, len(frames), B):
    sl = slice(lo, lo + B)
    a0 = np.array([x[0] for x in fit0[sl]]); a1 = np.array([x[0] for x in fit[sl]]); e0 = np.array([x[1] for x in fit0[sl]]) * 100; e1 = np.array([x[1] for x in fit[sl]]) * 100
    mv = np.array([np.linalg.norm(pose[i][:3, 3] - orig[i][:3, 3]) for i in range(lo, min(lo + B, len(frames)))]) * 100
    print(f"frames {frames[lo].index:3d}+: fitness {np.median(a0):.2f} -> {np.median(a1):.2f} (min {a1.min():.2f})  plane err cm {np.median(e0):.1f} -> {np.median(e1):.1f}  moved cm med {np.median(mv):.1f} max {mv.max():.1f}  dropped {sum(drop[sl])}")
