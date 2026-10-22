# EventMap — MT5 intraday event overlay

Draws the events that actually move an H1 chart: scheduled news from external
providers, the MT5 built-in calendar, and the recurring mechanical flow the
calendars do not carry (fixes, option cuts, auction settles, funding, expiries,
rolls).

Compiled with MetaEditor: **0 errors, 0 warnings.**

---

## Architecture

`WebRequest()` is **not permitted inside MT5 indicators**, so the indicator cannot
fetch anything itself. The split is:

```
fetch_events.ps1  (Windows, scheduled or manual)
        |  HTTPS
        v
   Forex Factory  +  TradingView   (+ Investing.com attempt)
        |
        v  normalized, ASCII, UTC epoch
MQL5\Files\EventMap\events.csv
        |
        v  FileRead
   EventMap.mq5  (indicator)
        +  MT5 built-in calendar (CalendarValueHistory)
        +  flow rule engine (UTC + per-date DST)
        v
   chart lines / labels / panel / alerts
```

Consequences worth knowing:

- Works **before MT5 is open** — the CSV is just a file.
- No `WebRequest` URL allowlisting needed.
- The feed is testable and inspectable outside the terminal.
- Readable in the **Strategy Tester** too (the built-in calendar is not).

---

## Providers

| Provider | Endpoint | Status |
|---|---|---|
| **Forex Factory** | `nfs.faireconomy.media/ff_calendar_thisweek.json` | **Working** — 73 events, impact + forecast + previous |
| **TradingView** | `economic-calendar.tradingview.com/events` | **Working** — 308 events, actual/forecast/previous, importance 1/0/-1 |
| **Investing.com** | `investing.com/economic-calendar/Service/getCalendarFilteredData` | **Blocked — HTTP 403** from this machine |

### About Investing.com

Every automated route returns **403 Forbidden**: the JSON endpoint, the
`sslecal2.forexprostools.com` widget host, and even the homepage, across
`Invoke-WebRequest` and `curl` with full browser headers. It is Cloudflare bot
protection, not a header problem. MT5's `WebRequest` would originate from the same
IP and hit the same wall.

The adapter is implemented and will work unchanged if the request is ever allowed
(different network, proxy, or an endpoint that is not protected). It reports the
block and skips rather than failing the run. I deliberately did not build a
Cloudflare bypass.

**If you need Investing.com specifically**, the only clean-path options are:
1. run the fetcher on a network/route where the endpoint is not blocked, or
2. use their official data offering, or
3. use TradingView (already wired) which carries the same public macro dataset
   with actual/forecast/previous — the practical substitute for the H1 use case.

**Option 1 is implemented** — pass `-Proxy` and the whole run (FF, TV and
Investing) goes through that egress. See [Through a proxy](#through-a-proxy).

---

## Install

Indicator (already installed for Pepperstone):

```
%APPDATA%\MetaQuotes\Terminal\73B7A2420D6397DFF9014A20F1201F97\MQL5\Indicators\EventMap\
```

Feed output (written by the fetcher):

```
%APPDATA%\MetaQuotes\Terminal\73B7A2420D6397DFF9014A20F1201F97\MQL5\Files\EventMap\events.csv
```

Attach: Navigator → Indicators → EventMap (right-click the folder → Refresh if
not listed). The panel footer shows `feed` as `12m`, `3h`, `n/a` or `14h!` (stale)
so you can see at a glance whether the data is live.

## Running the fetcher

```powershell
cd "$env:USERPROFILE\OneDrive\Desktop\EventMap"

# normal run
powershell -ExecutionPolicy Bypass -File .\fetch_events.ps1

# all providers, longer window, all terminals
powershell -ExecutionPolicy Bypass -File .\fetch_events.ps1 -Provider ff,tv,investing -DaysForward 14 -AllTerminals

# inspect rows without touching the terminal
powershell -ExecutionPolicy Bypass -File .\fetch_events.ps1 -PassThru
```

Options: `-Provider` (`ff,tv,investing`), `-DaysBack`, `-DaysForward`, `-OutDir`,
`-AllTerminals`, `-Countries`, `-Proxy`, `-ProxyUser`, `-ProxyTest`, `-Quiet`,
`-PassThru`.

### Python fetcher

`fetch_events.py` is the same logic on a bare Python 3.12+ (stdlib only — no pip
install), needed for the cloud run and handy anywhere else:

```powershell
python fetch_events.py                                 # same auto-detect + Pepperstone preference
python fetch_events.py --provider ff,tv,investing      # all providers
python fetch_events.py --out feed\events.csv           # any path (CI has no MT5 folder)
python fetch_events.py --proxy socks5h://127.0.0.1:9 --proxy-test
```

Both writers produce the identical feed format; the indicator cannot tell them
apart. Notes:

- `--proxy` accepts HTTP/HTTPS proxies natively; SOCKS goes through `curl.exe`.
- Terminal auto-detection requires a Windows `%APPDATA%` layout — on Linux/CI,
  always pass `--out`.

### Zero-VPS cloud feed (GitHub Actions)

The design that removes the local fetch entirely: the fetch runs on GitHub run-
ners from a datacenter egress, commits `feed/events.csv`, and the trading
machine just pulls it. No VPS, no proxy, no scheduled *fetching* — the only
local call is a file copy.

One-time setup:

1. Put this folder in a GitHub repo (the workflow lives in
   `.github/workflows/feed.yml`).
2. Manually run *EventMap feed* → *Run workflow* once to test, then confirm
   `feed/events.csv` exists in `main`.

Local pickup — either:

```powershell
# (a) a task that fetches the committed feed and drops it into the terminal
$f = "$env:APPDATA\MetaQuotes\Terminal\<HASH>\MQL5\Files\EventMap\events.csv"
curl.exe -sSfL -o $f https://raw.githubusercontent.com/<you>/<repo>/main/feed/events.csv
```

```powershell
# (b) clone the repo into a OneDrive-folder junction, then `git pull` keeps it synced
New-Item -ItemType Junction `
  -Path   "$env:APPDATA\MetaQuotes\Terminal\<HASH>\MQL5\Files\EventMap" `
  -Target "C:\Users\omsat\OneDrive\Desktop\EventMap\feed"
```

Notes and caveats:

- The repo itself is the **cache across runs**: each run reads the previous
  commit's `events.csv`, so a `429`'d provider is carried forward instead of
  being dropped — identical to the local script's behaviour.
- Investing.com is still likely to return `403` from Azure IPs (datacenter
  block). The workflow still works; it just leaves `investing 0` as today.
- Scheduled workflows stop if a repo is inactive for 60 days — the feed commit
  itself counts as activity, so it self-sustains.
- If 15-min cadence trips FF's rate limit, back off to 30 min
  (`.github/workflows/feed.yml` → `cron`).

### Resilience

- `429`, `5xx` and network errors are retried once (10 s wait for `429`, 3 s otherwise).
- If a provider still fails, **its previous rows are carried forward** rather than
  dropped. The feed header records it: `cached=ff`.
- Running a single provider (`-Provider tv`) does not delete the other providers'
  rows.
- Forex Factory rate-limits hard: it returned `429` after a handful of calls in ten
  minutes. A 15–30 min interval is fine; don't poll it per tick.

### Automate it

```powershell
powershell -ExecutionPolicy Bypass -File .\install_schedule.ps1              # every 30 min
powershell -ExecutionPolicy Bypass -File .\install_schedule.ps1 -IntervalMinutes 15
powershell -ExecutionPolicy Bypass -File .\install_schedule.ps1 -Remove
```

Registers a per-user scheduled task (no admin needed), logs to `fetch.log`.

### Through a proxy

Route only the fetcher — not the whole machine — through a different egress:

```powershell
# HTTP / HTTPS proxy
.\fetch_events.ps1 -Proxy "http://host:port"

# SOCKS5 with remote DNS resolution (preferred: no DNS leak)
.\fetch_events.ps1 -Proxy "socks5h://127.0.0.1:1080"

# with authentication
.\fetch_events.ps1 -Proxy "http://host:8080" -ProxyUser "user:pass"

# verify the egress before trusting it
.\fetch_events.ps1 -Proxy "socks5h://127.0.0.1:1080" -ProxyTest
```

`-ProxyTest` prints the egress IP and the HTTP status for every provider, so you
see immediately whether Investing.com answers `200` instead of `403`. It does not
write the feed.

Notes:

- **A VPN needs no proxy flags** — a VPN changes routing at the OS level. This is
  for an actual proxy: a proxy service, an SSH tunnel (`ssh -D 1080`), etc.
- SOCKS requires `curl.exe` (bundled with Windows 10 1803+). Everything goes
  through curl when present; the .NET fallback handles HTTP/HTTPS only.
- The fetcher reads `EVENTMAP_PROXY` / `EVENTMAP_PROXY_USER` when `-Proxy` is
  omitted, so the scheduled task can use a proxy without credentials appearing in
  the task command line:

  ```powershell
  .\install_schedule.ps1 -Proxy "socks5h://127.0.0.1:1080" -ProxyUser "user:pass"
  .\install_schedule.ps1 -ClearProxy
  ```

If Investing.com returns `200` but the parser finds no rows, the raw response is
saved to `investing_raw.html` next to the script — that file is enough to finish
the parser without guessing.

---

## Feed format

Pipe separated, ASCII, UTC epoch seconds. Versioned so the indicator can evolve.

```
# eventmap 1
# generated=2026-10-21T07:29:11Z provider=ff,tv,investing rows=377
epoch|cur|impact|title|actual|forecast|previous|source
1792413000|CAD|high|CPI m/m||0.2%|-0.1%|ff
```

Rules the fetcher guarantees (and the indicator relies on):

- exactly **8 fields**, `|` never appears inside a field
- ASCII only (`FILE_ANSI` safe)
- `impact` is one of `high` / `medium` / `low`
- `epoch` is UTC; the indicator applies the broker offset
- `source` is `ff` / `tv` / `investing`
- titles non-empty, sorted by epoch

---

## Same minute = one event

Providers name the same release differently (`CPI m/m` vs `Inflation Rate MoM`),
and fuzzy title matching is unreliable (`CPI (YoY)` vs `CPI (MoM)` share most
tokens but are different releases). So nothing is guessed:

- events from **any** source within the same minute and of the same kind collapse
  into **one line, one label, one panel row, one alert**
- the surviving row takes the **highest importance** and shows `+N`
- hovering the line lists every title in that minute

This also fixes duplication between the CSV feed and the built-in calendar.

## Reading the chart

| Visual | Meaning |
|---|---|
| Solid line | Scheduled news (colour = importance) |
| Dotted line | Daily mechanical flow |
| Dashed purple | Monthly / quarterly flow |
| Thin grey | Session marker |
| `+N` | N more releases in the same minute |
| Panel footer | broker offset, calendar status, feed age |

## Flow events (rule engine, UTC + per-date DST)

| Event | Rule |
|---|---|
| Tokyo 09:55 fix | 00:55 UTC, Mon–Fri |
| WMR 16:00 London fix | 16:00 London; high + purple on the last business day |
| FX option cuts | 10:00 London, 10:00 New York |
| LBMA gold auctions | 10:30 / 15:00 London |
| COMEX settlement | 13:30 New York |
| Perp funding | 00:00 / 08:00 / 16:00 UTC daily |
| Deribit expiry | Fri 08:00 UTC; quarterly last Friday of Mar/Jun/Sep/Dec |
| CME crypto reopen | Sun 18:00 New York |
| Sessions | Tokyo, London open/close, NY equity open/close |
| GSCI roll | 5th–9th business day |
| LME prompt / IMM roll | Third Wednesday |
| Quad witching | Third Friday of Mar/Jun/Sep/Dec |

DST is evaluated per date, so the London fix correctly shifts 15:00 → 16:00 UTC on
25 Oct 2026 while New York stays an hour later until 1 Nov.

## Key inputs

| Input | Default | Notes |
|---|---|---|
| `InpUseCsv` | true | Read the external feed |
| `InpCsvFile` | `EventMap\events.csv` | Path inside `MQL5\Files` |
| `InpCsvWarnHours` | 12 | Flag stale feed |
| `InpShowNews` | true | Built-in calendar |
| `InpMinImportance` | medium | Raise to `high` for a clean chart |
| `InpShowFlow` / `InpShowSessions` | true | Mechanical flow / session markers |
| `InpAlertMinutesBefore` | 15 | High-impact only, once per minute-group |

## Limitations

- **Investing.com is blocked here** (see above). Not a code defect.
- **Forex Factory** publishes only the current week, so a window extending past
  Sunday relies on TradingView for the tail.
- MT5 calendar is unavailable in the **Strategy Tester**; the CSV feed still works.
- The feed is only as fresh as the last fetcher run — watch the `feed` field.
- Titles are ASCII-normalised, so accented characters are stripped.

## Troubleshooting

| Symptom | Check |
|---|---|
| `feed n/a` | Does `MQL5\Files\EventMap\events.csv` exist? Run the fetcher once |
| `feed 14h!` | Scheduled task not running — check `fetch.log` |
| FF rows missing / `429` | Rate limited. Cached rows are kept; next run retries |
| Investing `403` | IP blocked — use `-Proxy` and verify with `-ProxyTest` |
| Proxy looks ignored | With a dead proxy every `-ProxyTest` check must fail; if not, `curl.exe` is missing |
| Lines shifted by hours | Broker server offset; leave `InpServerOffsetMin=9999` for auto |
| No news in tester | Expected — calendar API is unavailable there |
| Duplicate rows | Grouping applies only within 60s and the same kind; widen `InpPastDays` to inspect |
