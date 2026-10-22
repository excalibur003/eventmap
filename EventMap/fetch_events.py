#!/usr/bin/env python3
# +------------------------------------------------------------------+
# |  fetch_events.py  -  EventMap external feed (Python, stdlib only) |
# |                                                                  |
# |  Pulls the economic calendar from outside providers and writes a  |
# |  normalized feed the EventMap indicator can read:                 |
# |                                                                  |
# |      <terminal>/MQL5/Files/EventMap/events.csv                    |
# |                                                                  |
# |  Same feed contract as fetch_events.ps1, so the indicator does    |
# |  not care which one produced the file.                            |
# |                                                                  |
# |  No third-party packages: runs on a bare python3, which is what   |
# |  GitHub Actions gives you.                                        |
# |                                                                  |
# |  OUTPUT  (pipe separated, epoch is UTC seconds, ASCII only)       |
# |    # eventmap 1                                                   |
# |    # generated=2026-10-21T13:20:00Z provider=ff,tv rows=380       |
# |    epoch|cur|impact|title|actual|forecast|previous|source         |
# |    1792590600|USD|high|Core CPI m/m|0.3%|0.2%|0.1%|ff             |
# |                                                                  |
# |  USAGE                                                            |
# |    python fetch_events.py                          # auto-detect   |
# |    python fetch_events.py --out feed/events.csv    # any path      |
# |    python fetch_events.py --provider ff,tv,investing              |
# |    python fetch_events.py --proxy http://host:8080 --proxy-test   |
# +------------------------------------------------------------------+

from __future__ import annotations

import argparse
import base64
import gzip
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")

FF_WEEKS = ("lastweek", "thisweek", "nextweek")

INVESTING_URL = "https://www.investing.com/economic-calendar/Service/getCalendarFilteredData"

CURL = shutil.which("curl") or shutil.which("curl.exe")


# ------------------------------------------------------------------
#  HTTP
# ------------------------------------------------------------------
@dataclass
class Http:
    proxy: str = ""
    proxy_user: str = ""
    timeout: int = 30

    def get(self, url: str, headers: dict | None = None,
            timeout: int | None = None) -> tuple[int, str, str]:
        return self._request("GET", url, headers, None, timeout=timeout)

    def post(self, url: str, headers: dict | None = None, body: str | None = None,
             timeout: int | None = None) -> tuple[int, str, str]:
        return self._request("POST", url, headers, body, timeout=timeout)

    # -- retry policy: 429 = rate limited, 5xx = provider hiccup, 0 = network
    def _request(self, method, url, headers, body, retry=True, timeout=None):
        t = timeout or self.timeout
        status, text, err = self._once(method, url, headers, body, t)
        if retry and (status == 0 or status == 429 or status >= 500):
            time.sleep(10 if status == 429 else 3)
            status, text, err = self._once(method, url, headers, body, t)
        return status, text, err

    def _once(self, method, url, headers, body, timeout):
        # SOCKS is not supported by urllib; curl handles it (and is always
        # present on Windows 10+ and on the GitHub runners).
        if self.proxy and self.proxy.lower().startswith(("socks4", "socks5")):
            return self._curl(method, url, headers, body, timeout)
        return self._urllib(method, url, headers, body, timeout)

    def _urllib(self, method, url, headers, body, timeout):
        req = urllib.request.Request(
            url,
            data=body.encode("utf-8") if body is not None else None,
            method=method,
        )
        for k, v in (headers or {}).items():
            req.add_header(k, v)
        req.add_header("Accept-Encoding", "gzip")

        handlers: list = []
        if self.proxy:
            # Force the proxy explicitly; do not silently fall back to a
            # direct connection or to an unrelated HTTP_PROXY env var.
            handlers.append(urllib.request.ProxyHandler(
                {"http": self.proxy, "https": self.proxy}))
        else:
            handlers.append(urllib.request.ProxyHandler({}))

        if self.proxy and self.proxy_user:
            if ":" in self.proxy_user:
                token = base64.b64encode(self.proxy_user.encode()).decode()
                req.add_header("Proxy-Authorization", "Basic " + token)

        try:
            with urllib.request.build_opener(*handlers).open(req, timeout=timeout) as r:
                raw = r.read()
                if (r.headers.get("Content-Encoding") or "").lower() == "gzip":
                    raw = gzip.decompress(raw)
                return r.status, raw.decode("utf-8", "replace"), ""
        except urllib.error.HTTPError as e:
            raw = e.read() or b""
            if (e.headers.get("Content-Encoding") or "").lower() == "gzip":
                try:
                    raw = gzip.decompress(raw)
                except OSError:
                    pass
            return e.code, raw.decode("utf-8", "replace"), e.reason or ""
        except Exception as e:                                  # noqa: BLE001
            return 0, "", f"{type(e).__name__}: {e}"

    def _curl(self, method, url, headers, body, timeout):
        if not CURL:
            return 0, "", "curl not found (required for socks proxies)"
        fd, tmp = tempfile.mkstemp()
        os.close(fd)
        try:
            cmd = [CURL, "-sS", "-L", "--compressed",
                   "--max-time", str(timeout),
                   "--proxy", self.proxy,
                   "-w", "%{http_code}", "-o", tmp]
            if method != "GET":
                cmd += ["-X", method]
            if self.proxy_user:
                cmd += ["--proxy-user", self.proxy_user]
            for k, v in (headers or {}).items():
                cmd += ["-H", f"{k}: {v}"]
            if body is not None:
                cmd += ["--data-raw", body]
            cmd.append(url)

            out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 15)
            stdout = (out.stdout or "").strip()
            stderr = (out.stderr or "").strip()

            m = re.search(r"(\d{3})\s*$", stdout)
            status = int(m.group(1)) if m else 0
            err = stderr or (stdout if status == 0 else "")

            text = ""
            try:
                text = Path(tmp).read_text("utf-8", "replace")
            except OSError:
                pass
            return status, text, err
        except Exception as e:                                  # noqa: BLE001
            return 0, "", f"{type(e).__name__}: {e}"
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass


# ------------------------------------------------------------------
#  Rows
# ------------------------------------------------------------------
@dataclass
class Row:
    epoch: int
    currency: str
    impact: str
    title: str
    actual: str
    forecast: str
    previous: str
    source: str

    def line(self) -> str:
        return "|".join([str(self.epoch), self.currency, self.impact, self.title,
                         self.actual, self.forecast, self.previous, self.source])


def clean(s) -> str:
    """ASCII only (MQL5 FILE_ANSI), no pipe (it is the delimiter)."""
    if s is None:
        return ""
    s = str(s)
    s = "".join(ch for ch in s if 0x20 <= ord(ch) <= 0x7E)
    s = s.replace("|", "/")
    return re.sub(r"\s+", " ", s).strip()


def impact_of(s) -> str:
    v = str(s or "").strip().lower()
    return {"high": "high", "3": "high",
            "medium": "medium", "moderate": "medium", "2": "medium",
            "low": "low", "1": "low"}.get(v, "low")


def to_epoch(dt: datetime) -> int:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp())


def parse_dt(s: str) -> datetime | None:
    if not s:
        return None
    t = str(s).strip()
    if t.endswith("Z"):
        t = t[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(t)
    except ValueError:
        for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M"):
            try:
                return datetime.strptime(t, fmt).replace(tzinfo=timezone.utc)
            except ValueError:
                continue
    return None


class Feed:
    def __init__(self, quiet: bool = False):
        self.rows: list[Row] = []
        self.seen: set[str] = set()
        self.notes: list[str] = []
        self.quiet = quiet

    def note(self, msg: str) -> None:
        self.notes.append(msg)
        if not self.quiet:
            print(f"  {msg}", flush=True)

    def add(self, epoch: int, cur, impact, title,
            actual="", forecast="", previous="", source: str = "") -> bool:
        title = clean(title)
        if not title:
            return False
        cur = clean(cur).upper()[:3]
        key = f"{source}|{epoch}|{title}"
        if key in self.seen:
            return False
        self.seen.add(key)
        self.rows.append(Row(epoch, cur, impact_of(impact), title,
                             clean(actual), clean(forecast), clean(previous), source))
        return True


# ------------------------------------------------------------------
#  Providers
# ------------------------------------------------------------------
def get_ff(feed: Feed, http: Http, frm: datetime, to: datetime) -> int:
    n = 0
    for week in FF_WEEKS:
        url = f"https://nfs.faireconomy.media/ff_calendar_{week}.json"
        status, body, err = http.get(url, {"User-Agent": UA})
        if status != 200:
            if status == 404:
                feed.note(f"ff: {week} feed not published")
            else:
                feed.note(f"ff: {week} returned HTTP {status} - {clean(err)[:80]}")
            continue
        try:
            items = json.loads(body)
        except json.JSONDecodeError:
            feed.note(f"ff: {week} JSON parse failed")
            continue

        for e in items:
            dt = parse_dt(e.get("date", ""))
            if dt is None or not (frm <= dt <= to):
                continue
            cur = str(e.get("country") or "")
            if cur == "All":
                cur = "GLB"
            if feed.add(to_epoch(dt), cur, e.get("impact"), e.get("title"),
                        e.get("actual"), e.get("forecast"), e.get("previous"), "ff"):
                n += 1
    return n


def get_tv(feed: Feed, http: Http, frm: datetime, to: datetime, countries: str) -> int:
    url = ("https://economic-calendar.tradingview.com/events"
           f"?from={frm.strftime('%Y-%m-%dT%H:%M:%S.000Z')}"
           f"&to={to.strftime('%Y-%m-%dT%H:%M:%S.000Z')}"
           f"&countries={urllib.parse.quote(countries)}")

    status, body, err = http.get(url, {
        "Origin": "https://www.tradingview.com",
        "Referer": "https://www.tradingview.com/",
        "User-Agent": UA,
    })
    if status != 200:
        feed.note(f"tv: HTTP {status} - {clean(err)[:80]}")
        return 0
    try:
        j = json.loads(body)
    except json.JSONDecodeError:
        feed.note("tv: JSON parse failed")
        return 0
    if j.get("status") != "ok":
        feed.note(f"tv: unexpected status '{j.get('status')}'")
        return 0

    n = 0
    for e in j.get("result") or []:
        dt = parse_dt(e.get("date", ""))
        if dt is None or not (frm <= dt <= to):
            continue
        imp = int(e.get("importance", -1) or -1)
        impact = "high" if imp == 1 else ("medium" if imp == 0 else "low")
        cur = str(e.get("currency") or "") or str(e.get("country") or "")
        if feed.add(to_epoch(dt), cur, impact, e.get("title"),
                    e.get("actual"), e.get("forecast"), e.get("previous"), "tv"):
            n += 1
    return n


def investing_request(frm: datetime, to: datetime) -> tuple[str, dict, str]:
    body = "&".join([
        "country%5B%5D=",
        "importance%5B%5D=1",
        "importance%5B%5D=2",
        "importance%5B%5D=3",
        f"dateFrom={frm.strftime('%Y-%m-%d')}",
        f"dateTo={to.strftime('%Y-%m-%d')}",
        "timeZone=55",
        "timeFilter=timeRemain",
        "currentTab=custom",
        "limit_from=0",
    ])
    headers = {
        "User-Agent": UA,
        "X-Requested-With": "XMLHttpRequest",
        "Referer": "https://www.investing.com/economic-calendar/",
        "Accept": "application/json, text/javascript, */*; q=0.01",
        "Content-Type": "application/x-www-form-urlencoded",
        "Origin": "https://www.investing.com",
    }
    return INVESTING_URL, headers, body


COUNTRY_MAP = {
    "United States": "USD", "Euro Zone": "EUR", "United Kingdom": "GBP",
    "Japan": "JPY", "Canada": "CAD", "Australia": "AUD", "New Zealand": "NZD",
    "Switzerland": "CHF", "China": "CNY", "Germany": "EUR", "France": "EUR",
    "Italy": "EUR", "Spain": "EUR",
}

ROW_RE = re.compile(
    r'<tr[^>]*data-event-datetime="([^"]+)"[\s\S]*?(?=<tr[^>]*data-event-datetime=|\Z)')
CUR_RE = re.compile(r'title="([A-Za-z ]+)"')
TITLE_RE = re.compile(r'<td class="event"[^>]*>\s*<a[^>]*>([^<]+)</a>')


def get_investing(feed: Feed, http: Http, frm: datetime, to: datetime,
                  debug_dir: Path) -> int:
    url, headers, body = investing_request(frm, to)
    status, html, err = http.post(url, headers, body)

    if status != 200:
        why = clean(err) or "no body"
        feed.note(f"investing: HTTP {status} ({why[:60]}) - skipped")
        return 0
    if len(html) < 100:
        feed.note("investing: empty response - skipped")
        return 0

    n = 0
    for m in ROW_RE.finditer(html):
        dt = parse_dt(m.group(1).replace("/", "-"))
        if dt is None or not (frm <= dt <= to):
            continue
        block = m.group(0)

        cur = ""
        mc = CUR_RE.search(block)
        if mc:
            cur = mc.group(1)
        if len(cur) > 3:
            cur = COUNTRY_MAP.get(cur, cur)

        impact = "low"
        if "bull3" in block:
            impact = "high"
        elif "bull2" in block:
            impact = "medium"

        mt = TITLE_RE.search(block)
        title = mt.group(1) if mt else ""

        if feed.add(to_epoch(dt), cur, impact, title, "", "", "", "investing"):
            n += 1

    if n == 0:
        dump = debug_dir / "investing_raw.html"
        try:
            dump.write_text(html, encoding="utf-8")
            feed.note(f"investing: HTTP 200 but no rows parsed - raw saved to {dump}")
        except OSError:
            feed.note("investing: HTTP 200 but no rows parsed")
    return n


# ------------------------------------------------------------------
#  Output
# ------------------------------------------------------------------
def read_text_any(p: Path) -> str:
    """MT5 writes origin.txt as UTF-16; other files are plain ASCII/UTF-8."""
    raw = p.read_bytes()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16", "ignore")
    try:
        return raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        return raw.decode("latin-1", "ignore")


def auto_dirs() -> list[tuple[Path, str, bool]]:
    """[(feed dir, origin path text, indicator installed)] for every terminal."""
    base = Path(os.environ.get("APPDATA", "")) / "MetaQuotes" / "Terminal"
    if not base.is_dir():
        raise SystemExit(
            "No MT5 data folder (APPDATA/MetaQuotes/Terminal). On Linux/CI pass --out.")
    found = []
    for t in sorted(base.iterdir()):
        if not (t / "MQL5" / "Files").is_dir():
            continue
        origin = t / "origin.txt"
        text = read_text_any(origin).strip() if origin.is_file() else ""
        inst = (t / "MQL5" / "Indicators" / "EventMap" / "EventMap.ex5").is_file()
        found.append((t / "MQL5" / "Files" / "EventMap", text, inst))
    if not found:
        raise SystemExit(f"No MT5 terminal with MQL5/Files under {base}")
    return found


def resolve_targets(out: str, all_terminals: bool) -> list[Path]:
    def as_file(p: Path) -> Path:
        return p if p.suffix.lower() == ".csv" else p / "events.csv"

    if out:
        return [as_file(Path(out).expanduser())]

    found = auto_dirs()
    if all_terminals:
        return [d / "events.csv" for d, _, _ in found]

    # The terminal that actually has the indicator installed is the one that
    # will consume the feed; fall back to Pepperstone, then to the first one.
    for d, _, inst in found:
        if inst:
            return [d / "events.csv"]
    for d, origin, _ in found:
        if "Pepperstone" in origin:
            return [d / "events.csv"]
    return [found[0][0] / "events.csv"]


def read_rows(path: Path) -> list[Row]:
    if not path.is_file():
        return []
    out = []
    for line in path.read_text("ascii", "ignore").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("epoch|"):
            continue
        p = line.split("|")
        if len(p) != 8:
            continue
        try:
            epoch = int(p[0])
        except ValueError:
            continue
        out.append(Row(epoch, p[1], p[2], p[3], p[4], p[5], p[6], p[7]))
    return out


def write_atomic(path: Path, text: str) -> bool:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="ascii", newline="\n")
    for _ in range(5):
        try:
            os.replace(tmp, path)
            return True
        except PermissionError:      # terminal may hold the handle briefly
            time.sleep(0.2)
    try:                             # last resort: truncate in place
        with open(path, "w", encoding="ascii", newline="\n") as f:
            f.write(text)
        tmp.unlink(missing_ok=True)
        return True
    except OSError:
        tmp.unlink(missing_ok=True)
        return False


# ------------------------------------------------------------------
#  Proxy test
# ------------------------------------------------------------------
def proxy_test(http: Http, frm: datetime, to: datetime) -> None:
    shown = re.sub(r"//[^/@]+@", "//***@", http.proxy) if http.proxy else "direct (no proxy)"
    print(f"\nProxy: {shown}")

    status, body, err = http.get("https://api.ipify.org?format=json", timeout=20)
    if status == 200:
        try:
            ip = json.loads(body).get("ip", body)
        except json.JSONDecodeError:
            ip = body
        print(f"  egress IP       {ip}")
    else:
        print(f"  egress IP       FAILED  {clean(err)[:70]}")

    inv_url, inv_h, inv_b = investing_request(frm, to)
    checks = [
        ("Forex Factory", "GET",
         "https://nfs.faireconomy.media/ff_calendar_thisweek.json",
         {"User-Agent": UA}, None),
        ("TradingView", "GET",
         f"https://economic-calendar.tradingview.com/events"
         f"?from={frm.strftime('%Y-%m-%dT%H:%M:%S.000Z')}"
         f"&to={to.strftime('%Y-%m-%dT%H:%M:%S.000Z')}&countries=US",
         {"Origin": "https://www.tradingview.com",
          "Referer": "https://www.tradingview.com/", "User-Agent": UA}, None),
        ("Investing.com", "POST", inv_url, inv_h, inv_b),
    ]

    for name, method, url, headers, body in checks:
        if method == "GET":
            st, _, er = http.get(url)
        else:
            st, _, er = http.post(url, headers, body)
        note = "ok" if st == 200 else clean(er)[:60]
        print(f"  {name:<15}  HTTP {st:<4} {note}")
    print()


# ------------------------------------------------------------------
#  Main
# ------------------------------------------------------------------
def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        description="Build the EventMap feed from external calendar providers.")
    ap.add_argument("--provider", default="ff,tv",
                    help="comma separated: ff,tv,investing (default ff,tv)")
    ap.add_argument("--days-back", type=int, default=2)
    ap.add_argument("--days-forward", type=int, default=8)
    ap.add_argument("--out", default="",
                    help="events.csv path or directory; default = auto-detect MT5")
    ap.add_argument("--all-terminals", action="store_true")
    ap.add_argument("--countries", default="US,EU,GB,JP,CA,AU,NZ,CH,CN,DE,FR,IT,ES")
    ap.add_argument("--proxy", default=os.environ.get("EVENTMAP_PROXY", ""))
    ap.add_argument("--proxy-user",
                    default=os.environ.get("EVENTMAP_PROXY_USER", ""))
    ap.add_argument("--proxy-test", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    providers = []
    for chunk in args.provider.split(","):
        p = chunk.strip().lower()
        if p and p not in providers:
            providers.append(p)
    bad = [p for p in providers if p not in ("ff", "tv", "investing")]
    if bad:
        ap.error(f"unknown provider(s): {', '.join(bad)} (use ff, tv, investing)")

    now = datetime.now(timezone.utc).replace(microsecond=0)
    frm = now - timedelta(days=args.days_back)
    to = now + timedelta(days=args.days_forward)

    http = Http(proxy=args.proxy, proxy_user=args.proxy_user)

    if args.proxy_test:
        proxy_test(http, frm, to)
        return 0

    if not args.quiet:
        print("\nEventMap feed")
        print(f"  window  {frm:%Y-%m-%d %H:%M} -> {to:%Y-%m-%d %H:%M} UTC")
        shown = re.sub(r"//[^/@]+@", "//***@", http.proxy) if http.proxy else "direct (no proxy)"
        print(f"  proxy   {shown}")

    targets = resolve_targets(args.out, args.all_terminals)
    prev = read_rows(targets[0])

    feed = Feed(args.quiet)
    counts: dict[str, int] = {}

    if "ff" in providers:
        counts["ff"] = get_ff(feed, http, frm, to)
    if "tv" in providers:
        counts["tv"] = get_tv(feed, http, frm, to, args.countries)
    if "investing" in providers:
        counts["investing"] = get_investing(feed, http, frm, to, targets[0].parent)

    # A provider that is down or rate limited must not delete the coverage it
    # already delivered, and a run for one provider must not drop the others.
    keep = {p for p in ("ff", "tv", "investing")
            if p not in providers or counts.get(p, 0) == 0}
    kept = 0
    kept_src: set[str] = set()
    if keep and prev:
        for r in prev:
            if r.source not in keep:
                continue
            if not (to_epoch(frm) <= r.epoch <= to_epoch(to)):
                continue
            if feed.add(r.epoch, r.currency, r.impact, r.title,
                        r.actual, r.forecast, r.previous, r.source):
                kept += 1
                kept_src.add(r.source)
        if kept:
            feed.note(f"cached: kept {kept} rows for {','.join(sorted(kept_src))}")

    rows = sorted(feed.rows, key=lambda r: (r.epoch, r.source))
    if not rows:
        print("no rows - nothing written", file=sys.stderr)
        return 1

    meta = (f"# generated={now.strftime('%Y-%m-%dT%H:%M:%SZ')} "
            f"provider={','.join(providers)} rows={len(rows)}")
    if kept_src:
        meta += " cached=" + ",".join(sorted(kept_src))

    text = "\n".join(
        ["# eventmap 1", meta, "epoch|cur|impact|title|actual|forecast|previous|source"]
        + [r.line() for r in rows]) + "\n"

    written = []
    for t in targets:
        if write_atomic(t, text):
            written.append(t)

    if not args.quiet:
        print()
        print(f"  rows    {len(rows)}")
        for k in providers:
            note = "  (cached)" if kept and k in kept_src else ""
            print(f"  {k:<9} {counts.get(k, 0)}{note}")
        for w in written:
            print(f"  wrote   {w}")
        print()

    return 0 if written else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
