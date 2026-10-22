#!/usr/bin/env python3
# +------------------------------------------------------------------+
# |  fetch_investing.py  —  EventMap feed, investing.com (browser)   |
# |                                                                  |
# |  investing.com sits behind Cloudflare bot management that mass-  |
# |  403s every plain-HTTP client (urllib, curl, .NET) regardless    |
# |  of headers, cookies or even a residential IP, and headless      |
# |  Chromium does not pass either - only a HEADED browser does.     |
# |  This script drives Chromium via Playwright, opens the economic- |
# |  calendar page (the challenge runs for real), and performs the   |
# |  JSON API request from inside the page. The window is positioned |
# |  far off-screen so the task keeps running without flashing a     |
# |  window on your desktop.                                         |
# |                                                                  |
# |  Data source (the page's own JSON endpoint):                     |
# |    https://endpoints.investing.com/pd-instruments/v1/            |
# |        calendars/economic/events/occurrences                     |
# |    returns events[] (meta) + occurrences[] (dated rows).         |
# |                                                                  |
# |  Output: the standard EventMap pipe format:                      |
# |    # eventmap 1                                                  |
# |    # generated=... provider=investing rows=N                     |
# |    1792590600|USD|high|Core CPI m/m|||0.1%|investing             |
# |                                                                  |
# |  USAGE                                                           |
# |    python fetch_investing.py                  fetch (off-screen)  |
# |    python fetch_investing.py --visible        watch the browser   |
# |    python fetch_investing.py --headless       try headless (403)  |
# |    python fetch_investing.py --days-forward 8 --back 2            |
# |                                                                  |
# |  SETUP (once)                                                    |
# |    pip install playwright                                        |
# |    python -m playwright install chromium                         |
# +------------------------------------------------------------------+
import argparse
import json
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

CALENDAR_URL = "https://www.investing.com/economic-calendar/"
API_URL = ("https://endpoints.investing.com/pd-instruments/v1/"
           "calendars/economic/events/occurrences")

# investing.com's own default country filter (the ~20 major-economy IDs the
# site requests). The indicator filters by pair currencies anyway.
COUNTRY_IDS = "25,32,6,37,72,22,17,39,14,10,35,43,36,110,11,26,12,4,5,56"

def clean(s):
    if s is None:
        return ""
    return str(s).replace("|", "/").strip()


def fmt_val(sig, precision, unit):
    """105.3 + precision 1 + unit '' -> '105.3'; -161.6, 1, 'B' -> '-161.6B'"""
    if sig is None or sig == "":
        return ""
    try:
        value = float(sig)
    except (TypeError, ValueError):
        return clean(sig)
    out = f"{value:.{int(precision)}f}" if precision is not None else str(value)
    if "%B" in str(unit):
        out += "%B"
    elif unit:
        out += str(unit)
    return out


def occurrence_rows(payload):
    """JSON payload -> list of (epoch, cur, impact, title, actual, fcst, prev)."""
    ev_index = {}
    for ev in payload.get("events") or []:
        ev_index[ev.get("event_id")] = ev
    out = []
    for occ in payload.get("occurrences") or []:
        ev = ev_index.get(occ.get("event_id"))
        if not ev:
            continue
        stamp = clean(occ.get("occurrence_time"))
        try:
            dt = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        except ValueError:
            continue
        title = (ev.get("short_name") or ev.get("event_translated")
                 or ev.get("event_meta_title") or "Investing.com event")
        precision = occ.get("precision")
        row = (
            int(dt.timestamp()),
            clean(ev.get("currency")),
            clean(ev.get("importance")) or "low",
            title,
            fmt_val(occ.get("actual"), precision, occ.get("unit")),
            fmt_val(occ.get("forecast"), precision, occ.get("unit")),
            fmt_val(occ.get("previous"), precision, occ.get("unit")),
        )
        out.append(row)
    return out


def fetch_payloads(page, frm, to):
    """Navigate the tab itself to the API URL and read the JSON body.

    (An in-page fetch() breaks: the site's own JS wraps window.fetch and
    our call fails with 'TypeError: Failed to fetch'. A top-level
    navigation uses the browser's authentic TLS + cookies directly and
    is exactly what a human pasting the URL into the address bar does.)
    """
    windows = [(frm, to)]
    # the API caps each response; split long ranges into 10-day slices
    if (to - frm).days > 10:
        windows = []
        a = frm
        while a < to:
            b = min(a + timedelta(days=9, hours=23, minutes=59, seconds=59), to)
            windows.append((a, b))
            a = b + timedelta(seconds=1)

    payloads = []
    for a, b in windows:
        url = (f"{API_URL}?domain_id=1&limit=1000"
               f"&start_date={a:%Y-%m-%dT00:00:00.000Z}"
               f"&end_date={b:%Y-%m-%dT23:59:59.999Z}"
               f"&country_ids={COUNTRY_IDS}")
        payload = None
        # up to 3 tries: the first navigation to endpoints.* can hit its
        # own Cloudflare challenge; headed Chromium solves it in a few s
        for attempt in range(3):
            resp = page.goto(url, wait_until="domcontentloaded",
                             timeout=45000)
            status = resp.status if resp else 0
            try:
                text = resp.text() if resp else ""
            except Exception:
                text = ""
            if status == 200 and text.lstrip().startswith("{"):
                payload = json.loads(text)
                break
            print(f"investing: API nav attempt {attempt + 1}: "
                  f"{status} ({len(text)} bytes)", file=sys.stderr)
            page.wait_for_timeout(6000)
        if payload is None:
            raise RuntimeError("API unreachable after challenge retries")
        payloads.append(payload)
    return payloads


def main(argv):
    ap = argparse.ArgumentParser(
        description="Fetch investing.com economic calendar through a real browser.")
    ap.add_argument("--days-back", type=int, default=2)
    ap.add_argument("--days-forward", type=int, default=8)
    ap.add_argument("--out", default="EventMap/feed_investing.csv")
    ap.add_argument("--visible", action="store_true",
                    help="show the browser window (debugging)")
    ap.add_argument("--headless", action="store_true",
                    help="no window (Cloudflare usually blocks this)")
    ap.add_argument("--minutes", type=int, default=120,
                    help="timeout in seconds")
    args = ap.parse_args(argv)

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("playwright missing:  pip install playwright  &&  "
              "python -m playwright install chromium", file=sys.stderr)
        return 1

    now = datetime.now(timezone.utc).replace(microsecond=0)
    frm = (now - timedelta(days=args.days_back))
    to = (now + timedelta(days=args.days_forward))

    rows, failed = [], False
    with sync_playwright() as pw:
        launch = {}
        # headed off-screen passes Cloudflare; plain headless does not
        if args.visible:
            launch["headless"] = False
        elif args.headless:
            launch["headless"] = True
        else:
            launch["headless"] = False
            launch["args"] = ["--window-position=-32000,-32000"]
        browser = pw.chromium.launch(**launch)
        try:
            page = browser.new_page()
            page.goto(CALENDAR_URL, wait_until="domcontentloaded",
                      timeout=args.minutes * 1000)
            # let the challenge / page scripts settle
            try:
                page.wait_for_selector("tr[data-event-datetime]",
                                       timeout=25000)
            except Exception:
                pass
            page.wait_for_timeout(1500)

            try:
                payloads = fetch_payloads(page, frm, to)
            except Exception as e:
                print(f"investing: {e}", file=sys.stderr)
                failed = True
            else:
                seen = set()
                for p in payloads:
                    for row in occurrence_rows(p):
                        key = (row[0], row[1], row[3].lower())
                        if key in seen:
                            continue
                        seen.add(key)
                        rows.append(row)
                failed = not rows
                if failed:
                    print("investing: endpoint OK but no rows", file=sys.stderr)
        finally:
            browser.close()

    if failed:
        print("investing: keeping previous file", file=sys.stderr)
        return 1

    rows.sort(key=lambda r: r[0])
    out_rows = [("|".join([str(r[0]), r[1], r[2], r[3], r[4], r[5], r[6],
                           "investing"])) for r in rows]
    text = "\n".join(
        ["# eventmap 1",
         f"# generated={now:%Y-%m-%dT%H:%M:%SZ} provider=investing "
         f"rows={len(rows)}",
         "epoch|cur|impact|title|actual|forecast|previous|source"]
        + out_rows) + "\n"

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", delete=False, dir=out.parent,
                                     encoding="utf-8") as f:
        f.write(text)
        tmp = Path(f.name)
    tmp.replace(out)
    print(f"investing: {len(rows)} rows -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
