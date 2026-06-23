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

## GitHub-Transfer fuer Codex

Wenn ein GitHub-Transfer benoetigt wird, zuerst kurz pruefen:

```bash
git remote -v
git status --short
env | rg 'GITHUB|GH_|GIT_'
which gh || true
ssh -T git@github.com
```

Wenn kein lokaler GitHub-Token, kein `gh` und kein SSH-Key nutzbar sind, nicht
weiter mit `git push` probieren. Dann direkt das installierte GitHub-Plugin
verwenden.

Bewaehrter Fallback:

1. Privates Repository mit dem GitHub-Plugin anlegen oder bestehendes Repo per
   Plugin pruefen.
2. Aus `git ls-files` ein `.tgz`-Archiv bauen und den SHA-256 notieren.
3. Archiv ueber eine kurzlebige HTTPS-Quelle bereitstellen.
4. Per GitHub-Plugin einen einmaligen Workflow committen, der:
   - das Archiv herunterlaedt,
   - den SHA-256 prueft,
   - den Quellbaum entpackt,
   - temporaere Importdateien und den Workflow selbst entfernt,
   - den finalen Import-Commit nach `main` pusht.
5. Danach mit dem GitHub-Plugin pruefen:
   - Repository ist `private`,
   - zentrale Dateien wie `Package.swift`, `README.md`, `Sources/...` und
     `Tests/...` sind vorhanden,
   - `.github/import` und der Import-Workflow sind entfernt.
6. Lokal `swift test` ausfuehren.

Diese Vorgehensweise wurde fuer `mermayer/RoonLogWatcher_Swifted` erfolgreich
verwendet. Finaler Import-Commit: `cd2b05bf466aeee14e34f243231cf02d925f14c0`.
