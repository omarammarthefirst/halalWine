#!/usr/bin/env python3
"""Adds dist/runtime-entry.json to Runtime/manifest.json (newest first)."""
import json, pathlib, sys

root = pathlib.Path(__file__).resolve().parent.parent
entry_path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / "dist" / "runtime-entry.json"
manifest_path = root / "Runtime" / "manifest.json"

entry = json.loads(entry_path.read_text())
manifest = json.loads(manifest_path.read_text())
runtimes = [r for r in manifest.get("runtimes", []) if r.get("version") != entry["version"]]
runtimes.insert(0, entry)
manifest["schema"] = 1
manifest["runtimes"] = runtimes[:5]
manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
print(f"manifest now lists: {', '.join(r['version'] for r in manifest['runtimes'])}")
