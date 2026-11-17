# Per-game FEX config: profiles and "who fixes what"

Short answer: **`fast` / `default` / `compatible` are an Armada OS convention,
not upstream FEX.** FEX has no automatic "game → profile" database; configuration
stays per-game and manual. FEX developers fix concrete bugs (JIT/TSO/multiblock),
after which a toggle may stop being needed, but that happens per bug report, not
by itself.

## Table of contents

- [1. What `fast` / `default` / `compatible` are](#1-what-fast--default--compatible-are)
- [2. The per-game config mechanism in FEX](#2-the-per-game-config-mechanism-in-fex)
- [3. What Proton has](#3-what-proton-has)
- [4. Keeping configs in this repo](#4-keeping-configs-in-this-repo)
- [5. Warhammer 40,000: Space Marine (55150)](#5-warhammer-40000-space-marine-55150)
- [6. Summary](#6-summary)

## 1. What `fast` / `default` / `compatible` are

The file `/usr/share/armada/fex-profiles.json` (Armada OS) — three sets of toggles:

| profile | TSOEnabled | Multiblock | X87ReducedPrecision | VectorTSO | MemcpySetTSO | HalfBarrierTSO |
|---|---|---|---|---|---|---|
| `default` | 1 | 1 | 1 | 0 | 0 | 1 |
| `fast` | 0 | 1 | 1 | 0 | 0 | 0 |
| `compatible` | 1 | 0 | 0 | 1 | 1 | 1 |

These are speed/correctness trade-offs, not "official FEX profiles".
Our measurements (RE4) showed: the difference between profiles is within noise —
the limiter was the GPU, not FEX (`results/re4/fps-fex-*.csv`).

## 2. The per-game config mechanism in FEX

Config layers, in ascending priority:

```
5  FEX_* env vars
4  FEX_APP_CONFIG=<file>   (Proton's proton-fex-config.json is generated
                            only if this variable is NOT set)
3  ~/.config/fex-emu/AppConfig/Steam_<SteamAppId>_<exe>.json
2  ~/.config/fex-emu/AppConfig/<exe>.json
1  global: /usr/share/fex-emu/Config.json (ro) / ~/.config/fex-emu/Config.json
```

1. global: `/usr/share/fex-emu/Config.json` (ro) / `~/.config/fex-emu/Config.json`;
2. by exe name: `~/.config/fex-emu/AppConfig/<exe>.json`
   (e.g. `SpaceMarine.exe.json`);
3. by Steam game: `~/.config/fex-emu/AppConfig/Steam_<SteamAppId>_<exe>.json`
   (e.g. `Steam_55150_SpaceMarine.exe.json`) — the name is built from the env
   `SteamAppId` + the exe basename (`Source/Common/Config.cpp`, `LoadConfig`);
4. `FEX_APP_CONFIG=<file>` — a user override; Proton generates its own
   `compatdata/<appid>/proton-fex-config.json` **only if the variable is not set**;
5. env variables `FEX_*`.

JSON format:

```json
{
  "Config": { "Multiblock": "0" },
  "AppOverrides": {
    "SpaceMarine.exe": { "TSOEnabled": "0" }
  },
  "ThunksDB": {}
}
```

`AppOverrides` matches the exe name by wildcard (first match).
Global examples live in `/usr/share/fex-emu/AppConfig/`
(`PluginLoader.json`, `client.json`, `steamwebhelper.json`).

## 3. What Proton has

- the built-in table `fex_application_profiles` in the `proton` script — currently
  **only The Witcher 3** (`X87ReducedPrecision=0`);
- `proton-fex-config.json` in `compatdata/<appid>/` — generated per session,
  covers only `TSOEnabled`, `Multiblock`, `SilentLog` + the built-in profiles;
- env: `STEAM_COMPAT_FEX_CONFIG` (`TSOEnabled:0,Multiblock:0`),
  `STEAM_FEX_TSOENABLED`, `STEAM_FEX_MULTIBLOCK`;
- `FEX_APP_CONFIG_LOCATION` points to the chosen Proton's `share/fex-emu/`.

## 4. Keeping configs in this repo

File: `configs/Steam_55150_SpaceMarine.exe.json` (example for Space Marine).

Activation without modifying Proton — a symlink:

```bash
mkdir -p ~/.config/fex-emu/AppConfig
ln -sf /var/home/armada/opencode/fex/configs/Steam_55150_SpaceMarine.exe.json \
       ~/.config/fex-emu/AppConfig/Steam_55150_SpaceMarine.exe.json
```

Or via Steam launch options:

```
FEX_APP_CONFIG=/var/home/armada/opencode/fex/configs/Steam_55150_SpaceMarine.exe.json %command%
```

Verifying that the config was picked up: with `PROTON_LOG=1`, typos show up in
the FEX log as `Unknown configuration option`; the file itself is read from the
`AppConfig` layer path.

## 5. Warhammer 40,000: Space Marine (55150)

The game's crash is **not about performance/profile**: at `SpaceMarine.exe+0x699EE7`
there is a `mov %ecx,(%eax,%edi,4)` with `edi=0x31C33396` (the index came from
`0xA99BB0`), and the write lands at `0xD77000F8`. This is an OOB write from a
garbage index, not a TSO/multiblock effect.

The whole TSO × Multiblock matrix (`1/1`, `1/0`, `0/0`, `0/1`) crashes
identically, so a profile is not a fix here — the "JIT bug" hypothesis was
tested and refuted (details: `../spacemarine-proton-fix/`).

## 6. Summary

- "One game needs fast, another compatible" — a normal state; it is not a bug
  and not an "unfinished" part of FEX.
- Upstream does not plan to support a per-game profile database; per-app config
  is the only first-class mechanism.
- A distro/user can keep its own profiles (like Armada) and lay them out
  per-game via `AppConfig`/`FEX_APP_CONFIG`.
