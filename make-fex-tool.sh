#!/bin/bash
# make-fex-tool.sh — create/update a separate Steam compatibility tool
# based on an existing Proton, with its FEX (libwow64fex.dll/.so) swapped in.
#
# The original Proton is NOT modified: the Proton tree is copied as a symlink
# farm (real directories, files — symlinks), and only the two FEX files are
# replaced with real files from your build.
#
# Usage:
#   ./make-fex-tool.sh <proton-dir> <fex-dll> <fex-so> [tool-name] [display-name]
#
# Example:
#   ./make-fex-tool.sh \
#     "/var/home/armada/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)" \
#     /path/to/build/libwow64fex.dll \
#     /path/to/build/libwow64fex.so \
#     fex-custom "Proton 11.0 ARM64 + custom FEX"
#
# After creating: restart Steam -> game Properties -> Compatibility ->
# select "Proton 11.0 ARM64 + custom FEX".
set -euo pipefail

PROTON="${1:?usage: make-fex-tool.sh <proton-dir> <fex-dll> <fex-so> [tool-name] [display-name]}"
FEX_DLL="${2:?need built libwow64fex.dll}"
FEX_SO="${3:?need built libwow64fex.so}"
NAME="${4:-fex-custom}"
DISPLAY="${5:-Proton ARM64 + custom FEX}"

DEST="$HOME/.local/share/Steam/compatibilitytools.d/$NAME"

[ -d "$PROTON" ] || { echo "ERROR: no such proton dir: $PROTON" >&2; exit 1; }
[ -f "$PROTON/proton" ] || { echo "ERROR: $PROTON is not a Proton dir (no ./proton)" >&2; exit 1; }
[ -f "$FEX_DLL" ] || { echo "ERROR: missing $FEX_DLL" >&2; exit 1; }
[ -f "$FEX_SO" ]  || { echo "ERROR: missing $FEX_SO" >&2; exit 1; }

# --- sanity: the IMAGE_FILE_DLL bit must be set, otherwise wine will not call DllMain ---
python3 - "$FEX_DLL" <<'EOF'
import struct, sys
d = open(sys.argv[1], 'rb').read()
pe = struct.unpack_from('<I', d, 0x3c)[0]
chars, = struct.unpack_from('<H', d, pe + 22)
print(f"FEX DLL: chars=0x{chars:04x} -> " + ("DLL bit OK" if chars & 0x2000 else "DLL BIT MISSING"))
sys.exit(0 if chars & 0x2000 else 1)
EOF

echo "==> removing old tool dir (if any): $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"

echo "==> creating symlink farm from: $PROTON"
cp -as "$PROTON"/. "$DEST"/

# proton writes this file via open(..., "w") — if it is left as a symlink,
# the write would go into the original Proton. Make it a real copy.
if [ -f "$PROTON/files/steampipe_fixups_mtime" ]; then
  rm -f "$DEST/files/steampipe_fixups_mtime"
  cp "$PROTON/files/steampipe_fixups_mtime" "$DEST/files/steampipe_fixups_mtime"
fi
# keep dist.lock a real file too (flock must not touch the original)
rm -f "$DEST/dist.lock"
: > "$DEST/dist.lock"

echo "==> installing custom FEX"
rm -f "$DEST/files/lib/wine/aarch64-windows/libwow64fex.dll" \
      "$DEST/files/lib/wine/aarch64-unix/libwow64fex.so"
cp "$FEX_DLL" "$DEST/files/lib/wine/aarch64-windows/libwow64fex.dll"
cp "$FEX_SO"  "$DEST/files/lib/wine/aarch64-unix/libwow64fex.so"

echo "==> writing compatibilitytool.vdf"
# cp -as may have made this file a symlink to the original — cannot write through it
rm -f "$DEST/compatibilitytool.vdf"
cat > "$DEST/compatibilitytool.vdf" <<EOF
"compatibilitytools"
{
  "compat_tools"
  {
    "$NAME"
    {
      "install_path" "."
      "display_name" "$DISPLAY"
      "from_oslist" "windows"
      "to_oslist" "linux"
    }
  }
}
EOF

chmod +x "$DEST/proton"

echo
echo "==> done: $DEST"
echo "--- FEX files in tool ---"
md5sum "$DEST/files/lib/wine/aarch64-windows/libwow64fex.dll" \
       "$DEST/files/lib/wine/aarch64-unix/libwow64fex.so"
ls -l "$DEST/files/lib/wine/aarch64-windows/libwow64fex.dll" \
      "$DEST/files/lib/wine/aarch64-unix/libwow64fex.so"
echo
echo "Next: restart Steam, then game Properties -> Compatibility -> '$DISPLAY'"
