# Using a custom-built FEX in Proton without modifying Proton

Goal: run games from Steam with **your build** of `libwow64fex.dll` / `libwow64fex.so`,
without touching the original Proton files (in `steamapps/common/...` or
`/usr/share/steam/...`).

## Table of contents

- [0. What to know up front](#0-what-to-know-up-front)
- [1. Method A (recommended): symlink farm in `compatibilitytools.d`](#1-method-a-recommended-symlink-farm-in-compatibilitytoolsd)
- [2. Verifying that your FEX is actually loaded](#2-verifying-that-your-fex-is-actually-loaded)
- [3. Rollback](#3-rollback)
- [4. Method B: full copy of Proton](#4-method-b-full-copy-of-proton)
- [5. Method C: temporary bind-mount (no copy)](#5-method-c-temporary-bind-mount-no-copy)
- [6. Pitfalls](#6-pitfalls)
- [7. Cheat sheet](#7-cheat-sheet)

---

## 0. What to know up front

- FEX in Proton is a **pair** of files inside Proton:
  - `files/lib/wine/aarch64-windows/libwow64fex.dll` (PE, ARM64)
  - `files/lib/wine/aarch64-unix/libwow64fex.so` (the unix part)
  Both must come from **one build**.
- The DLL's PE header **must** have the `IMAGE_FILE_DLL` bit set (`chars & 0x2000`).
  Without it wine does not call `DllMain`/`BTCpuProcessInit` and FEX never
  initializes (that was the root of the first problem). Check:
  ```bash
  python3 -c 'import struct,sys; d=open(sys.argv[1],"rb").read(); pe=struct.unpack_from("<I",d,0x3c)[0]; c=struct.unpack_from("<H",d,pe+22)[0]; print(hex(c), "OK" if c&0x2000 else "MISSING DLL BIT")' libwow64fex.dll
  ```
- `WINEDLLPATH` **does not work** for swapping FEX: wine first looks for the
  builtin in its own binary's directory; `WINEDLLPATH` comes after. Verified —
  the stock FEX gets loaded.
- Proton variables (`STEAM_COMPAT_FEX_CONFIG`, `FEX_APP_CONFIG`, `STEAM_FEX_*`)
  change only the **settings** of FEX, not the binary itself.

Therefore the right path is a **separate compatibility tool**: a Steam tool that
references Proton's files, but with the FEX files swapped in.

---

## 1. Method A (recommended): symlink farm in `compatibilitytools.d`

The Proton tree is copied as symlinks (real directories, files — links), and only
the two FEX files are real, from your build. The original is not modified and it
takes up almost no space:

```
~/.local/share/Steam/compatibilitytools.d/fex-custom/
├── compatibilitytool.vdf                 tool name
├── proton                                symlink → original
└── files/                                symlink farm → original Proton
    ├── steampipe_fixups_mtime            real copy (proton writes to it)
    ├── dist.lock                         real file (flock must not touch original)
    └── lib/wine/
        ├── aarch64-windows/libwow64fex.dll   real — your build
        └── aarch64-unix/libwow64fex.so       real — your build
```

### Ready-made script

```bash
cd /var/home/armada/opencode/fex
chmod +x make-fex-tool.sh

./make-fex-tool.sh \
  "/var/home/armada/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)" \
  /path/to/build/libwow64fex.dll \
  /path/to/build/libwow64fex.so \
  fex-custom "Proton 11.0 ARM64 + custom FEX"
```

The script:
1. checks the `IMAGE_FILE_DLL` bit;
2. does `cp -as` (symlink farm) into
   `~/.local/share/Steam/compatibilitytools.d/fex-custom`;
3. replaces `libwow64fex.dll` and `libwow64fex.so` with yours;
4. writes `compatibilitytool.vdf` with the tool name.

### Manually (the same thing)

```bash
REAL="/var/home/armada/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)"
DEST="$HOME/.local/share/Steam/compatibilitytools.d/fex-custom"

rm -rf "$DEST" && mkdir -p "$DEST"
cp -as "$REAL"/. "$DEST"/

# FEX files: remove the symlinks and place the real build files
rm -f "$DEST/files/lib/wine/aarch64-windows/libwow64fex.dll" \
      "$DEST/files/lib/wine/aarch64-unix/libwow64fex.so"
cp /path/to/build/libwow64fex.dll "$DEST/files/lib/wine/aarch64-windows/"
cp /path/to/build/libwow64fex.so  "$DEST/files/lib/wine/aarch64-unix/"

cat > "$DEST/compatibilitytool.vdf" <<'EOF'
"compatibilitytools"
{
  "compat_tools"
  {
    "fex-custom"
    {
      "install_path" "."
      "display_name" "Proton 11.0 ARM64 + custom FEX"
      "from_oslist" "windows"
      "to_oslist" "linux"
    }
  }
}
EOF
```

### Enabling it in Steam

1. Restart Steam (a new tool is read at startup).
2. Game → Properties → **Compatibility** → "Force the use of a specific Steam
   Play compatibility tool" → select **"Proton 11.0 ARM64 + custom FEX"**.
3. Launch the game.

> Note: in the current config game 55150 is assigned to
> `proton-cachyos-11.0-arm64`. To test your FEX build specifically, you have to
> switch it to the created tool explicitly (or create a tool based on
> CachyOS-Proton, but its directory is in `/usr/share` — see §5).

---

## 2. Verifying that your FEX is actually loaded

While the game is running:

```bash
grep -h libwow64fex /proc/*/maps | sort -u
```

A path **from your tool** must appear, e.g.:
```
.../compatibilitytools.d/fex-custom/files/lib/wine/aarch64-windows/libwow64fex.dll
```

Additionally:
- the `md5sum` of the file in the tool must match your build;
- if the build contains temporary markers (`SPDIAG` etc.) — they will appear in
  the game/Steam log;
- the FEX version is visible in the FEX log (`FEX: ... version`) without the
  wine prefix.

---

## 3. Rollback

```bash
rm -rf "$HOME/.local/share/Steam/compatibilitytools.d/fex-custom"
```
and set the previous Proton back in the game's properties. The original Proton
was not modified, so there is nothing else to fix.

---

## 4. Method B: full copy of Proton

If you do not want symlinks (e.g. you are afraid the tool writes something into
`files/`):

```bash
REAL="/var/home/armada/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)"
DEST="$HOME/.local/share/Steam/compatibilitytools.d/fex-custom"
rm -rf "$DEST" && cp -a "$REAL" "$DEST"
# then — replace the two FEX files and place compatibilitytool.vdf (as in §1)
```

Pro: fully isolated. Con: ~1.9 GB for the copy.

---

## 5. Method C: temporary bind-mount (no copy)

Only for quick experiments, requires root, **does not survive a reboot**:

```bash
sudo mount --bind /path/to/libwow64fex.dll \
  "/var/home/armada/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/files/lib/wine/aarch64-windows/libwow64fex.dll"
sudo mount --bind /path/to/libwow64fex.so \
  "/var/home/armada/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/files/lib/wine/aarch64-unix/libwow64fex.so"
# rollback:
sudo umount ".../libwow64fex.dll" ".../libwow64fex.so"
```

Caveat: the game runs in a pressure-vessel container; the bind-mount is usually
visible, but that is not guaranteed. For permanent use — Method A.

---

## 6. Pitfalls

1. **The tool base must be in home.** The symlink farm references Proton's files;
   inside pressure-vessel the home directory is mounted, while `/usr/share/steam/...`
   may be inaccessible. So we take the base from
   `~/.local/share/Steam/steamapps/common/...`, not from `/usr/share/steam/...`.
2. **CachyOS-Proton from `/usr/share/steam/compatibilitytools.d/`** is a packaged
   (rpm) tool. Do not patch it directly: a package update overwrites the files.
   You need your own FEX — make a separate tool on a copy/farm (or copy
   CachyOS-Proton into home and farm from that).
3. **The DLL+so pair** — always from one build; do not mix with depot files.
4. **The DLL bit** — check it before every deploy (§0).
5. **Restarting Steam** — mandatory after creating/modifying a tool.
6. Do not confuse with `steamapps/common/FEX-Emu` (a separate Steam tool) and the
   system `fex-emu` (`/usr/bin/FEX`) — a game through Proton uses the FEX
   **inside Proton**.

---

## 7. Cheat sheet

```bash
# build FEX (example)
cd /var/home/armada/opencode/fex-src && ...

# create the tool
/var/home/armada/opencode/fex/make-fex-tool.sh \
  "/var/home/armada/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)" \
  /path/to/libwow64fex.dll /path/to/libwow64fex.so \
  fex-custom "Proton 11.0 ARM64 + custom FEX"

# check that our FEX got loaded
grep -h libwow64fex /proc/*/maps | sort -u

# rollback
rm -rf ~/.local/share/Steam/compatibilitytools.d/fex-custom
```
