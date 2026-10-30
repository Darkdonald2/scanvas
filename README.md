# Scanvas

A free LiDAR 3D scanner for iPhone and iPad. No account, no subscription, no paywall: every feature and every export is unlocked.

## Features

| Mode | What it does |
| --- | --- |
| **Room** | Apple RoomPlan scanning of walls, doors, windows, openings and furniture. Scan several rooms in a row and they are merged into one floor plan. |
| **Space** | LiDAR mesh scanning of spaces of any size (whole floors, warehouses, outdoors) with live mesh preview, surface classification and photo colours. |
| **Object** | Apple Object Capture guided scanning → textured USDZ model. |
| **Photos** | Turn 20–200 photos into a textured 3D model on the device. |
| **Measure** | AR tape measure with multi-point paths and totals. |

Every scan opens in a 3D viewer (colour / surface / wireframe shading, tap-to-measure) and a 2D plan view (rooms: full plan with dimensions; spaces: adjustable horizontal section).

### Exports

| Format | Use it for |
| --- | --- |
| **DXF floor plan** | AutoCAD (open directly) and Revit (Insert › Import CAD). Layers: `A-WALL`, `A-DOOR`, `A-GLAZ`, `A-FURN`, `A-FLOR`, `A-ANNO-DIMS`, `A-ANNO-TEXT`. Walls are cut at doors and windows, doors have swings, every wall is dimensioned. For spaces it is a plan section of the mesh at the height you choose. |
| **DXF 3D** | 3D faces in AutoCAD/Revit, one layer per part (walls, floor, ceiling…). |
| **IFC** | Revit (Open › IFC or Link IFC), ArchiCAD, BIM viewers. Rooms become real `IfcWall`, `IfcDoor`, `IfcWindow` (with openings cut in the walls), `IfcSlab` and `IfcFurnishingElement` (IFC2x3). Spaces/objects become IFC4 mesh proxies. |
| OBJ, USDZ, GLB, STL, PLY | Revit 2024+, SketchUp, Blender, Rhino, 3D printing, web, AR Quick Look. |
| PTS / XYZ point cloud | Autodesk ReCap → RCP for AutoCAD/Revit point-cloud workflows, CloudCompare. |
| PDF / PNG plan | Printable plan with dimensions, area and scale bar. |
| CSV | Every wall, door, window and object with sizes, plus floor area. |

DXF units can be millimetres, centimetres, metres, inches or feet. Exports are also saved in the Files app under *On My iPhone › Scanvas › Exports*.

## Requirements

- iPhone 12 Pro or newer Pro model, or an iPad Pro with LiDAR, on iOS 17 or later. (Measure works on any ARKit device.)

## Building

### On GitHub (no Mac needed)

Every push to `main` runs **Build IPA** in GitHub Actions. It publishes `Scanvas.ipa` on the `latest` release. Download it on your iPhone and open it with AltStore / SideStore, which signs it with your Apple ID.

### On a Mac

```bash
brew install xcodegen   # once
bash make-ipa.command   # or double-click it in Finder
```

This generates `Scanvas.xcodeproj` with XcodeGen and builds an unsigned `Scanvas.ipa`. To run from Xcode instead, run `xcodegen`, open `Scanvas.xcodeproj`, set your team, and change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` to something unique.

## Project layout

```
App/Sources
├── Capture/   RoomPlan, LiDAR mesh scanner, Object Capture, Photos → 3D, AR measure
├── Convert/   RoomPlan → plan model
├── Export/    DXF, IFC, OBJ/PLY/STL/GLB/PTS/XYZ, USDZ, PDF/PNG plan writers
├── Models/    Plan model, mesh data, projects
├── Storage/   Project library on disk
└── Views/     Home, project viewer, plan view, export, settings
```
