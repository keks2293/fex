#!/usr/bin/env python3
"""Generate FEX_APP_CONFIG for an A/B run.

Replicates the logic of /usr/libexec/armada/armada-game-launch (apply_fex):
takes /usr/share/fex-emu/Config.json, drops RootFS/ThunkHostLibs/ThunkGuestLibs
(so the Steam-FEX rootfs is not clobbered), overlays the profile from
/usr/share/armada/fex-profiles.json and writes the result to a file.

The file path is printed to stdout — it is exported as FEX_APP_CONFIG.
arm64ec/wow64 FEX (proton-cachyos) reads exactly this variable; on-disk
configs are seen only by the system FEX.
"""
import json
import sys
from pathlib import Path

BASE = Path("/usr/share/fex-emu/Config.json")
PROFILES = Path("/usr/share/armada/fex-profiles.json")
OUTDIR = Path("/tmp/opencode/fex-cfg")


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <profile>", file=sys.stderr)
        print(f"available: {list(json.load(open(PROFILES))['profiles'].keys())}", file=sys.stderr)
        sys.exit(1)
    profile = sys.argv[1]

    contract = json.load(open(PROFILES, encoding="utf-8"))
    profiles = contract["profiles"]
    if profile not in profiles:
        print(f"no profile {profile!r}; available: {list(profiles)}", file=sys.stderr)
        sys.exit(1)

    config = json.load(open(BASE, encoding="utf-8"))
    for key in ("RootFS", "ThunkGuestLibs", "ThunkHostLibs"):
        config.get("Config", {}).pop(key, None)
    allowed = set().union(*(p["config"].keys() for p in profiles.values()))
    fex = profiles[profile]["config"]
    config.setdefault("Config", {}).update({k: v for k, v in fex.items() if k in allowed})

    OUTDIR.mkdir(parents=True, exist_ok=True)
    out = OUTDIR / f"fex-{profile}.json"
    out.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    # profile keys only, for the log
    active = {k: v for k, v in config["Config"].items() if k in allowed}
    print(f"FEX_PROFILE={profile}", file=sys.stderr)
    print(f"FEX_CONFIG_KEYS={json.dumps(active, sort_keys=True)}", file=sys.stderr)
    print(out)


if __name__ == "__main__":
    main()
