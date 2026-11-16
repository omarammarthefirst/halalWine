#!/bin/bash
# Assembles the halalWine runtime ("Windows engine").
#
# SOURCE=whisky (default) — the engine published by the maintained Whisky fork
#   (github.com/frankea/Whisky "Wine Libraries" releases): Wine built from
#   CrossOver's open-source code, with DXMT and DXVK. DXMT needs CrossOver's
#   Mac driver (winemac.so must export macdrv_functions), which upstream Wine
#   builds do not provide.
# SOURCE=gcenx — upstream Wine from Gcenx/macOS_Wine_builds + DXMT + DXVK-macOS.
#   DXMT will NOT work with it (see above); kept for testing newer Wine.
#
# Output: dist/halalwine-runtime-<version>.tar.xz, dist/runtime-entry.json
#
# D3DMetal is never included: Apple's license does not allow redistribution.
# Users import it in the app from their own Game Porting Toolkit download.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="${SOURCE:-whisky}"
WHISKY_ENGINE_TAG="${WHISKY_ENGINE_TAG:-v4.8.3}"
# Checksum published in the v4.8.3 release notes; set to "" to skip for other tags.
WHISKY_ENGINE_SHA256="${WHISKY_ENGINE_SHA256-08ffabd7b7c352470faee2b1d51061b341316e401439ca805c5302acc2fb8818}"
WINE_VERSION="${WINE_VERSION:-11.21}"         # gcenx only
WINE_FLAVOR="${WINE_FLAVOR:-devel}"           # gcenx only: devel | staging
DXMT_VERSION="${DXMT_VERSION:-v0.80}"         # gcenx only
DXVK_TAG="${DXVK_TAG:-v1.10.3-20230507}"      # gcenx only; empty to skip
REVISION="${REVISION:-1}"
# Date-based so every new runtime sorts after older ones.
VERSION="${RUNTIME_VERSION:-$(date -u +%Y.%m.%d).$REVISION}"
REPO="${GITHUB_REPOSITORY:-omarammarthefirst/halalWine}"

WORK="$(mktemp -d)"
OUT="dist"
R="$WORK/halalwine-runtime"
mkdir -p "$WORK/dl" "$OUT" "$R/components/dxmt" "$R/components/dxvk"
auth=()
if [ -n "${GH_TOKEN:-}" ]; then auth=(-H "Authorization: Bearer $GH_TOKEN"); fi

if [ "$SOURCE" = "whisky" ]; then
  echo "▶ Whisky engine $WHISKY_ENGINE_TAG (Wine from CrossOver sources)"
  ENGINE_URL="https://github.com/frankea/Whisky/releases/download/$WHISKY_ENGINE_TAG/Libraries.tar.gz"
  curl -fL --retry 4 -o "$WORK/dl/engine.tar.gz" "$ENGINE_URL"
  if [ -n "$WHISKY_ENGINE_SHA256" ]; then
    echo "$WHISKY_ENGINE_SHA256  $WORK/dl/engine.tar.gz" | shasum -a 256 -c -
  fi
  tar -xzf "$WORK/dl/engine.tar.gz" -C "$WORK"
  L="$WORK/Libraries"
  mv "$L/Wine" "$R/wine"
  cp -R "$L/DXMT/." "$R/components/dxmt/"
  for arch in x64 x32; do
    if [ -d "$L/DXVK/$arch" ]; then mkdir -p "$R/components/dxvk/$arch" && cp "$L/DXVK/$arch"/*.dll "$R/components/dxvk/$arch/"; fi
  done
  plist_value() { /usr/bin/plutil -extract "$1" raw "$L/WhiskyWineVersion.plist" 2>/dev/null || echo "?"; }
  if [ "$(uname)" = "Darwin" ]; then
    DXMT_VERSION="$(plist_value dxmtVersion)"
    DXVK_TAG="$(plist_value dxvkVersion)"
  else
    DXMT_VERSION="see engine"; DXVK_TAG="see engine"
  fi
  WINE_VERSION="${WHISKY_WINE_VERSION:-11.19}"   # replaced by `wine --version` below
  WINE_DESCRIPTION="CrossOver-based Wine (frankea/Whisky engine $WHISKY_ENGINE_TAG)"
  SOURCE_NOTE="Engine: https://github.com/frankea/Whisky/releases/tag/$WHISKY_ENGINE_TAG
  Wine source (CrossOver sources + patches): https://github.com/frankea/winecx-gptk
  CrossOver sources: https://www.codeweavers.com/crossover/source
  Bundled libraries (GStreamer, FFmpeg, MoltenVK, SDL2, ...) come from the
  engine build; their sources are linked from the engine's release notes."
  # DXMT needs these from CrossOver's Mac driver; fail early if missing.
  test -f "$R/wine/lib/wine/x86_64-unix/winemetal.so"
  test -f "$R/components/dxmt/x64/d3d11.dll"
  if [ "$(uname)" = "Darwin" ]; then
    nm -gU "$R/wine/lib/wine/x86_64-unix/winemac.so" | grep -q " _macdrv_functions$" \
      || { echo "winemac.so does not export macdrv_functions; DXMT cannot work"; exit 1; }
  fi
else
  echo "▶ Wine $WINE_FLAVOR $WINE_VERSION (upstream, Gcenx)"
  curl -fL --retry 4 -o "$WORK/dl/wine.tar.xz" \
    "https://github.com/Gcenx/macOS_Wine_builds/releases/download/$WINE_VERSION/wine-$WINE_FLAVOR-$WINE_VERSION-osx64.tar.xz"
  mkdir -p "$WORK/wine-x"
  tar -xf "$WORK/dl/wine.tar.xz" -C "$WORK/wine-x"
  WINE_DIR="$(find "$WORK/wine-x" -type d -path '*/Contents/Resources/wine' | head -1)"
  if [ -z "$WINE_DIR" ]; then echo "Wine folder not found in archive"; find "$WORK/wine-x" -maxdepth 4; exit 1; fi
  mv "$WINE_DIR" "$R/wine"

  echo "▶ DXMT $DXMT_VERSION"
  curl -fL --retry 4 -o "$WORK/dl/dxmt.tar.gz" \
    "https://github.com/3Shain/dxmt/releases/download/$DXMT_VERSION/dxmt-$DXMT_VERSION-builtin.tar.gz"
  mkdir -p "$WORK/dxmt-x"
  tar -xf "$WORK/dl/dxmt.tar.gz" -C "$WORK/dxmt-x"
  for arch in x86_64-unix x86_64-windows i386-windows; do
    src="$(find "$WORK/dxmt-x" -type d -name "$arch" | head -1)"
    if [ -n "$src" ]; then mkdir -p "$R/components/dxmt/$arch" && cp -R "$src/." "$R/components/dxmt/$arch/"; fi
  done

  if [ -n "$DXVK_TAG" ]; then
    echo "▶ DXVK-macOS $DXVK_TAG"
    DXVK_URL="$(curl -fsSL ${auth[@]+"${auth[@]}"} "https://api.github.com/repos/Gcenx/DXVK-macOS/releases/tags/$DXVK_TAG" \
      | python3 -c 'import json,sys; a=[x for x in json.load(sys.stdin)["assets"] if x["name"].endswith(".tar.gz") and "builtin" not in x["name"]]; print(a[0]["browser_download_url"] if a else "")')"
    if [ -n "$DXVK_URL" ]; then
      curl -fL --retry 4 -o "$WORK/dl/dxvk.tar.gz" "$DXVK_URL"
      mkdir -p "$WORK/dxvk-x"
      tar -xf "$WORK/dl/dxvk.tar.gz" -C "$WORK/dxvk-x"
      for arch in x64 x32; do
        src="$(find "$WORK/dxvk-x" -type d -name "$arch" | head -1)"
        if [ -n "$src" ]; then mkdir -p "$R/components/dxvk/$arch" && cp "$src"/*.dll "$R/components/dxvk/$arch/"; fi
      done
    fi
  fi
  WINE_DESCRIPTION="upstream Wine $WINE_FLAVOR $WINE_VERSION (Gcenx/macOS_Wine_builds)"
  SOURCE_NOTE="Binary build: https://github.com/Gcenx/macOS_Wine_builds/releases/tag/$WINE_VERSION
  Source code: https://gitlab.winehq.org/wine/wine"
fi

WINE_BIN="$R/wine/bin/wine"; [ -e "$WINE_BIN" ] || WINE_BIN="$R/wine/bin/wine64"
if [ "$(uname)" = "Darwin" ]; then
  echo "▶ Smoke test"
  DETECTED="$("$WINE_BIN" --version 2>/dev/null || true)"
  echo "  $DETECTED"
  if [ "$SOURCE" = "whisky" ] && [ -n "$DETECTED" ]; then WINE_VERSION="${DETECTED#wine-}"; WINE_VERSION="${WINE_VERSION%% *}"; fi
fi

cat > "$R/runtime.json" <<JSON
{
  "version": "$VERSION",
  "wineVersion": "$WINE_VERSION",
  "components": {
    "wine": "$WINE_DESCRIPTION",
    "dxmt": "$DXMT_VERSION",
    "dxvk": "${DXVK_TAG:-none}"
  }
}
JSON

cat > "$R/NOTICE.txt" <<TXT
halalWine runtime $VERSION — open-source components and where to get their source code:

Wine $WINE_VERSION — GNU LGPL 2.1 or later — $WINE_DESCRIPTION
  $SOURCE_NOTE
DXMT $DXMT_VERSION — zlib license — https://github.com/3Shain/dxmt
DXVK ${DXVK_TAG:-(not included)} — zlib license — https://github.com/Gcenx/DXVK-macOS
MoltenVK — Apache 2.0 — https://github.com/KhronosGroup/MoltenVK
wine-mono / wine-gecko — see https://gitlab.winehq.org/wine-mono/wine-mono

D3DMetal is not included. It belongs to Apple and is imported by each user
from Apple's Game Porting Toolkit.
TXT

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
  "components": { "wine": "$WINE_DESCRIPTION", "dxmt": "$DXMT_VERSION", "dxvk": "${DXVK_TAG:-none}" }
}
JSON
echo "VERSION=$VERSION" > "$OUT/runtime.env"
echo "✔ $ARCHIVE ($SIZE bytes, sha256 $SHA)"
rm -rf "$WORK"
