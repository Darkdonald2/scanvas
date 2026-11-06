# Scanvas handover

Written 4 November 2026 for moving this project to a new account. It should let a new owner, or a new Claude
session, carry on without anything from the old one.

## 1. What this is

**Scanvas** is a free iPhone/iPad LiDAR scanning app, similar in spirit to Polycam but with no paywall. It has
two parts:

- **The iPhone app** (Swift/SwiftUI, iOS 17+). It covers Room (RoomPlan), Space (LiDAR mesh plus photo
  textures), Object (Object Capture), Photos-to-model, Measure, and **Pipes** (a drainage pipe survey). It exports
  DXF, IFC, OBJ, USDZ, GLB, STL, PLY, PTS, XYZ, PDF, PNG and CSV.
- **Scanvas Studio** (Python, macOS and Windows). It processes a *raw capture* from the phone into a denser,
  sharper textured model, and can send the result back to the phone over Wi-Fi.

### Current state (all working and tested)

| Area | State |
| --- | --- |
| Space scans on the phone | Good quality. Long scans no longer crash; memory was cut and texture pages are drawn one at a time. |
| Pipes mode | Built. The user had only lightly tested it at the time of writing. |
| Raw capture and Send to computer | Working. The user captured "Space 4" (462 frames) and sent it to Studio over Wi-Fi. |
| Studio processing | Working on real data after the non-manifold fix (see §8). It produced a textured OBJ/GLB for Space 4. |
| Getting the model back on the phone | Built, and tested against a simulated phone. Not yet confirmed on a real phone. |

## 2. Where things live

| What | Where |
| --- | --- |
| Source | GitHub repo `Darkdonald2/scanvas`, branch `main` (everything is committed there) |
| iPhone app download | Release **`latest`** → `Scanvas.ipa` (rebuilt on every push to `main` that touches the app) |
| Studio downloads | Release **`studio`** → `ScanvasStudio-mac-intel.zip`, `ScanvasStudio-mac-apple-silicon.zip`, `ScanvasStudio-windows.zip`, `ScanvasStudio-source.zip` |
| Copies in the old project | `/mnt/project-files/scanvas/Scanvas.ipa` and `scanvas-source.zip` (these won't move with the account; the repo is the source of truth) |
| Reference notes | `podium2-drainage-notes.md` (the user's earlier drainage drawing conventions; used only as reference for Pipes) |

## 3. Repository layout

```
project.yml                  XcodeGen project (Info.plist keys, bundle id, iOS 17)
make-ipa.command             Builds an unsigned Scanvas.ipa (used by CI; runs on any Mac with Xcode)
README.md                    Feature and export overview
HANDOVER.md                  This file
App/Sources/
  ScanvasApp.swift
  Capture/   MeshScanner (ARKit mesh, keyframes, photos), MeshScanView (Space UI), RawRecorder (raw capture),
             PipeTracer + PipeSurveyView (Pipes), RoomScanView, ObjectCapture, MeasureView
  Process/   SpaceProcessing (pipeline shared by Space and Pipes), Texturer (phone texturing),
             CameraRefiner (ICP), MeshCleaner (clean + orient to camera path), PipeGeometry, StudioImport
  Models/    MeshData, TexturedMesh, PipeSurvey, PlanModel, Project
  Export/    Exporter, DXFWriter, IFCWriter, MeshFormats, SceneExport, PipeExport, PipePlanRenderer, Plan*
  Views/     HomeView, ProjectDetailView, PipeDetailView, SceneViewer (inside/outside 3D), FloorPlanView,
             ExportView, SettingsView, RawTransferView (Send to computer)
  Storage/   ProjectStore (Documents/Scans/<uuid>/…)
studio/
  scanvas_studio/  capture.py (reads raw), pipeline.py (processing), texturing.py (texture bake + OBJ/GLB writers),
                   server.py (Wi-Fi receiver + Bonjour), app.py (Tk window), cli.py
  tests/           make_synthetic.py (synthetic room in raw format), evaluate.py (accuracy check)
  run_studio.py, requirements.txt, launch scripts for Mac/Windows, README.md, RELEASE_NOTES.md
.github/workflows/
  build-ipa.yml       iPhone app → release "latest"
  build-studio.yml    Studio for Intel Mac, Apple-silicon Mac, Windows → release "studio"
```

## 4. iPhone app architecture (the parts that matter most)

**Space scan flow:** `MeshScanner` runs ARKit scene reconstruction. While scanning it keeps:

- mesh anchors, including after interruptions;
- keyframes at 256×192 RGB plus half-precision depth and nearby anchor poses, capped at 700;
- sharp full-size photos written to `Keyframes/`.

On Finish, `SpaceProcessing.process` runs these steps in order:

1. clean (off by default);
2. Taubin smooth;
3. orient the faces toward the camera path (this stops the scan turning inside out);
4. vertex colours;
5. camera refinement (ICP, on by default);
6. `Texturer`: best photo per triangle, union-find charts, shelf packing into up to ten 4096² pages, per-photo
   brightness gains;
7. save `mesh.bin`, `textured.bin` and `tex_N.jpg`.

Each scan writes a `processing.txt` report (⋯ › Processing details). If the app is closed mid-way, the step it
reached and its memory use are shown on the next launch.

**Settings › Processing (testing):** compact textures (on), full-res photos (on), refine cameras (on), clean mesh
(off).

**Pipes:** `PipeTracer` aims using depth, snaps to the pipe centre line, measures size, and records fittings and
photos. The survey goes to `pipes.json`. Exports are PDF report, DXF (P-<SYSTEM> layers, double precision), IFC
(IfcFlowSegment), CSV and PNG. Alignment to drawing coordinates uses 1–2 reference points, a rotation and a floor
level.

**Raw capture** (Settings › Computer processing): `RawRecorder` writes about 6 frames a second (4 a second at 4K)
straight to disk in `Raw/`. With raw on, the phone only makes a coloured preview and leaves texturing to Studio.

**Send to computer** (scan ⋯ menu, raw scans only), in `RawTransferView`:

- Finds Studio with Bonjour (`_scanvas._tcp`), uploads file by file using the pairing code, and stores
  `Raw/studio-link.json`.
- Polls `/result/<transfer>` and offers **Get processed model** when Studio is done.
- The other routes are **Make a zip** and **Import processed model from Files** (.glb).
- `StudioImport` turns the GLB into `textured.bin` plus `tex_0.jpg`.

## 5. Raw capture format ("scanvas-raw", version 1)

Full table in `studio/README.md`. In short:

- `capture.json`;
- `frames.jsonl`, one line per frame with image/depth/confidence paths, intrinsics `[fx, fy, cx, cy]` in image
  pixels, `cameraToWorld` (4×4 column-major), exposure, light estimate, and nearby anchor poses;
- `images/*.jpg` at full camera resolution;
- `depth/*.bin` (float32 metres, 256×192) and `confidence/*.bin` (uint8 0–2);
- `anchors.json` (final anchor poses, used to undo drift), `arkit_mesh.ply`, and `pipes.json` / `project.json`
  when present.

Coordinates are ARKit's: Y up, metres, with the camera looking along −Z.

## 6. Studio pipeline

`pipeline.process` runs these steps:

0. Depth pixels on the outlines of things are dropped (`depth_edges`) wherever depth is fused or aligned.
1. **Drift correction:** frames are moved by how much their nearest anchor has moved since they were taken.
2. **Photo choice:** blur is judged relative to neighbouring frames, and the sharpest frame is kept per position.
3. **Fuse:** Open3D `VoxelBlockGrid` TSDF at 2 cm (Fast), 1 cm (High) or 6 mm (Ultra). Colour is at half
   resolution.
4. **Refine cameras:** point-to-plane ICP of each frame's high-confidence depth against a first-pass mesh, then
   fuse again. One pass helps; a second pass made it worse in tests.
5. **Clean:** remove clusters below max(0.02 m², 0.05 % of the area), then Taubin smoothing.
6. **Texture** (`texturing.py`; this replaces Open3D's own `project_images_to_albedo`, which bled colour through
   objects):
   - decimate to 200k / 600k / 1.2M triangles, then `make_manifold`, then UVAtlas;
   - score each triangle against each photo, keeping the top 8. A photo only counts if nothing in the model is
     nearer within a few pixels (a depth picture of the model per photo) and the photo's own LiDAR depth agrees
     with the model there;
   - join patches with neighbours;
   - per-photo brightness gains, then a smooth per-patch correction toward the colour the photos agree on;
   - rasterise texel→triangle ids with PIL, then sample every texel from its photo at full resolution;
   - fill the gaps between patches so no dark lines show at a distance;
   - on failure, retry with half the triangles (twice) before falling back to the coloured mesh only.
7. **Export:** `model_textured.obj/.mtl/.jpg`, `model_textured.glb` (unlit, texture embedded),
   `model_dense_colour.ply` and `point_cloud.ply`. Choosing Z up adds `phone_model.glb` in Y up. `processing.json`
   records the run.

On the synthetic room at High: about 2.5 minutes, about 3 GB peak memory, mean surface error about 7 mm. On the
user's real Space 4 at Ultra: 18.6 minutes and a 9.2M-triangle fusion. Recommend **High**.

Results go to `~/Scanvas Studio/Scans/`. Received raw scans are saved as `<name> <date>`, and results as
`<name> - model`. The pairing code is in `~/Scanvas Studio/pairing-code.txt`. The Wi-Fi server listens on port 8765
(it falls back to 8766/8767).

## 7. Build, release, install

**iPhone app:**

- CI (`build-ipa.yml`, macos-15) runs `make-ipa.command`, which uses XcodeGen and builds unsigned. It publishes
  `Scanvas.ipa` to release `latest`.
- Install with **AltStore or SideStore**, which sign the app with your own Apple ID. With a free Apple ID the app
  expires after 7 days, so refresh it in AltStore.
- `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` is `com.yourname.scanvas`. Change it if you sign the app yourself
  in Xcode.

**Studio:**

- CI (`build-studio.yml`) runs a matrix of `macos-14` (Apple silicon), **`macos-15-intel` with `open3d==0.19.0`**
  and `windows-latest`.
- On each runner it generates a synthetic scan, processes it, evaluates the result, packages with PyInstaller
  (`--collect-all open3d`; plotly and dash must stay included because Open3D imports them), and smoke-tests the
  packaged app.
- It then publishes to release `studio`: the release is created first, then each file is uploaded with retries,
  because GitHub returned HTTP 500 when everything was uploaded in one call.
- **Intel pin:** Open3D 0.20 has no Intel Mac wheels, and 0.19.0 is the last version with them (universal2,
  Python 3.12). Keep this pin for Intel until the user no longer needs Intel.
- Unsigned app: on a Mac, right-click › Open the first time. On Windows, allow it on private networks so the
  phone can reach it.
- From source: `pip install -r studio/requirements.txt` then `python studio/run_studio.py`, or use the
  double-click launchers in `studio/`.

**Commits:** the old sessions committed as `Claude <noreply@anthropic.com>` with a Co-Authored-By footer. Pushes
to `main` trigger the builds. Studio-only changes don't rebuild the ipa.

## 8. Recent fixes (newest first)

- **Doubled walls from camera drift** (5 November 2026, second change). ARKit corrects its map during a scan
  but photos keep the position they were taken at, so early photos can be tens of centimetres off. Studio's
  old refinement only accepted corrections under 8 cm against a first pass that was itself doubled.
  `pipeline.align_to_phone_mesh` now slides every photo's depth onto `arkit_mesh.ply` first (coarse-to-fine
  ICP from 50 cm, starting from the previous photo's correction) and drops photos that fit nowhere. CI builds
  a synthetic scan whose first photos are 40 cm and 8° out and fails if the result isn't clean.
  Checked on the user's real Space 3 (529 photos) with a stand-in for Open3D's ICP (`MeshMatcher` is
  swappable for this): the first ~40 photos were 24 cm from the phone's mesh and ended under 1 cm, later
  blocks went from 4-11 cm to 1-2 cm, and 3 photos at the very start were dropped. The same scan showed
  that mesh anchors are sometimes re-created a metre away, so `capture._correct_drift` now ignores
  mesh-anchor corrections over 30 cm.
- **Raw capture changes** (same change): the app drops an `ARAnchor` on the camera's path about once a second
  and saves the nearest three per frame (`poseAnchors`) plus their final poses (`pose_anchors.json`); Studio
  prefers these over mesh anchors for drift correction. Raw photos now start only after tracking has been
  steady for 2 s (after the exposure lock at 1.5 s) and pause the same way after tracking is lost, photos
  taken while turning faster than about 70°/s are skipped, and each frame records mapping state and speeds.
  The scan screens show what raw capture is doing (`MeshScanner.rawState`, `RawStatusBadge`): a yellow
  "Getting ready" badge while waiting, a green "Recording raw photos" badge with a haptic tap when it starts,
  and an orange badge when it pauses. Safety net: if tracking hasn't settled after 6 s, recording starts
  anyway whenever tracking is normal. Finish refuses to save a raw scan with no photos.
  None of the capture changes has been tried on a phone yet.
- **The phone couldn't import Studio's GLB** (5 November 2026). `write_glb` built the `bufferViews` table but
  never put it in the file, so no program could read Studio's GLBs and the phone refused them. Fixed in Studio;
  CI now reads the GLB back (`studio/tests/check_glb.py`). The phone's `StudioImport` also rebuilds the table
  for files made by the old Studio, checks every offset, reads PNG textures, and the import screen now always
  shows progress and errors.
- **Studio texture quality** (same date), found by re-baking the user's Space 4 (see the comparison in the pull
  request). Old problems: silhouettes of people and furniture painted onto the walls behind them, and plain
  walls made of visibly different rectangles. Now a photo may only paint a surface if (a) nothing in the model
  is nearer within a few pixels (`EDGE_R`), and (b) that photo's own LiDAR depth agrees the surface was there.
  Patches are then levelled to the colour the photos agree on (`_match_colours`), gaps between patches are
  filled (`_fill_gaps`), and all sharp photos are used (500 at High) instead of 200.
- **Thin sheets hanging off the edges of people and furniture:** depth pixels on outlines are dropped before
  fusing (`capture.depth_edges`). On Space 4 these sheets were most of the 25 % of triangles no photo could see.
- **Studio remembers transfers** across restarts (`~/Scanvas Studio/transfers.json`), and processing a received
  scan again by hand still reaches the phone's "Get processed model".
- **Pull requests are built and tested** by both workflows without publishing a release.
- **Studio texturing failed on real scans** with "UVAtlasPartition: Non-manifold mesh". Decimating a 9M-triangle
  mesh left vertices where separate sheets touch. Fixed with `make_manifold` (removes non-manifold edges and
  vertices), a single-partition UVAtlas fallback, and lighter retries.
- **Studio downloads not published:** fixed with the HTTP 500 retry logic and the plotly packaging fix. An Intel
  Mac build was added.
- **Red, cyan and black patches on phone textures:** the brightness gain math had a precedence bug (`a * g >> 8`).
- **Long scans crashing at "Encoding texture 9 of 10" (918 MB):** each page stayed in memory. Pages now share one
  reused bitmap and are written with ImageIO, and keyframes are freed first. This came alongside other memory
  cuts: Float16 depth, 8 nearest anchors per keyframe, a bounded photo queue, compact adjacency, and a
  lightweight thumbnail.
- **Scans inside out when "Clean mesh" is on:** after welding, the orientation vote flipped. Scans are now always
  oriented toward the camera path.
- **Inside view could go up but not down:** replaced the buttons with a vertical lift stick.

## 9. Known issues and next steps

- Confirm on a real phone: "Get processed model" over Wi-Fi, and importing a 600k-triangle, 8192² model (about
  80 MB). Watch memory in the 3D viewer.
- People who move during a scan still end up as rough shapes in the mesh. Their colour no longer leaks onto
  the walls, but removing them from the geometry (masking with ARKit person segmentation at capture, or
  dropping depth that disagrees with later frames) is not done yet.
- Studio does not save its refined camera positions, so a texture can't be re-baked later without re-running
  the whole pipeline. Saving them in the results folder would make that possible.
- Phone viewer: a phone-textured scan has up to ten 4096² pages, which is about 700 MB+ of GPU memory. It could
  crash the 3D viewer on long scans; consider downsampled textures for viewing.
- Studio's camera refinement can't remove slow drift around a loop. Pose-graph optimisation with loop closure is
  the next big step for long scans.
- Ultra is slow (18 min) and heavy; High is the sensible default.
- Pipes mode needs real-world testing. The user hasn't reported back on it yet.
- Ideas not yet built: USDZ output from Studio (would need `usd-core`), Windows/Intel GPU acceleration, and
  automatic AirDrop-free return for zip transfers.

## 10. Tied to the old account (move these)

| Item | What to do |
| --- | --- |
| GitHub repo `Darkdonald2/scanvas` | Transfer it to the new GitHub account (Settings › Transfer ownership), or fork it. Releases and Actions move with a transfer. Then update the two hard-coded links below. |
| Hard-coded release links | `App/Sources/Views/SettingsView.swift` and `Views/RawTransferView.swift` link to `https://github.com/Darkdonald2/scanvas/releases/tag/studio`. Change them if the repo owner or name changes. |
| GitHub Actions | Needs Actions enabled and the workflow permission `contents: write` (already in the workflow files). No secrets are used. |
| Claude GitHub access | Connect the new account at claude.ai/connect-github, install the Claude GitHub app on the repo, and attach the repo to new sessions. |
| AltStore | Uses the user's own Apple ID; nothing is stored in the repo. |
| Project files | `/mnt/project-files/scanvas/` only holds copies. Download anything wanted from it before leaving; the repo and releases have everything. |
| Project memory | Memory was off in this project, so nothing needs exporting. |
| Bundle id | `com.yourname.scanvas` is a placeholder. Change it only if signing with a paid developer account. |
