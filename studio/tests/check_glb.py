"""Reads a GLB the way the Scanvas iPhone app (and any other viewer) does, and fails if anything is missing or
points outside the file. Studio 1.0 wrote GLBs without their bufferViews table, which nothing could open."""
import json
import struct
import sys
from pathlib import Path


def check(path: Path) -> dict:
    b = path.read_bytes()
    magic, version, total = struct.unpack_from("<III", b, 0)
    assert magic == 0x46546C67 and version == 2, "not a GLB 2 file"
    assert total == len(b), f"header says {total} bytes, file has {len(b)}"
    json_len, json_type = struct.unpack_from("<II", b, 12)
    assert json_type == 0x4E4F534A and json_len % 4 == 0, "bad JSON chunk"
    g = json.loads(b[20:20 + json_len])
    bin_len, bin_type = struct.unpack_from("<II", b, 20 + json_len)
    assert bin_type == 0x004E4942 and 20 + json_len + 8 + bin_len == len(b), "bad binary chunk"
    assert g["buffers"][0]["byteLength"] == bin_len
    views, accessors = g["bufferViews"], g["accessors"]
    for v in views:
        assert v["byteOffset"] % 4 == 0 and v["byteOffset"] + v["byteLength"] <= bin_len, "buffer view outside the file"
    prim = g["meshes"][0]["primitives"][0]
    size = {"VEC3": 12, "VEC2": 8, "SCALAR": 4}
    counts = {}
    for name, a in list(prim["attributes"].items()) + [("indices", prim["indices"])]:
        acc = accessors[a]
        assert acc["count"] * size[acc["type"]] <= views[acc["bufferView"]]["byteLength"], f"{name} is larger than its buffer view"
        counts[name] = acc["count"]
    assert counts["POSITION"] == counts["NORMAL"] == counts["TEXCOORD_0"] > 0
    assert counts["indices"] % 3 == 0 and counts["indices"] > 0
    iv = views[g["images"][0]["bufferView"]]
    start = 20 + json_len + 8 + iv["byteOffset"]
    assert b[start:start + 2] == b"\xff\xd8", "the embedded texture isn't a JPEG"
    idx_view = views[accessors[prim["indices"]]["bufferView"]]
    i0 = 20 + json_len + 8 + idx_view["byteOffset"]
    top = max(struct.unpack_from(f"<{counts['indices']}I", b, i0))
    assert top < counts["POSITION"], "an index points past the last vertex"
    return {"triangles": counts["indices"] // 3, "vertices": counts["POSITION"], "texture_bytes": iv["byteLength"]}


if __name__ == "__main__":
    print("GLB ok:", check(Path(sys.argv[1])))
