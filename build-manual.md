# Building FEX-2611.1 on-device: `libwow64fex.dll` + `libwow64fex.so`

Builds **vanilla** FEX (tag `FEX-2611.1`, commit `4f9c1f1e36443d22d7655477e34f51b95b685bf1`)
**without a single change to the FEX sources** — toolchain wrappers only. The result
replaces `libwow64fex.dll`/`.so` in the Proton 11 (ARM64) Proton tool for the Space
Marine test (see `../spacemarine-proton-fix/warhammer-40k-space-marine.md`).

## Table of contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Build steps](#build-steps)
- [Verification](#verification)
- [Pitfalls: why so many errors (zig gotchas)](#pitfalls-why-so-many-errors-zig-gotchas)
- [Reboot: what burns and how to rebuild](#reboot-what-burns-and-how-to-rebuild)

## Overview

| Artifact | What it is | Verified |
|---|---|---|
| `libwow64fex.dll` | PE32+ ARM64 DLL, the whole FEX wow64 engine | imports are **only** `ntdll.dll` + `wow64.dll` (as in the depot); 23 exports = `libwow64fex.def` (BTCpu* + `__wine_get_unix_opcode`); entry `DllMainCRTStartup`; Subsystem = GUI (2); WINE marker (wine_builtin.bin) in place |
| `libwow64fex.so` | native aarch64 unixlib bridge | single export `__wine_unix_call_funcs`; dependencies glibc+libstdc++ (profile = depot, 68 KB vs the depot's 71 KB) |

The FEX sources are untouched. Every workaround is build infrastructure:
zig compiler wrappers, a CMake shim, a manual lld-link, and two micro-stubs.

## Prerequisites

- Retroid Pocket 6, RK3566 (4×A72+4×A55), aarch64, 6 GB RAM → **build with `-j2`**
- **bootc read-only**: everything goes through `echo "armada" | sudo -S dnf ... --transient`
  (packages live in the overlay and **burn on reboot**)
- `/tmp` = tmpfs 3.7 GB — **the entire build dir and artifacts burn on reboot**;
  only `home` survives a reboot (fex-src, this repo, proton-patched, compatdata)
- **do not reboot** until the swap test is finished

### Packages (in one shot)

```sh
echo "armada" | sudo -S dnf install -y --transient \
  zig gcc gcc-c++ cmake ninja-build lld git binutils glibc-devel make
```

(`lld` — for the final DLL link; `zig` 0.16 — the aarch64-windows-gnu cross-compiler.)

## Build steps

### 1. FEX sources

```sh
# in home (survives reboot)
cd ~/opencode
git clone https://github.com/FEX-Emu/FEX fex-src   # or already cloned
cd fex-src
git fetch --tags
git checkout -b build-2611.1 FEX-2611.1
git submodule update --init --recursive   # vixl @6561d40, rpmalloc @ed22744 etc.
```

### 2. Cross binutils (dlltool/ar/ld)

zig does not ship binutils; FEX CMake requires `aarch64-w64-mingw32-{dlltool,ar,windres}`.
Build binutils 2.45 from source:

```sh
cd /tmp/opencode
git clone --depth 1 --branch binutils-2_45 https://sourceware.org/git/binutils-gdb.git binutils-2.45
mkdir build-binutils && cd build-binutils
../binutils-2.45/configure --prefix=/tmp/opencode/xtools \
  --target=aarch64-w64-mingw32 --disable-winsup --disable-libdecnumber --with-pic \
  'CC=zig cc -target aarch64-linux-gnu' CFLAGS=-O2 target_alias=aarch64-w64-mingw32
make -j4 && make install
```

Result: `/tmp/opencode/xtools/bin/aarch64-w64-mingw32-{ar,dlltool,windres,ld,as,ar,nm,objdump,strip,...}`.

Symlinks into tools/bin (the wrappers below live there too):

```sh
mkdir -p /tmp/opencode/tools/bin
for t in ar dlltool windres as ld objcopy nm; do
  ln -sf /tmp/opencode/xtools/bin/aarch64-w64-mingw32-$t /tmp/opencode/tools/bin/aarch64-w64-mingw32-$t
done
```

### 3. Zig wrappers (cross compiler)

zig cc/c++ as `aarch64-w64-mingw32-clang{,++}`. Every rewrite is documented inside
the file; the full list of "why" — in the table at the end (Pitfalls).

#### `/tmp/opencode/tools/bin/aarch64-w64-mingw32-clang` (and `...-clang++` with `cc`→`c++`)

```bash
#!/bin/bash
# FEX build shim: zig as aarch64-w64-mingw32 cross compiler.
#
# -print-libgcc-file-name: zig keeps libgcc embedded (resolves -lgcc internally),
#   so emit the flag instead of a file path (FEX Source/Windows/CMakeLists.txt
#   feeds this output into target_link_libraries).
# -march=armv8-a[+crc]: zig's cross clang parses -march as a CPU name; its
#   baseline "generic" == ARMv8.0-A, so map to generic[+crc] (same ISA FEX's
#   CI targets). Note: in zig's clang a subsequent -mcpu=generic RESETS the
#   feature set (no crc), so drop -mcpu=generic when it accompanies -march.
# -lsynchronization: FEX links this (an llvm-mingw extra lib) on MINGW. zig has
#   no such bundled lib; FEX pulls no symbols from it, so map to an empty
#   archive. Undefined-symbol errors at link time would reveal otherwise.
# @rsp files: expand, apply the same rewrites, pass a temp rsp (zig expands
#   response files itself, after our arg loop).
# -static: zig cc turns -shared -static into an AR ARCHIVE (driver quirk), and
#   FEX's wow64 DLL is self-contained (bundles its own CRT/WinAPI layer, like
#   the depot build) so no mingw runtime is needed. Drop it at link time.
# -fno-sanitize=all: zig cc enables a full UBSan suite BY DEFAULT on
#   aarch64-windows C++, which FEX CI does not have and which requires a
#   ubsan runtime zig doesn't bundle for this target. Disable it.
map_case() { # $1 = token; sets REPLY_TOKEN, may set DROP_GENERIC_MCPU
  case "$1" in
    -static) REPLY_TOKEN="" ;;
    -march=armv8-a+crc)
      REPLY_TOKEN="-march=generic+crc"
      DROP_GENERIC_MCPU=1
      ;;
    -march=armv8-a) REPLY_TOKEN="-march=generic" ;;
    -lsynchronization) REPLY_TOKEN=/tmp/opencode/tools/lib/libsynchronization.a ;;
    # CMake adds --out-implib for Windows SHARED targets; zig rejects
    # -femit-implib on -static links. Nothing we build consumes the implib.
    -Wl,--out-implib*) REPLY_TOKEN="" ;;
    *) REPLY_TOKEN="$1" ;;
  esac
}

args=()
for a in "$@"; do
  case "$a" in
    -print-libgcc-file-name)
      echo "-lgcc"
      exit 0
      ;;
    @*)
      src="${a#@}"
      tmp="$(mktemp /tmp/opencode/rsp.XXXXXX)"
      read -r -a tokens < "$src"
      mapped=()
      for t in "${tokens[@]}"; do
        map_case "$t"
        [ -n "$REPLY_TOKEN" ] && mapped+=("$REPLY_TOKEN")
      done
      if [ -n "${DROP_GENERIC_MCPU:-}" ]; then
        kept=()
        for t in "${mapped[@]}"; do
          [ "$t" = "-mcpu=generic" ] && continue
          kept+=("$t")
        done
        mapped=("${kept[@]}")
      fi
      printf '%s ' "${mapped[@]}" > "$tmp"
      DROP_GENERIC_MCPU=""
      a="@$tmp"
      ;;
    *)
      map_case "$a"
      a="$REPLY_TOKEN"
      ;;
  esac
  [ -n "$a" ] && args+=("$a")
done
if [ -n "${DROP_GENERIC_MCPU:-}" ]; then
  out=()
  for a in "${args[@]}"; do
    [ "$a" = "-mcpu=generic" ] && continue
    out+=("$a")
  done
  args=("${out[@]}")
fi
exec /usr/bin/zig cc -target aarch64-windows-gnu -fno-sanitize=all "${args[@]}"
```

(for `aarch64-w64-mingw32-clang++` — identical, but `exec /usr/bin/zig c++ ...`)

#### CMake shim `/tmp/opencode/tools/toolchain_zig.cmake`

```cmake
# Local toolchain shim for the on-device FEX-2611.1 build (zig as aarch64-w64-mingw32).
#
# Includes FEX's own toolchain file unchanged, then overrides the linker flag
# initializers, because zig cc's -Wl, allow-list rejects:
#   --file-alignment=4096  (PE file alignment; debug-symbol convenience only —
#                           FEX JIT allocates its own memory at runtime, and the
#                           Proton patch step (dd at offset 32) is header-based)
#   /mllvm:-align-loops=1  (workaround for llvm/llvm-project#47432, fixed in
#                           modern LLVM; we compile with clang 21)
# Everything else (static linking, -lc++/-lc++abi/-lunwind + -lgcc via
# target_link_libraries, dlltool import libs) is FEX's own CMake.
include(/var/home/armada/opencode/fex-src/Data/CMake/toolchain_mingw.cmake)
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-static")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static")
```

#### Small third-party libraries

```sh
mkdir -p /tmp/opencode/tools/lib
# 1) empty libsynchronization.a (FEX links it on MINGW; takes no symbols from it)
/tmp/opencode/tools/bin/aarch64-w64-mingw32-ar rcs /tmp/opencode/tools/lib/libsynchronization.a

# 2) zig's C++ runtime archives under stable names
#    (materialized by zig in ~/.cache/zig/o/<hash>/*.lib on the first link)
cd /tmp/opencode/tools/lib
for pair in 'c++' 'c++abi' 'unwind' 'compiler_rt' 'zigc'; do
  cp "$(ls /var/home/armada/.cache/zig/o/*/${pair}.lib | head -1)" "./zig-${pair}.lib"
done
```

`compiler_rt.lib` provides the weak `__chkstk` that FEX objects reference.

#### `__clear_cache` stub

FEX (`Arm64.cpp`, `CodeCache.cpp`) calls `__builtin___clear_cache` to publish
JIT code. In FEX CI (llvm-mingw) the symbol comes from libmingw32; zig's copy of
mingw does not have it. AArch64: I/D caches are coherent for PE/VA, the minimum
is ISB; we do a conservative full flush (a superset, called rarely — at
finalization/patching of code pages):

`/tmp/opencode/tools/lib/clearcache_stub.c`:

```c
void __clear_cache(void* begin_code, void* end_code) {
  register unsigned char* b = (unsigned char*)begin_code;
  register unsigned char* e = (unsigned char*)end_code;
  __asm__ volatile(
      "1:\n"
      "  cmp %1, %0\n"
      "  b.ls 2f\n"
      "  dc cvau, %0\n"
      "  ic ivau, %0\n"
      "  add %0, %0, #64\n"
      "  b 1b\n"
      "2:\n"
      "  dsb ish\n"
      "  isb\n"
      : "+r"(b)
      : "r"(e)
      : "memory");
}
```

```sh
zig cc -target aarch64-windows-gnu -fno-sanitize=all -O2 -c \
  /tmp/opencode/tools/lib/clearcache_stub.c -o /tmp/opencode/tools/lib/clearcache_stub.obj
# check: nm ... | grep 'T __clear_cache'
```

### 4. Configure

**Unix Makefiles, NOT Ninja**: CMake 4.3 for Clang+Ninja hangs on a rule for
`clang-scan-deps`, which zig does not have (NOTFOUND → build failure).
The Makefiles generator does not use scan-deps.

```sh
export PATH=/tmp/opencode/tools/bin:$PATH
cmake -S /var/home/armada/opencode/fex-src -B /tmp/opencode/build-fex -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE=/tmp/opencode/tools/toolchain_zig.cmake \
  -DMINGW_TRIPLE=aarch64-w64-mingw32 \
  -DENABLE_LTO=False \
  -DENABLE_ASSERTIONS=True \
  -DBUILD_TESTING=False \
  -DENABLE_JEMALLOC_GLIBC_ALLOC=False \
  -DTUNE_CPU=generic \
  -DCMAKE_INSTALL_PREFIX=/tmp/opencode/build-fex/install
```

Flags = as in FEX's official mingw-CI (`.github/workflows/mingw_build.yml`:
`ENABLE_LTO=False ENABLE_ASSERTIONS=True BUILD_TESTING=False`, same triplet),
except `CMAKE_BUILD_TYPE=Release` (CI — Debug) — we take Release for the game.
`ASSERTIONS_ENABLED=1` is active in Release if `ENABLE_ASSERTIONS=True` —
useful: a failed build writes the exact assert into the FEX log.

Check: in the configure log — `FEX version: FEX-2611.1`, `Assertions enabled`,
`COMPILER_SUPPORTS_CPU_TYPE - Success`.

### 5. Build: only `wow64fex`

**NOT `make all`**: the `FEXCore_shared` (libFEXCore.dll) target fails on the
zig link (quirk, see the Pitfalls table) and is **not needed** for the Proton swap.

```sh
export PATH=/tmp/opencode/tools/bin:$PATH
make -C /tmp/opencode/build-fex wow64fex -j2   # ~25–35 min on RP6
```

Key artifacts:
- `/tmp/opencode/build-fex/Source/Windows/WOW64/CMakeFiles/wow64fex.dir/objects.a`
- static libs: `FEXCore/Source/libFEXCore_Base.a`, `Source/Common/libCommon.a`,
  `Source/Tools/CommonTools/libCommonTools.a`, `Source/Windows/Common/libCommonWindows{,Runtime}.a`,
  `Source/Windows/lib{ntdll,wow64}_ex.a`, `External/*`
- `Bin/libwow64fex.dll` — at this stage an **empty/archive stub** (zig with
  `-shared -static` would have emitted an AR archive; the wrapper drops `-static`,
  but CMake still invokes the link through zig — see the next step: the final
  link is done manually with lld-link, and that is the normal result)

### 6. `libwow64fex.so` (unixlib bridge)

One FEX file (`Source/Windows/UnixLib/FEXUnixLib.cpp`) + `-lrt`.
Important: **without** `-fvisibility=hidden` (it would hide the single export),
but with a version script, so that weak C++ runtime symbols do not stick out
into dynsym (as in the depot — a clean profile):

```sh
printf '{\n  global: __wine_unix_call_funcs;\n  local: *;\n};\n' > /tmp/opencode/unixlib.map
g++ -O2 -std=gnu++20 -fPIC -shared \
  /var/home/armada/opencode/fex-src/Source/Windows/UnixLib/FEXUnixLib.cpp \
  -lrt -o /tmp/opencode/libwow64fex.so \
  -Wl,--version-script=/tmp/opencode/unixlib.map
strip --strip-unneeded /tmp/opencode/libwow64fex.so
# check: nm -D | grep -c wine_unix_call  → 1
```

### 7. Final DLL link: lld-link `/lldmingw`

Why not zig cc: zig's windows-gnu driver **unconditionally** adds the mingw-CRT +
UCRT import libs (ignoring `-nostdlib/-nostartfiles/-nodefaultlibs`) →
duplicate symbols from FEX's embedded CRT (`atexit`, `DllMainCRTStartup`,
`_tls_index`, `_chsize`) and foreign UCRT imports. The FEX objects and static
libs are exactly what CMake built; only the link driver differs (in CI it is
lld through llvm-mingw).

The key flag is **`/lldmingw`** (see `lld/COFF/Driver.cpp`: `config->mingw =
args.hasArg(OPT_lldmingw)`; `lld/COFF/Writer.cpp`: `insertCtorDtorSymbols()`
is called only in mingw mode). It is precisely what defines
`__CTOR_LIST__`/`__DTOR_LIST__` with sentinels (`-1`, ctors, `0`) — the layout
that FEX's `Source/Windows/Common/CRT/CRT.cpp` is written against
(`extern void (*__CTOR_LIST__[])(); ... &__CTOR_LIST__[1]`, walk until NULL).
Without the flag the link fails: `undefined symbol: __CTOR_LIST__`.

`/tmp/opencode/link-wow64fex.sh`:

```bash
#!/bin/bash
# Manual final link of libwow64fex.dll with lld-link (ld.lld -flavor link).
set -e
B=/tmp/opencode/build-fex
LIB=/tmp/opencode/tools/lib
SRC=/var/home/armada/opencode/fex-src
WOW=$B/Source/Windows/WOW64
OUT=$B/Bin/libwow64fex.dll

rm -rf /tmp/opencode/wow64-objs && mkdir -p /tmp/opencode/wow64-objs
( cd /tmp/opencode/wow64-objs && /tmp/opencode/xtools/bin/aarch64-w64-mingw32-ar x "$WOW/CMakeFiles/wow64fex.dir/objects.a" )

ld.lld -flavor link \
  -out:"$OUT" \
  -def:"$SRC/Source/Windows/WOW64/libwow64fex.def" \
  -entry:DllMainCRTStartup \
  -subsystem:windows \
  /lldmingw \
  /tmp/opencode/wow64-objs/*.obj \
  "$LIB/clearcache_stub.obj" \
  "$B/FEXCore/Source/libFEXCore_Base.a" \
  "$B/Source/Common/libCommon.a" \
  "$B/Source/Tools/CommonTools/libCommonTools.a" \
  "$B/Source/Windows/Common/libCommonWindows.a" \
  "$B/Source/Windows/Common/libCommonWindowsRuntime.a" \
  "$B/Source/Windows/libwow64_ex.a" \
  "$B/Source/Windows/libntdll_ex.a" \
  "$LIB/zig-compiler_rt.lib" \
  "$LIB/zig-zigc.lib" \
  "$B/Source/Common/cpp-optparse/libcpp-optparse.a" \
  "$B/External/tiny-json/libtiny-json.a" \
  "$B/External/fmt/libfmt.a" \
  "$B/External/xxhash/cmake_unofficial/libxxhash.a" \
  "$B/External/cephes/libcephes_128bit.a" \
  "$B/External/SoftFloat-3e/libsoftfloat_3e.a" \
  "$LIB/zig-c++.lib" \
  "$LIB/zig-c++abi.lib" \
  "$LIB/zig-unwind.lib" \
  "$B/FEXCore/Source/libJemallocLibs.a" \
  "$B/External/rpmalloc/librpmalloc.a"

# CMake POST_BUILD (patch_library_wine): wine_builtin.bin at offset 32
dd bs=32 count=1 seek=2 conv=notrunc if="$SRC/Source/Windows/wine_builtin.bin" of="$OUT"

file "$OUT"
ls -la "$OUT"
echo "=== imports ==="
/tmp/opencode/xtools/bin/aarch64-w64-mingw32-objdump -p "$OUT" | grep 'DLL Name'
```

Library order = `linkLibs.rsp` from CMake (wow64fex). `--gc-sections`/`--strip`
are not needed for lld-link (section GC is on by default, no symtab in COFF).
The `LNK4217 _chsize` warning (defined locally + imported) is harmless:
the local definition wins and does not end up in the import table (verify!).

## Verification

### 8. DLL checks

```sh
O=/tmp/opencode/xtools/bin/aarch64-w64-mingw32-objdump
D=/tmp/opencode/build-fex/Bin/libwow64fex.dll
file "$D"                                  # PE32+ executable for WINE (GUI), ARM64
$O -p "$D" | grep -E 'AddressOfEntryPoint|Subsystem'   # entry != 0; 00000002 (GUI)
$O -p "$D" | grep 'DLL Name'               # exactly: ntdll.dll, wow64.dll
$O -p "$D" | awk '/Export Address Table/,0' | head -3  # Number in EAT = 00000017 (23)
dd if="$D" bs=32 count=1 skip=2 2>/dev/null | cmp - \
  /var/home/armada/opencode/fex-src/Source/Windows/wine_builtin.bin && echo WINE-PATCH-OK
```

Expected results:

| Check | Expected |
|---|---|
| `file` | `PE32+ ... for WINE (GUI)`, ARM64 (WINE = the wine_builtin marker) |
| entry point / subsystem | entry != 0; Subsystem `00000002` (GUI) |
| imports (`DLL Name`) | exactly `ntdll.dll`, `wow64.dll` (depot: the same) |
| exports | Number in EAT = `00000017` (23) (depot: the same — one `libwow64fex.def`) |
| WINE marker | `cmp` succeeds → `WINE-PATCH-OK` |
| size | ~3.7 MB (depot 4.7 MB — different build stack; same order) |

### 9. Swap into the Proton tool and the swap test

```sh
# the tool (depot copy) is already in home — survives reboot
TOOL=/var/home/armada/opencode/proton-patched
rm -f $TOOL/files/lib/wine/aarch64-windows/libwow64fex.dll \
      $TOOL/files/lib/wine/aarch64-unix/libwow64fex.so   # depot files are r-xr-xr-x!
cp /tmp/opencode/build-fex/Bin/libwow64fex.dll $TOOL/files/lib/wine/aarch64-windows/
cp /tmp/opencode/libwow64fex.so                 $TOOL/files/lib/wine/aarch64-unix/
chmod 644 $TOOL/files/lib/wine/aarch64-windows/libwow64fex.dll \
          $TOOL/files/lib/wine/aarch64-unix/libwow64fex.so
```

Launch — `scripts/launch-swap-test.sh 1` (fresh prefix
`~/opencode/compatdata-swap/1`, `FEX_APP_CONFIG=/tmp/opencode/fex-cfg/fex-log.json`
with `SilentLog=0` — FEX writes logs; environment: `SteamAppId=55150`,
`STEAM_COMPAT_TOOL_PATHS=$TOOL`). Log: `/tmp/opencode/game-swap1.log`.

**Success criterion**: get past the RLink point (in the depot build the crash
comes ~3–4 s after the RLink net thread starts) — 5–10 min without a minidump,
`gamePC.cfg` written, no `.dmp` in `drive_c/users/steamuser/AppData/Local/Temp/`.

FEX lines in the log: `^[A-Z] [0-9A-F]{2,4} ` without a WINE prefix
(A/E = assert/error, D = debug, I = info; the game's tid was `E0`).

## Pitfalls: why so many errors (zig gotchas)

| # | Symptom | Cause | Workaround |
|---|---|---|---|
| 1 | `CMAKE_CXX_COMPILER_CLANG_SCAN_DEPS-NOTFOUND` (Ninja) | CMake 4.3 for Clang+Ninja requires clang-scan-deps | Unix Makefiles generator |
| 2 | `unknown CPU: 'armv8'` | zig-clang parses `-march` as a CPU name | `-march=armv8-a+crc` → `generic+crc` |
| 3 | `__crc32d requires target feature 'crc'` | in zig, `-mcpu=generic` **resets** the feature set, killing `+crc` | drop `-mcpu=generic` when it accompanies `-march=...+crc` |
| 4 | `unable to find static system library 'synchronization'` | an llvm-mingw lib; zig does not have it; FEX pulls no symbols from it | empty `libsynchronization.a` |
| 5 | `the argument -femit-implib is allowed only when building a Windows DLL` | CMake adds `--out-implib`; zig does not emit an implib for a static link | drop `-Wl,--out-implib*` |
| 6 | link `-shared -static` → **AR archive** instead of PE | zig cc driver quirk | drop `-static` (the DLL is self-contained, with its own CRT) |
| 7 | `undefined symbol: __ubsan_handle_*` | zig enables a **full UBSan suite by default** for aarch64-windows C++; the runtime is not bundled | `-fno-sanitize=all` in the wrapper |
| 8 | `duplicate symbol: atexit/DllMainCRTStartup/_tls_index/_chsize` | the zig driver **unconditionally** drags in mingw-CRT+UCRT, ignoring `-nostdlib*` | manual final link with lld-link |
| 9 | `undefined symbol: __clear_cache` | missing in zig's copy of mingw (in llvm-mingw — from libmingw32) | stub object (full I-cache flush) |
| 10 | `undefined symbol: __CTOR_LIST__` | lld-link defines it **only in `/lldmingw` mode** (insertCtorDtorSymbols, sentinels -1/0) | the `/lldmingw` flag (the clang mingw-driver in FEX CI does the same) |

Sources: `lld/COFF/{Driver,Writer}.cpp`, `binutils ld/scripttempl/pe.sc`,
`FEX .github/workflows/mingw_build.yml`, `FEX Source/Windows/Common/CRT/CRT.cpp`.

## Reboot: what burns and how to rebuild

Burns: the transient dnf packages (zig, lld, cmake, ninja, gcc), **all of**
`/tmp/opencode` (build-fex, tools, xtools, artifacts). Survives:
`~/opencode/fex-src`, `~/opencode/proton-patched`, `~/opencode/compatdata-swap`,
this repo.

Repeat: steps 1 → 2 → 3 → 4 → 5 → 6 → 7, then Verification (DLL checks → swap
test) — everything above is self-contained.
Before a relaunch: check for stale processes
(`for pid in $(pgrep -f SpaceMarine); do cat /proc/$pid/comm; done` —
`pgrep -f` false-matches on the bash wrapper itself).
