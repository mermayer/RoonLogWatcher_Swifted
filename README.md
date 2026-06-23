# Roon Log Watcher for macOS

This Swift/macOS version is based on the original [`stefanmauron/roon-log-watcher`](https://github.com/stefanmauron/roon-log-watcher) GitHub project.

Roon Log Watcher is a native macOS menu bar app for watching local Roon,
Roon Server, RAAT Server, Roon Appliance and Roon Bridge log files. It exposes a
browser-based dashboard at `http://127.0.0.1:17666`, keeps a bounded in-memory log
history, highlights relevant events and calculates a weighted Roon Health score.
The dashboard can also be opened from another system on the same network by
using the Roon Mac's hostname or IP address with the configured dashboard port,
provided macOS firewall and network settings allow the connection.

The app can run against real local Roon logs or, when no logs are found, a demo
feed. Direct Roon Server API access is not required.

## Screenshots

### Dashboard

![Roon Log Watcher dashboard](docs/screenshots/readme/dashboard.png)

### Configuration

![Roon Log Watcher configuration](docs/screenshots/readme/configuration.png)

### Roon Health Details

![Roon Health details](docs/screenshots/readme/health-details.png)

## What Gets Monitored

The watcher combines log-derived events with local system signals:

- Log files from common Roon locations under `~/Library`, `/Users/Shared`,
  `/Library`, and the configured `baseDirectory`.
- Optional manual log directories and environment based paths:
  `ROON_LOG_DIR`, `ROONSERVER_LOG_DIR`, and `ROONSERVER_DATAROOT`.
- Current, non-rotated log files matching `fileNameIncludes`, while rotated
  archives and AppleDouble metadata files such as `._Package.swift` are ignored
  by the live tailer.
- New log lines only; the tailer polls append-only changes instead of re-reading
  whole files on every refresh.
- Roon memory lines: physical, managed, unmanaged and virtual memory, plus a
  compact 24-hour Roon memory trend in the live-log header.
- Playback activity and instability: playing, stopped, buffering, timeout,
  failed, dropped and network error style lines.
- RAAT activity: connect, reconnect, disconnect, transport lost and device lost.
- Roon file-cache status and image fetch retry/failure lines.
- Server lifecycle and failure indicators: startup, shutdown, fatal, crash,
  panic, unhandled exception, out-of-memory and segmentation fault.
- Database signals: corruption, malformed SQLite image, locked database,
  SQLite busy, slow query, timeout, rollback and maintenance completion.
- Local host status: likely Roon host detection, matching Roon processes, CPU,
  resident memory, optional open-file counts and log-volume free space.
- Dashboard state: retained recent logs, exportable log history, deduplicated
  alerts, playback/RAAT timeline, log-volume buckets, health trend samples and
  24-hour memory trend samples.

## Roon Health Score

Roon Health starts at `100`. Each active health signal contributes an impact
value. The total impact is capped at `100`, then subtracted:

```text
score = max(0, 100 - min(100, sum(signal impacts)))
```

The state is derived from both score and severity:

- `Healthy`: no warning/critical signals and score is at least `82`.
- `Degraded`: warning signals exist, or the score falls below `82`.
- `Critical`: any critical signal exists, or the score falls below `55`.
- `Unknown`: no useful log/source evidence is available yet.

Signals are sorted by severity first, then by impact and recency. The dashboard
shows the strongest current signals, while the Health Details panel includes the
trend, local system state and watched-source state.

Default signal weights:

| Area | Condition | Default impact |
| --- | --- | ---: |
| Sources | no watched source | 28 |
| Sources | only demo data | 16 |
| Sources | only inactive/non-current logs | 20 |
| Logs | no line processed yet | 24 |
| Logs | stream stale warning / critical | 16 / 34 |
| Events | critical log events in the event window | up to 42 |
| Events | warning burst in the event window | up to 28 |
| Server | fatal crash, panic, unhandled exception, OOM | 42 |
| Server | latest server state stopped | 40 |
| Server | retryable or generic exception warnings | up to 18 |
| Database | corruption or malformed SQLite database | up to 42 |
| Database | locked/busy/slow/failed database activity | up to 24 |
| RAAT | visible transport interruption burst warning / critical | 18 / 34 |
| RAAT | latest state disconnected | 12 |
| Playback | timeout/failure warning burst | up to 24 |
| Playback | heavy repeated playback instability | up to 32 |
| Memory | near threshold at 92% / over threshold | 12 / 28 |
| Memory | growth over the configured window | 18 |
| System | high Roon process CPU | 14 |
| System | high Roon process memory | 14 |
| Disk | low / critical free log-volume space | 14 / 34 |

The important detail is that not every Roon `Error` text is treated as equally
dangerous. A plain playback buffering line, image fetch retry or transient
SQLite busy message should not collapse the score to zero. The evaluator looks at
the parsed domain, severity, recency and repetition window before assigning
impact.

## Log Message Weighting

The parser first tries to classify a line into a known domain. Domain-specific
classification wins over plain text severity:

- `info`: memory samples, file-cache status, normal playback activity, RAAT
  reconnect/connect events, plain buffering, database maintenance and image
  fetch retries that still have attempts left.
- `warning`: playback timeout, failed, dropped or network-error lines; RAAT
  transport lost, device lost or disconnected lines; server stopped; retryable or
  generic exceptions; SQLite busy, locked database, slow query, timeout, rollback
  and exhausted image fetch retries.
- `critical`: fatal, crash, panic, unhandled/uncaught exception, out-of-memory,
  segmentation fault, database corruption and malformed SQLite database image.

If a line is interesting but does not match a domain parser, it becomes a
highlighted log event. Fallback weighting uses conservative keywords:
`fatal`, `crash` and `corrupt` become critical; `warning`, `timeout`, `failed`
and `disconnect` become warning; other highlighted lines remain informational.

The health evaluator then applies windowed thresholds. Plain buffering and normal
RAAT reconnect activity stay informational. Playback timeout/failure warnings are
warning-level by default and become critical only after a much larger repeated
burst. RAAT transport interruptions use warning and critical disconnect counts.
Database corruption is immediately critical, while SQLite busy/locked activity is
warning-level and capped.

## Configuration

The app creates its configuration at:

```text
~/Library/Application Support/RoonLogWatcher/config.json
```

You can open or reveal that file from the menu bar item, or edit the most common
settings from the browser dashboard using the gear button.

Currently active settings:

- `language` (`de` or `en`)
- `dashboardPort`
- `pollIntervalSeconds`
- `baseDirectory`
- `autoDiscoverRoonLogDirectories`
- `logDirectories`
- `fileNameIncludes`
- `maxFilesPerDirectory`
- `enableDemoModeWhenNoLogs`
- `watchExistingLogsFromEnd`
- `recentLogMaxLines`
- `logHistoryMaxLines`
- `maxLogLineCharacters`
- `alertDedupeSeconds`
- `logVolumeWindowMinutes` (`15`, `60`, `180` or `360`)
- `memoryAlerts`
- `healthRules`
- `sendMacNotifications`
- `showAllLogLines`

The main health-rule defaults are:

- log stale warning / critical: `180s` / `600s`
- warning burst window/count: `15 min` / `5`
- RAAT disconnect window, warning count, critical count: `15 min`, `2`, `5`
- database window: `30 min`
- playback window / critical base count: `15 min` / `5`
- disk warning / critical free space: `10 GB` / `2 GB`
- disk warning / critical free ratio: `5%` / `2%`
- process CPU warning: `80%`
- process memory warning: `4096 MB`
- health trend sample interval: `30s`
- memory thresholds: physical `2500 MB`, managed `2000 MB`, unmanaged `1800 MB`
- memory near-threshold warning: `92%` of the configured metric threshold
- memory growth window / threshold: `30 min` / `200 MB`

## Run

```bash
./script/build_and_run.sh
```

## Test

```bash
swift test
```
