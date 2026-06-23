# Roon Log Watcher for macOS

Early Swift/macOS rewrite of `stefanmauron/roon-log-watcher`.

The first version is intentionally small:

- macOS menu bar app
- local browser dashboard at `http://127.0.0.1:17666`
- automatic discovery of common Roon log folders
- polling tailer that reads only newly appended log lines
- demo feed when no Roon logs are present
- memory, playback, RAAT and server event parsing

Direct Roon Server access is not required for day-to-day development. The app
can be developed with synthetic log lines and later validated against real logs.

## Run

```bash
./script/build_and_run.sh
```

## Test

```bash
swift test
```

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
- `alertDedupeSeconds`
- `logVolumeWindowMinutes` (`15`, `60`, `180` or `360`)

Some compatibility fields such as `memoryAlerts`, `sendMacNotifications` and
`showAllLogLines` are already stored for the next feature passes.
