# Scanvas Studio

The computer side of Scanvas. The iPhone records a **raw capture** (full-resolution photos about six times a
second, each with its LiDAR depth, depth confidence, exact camera pose and lens values), and Studio turns it into a
model far denser and sharper than a phone can process on its own.

## What it does

1. **Chooses photos**: drops motion-blurred frames and keeps the sharpest view of every spot.
2. **Fuses depth**: integrates every depth map into one volume (TSDF), at 2 cm, 1 cm or 6 mm detail.
3. **Refines cameras**: lines each photo's depth up with the phone's own mesh, which removes drift of tens of
   centimetres and drops photos that fit nowhere, then with the fused surface (point-to-plane ICP), then fuses again.
4. **Cleans**: removes floating bits and smooths LiDAR noise.
5. **Textures**: unwraps the surface and paints every texel from the single best full-resolution photo of that
   spot (close, head-on, sharp, not hidden behind anything, and agreeing with that photo's own LiDAR depth, so
   people who walked through aren't painted onto the walls), with patches joined and colours levelled.
6. **Exports** to the results folder:
   - `model_textured.obj` with `.mtl` and `.jpg`, for Revit, SketchUp, Blender, 3ds Max and Rhino
   - `model_textured.glb`, for web viewers, Blender, Unity and Unreal
   - `model_dense_colour.ply`, the full-detail coloured mesh
   - `point_cloud.ply`, for CloudCompare and ReCap

## Getting scans from the iPhone

- **Wi-Fi:** keep Studio open. On the iPhone, open the scan › ⋯ › **Send to computer**, type the pairing code shown
  in Studio and tap the computer. Studio processes it as soon as it arrives.
- **Zip:** on the same screen, tap **Make a zip**, then AirDrop it or save it to Files, iCloud, OneDrive or USB.
  In Studio, click **Open raw zip…**.

## Running

Download from the repository's **studio** release, or run from source with Python 3.10–3.12:

```
pip install -r requirements.txt
python run_studio.py                       # the window
python run_studio.py scan.zip --quality high --z-up   # command line
python run_studio.py --serve               # Wi-Fi receiver only
```

Results go to `~/Scanvas Studio/Scans`.

## Raw capture format ("scanvas-raw", version 1)

| File | Contents |
| --- | --- |
| `capture.json` | Device, frame count, image and depth sizes, conventions |
| `frames.jsonl` | One JSON object per frame: `image`, `depth`, `confidence`, `width`, `height`, `depthWidth`, `depthHeight`, `intrinsics` [fx, fy, cx, cy] in image pixels, `cameraToWorld` (4×4 column-major), `exposureDuration`, `exposureOffset`, `ambientIntensity`, `colorTemperature`, `anchors` (poses of nearby mesh anchors when the frame was taken), `poseAnchors`, `mapping` (ARKit's world-mapping state), `turnSpeed` (rad/s), `walkSpeed` (m/s) |
| `images/NNNNNN.jpg` | Camera photo at full camera resolution (1920×1440, or 4K) |
| `depth/NNNNNN.bin` | LiDAR depth, float32 metres, row-major |
| `confidence/NNNNNN.bin` | LiDAR confidence, uint8 0 (low), 1 (medium), 2 (high) |
| `anchors.json` | Final pose of every mesh anchor; Studio uses the change since each frame to undo tracking drift |
| `pose_anchors.json` | Final pose of every path anchor (the app drops one on the camera's path about once a second); each frame's `poseAnchors` holds the nearest three as they were then, which gives the drift directly |
| `arkit_mesh.ply` | The phone's own mesh. Studio lines every photo up with it before fusing, because it already has ARKit's map corrections in it |
| `pipes.json` | Pipe survey (Pipes scans only) |

ARKit world coordinates are right-handed, in metres, with Y up. Cameras look along −Z with +Y up, and image pixels
start at the top left.
