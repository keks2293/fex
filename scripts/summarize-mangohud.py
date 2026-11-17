#!/usr/bin/env python3
"""MangoHud CSV summary: fps and frametime.

Uses the frame_rate and frame_time columns (MangoHud names; falls back to a
substring match on the header). Prints mean/median/min/max fps and
median/p5/p95/max frametime. Several CSVs -> one table.
"""
import csv
import sys


def cols(header):
    low = {h.strip().lower(): i for i, h in enumerate(header)}
    def find(*names):
        for n in names:
            for k, i in low.items():
                if n in k:
                    return i
        return None
    return find("frame_rate", "framerate", "fps"), find("frame_time", "frametime", "ft")


def fnum(s):
    try:
        return float(str(s).replace(",", "."))
    except (ValueError, AttributeError):
        return None


def summarize(path):
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        rows = list(csv.reader(f))
    # MangoHud CSV: 1-2 metadata rows (os,cpu,gpu,ram,...), then the header row
    # with fps,frametime,..., then the data. Look for the row with fps+frametime.
    hdr_i = None
    for i, r in enumerate(rows):
        low = [h.strip().lower() for h in r]
        if "fps" in low and "frametime" in low:
            hdr_i = i
            break
    if hdr_i is None or hdr_i + 1 >= len(rows):
        return None
    low = [h.strip().lower() for h in rows[hdr_i]]
    fi = low.index("fps")
    ti = low.index("frametime")
    data = rows[hdr_i + 1:]
    fps = [v for v in (fnum(r[fi]) for r in data if fi is not None and fi < len(r)) if v and v > 0]
    ft = [v for v in (fnum(r[ti]) for r in data if ti is not None and ti < len(r)) if v and v > 0]
    if not fps:
        return None
    fps_s = sorted(fps)
    ft_s = sorted(ft)
    n = len(fps_s)
    def pct(a, p):
        if not a:
            return float("nan")
        k = max(0, min(len(a) - 1, int(round((p / 100.0) * (len(a) - 1)))))
        return a[k]
    return {
        "n": n,
        "fps_mean": sum(fps_s) / n,
        "fps_med": fps_s[n // 2],
        "fps_min": fps_s[0],
        "fps_p5": pct(fps_s, 5),
        "fps_max": fps_s[-1],
        "ft_med": ft_s[len(ft_s) // 2] if ft_s else float("nan"),
        "ft_p95": pct(ft_s, 95),
        "ft_max": ft_s[-1] if ft_s else float("nan"),
    }


def main():
    for path in sys.argv[1:]:
        s = summarize(path)
        label = path.split("/")[-1]
        if not s:
            print(f"{label}: no data")
            continue
        print(
            f"{label}: n={s['n']} "
            f"fps mean={s['fps_mean']:.1f} med={s['fps_med']:.1f} "
            f"p5={s['fps_p5']:.1f} min={s['fps_min']:.1f} max={s['fps_max']:.1f} | "
            f"ft med={s['ft_med']:.1f} p95={s['ft_p95']:.1f} max={s['ft_max']:.1f} ms"
        )


if __name__ == "__main__":
    main()
