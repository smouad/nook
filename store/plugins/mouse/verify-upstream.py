"""Verify byte-identical MMF source against the checked-in, pinned provenance manifest."""
import hashlib
import json
from pathlib import Path

plugin = Path(__file__).resolve().parent
upstream = plugin / "upstream"
manifest = json.loads((upstream / "sources.json").read_text())
assert manifest["version"] == "3.1.0"
assert manifest["revision"] == "603646cdb5200eb9d0db0afdb5967c7ec41c5de0"
assert manifest["revision"] in (plugin / "native/MouseEngineProvenance.swift").read_text()
recorded = set()
for item in manifest["files"]:
    path = item["path"]
    assert path not in recorded and not Path(path).is_absolute() and ".." not in Path(path).parts, path
    recorded.add(path)
    actual = hashlib.sha256((upstream / path).read_bytes()).hexdigest()
    assert actual == item["sha256"], f"Original MMF source changed: {path}"
actual_files = {p.relative_to(upstream).as_posix() for p in upstream.rglob("*")
                if p.is_file() and "adapter" not in p.relative_to(upstream).parts and p.name != "sources.json"}
assert actual_files == recorded, "Unrecorded or missing upstream files"
print(f"PASS: {len(recorded)} original MMF 3.1.0 files match their pinned SHA-256 hashes.")
