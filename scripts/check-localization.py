#!/usr/bin/env python3
"""Checks that every L("key") used in the app exists in every language, and
that format specifiers match between languages."""
import re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
app = root / "Sources" / "HalalWineApp"
used = set()
for swift in app.rglob("*.swift"):
    text = swift.read_text(encoding="utf-8")
    used |= set(re.findall(r'\bL\("([A-Za-z0-9_.]+)"', text))
# Keys built at runtime.
used |= {f"backend.{b}.about" for b in ["d3dmetal", "dxmt", "dxvk", "wined3d"]}
used |= {f"flag.{f}" for f in ["easyAntiCheat", "battlEye", "riotVanguard", "otherAntiCheat", "usesSteam",
                               "needsPublisherLauncher", "unsupportedArchitecture", "mayHaveMacVersion"]}

pattern = re.compile(r'^"([^"]+)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')
tables = {}
ok = True
for lproj in sorted((app / "Resources").glob("*.lproj")):
    table = {}
    for n, line in enumerate((lproj / "Localizable.strings").read_text(encoding="utf-8").splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("/*") or line.startswith("//"):
            continue
        m = pattern.match(line)
        if not m:
            print(f"{lproj.name}:{n}: cannot parse: {line}"); ok = False; continue
        if m.group(1) in table:
            print(f"{lproj.name}:{n}: duplicate key {m.group(1)}"); ok = False
        table[m.group(1)] = m.group(2)
    tables[lproj.name] = table

spec = re.compile(r'%(?:\d+\$)?[@dDuUxXoOfeEgGcCsSpaAF]|%ld|%lld')
for name, table in tables.items():
    for key in sorted(used - table.keys()):
        print(f"{name}: missing {key}"); ok = False
    for key in sorted(table.keys() - used):
        print(f"{name}: unused {key}")
base = tables.get("en.lproj", {})
for name, table in tables.items():
    for key, value in table.items():
        if key in base and sorted(spec.findall(value)) != sorted(spec.findall(base[key])):
            print(f"{name}: format mismatch in {key}"); ok = False

print(f"{len(used)} keys used, languages: {', '.join(tables)}")
sys.exit(0 if ok else 1)
