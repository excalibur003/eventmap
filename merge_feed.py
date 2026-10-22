#!/usr/bin/env python3
# +------------------------------------------------------------------+
# |  merge_feed.py  —  combine the cloud feed + local sources        |
# |                                                                  |
# |  The GitHub Action publishes feed/events.csv (Forex Factory).    |
# |  Investing.com rows come from a local browser fetch because      |
# |  Cloudflare hard-blocks plain-HTTP clients. This script merges   |
# |  the parts into the single pipe-format file the indicator reads. |
# |                                                                  |
# |  Behavior:                                                       |
# |   - every input file must be EventMap pipe format (header '#')   |
# |   - rows outside the window are dropped (days back / forward)    |
# |   - duplicate rows (same epoch+src+title) are deduped            |
# |   - output is written atomically; missing local parts are OK      |
# |                                                                  |
# |  USAGE                                                           |
# |    python merge_feed.py --out EventMap\events.csv ^                |
# |        --in EventMap\cloud_events.csv ^                           |
# |        --in EventMap\feed_investing.csv                           |
# +------------------------------------------------------------------+
import argparse
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

HEADER = "epoch|cur|impact|title|actual|forecast|previous|source"


def read_rows(path: Path):
    """Parse an EventMap pipe file -> (provider_label, [rows])."""
    provider = None
    rows = []
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as e:
        print(f"merge: cannot read {path} ({e}) - skipped", file=sys.stderr)
        return None, []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("#"):
            if "provider=" in line:
                provider = line.split("provider=", 1)[1].split()[0]
            continue
        if line.startswith(HEADER) or line.startswith("epoch|"):
            continue
        f = line.split("|")
        if len(f) != 8:
            continue
        try:
            epoch = int(f[0])
        except ValueError:
            continue
        if epoch < 1_000_000_000:
            continue
        rows.append({
            "epoch": epoch, "cur": f[1].strip(), "impact": f[2].strip(),
            "title": f[3].strip(), "actual": f[4].strip(),
            "forecast": f[5].strip(), "previous": f[6].strip(),
            "source": f[7].strip() or "merged",
        })
    return provider, rows


def main(argv):
    ap = argparse.ArgumentParser(
        description="Merge EventMap pipe-format feeds into one events.csv.")
    ap.add_argument("--out", required=True, help="final events.csv path")
    ap.add_argument("--in", dest="inputs", action="append", default=[],
                    help="input pipe file (repeatable, in priority order)")
    ap.add_argument("--days-back", type=int, default=2)
    ap.add_argument("--days-forward", type=int, default=8)
    args = ap.parse_args(argv)

    now = datetime.now(timezone.utc).replace(microsecond=0)
    lo = int((now - timedelta(days=args.days_back)).timestamp())
    hi = int((now + timedelta(days=args.days_forward)).timestamp())

    rows, seen, sources = [], set(), []
    for name in args.inputs:
        p = Path(name)
        if not p.exists():
            print(f"merge: {p} missing - skipped", file=sys.stderr)
            continue
        provider, rws = read_rows(p)
        n = 0
        for r in rws:
            if not (lo <= r["epoch"] <= hi):
                continue
            key = (r["epoch"], r["source"], r["title"].lower())
            if key in seen:
                continue
            seen.add(key)
            rows.append(r)
            n += 1
        if provider:
            for lab in provider.split(","):
                if lab and lab not in sources:
                    sources.append(lab)
            print(f"merge: {p.name}: {n}/{len(rws)} rows in window "
                  f"({provider})")
        else:
            if p.stem not in sources:
                sources.append(p.stem)
            print(f"merge: {p.name}: {n}/{len(rws)} rows in window")

    if not rows:
        print("merge: no rows at all - NOT overwriting the output",
              file=sys.stderr)
        return 1

    rows.sort(key=lambda r: (r["epoch"], r["source"]))
    text = "\n".join(
        ["# eventmap 1",
         f"# generated={now:%Y-%m-%dT%H:%M:%SZ} "
         f"provider={','.join(dict.fromkeys(sources))} rows={len(rows)}",
         HEADER]
        + ["|".join([str(r["epoch"]), r["cur"], r["impact"], r["title"],
                     r["actual"], r["forecast"], r["previous"], r["source"]])
           for r in rows]) + "\n"

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", delete=False, dir=out.parent,
                                     encoding="utf-8") as f:
        f.write(text)
        tmp = Path(f.name)
    tmp.replace(out)
    print(f"merge: wrote {len(rows)} rows -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
