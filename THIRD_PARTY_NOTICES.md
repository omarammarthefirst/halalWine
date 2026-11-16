# Third-party software

halalWine's app code is MIT-licensed. The **Windows engine** (runtime) that the
app downloads on first launch is assembled by `scripts/build-runtime.sh` from
the following open-source projects, each under its own license. Every runtime
release includes a `NOTICE.txt` with exact versions and source links.

| Component | License | Source |
|---|---|---|
| Wine (macOS builds by Gcenx) | GNU LGPL 2.1 or later | https://gitlab.winehq.org/wine/wine · builds: https://github.com/Gcenx/macOS_Wine_builds |
| DXMT | zlib | https://github.com/3Shain/dxmt |
| DXVK-macOS | zlib | https://github.com/Gcenx/DXVK-macOS |
| MoltenVK | Apache 2.0 | https://github.com/KhronosGroup/MoltenVK |
| wine-mono | MIT and others | https://gitlab.winehq.org/wine-mono/wine-mono |
| wine-gecko | MPL 2.0 | https://gitlab.winehq.org/wine/wine-gecko |

**LGPL compliance:** Wine is distributed unmodified as built by Gcenx. Its
complete source code is available at the links above for the exact version
named in each runtime's `NOTICE.txt`. If you modify Wine for your own runtime,
publish your patches alongside the release.

**Not included:** Apple's D3DMetal (part of the Game Porting Toolkit) is
proprietary and is never redistributed by this project. Users download it from
Apple and import it into their own copy of the app.

**Downloaded on demand:** Microsoft Visual C++ Redistributable, DirectX (June
2010) and XNA Framework 4.0 are downloaded from Microsoft only when a game needs
them, or taken from the game's own folder, and installed into that game's
Windows environment.
