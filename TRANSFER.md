# Roon Log Watcher Transfer

Diese Mappe enthaelt den aktuellen Projektstand ohne lokale Build-Artefakte.

## Auf dem Ziel-Mac entpacken

```bash
mkdir -p ~/Documents/Codex_Projects/RoonLogWatcher
tar -xzf ~/Desktop/RoonLogWatcher-transfer.tgz -C ~/Documents/Codex_Projects/RoonLogWatcher
cd ~/Documents/Codex_Projects/RoonLogWatcher
chmod +x script/build_and_run.sh
```

## Pruefen und starten

```bash
swift test
./script/build_and_run.sh --verify
```

Danach das Dashboard im Browser oeffnen:

```text
http://127.0.0.1:17666
```

## Konfiguration

Die App erstellt ihre Konfiguration auf dem Ziel-Mac automatisch unter:

```text
~/Library/Application Support/RoonLogWatcher/config.json
```

Die lokale Config vom Quell-Mac ist nicht Bestandteil dieses Transferpakets.
Das ist beabsichtigt, damit der Roon-Mac seine eigenen Roon-Logpfade per
Auto-Discovery finden kann.

Typische Roon-Logpfade, falls manuell benoetigt:

```text
~/Library/RoonServer/Logs
~/Library/Roon/Logs
/Library/RoonServer/Logs
/Users/Shared/RoonServer/Application Support/RoonServer/Logs
/Users/Shared/Roon/Application Support/Roon/Logs
```
