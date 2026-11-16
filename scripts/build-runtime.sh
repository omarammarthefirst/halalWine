#!/bin/bash
# Assembles the halalWine runtime ("Windows engine") from open-source parts:
#   • Wine for macOS — Gcenx/macOS_Wine_builds (LGPL-2.1)
#   • DXMT           — 3Shain/dxmt (zlib)          DirectX 10/11 → Metal
#   • DXVK-macOS     — Gcenx/DXVK-macOS (zlib)     DirectX 10/11 → Vulkan → MoltenVK
# Output: dist/halalwine-runtime-<version>.tar.xz and dist/runtime-entry.json
#
# D3DMetal is NOT included: Apple's license does not allow redistribution.
# Users import it in the app from their own Game Porting Toolkit download.
set -euo pipefail
cd "$(dirname "$0")/.."

WINE_VERSION="${WINE_VERSION:-11.21}"
WINE_FLAVOR="${WINE_FLAVOR:-devel}"          # devel | staging
DXMT_VERSION="${DXMT_VERSION:-v0.80}"
DXVK_TAG="${DXVK_TAG:-v1.10.3-20230507}"      # empty to skip DXVK
REVISION="${REVISION:-1}"
VERSION="$WINE_VERSION-$REVISION"
REPO="${GITHUB_REPOSITORY:-omarammarthefirst/halalWine}"

WORK="$(mktemp -d)"
OUT="dist"
R="$WORK/halalwine-runtime"
mkdir -p "$WORK/dl" "$OUT" "$R/components/dxmt" "$R/components/dxvk"
auth=()
if [ -n "${GH_TOKEN:-}" ]; then auth=(-H "Authorization: Bearer $GH_TOKEN"); fi

echo "▶ Wine $WINE_FLAVOR $WINE_VERSION"
curl -fL --retry 4 -o "$WORK/dl/wine.tar.xz" \
  "https://github.com/Gcenx/macOS_Wine_builds/releases/download/$WINE_VERSION/wine-$WINE_FLAVOR-$WINE_VERSION-osx64.tar.xz"
mkdir -p "$WORK/wine-x"
tar -xf "$WORK/dl/wine.tar.xz" -C "$WORK/wine-x"
WINE_DIR="$(find "$WORK/wine-x" -type d -path '*/Contents/Resources/wine' | head -1)"
if [ -z "$WINE_DIR" ]; then echo "Wine folder not found in archive"; find "$WORK/wine-x" -maxdepth 4; exit 1; fi
mv "$WINE_DIR" "$R/wine"
test -x "$R/wine/bin/wine" || test -x "$R/wine/bin/wine64"

echo "▶ DXMT $DXMT_VERSION"
curl -fL --retry 4 -o "$WORK/dl/dxmt.tar.gz" \
  "https://github.com/3Shain/dxmt/releases/download/$DXMT_VERSION/dxmt-$DXMT_VERSION-builtin.tar.gz"
mkdir -p "$WORK/dxmt-x"
tar -xf "$WORK/dl/dxmt.tar.gz" -C "$WORK/dxmt-x"
for arch in x86_64-unix x86_64-windows i386-windows; do
  src="$(find "$WORK/dxmt-x" -type d -name "$arch" | head -1)"
  if [ -n "$src" ]; then mkdir -p "$R/components/dxmt/$arch" && cp -R "$src/." "$R/components/dxmt/$arch/"; fi
done
if [ ! -f "$R/components/dxmt/x86_64-windows/d3d11.dll" ] || [ ! -f "$R/components/dxmt/x86_64-unix/winemetal.so" ]; then
  echo "Unexpected DXMT layout:"; find "$WORK/dxmt-x" | head -40; exit 1
fi

DXVK_NAME=""
if [ -n "$DXVK_TAG" ]; then
  echo "▶ DXVK-macOS $DXVK_TAG"
  DXVK_URL="$(curl -fsSL ${auth[@]+"${auth[@]}"} "https://api.github.com/repos/Gcenx/DXVK-macOS/releases/tags/$DXVK_TAG" \
    | python3 -c 'import json,sys; a=[x for x in json.load(sys.stdin)["assets"] if x["name"].endswith(".tar.gz") and "builtin" not in x["name"]]; print(a[0]["browser_download_url"] if a else "")')"
  if [ -n "$DXVK_URL" ]; then
    DXVK_NAME="$(basename "$DXVK_URL")"
    curl -fL --retry 4 -o "$WORK/dl/dxvk.tar.gz" "$DXVK_URL"
    mkdir -p "$WORK/dxvk-x"
    tar -xf "$WORK/dl/dxvk.tar.gz" -C "$WORK/dxvk-x"
    for arch in x64 x32; do
      src="$(find "$WORK/dxvk-x" -type d -name "$arch" | head -1)"
      if [ -n "$src" ]; then mkdir -p "$R/components/dxvk/$arch" && cp "$src"/*.dll "$R/components/dxvk/$arch/"; fi
    done
  else
    echo "  (no DXVK asset found, skipping)"
  fi
fi

cat > "$R/runtime.json" <<JSON
{
  "version": "$VERSION",
  "wineVersion": "$WINE_VERSION",
  "components": {
    "wine": "$WINE_FLAVOR $WINE_VERSION (Gcenx/macOS_Wine_builds)",
    "dxmt": "$DXMT_VERSION",
    "dxvk": "${DXVK_TAG:-none}"
  }
}
JSON

cat > "$R/NOTICE.txt" <<TXT
halalWine runtime $VERSION — open-source components and where to get their source code:

Wine $WINE_VERSION ($WINE_FLAVOR) — GNU LGPL 2.1 or later
  Binary build: https://github.com/Gcenx/macOS_Wine_builds/releases/tag/$WINE_VERSION
  Source code:  https://dl.winehq.org/wine/source/ and https://gitlab.winehq.org/wine/wine
DXMT $DXMT_VERSION — zlib license — https://github.com/3Shain/dxmt
DXVK-macOS ${DXVK_TAG:-(not included)} — zlib license — https://github.com/Gcenx/DXVK-macOS
MoltenVK (bundled with Wine) — Apache 2.0 — https://github.com/KhronosGroup/MoltenVK
wine-mono / wine-gecko (bundled with Wine) — see https://gitlab.winehq.org/wine-mono/wine-mono

D3DMetal is not included. It belongs to Apple and is imported by each user
from Apple's Game Porting Toolkit.
TXT

if [ "$(uname)" = "Darwin" ]; then
  echo "▶ Smoke test"
  WINE_BIN="$R/wine/bin/wine"; [ -x "$WINE_BIN" ] || WINE_BIN="$R/wine/bin/wine64"
  "$WINE_BIN" --version || echo "  (wine --version failed; is Rosetta installed?)"
fi

echo "▶ Packaging"
ARCHIVE="$OUT/halalwine-runtime-$VERSION.tar.xz"
if [ "$(uname)" = "Darwin" ]; then
  tar --options xz:compression-level=6,xz:threads=0 -C "$WORK" -cJf "$ARCHIVE" halalwine-runtime
else
  XZ_OPT="-6 -T0" tar -C "$WORK" -cJf "$ARCHIVE" halalwine-runtime
fi
SHA="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
SIZE="$(wc -c < "$ARCHIVE" | tr -d ' ')"
cp "$R/NOTICE.txt" "$OUT/RUNTIME-NOTICE.txt"
cat > "$OUT/runtime-entry.json" <<JSON
{
  "version": "$VERSION",
  "wineVersion": "$WINE_VERSION",
  "url": "https://github.com/$REPO/releases/download/runtime-$VERSION/halalwine-runtime-$VERSION.tar.xz",
  "sha256": "$SHA",
  "size": $SIZE,
  "components": { "wine": "$WINE_FLAVOR $WINE_VERSION", "dxmt": "$DXMT_VERSION", "dxvk": "${DXVK_TAG:-none}" }
}
JSON
echo "VERSION=$VERSION" > "$OUT/runtime.env"
echo "✔ $ARCHIVE ($SIZE bytes, sha256 $SHA)"
rm -rf "$WORK"
