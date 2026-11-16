#!/usr/bin/env python3
"""Creates a fake Godot 4 game folder (tiny but valid .exe + .pck) for tests:
    scripts/make-fixture.py "/tmp/Demo.Game.v1.2.3"
"""
import os, struct, sys

def pe():
    b = bytearray(0x1400)
    b[0:2] = b"MZ"
    struct.pack_into("<I", b, 0x3C, 0x80)
    b[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<HHIIIHH", b, 0x84, 0x8664, 1, 0, 0, 0, 240, 0x22)
    o = 0x98
    struct.pack_into("<H", b, o, 0x20B)
    struct.pack_into("<H", b, o + 68, 2)
    struct.pack_into("<I", b, o + 108, 16)
    b[o + 240:o + 248] = b".rdata\0\0"
    struct.pack_into("<IIII", b, o + 248, 0x1000, 0x1000, 0x1000, 0x400)
    return bytes(b)

def pck(major=4, minor=5, patch=0):
    header = b"GDPC" + struct.pack("<IIII", 3, major, minor, patch)
    project = b"ECFG" + struct.pack("<I", 0)
    path = b"project.binary"
    path += b"\0" * ((4 - len(path) % 4) % 4)
    size = len(header) + 4 + 8 + 8 + 64
    directory = struct.pack("<II", 1, len(path)) + path + struct.pack("<QQ", 0, len(project)) + b"\0" * 16 + struct.pack("<I", 0)
    return header + struct.pack("<IQQ", 2, size, size + len(project)) + b"\0" * 64 + project + directory

root = sys.argv[1] if len(sys.argv) > 1 else "Demo.Game.v1.2.3"
os.makedirs(os.path.join(root, "data_demo_windows_x86_64"), exist_ok=True)
open(os.path.join(root, "DemoGame.exe"), "wb").write(pe())
open(os.path.join(root, "DemoGame.pck"), "wb").write(pck())
open(os.path.join(root, "data_demo_windows_x86_64", "GodotSharp.dll"), "wb").write(b"\0")
print(root)
