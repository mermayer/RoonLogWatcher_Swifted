import Foundation

enum DashboardAssets {
    static let html = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Roon Log Watcher</title>
      <link rel="stylesheet" href="/style.css">
    </head>
    <body>
      <main class="app-shell">
        <header class="topbar">
          <div class="brand">
            <span class="brand-icon">▤</span>
            <strong>Roon Log Watcher</strong>
          </div>
          <div class="top-status">
            <span><i class="dot ok"></i> <span data-i18n="top.server">Server</span>: <strong id="serverState">Connected</strong></span>
            <span id="serverName">Roon Server</span>
            <span><span data-i18n="top.localPort">Local Port</span>: <strong id="localPort">--</strong></span>
            <span><span data-i18n="top.uptime">Uptime</span>: <strong id="uptime">--</strong></span>
          </div>
          <div class="top-actions">
            <a class="button" id="exportLogs" href="/api/export/logs.txt" data-i18n="action.exportLogs">Export Logs</a>
            <button class="icon-button" id="openSettings" type="button" title="Settings" data-i18n-title="action.settings">⚙</button>
          </div>
        </header>

        <section class="workspace">
          <aside class="left-rail">
            <section class="section runtime-section">
              <div class="section-title">
                <h2 data-i18n="section.runtimeHealth">Runtime Health</h2>
                <span id="sinceLabel">Since --</span>
              </div>
              <div id="roonHealth" class="roon-health"></div>
              <div id="runtimeList" class="health-list"></div>
            </section>

            <section class="section sources-section">
              <div class="section-title">
                <h2 data-i18n="section.sources">Watched Log Sources</h2>
              </div>
              <div id="sourceList" class="source-list"></div>
              <div class="section-footer">
                <span id="sourceCount">0 current</span>
                <button class="small-button" id="manageSources" type="button" data-i18n="action.manageSources">Manage Sources...</button>
              </div>
            </section>

            <section class="section resources-section">
              <div class="section-title">
                <h2 data-i18n="section.memoryResources">Memory & Resources</h2>
              </div>
              <div id="resourceList" class="resource-list"></div>
              <div class="updated-row">
                <span data-i18n="label.updated">Updated:</span>
                <strong id="updatedAt">--</strong>
                <span class="refresh-mark">↻</span>
              </div>
            </section>
          </aside>

          <section class="center-pane">
            <div class="pane-header">
              <h2 data-i18n="section.liveLogStream">Live Log Stream</h2>
              <div id="memoryTrendHeader" class="memory-trend-header empty"></div>
              <label class="toggle"><span class="toggle-label" data-i18n="label.autoScroll">Auto Scroll</span> <input id="autoScrollToggle" type="checkbox" checked><span class="toggle-control"></span></label>
            </div>
            <div class="log-toolbar">
              <button class="pause-button" id="pauseStream" type="button" title="Pause live stream">Ⅱ</button>
              <label data-i18n="label.level">Level</label>
              <select id="levelFilter">
                <option value="warningCritical" data-i18n="filter.warningCritical">Warnings + Critical</option>
                <option value="all" data-i18n="filter.all">All</option>
                <option value="warning" data-i18n="filter.warnings">Warnings</option>
                <option value="critical" data-i18n="filter.critical">Critical</option>
                <option value="info">Info</option>
              </select>
              <input id="searchInput" type="search" placeholder="Filter logs..." data-i18n-placeholder="placeholder.filterLogs">
              <label class="checkbox-label"><input id="regexInput" type="checkbox"> Regex</label>
              <span id="streamStatus" class="stream-status" hidden></span>
              <button class="small-button clear-button" id="clearSearch" type="button" data-i18n="action.clear">Clear</button>
              <button class="kebab-button" type="button">⋮</button>
            </div>
            <div class="log-table-wrap">
              <table class="log-table">
                <thead>
                  <tr>
                    <th><span class="label-with-help"><span data-i18n="table.time">Time</span><span class="help-icon tooltip-left" tabindex="0" role="button" data-help="logs.table.time"></span></span></th>
                    <th><span class="label-with-help"><span data-i18n="table.level">Level</span><span class="help-icon tooltip-left" tabindex="0" role="button" data-help="logs.table.level"></span></span></th>
                    <th><span class="label-with-help"><span data-i18n="table.source">Source</span><span class="help-icon tooltip-left" tabindex="0" role="button" data-help="logs.table.source"></span></span></th>
                    <th><span class="label-with-help"><span data-i18n="table.message">Message</span><span class="help-icon tooltip-left" tabindex="0" role="button" data-help="logs.table.message"></span></span></th>
                  </tr>
                </thead>
                <tbody id="logRows"></tbody>
              </table>
            </div>
            <div id="logDetail" class="log-detail" hidden>
              <div class="log-detail-meta">
                <span id="detailLevel" class="level-badge level-info">INFO</span>
                <span id="detailTime">--</span>
                <span id="detailSource">--</span>
              </div>
              <pre id="detailMessage"></pre>
              <div class="log-detail-actions">
                <span id="detailStatus"></span>
                <button class="small-button" id="copyLogLine" type="button" data-i18n="action.copy">Copy</button>
                <button class="small-button" id="closeLogDetail" type="button" data-i18n="action.close">Close</button>
              </div>
            </div>
            <div class="chart-panel">
              <div class="chart-toolbar">
                <select id="chartRange" aria-label="Log volume time window">
                  <option value="60" data-i18n="range.oneHour">1 hour</option>
                  <option value="15" data-i18n="range.fifteenMin">15 min</option>
                  <option value="180" data-i18n="range.threeHours">3 hours</option>
                  <option value="360" data-i18n="range.sixHours">6 hours</option>
                </select>
                <span data-i18n="chart.logVolume">Log Volume</span>
                <span id="chartBucketLabel" class="chart-bucket-label"></span>
                <div class="chart-legend">
                  <span><i class="legend-swatch total"></i><span data-i18n="chart.total">Total</span></span>
                  <span><i class="legend-swatch warn"></i><span data-i18n="chart.warning">Warnings</span></span>
                  <span><i class="legend-swatch bad"></i><span data-i18n="chart.error">Errors</span></span>
                </div>
                <span class="chart-now" data-i18n="chart.now">Now</span>
                <button type="button">‹</button>
                <button type="button">›</button>
              </div>
              <div class="chart-body">
                <div id="volumeAxis" class="volume-axis"></div>
                <div id="volumeChart" class="volume-chart"></div>
              </div>
              <div id="volumeTimeline" class="volume-timeline"></div>
            </div>
          </section>

          <aside class="right-rail">
            <section class="section alerts-section">
              <div class="section-title">
                <h2 data-i18n="section.alerts">Alerts</h2>
                <span class="trash">⌫</span>
              </div>
              <div class="tabs">
                <button class="tab active" data-alert-filter="all"><span data-i18n="filter.all">All</span> <span id="allAlertCount">0</span></button>
                <button class="tab" data-alert-filter="critical"><span data-i18n="filter.errors">Errors</span> <span id="errorAlertCount">0</span></button>
                <button class="tab" data-alert-filter="warning"><span data-i18n="filter.warnings">Warnings</span> <span id="warningAlertCount">0</span></button>
              </div>
              <div id="alertDetail" class="alert-detail" hidden>
                <div class="alert-detail-meta">
                  <span id="alertDetailLevel" class="level-badge level-info">INFO</span>
                  <span id="alertDetailTime">--</span>
                  <span id="alertDetailSource">--</span>
                </div>
                <strong id="alertDetailTitle">--</strong>
                <pre id="alertDetailMessage"></pre>
                <div class="alert-detail-actions">
                  <span id="alertDetailStatus"></span>
                  <button class="small-button" id="copyAlertMessage" type="button" data-i18n="action.copy">Copy</button>
                  <button class="small-button" id="closeAlertDetail" type="button" data-i18n="action.close">Close</button>
                </div>
              </div>
              <div id="alertList" class="alert-list"></div>
              <a class="text-link" href="/api/snapshot" data-i18n="link.viewAllAlerts">View all alerts...</a>
            </section>

            <section class="section playback-section">
              <div class="section-title">
                <h2 data-i18n="section.playbackRaat">Playback & RAAT Events</h2>
              </div>
              <div id="playbackList" class="playback-list"></div>
              <a class="text-link" href="/api/snapshot" data-i18n="link.viewAllEvents">View all events...</a>
            </section>
          </aside>
        </section>

        <aside id="settingsPanel" class="settings-panel" hidden>
          <div class="settings-card">
            <div class="settings-head">
              <div>
                <h2 data-i18n="settings.title">Configuration</h2>
                <p id="configPath" data-i18n="settings.loadingPath">Loading config path...</p>
              </div>
              <button class="icon-button" id="closeSettings" type="button">×</button>
            </div>

            <form id="settingsForm" class="settings-form">
              <label>
                <span data-i18n="settings.language">Language</span>
                <select id="configLanguage" name="language">
                  <option value="de">Deutsch</option>
                  <option value="en">English</option>
                </select>
              </label>
              <label>
                <span data-i18n="settings.dashboardPort">Dashboard Port</span>
                <input id="configPort" name="dashboardPort" type="number" min="1024" max="65535">
              </label>
              <label>
                <span data-i18n="settings.pollingInterval">Polling Interval</span>
                <input id="configPoll" name="pollIntervalSeconds" type="number" min="0.25" max="30" step="0.25">
              </label>
              <label>
                <span data-i18n="settings.maxFiles">Max Files / Directory</span>
                <input id="configMaxFiles" name="maxFilesPerDirectory" type="number" min="1" max="500">
              </label>
              <label>
                <span data-i18n="settings.recentLogs">Recent Log Lines</span>
                <input id="configRecentLogs" name="recentLogMaxLines" type="number" min="100" max="10000">
              </label>
              <label>
                <span data-i18n="settings.historyLogs">Retained History Lines</span>
                <input id="configHistoryLogs" name="logHistoryMaxLines" type="number" min="100" max="50000">
              </label>
              <label>
                <span data-i18n="settings.maxLogLineLength">Max Log Line Length</span>
                <input id="configMaxLineLength" name="maxLogLineCharacters" type="number" min="200" max="20000">
              </label>
              <label>
                <span data-i18n="settings.alertDedupe">Alert Dedupe Seconds</span>
                <input id="configDedupe" name="alertDedupeSeconds" type="number" min="5" max="600">
              </label>
              <div class="settings-subhead full"><span data-i18n="settings.healthRules">Health Rules</span><span class="help-icon tooltip-left" tabindex="0" role="button" data-help="settings.healthRules"></span></div>
              <label>
                <span data-i18n="settings.logStaleWarning">Log stale warning</span>
                <input id="configLogStaleWarning" type="number" min="15" max="86400" step="15">
              </label>
              <label>
                <span data-i18n="settings.logStaleCritical">Log stale critical</span>
                <input id="configLogStaleCritical" type="number" min="45" max="172800" step="15">
              </label>
              <label>
                <span data-i18n="settings.raatWarningDisconnects">RAAT warning disconnects</span>
                <input id="configRaatWarning" type="number" min="1" max="500">
              </label>
              <label>
                <span data-i18n="settings.raatCriticalDisconnects">RAAT critical disconnects</span>
                <input id="configRaatCritical" type="number" min="1" max="500">
              </label>
              <label>
                <span data-i18n="settings.diskWarningGB">Disk warning free GB</span>
                <input id="configDiskWarningGB" type="number" min="1" max="10000" step="0.5">
              </label>
              <label>
                <span data-i18n="settings.diskCriticalGB">Disk critical free GB</span>
                <input id="configDiskCriticalGB" type="number" min="0.5" max="10000" step="0.5">
              </label>
              <label>
                <span data-i18n="settings.cpuWarning">Process CPU warning</span>
                <input id="configCPUWarning" type="number" min="1" max="1000" step="1">
              </label>
              <label>
                <span data-i18n="settings.processMemoryWarning">Process memory warning</span>
                <input id="configProcessMemoryWarning" type="number" min="64" max="1048576" step="64">
              </label>
              <label>
                <span data-i18n="settings.logVolumeWindow">Log Volume Window</span>
                <select id="configVolumeWindow" name="logVolumeWindowMinutes">
                  <option value="15" data-i18n="range.fifteenMin">15 min</option>
                  <option value="60" data-i18n="range.oneHour">1 hour</option>
                  <option value="180" data-i18n="range.threeHours">3 hours</option>
                  <option value="360" data-i18n="range.sixHours">6 hours</option>
                </select>
              </label>
              <label>
                <span data-i18n="settings.baseDirectory">Base Directory</span>
                <input id="configBase" name="baseDirectory" type="text">
              </label>
              <label class="full">
                <span data-i18n="settings.manualDirs">Manual Log Directories</span>
                <textarea id="configDirs" name="logDirectories" rows="5" placeholder="/Users/you/Library/RoonServer/Logs" data-i18n-placeholder="placeholder.manualDirs"></textarea>
              </label>
              <label class="full">
                <span data-i18n="settings.filenameIncludes">Filename Includes</span>
                <input id="configIncludes" name="fileNameIncludes" type="text" placeholder="log, txt">
              </label>

              <div class="settings-toggles full">
                <label><input id="configAutoDiscover" type="checkbox"> <span data-i18n="settings.autoDiscover">Auto-discover Roon log folders</span></label>
                <label><input id="configDemo" type="checkbox"> <span data-i18n="settings.demoFeed">Use demo feed when no logs are found</span></label>
                <label><input id="configFromEnd" type="checkbox"> <span data-i18n="settings.watchFromEnd">Start watching existing logs from end</span></label>
                <label><input id="configNotifications" type="checkbox"> <span data-i18n="settings.notifications">macOS notifications</span></label>
                <label><input id="configShowAll" type="checkbox"> <span data-i18n="settings.showAll">Process all live log lines</span></label>
              </div>

              <div class="settings-actions full">
                <span id="settingsStatus"></span>
                <button class="small-button" id="reloadConfig" type="button" data-i18n="action.reload">Reload</button>
                <button class="button" type="submit" data-i18n="action.saveConfig">Save Config</button>
              </div>
            </form>
          </div>
        </aside>

        <aside id="healthPanel" class="modal-panel" hidden>
          <div class="modal-card health-card">
            <div class="settings-head">
              <div>
                <h2 data-i18n="health.detailsTitle">Health Details</h2>
                <p id="healthDetailSummary">--</p>
              </div>
              <button class="icon-button" id="closeHealth" type="button">×</button>
            </div>
            <div class="health-detail-body">
              <section>
                <div class="detail-section-title" data-i18n="health.trend">Health Trend</div>
                <div id="healthTrendDetail" class="health-trend-detail"></div>
              </section>
              <section>
                <div class="detail-section-title" data-i18n="health.signals">Signals</div>
                <div id="healthSignalList" class="health-detail-list"></div>
              </section>
              <section>
                <div class="detail-section-title" data-i18n="health.system">Local System</div>
                <div id="healthSystemList" class="health-detail-list"></div>
              </section>
              <section>
                <div class="detail-section-title" data-i18n="health.sourceHealth">Log Sources</div>
                <div id="healthSourceList" class="health-detail-list"></div>
              </section>
              <div class="settings-actions">
                <span id="healthDetailStatus"></span>
                <button class="button" id="exportIncident" type="button" data-i18n="action.exportIncident">Export Diagnosis</button>
              </div>
            </div>
          </div>
        </aside>

        <aside id="sourcePanel" class="modal-panel" hidden>
          <div class="modal-card source-card">
            <div class="settings-head">
              <div>
                <h2 data-i18n="sources.title">Log Sources</h2>
                <p id="sourceModalSummary">--</p>
              </div>
              <button class="icon-button" id="closeSources" type="button">×</button>
            </div>
            <div id="sourceModalList" class="source-detail-list"></div>
            <form id="sourceForm" class="source-form">
              <label class="source-checkline"><input id="sourceAutoDiscover" type="checkbox"> <span data-i18n="settings.autoDiscover">Auto-discover Roon log folders</span></label>
              <label>
                <span data-i18n="settings.manualDirs">Manual Log Directories</span>
                <textarea id="sourceDirs" rows="5" placeholder="/Users/you/Library/RoonServer/Logs" data-i18n-placeholder="placeholder.manualDirs"></textarea>
              </label>
              <div class="settings-actions">
                <span id="sourceStatus"></span>
                <button class="small-button" id="openSettingsFromSources" type="button" data-i18n="action.allSettings">All Settings</button>
                <button class="button" type="submit" data-i18n="action.saveSources">Save Sources</button>
              </div>
            </form>
          </div>
        </aside>
      </main>
      <script src="/app.js"></script>
    </body>
    </html>
    """

    static let css = """
    :root {
      color-scheme: dark;
      --bg: #080b0f;
      --surface: #12171d;
      --surface-2: #151a20;
      --surface-3: #0f1419;
      --line: #2a3038;
      --line-soft: rgba(255, 255, 255, 0.065);
      --text: #edf2f7;
      --muted: #99a3af;
      --muted-2: #69737e;
      --green: #62d17d;
      --blue: #53a7ff;
      --yellow: #ffd34e;
      --red: #ff5c5c;
      --level-info: #62d17d;
      --level-debug: #53a7ff;
      --level-warning: #ffd34e;
      --level-critical: #ff6b6b;
      --level-info-bg: rgba(98, 209, 125, 0.12);
      --level-debug-bg: rgba(83, 167, 255, 0.13);
      --level-warning-bg: rgba(255, 211, 78, 0.16);
      --level-critical-bg: rgba(255, 92, 92, 0.16);
      --shadow: rgba(0, 0, 0, 0.38);
    }

    * { box-sizing: border-box; }

    html, body {
      min-height: 100%;
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
      font-size: 14px;
    }

    body {
      overflow: hidden;
    }

    h1, h2, h3, p { margin: 0; }

    .app-shell {
      height: 100vh;
      min-width: 1200px;
      overflow: hidden;
      background:
        radial-gradient(circle at 20% 0%, rgba(61, 80, 92, 0.2), transparent 32rem),
        linear-gradient(180deg, #11161b 0%, #080b0f 100%);
    }

    .topbar {
      height: 52px;
      display: grid;
      grid-template-columns: 280px 1fr auto;
      align-items: center;
      border-bottom: 1px solid var(--line);
      background: rgba(13, 16, 20, 0.92);
      box-shadow: 0 18px 50px var(--shadow);
    }

    .brand {
      display: flex;
      align-items: center;
      gap: 12px;
      padding: 0 20px;
      font-size: 17px;
      font-weight: 720;
    }

    .brand-icon {
      width: 22px;
      height: 22px;
      display: grid;
      place-items: center;
      border: 1px solid #7c8793;
      border-radius: 5px;
      color: #ccd5df;
      font-size: 14px;
    }

    .top-status {
      display: flex;
      align-items: center;
      gap: 0;
      min-width: 0;
      color: #d5dbe2;
    }

    .top-status > span {
      display: inline-flex;
      align-items: center;
      min-width: 0;
      padding: 0 24px;
      height: 24px;
      border-left: 1px solid var(--line);
      white-space: nowrap;
    }

    .top-status strong {
      margin-left: 4px;
      color: var(--green);
      font-weight: 640;
    }

    .dot {
      width: 9px;
      height: 9px;
      border-radius: 50%;
      display: inline-block;
      margin-right: 9px;
      background: var(--muted-2);
    }

    .dot.ok { background: var(--green); box-shadow: 0 0 18px rgba(98, 209, 125, 0.35); }
    .dot.warn { background: var(--yellow); }
    .dot.bad { background: var(--red); }

    .top-actions {
      display: flex;
      align-items: center;
      gap: 14px;
      padding: 0 22px;
    }

    .button, .small-button, .icon-button, .tab, select, input {
      border: 1px solid var(--line);
      background: #131820;
      color: var(--text);
      border-radius: 5px;
      font: inherit;
    }

    .button {
      height: 30px;
      display: inline-flex;
      align-items: center;
      padding: 0 13px;
      text-decoration: none;
      font-weight: 620;
    }

    .icon-button {
      width: 30px;
      height: 30px;
      display: grid;
      place-items: center;
      color: #c8d0d9;
      text-decoration: none;
    }

    .help-icon {
      width: 16px;
      height: 16px;
      position: relative;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      flex: 0 0 auto;
      border: 0;
      border-radius: 50%;
      color: #b9c3ce;
      background-color: transparent;
      font-size: 0;
      line-height: 1;
      font-weight: 760;
      cursor: help;
      user-select: none;
      vertical-align: middle;
    }

    .help-icon:hover,
    .help-icon:focus,
    .help-icon:focus-visible {
      color: #dbe8ff;
      background-color: rgba(83, 167, 255, 0.12);
      outline: none;
    }

    .top-status > .help-icon {
      width: 16px;
      min-width: 16px;
      height: 16px;
      padding: 0;
      border: 0;
      white-space: normal;
    }

    .help-icon svg {
      width: 16px;
      height: 16px;
      display: block;
      fill: currentColor;
      stroke: none;
      pointer-events: none;
      overflow: visible;
    }

    .help-tooltip {
      position: fixed;
      z-index: 1000;
      max-width: min(300px, calc(100vw - 24px));
      padding: 9px 10px;
      border: 1px solid rgba(118, 170, 255, 0.38);
      border-radius: 6px;
      color: #edf2f7;
      background: rgba(12, 16, 21, 0.98);
      box-shadow: 0 18px 44px rgba(0, 0, 0, 0.5);
      font-size: 12px;
      line-height: 1.42;
      font-weight: 540;
      pointer-events: none;
    }

    .help-tooltip[hidden] {
      display: none;
    }

    .label-with-help,
    .value-with-help {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      min-width: 0;
    }

    .help-label-text {
      min-width: 0;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .value-with-help {
      justify-content: flex-end;
    }

    .workspace {
      height: calc(100vh - 52px);
      display: grid;
      grid-template-columns: 324px minmax(520px, 1fr) 360px;
    }

    .left-rail, .right-rail, .center-pane {
      min-height: 0;
    }

    .left-rail, .right-rail {
      display: grid;
      grid-auto-rows: min-content;
      background: rgba(18, 23, 29, 0.72);
    }

    .left-rail { border-right: 1px solid var(--line); }
    .right-rail {
      grid-auto-rows: unset;
      grid-template-rows: minmax(0, 0.96fr) minmax(0, 1.04fr);
      overflow: hidden;
      border-left: 1px solid var(--line);
    }

    .right-rail .section {
      min-height: 0;
      display: grid;
    }

    .alerts-section {
      grid-template-rows: 48px auto minmax(0, 1fr) auto;
    }

    .playback-section {
      grid-template-rows: 48px minmax(0, 1fr) auto;
    }

    .section {
      border-bottom: 1px solid var(--line);
      background: linear-gradient(180deg, rgba(255,255,255,0.025), rgba(0,0,0,0.04));
    }

    .section-title {
      min-height: 48px;
      display: flex;
      align-items: center;
      justify-content: flex-start;
      gap: 12px;
      padding: 0 22px;
    }

    .section-title h2, .pane-header h2 {
      font-size: 12px;
      line-height: 1.2;
      color: #c5ccd5;
      text-transform: uppercase;
      letter-spacing: 0.02em;
      font-weight: 760;
    }

    .section-title span {
      color: var(--muted);
      font-size: 12px;
    }

    .section-title > span:not(.help-icon) {
      margin-left: auto;
    }

    .health-list, .source-list, .resource-list {
      padding: 0 22px 18px;
      display: grid;
      gap: 12px;
    }

    .roon-health {
      margin: 0 22px 16px;
      padding: 12px;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: rgba(8, 12, 16, 0.58);
      cursor: pointer;
    }

    .roon-health:hover {
      background: rgba(255, 255, 255, 0.045);
    }

    .roon-health.healthy { border-color: rgba(98, 209, 125, 0.38); }
    .roon-health.degraded { border-color: rgba(255, 211, 78, 0.42); }
    .roon-health.critical { border-color: rgba(255, 92, 92, 0.48); }
    .roon-health.unknown { border-color: rgba(153, 163, 175, 0.36); }

    .roon-health-top {
      display: grid;
      grid-template-columns: 46px minmax(0, 1fr);
      gap: 11px;
      align-items: center;
    }

    .health-score-wrap {
      display: inline-flex;
      align-items: center;
      gap: 5px;
      width: 46px;
    }

    .health-score {
      width: 46px;
      height: 46px;
      min-width: 46px;
      flex: 0 0 46px;
      aspect-ratio: 1 / 1;
      box-sizing: border-box;
      display: grid;
      place-items: center;
      border-radius: 999px;
      border: 2px solid currentColor;
      color: var(--green);
      font-weight: 760;
      font-variant-numeric: tabular-nums;
    }

    .roon-health.degraded .health-score { color: var(--yellow); }
    .roon-health.critical .health-score { color: var(--red); }
    .roon-health.unknown .health-score { color: var(--muted); }

    .health-title {
      display: grid;
      grid-template-columns: minmax(0, 1fr);
      align-items: center;
      gap: 3px;
      color: var(--text);
      font-size: 13px;
      font-weight: 720;
    }

    .health-title .label-with-help {
      white-space: nowrap;
    }

    .health-state {
      color: var(--muted);
      font-size: 12px;
      font-weight: 620;
      white-space: nowrap;
      flex: 0 0 auto;
      justify-self: start;
    }

    .health-summary {
      margin-top: 5px;
      color: var(--muted);
      font-size: 12px;
      line-height: 1.35;
    }

    .health-signals {
      display: grid;
      gap: 7px;
      margin-top: 11px;
    }

    .health-trend {
      height: 22px;
      display: grid;
      grid-template-columns: repeat(24, minmax(2px, 1fr));
      gap: 2px;
      align-items: end;
      margin-top: 10px;
    }

    .health-trend span {
      min-height: 3px;
      height: calc(var(--h) * 1%);
      border-radius: 2px 2px 0 0;
      background: var(--green);
    }

    .health-trend span.degraded { background: var(--yellow); }
    .health-trend span.critical { background: var(--red); }
    .health-trend span.unknown { background: var(--muted); }

    .health-signal {
      display: grid;
      grid-template-columns: 8px 1fr;
      gap: 8px;
      align-items: start;
      color: #cbd3dc;
      font-size: 12px;
      line-height: 1.35;
    }

    .health-signal::before {
      content: "";
      width: 7px;
      height: 7px;
      margin-top: 4px;
      border-radius: 50%;
      background: var(--green);
    }

    .health-signal.warning::before { background: var(--yellow); }
    .health-signal.critical::before { background: var(--red); }
    .health-signal.info::before { background: var(--green); }

    .health-row, .source-row, .resource-row {
      display: grid;
      align-items: center;
      gap: 12px;
      min-height: 22px;
    }

    .health-row {
      grid-template-columns: 22px minmax(0, 1fr) auto;
    }

    .health-row.warning .status-icon { background: var(--yellow); }
    .health-row.critical .status-icon { background: var(--red); }
    .health-row.info .status-icon { background: var(--green); }
    .health-row.warning .row-value { color: var(--yellow); }
    .health-row.critical .row-value { color: var(--red); }
    .health-row.info .row-value { color: var(--green); }

    .source-row {
      grid-template-columns: 18px minmax(0, 1fr) auto;
    }

    .source-row.waiting .source-check {
      color: #17202a;
      background: #8aa0b4;
    }

    .source-row.live .source-check {
      background: var(--green);
    }

    .source-row.waiting .row-value {
      color: var(--muted);
    }

    .source-groups {
      display: grid;
      gap: 12px;
    }

    .source-group {
      display: grid;
      gap: 10px;
    }

    .source-group-title {
      color: var(--muted);
      font-size: 11px;
      font-weight: 760;
      text-transform: uppercase;
    }

    .status-icon, .source-check, .play-icon {
      width: 17px;
      height: 17px;
      display: grid;
      place-items: center;
      border-radius: 50%;
      color: #071009;
      background: var(--green);
      font-size: 11px;
      font-weight: 760;
    }

    .row-title {
      color: #e7ecf2;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }

    .row-title.label-with-help {
      overflow: visible;
    }

    .row-value {
      color: var(--green);
      font-variant-numeric: tabular-nums;
      white-space: nowrap;
    }

    .row-value .help-icon,
    .row-title .help-icon {
      color: #9da7b2;
    }

    .section-footer {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 0 22px 18px;
      color: var(--muted);
      font-size: 12px;
    }

    .small-button {
      height: 28px;
      padding: 0 12px;
      font-weight: 620;
    }

    .resources-section {
      min-height: 360px;
    }

    .resource-row {
      grid-template-columns: minmax(0, 1fr) minmax(72px, max-content) minmax(44px, max-content);
      gap: 10px;
    }

    .resource-row .value-with-help {
      gap: 5px;
    }

    .bar-track {
      grid-column: 1 / -1;
      height: 4px;
      overflow: hidden;
      border-radius: 999px;
      background: #2a3036;
      margin-top: -4px;
    }

    .bar-fill {
      height: 100%;
      width: var(--value, 50%);
      background: linear-gradient(90deg, var(--green), #7fe895);
    }

    .spark {
      width: 82px;
      height: 18px;
      display: flex;
      gap: 2px;
      align-items: end;
    }

    .spark span {
      width: 3px;
      height: calc(var(--h) * 1%);
      min-height: 3px;
      border-radius: 2px 2px 0 0;
      background: linear-gradient(180deg, #58b9ff, rgba(88, 185, 255, 0.35));
    }

    .updated-row {
      display: grid;
      grid-template-columns: auto 1fr auto;
      gap: 10px;
      padding: 18px 22px 20px;
      border-top: 1px solid var(--line);
      color: var(--muted);
      font-size: 13px;
    }

    .updated-row strong {
      color: #cbd3dc;
      font-weight: 520;
    }

    .center-pane {
      display: grid;
      grid-template-rows: 48px 44px minmax(260px, 1fr) auto 214px;
      background: rgba(9, 12, 16, 0.48);
    }

    .pane-header, .log-toolbar {
      display: flex;
      align-items: center;
      border-bottom: 1px solid var(--line);
    }

    .pane-header {
      display: grid;
      grid-template-columns: max-content minmax(280px, 1fr) max-content;
      justify-content: space-between;
      gap: 16px;
      padding: 0 18px;
    }

    .memory-trend-header {
      min-width: 0;
      width: 100%;
      max-width: none;
      justify-self: stretch;
      display: grid;
      grid-template-columns: max-content minmax(90px, 1fr) max-content max-content;
      align-items: center;
      gap: 9px;
      padding: 5px 10px;
      border: 1px solid rgba(139, 152, 166, 0.24);
      border-radius: 6px;
      background: rgba(12, 17, 23, 0.72);
      color: var(--muted);
      overflow: hidden;
    }

    .memory-trend-header.empty {
      opacity: 0.72;
    }

    .memory-trend-title {
      color: #aeb8c4;
      font-size: 11px;
      font-weight: 760;
      text-transform: uppercase;
      white-space: nowrap;
    }

    .memory-trend-bars {
      --memory-bars: 24;
      min-width: 0;
      height: 20px;
      display: grid;
      grid-template-columns: repeat(var(--memory-bars), minmax(2px, 1fr));
      align-items: end;
      gap: 2px;
    }

    .memory-trend-bars span {
      min-height: 3px;
      height: calc(var(--h) * 1%);
      border-radius: 2px 2px 0 0;
      background: linear-gradient(180deg, #58b9ff, rgba(88, 185, 255, 0.36));
    }

    .memory-trend-value,
    .memory-trend-delta {
      font-size: 12px;
      font-weight: 720;
      font-variant-numeric: tabular-nums;
      white-space: nowrap;
    }

    .memory-trend-value {
      color: #e7ecf2;
    }

    .memory-trend-delta {
      color: var(--muted);
    }

    .memory-trend-header.rising .memory-trend-delta { color: var(--yellow); }
    .memory-trend-header.falling .memory-trend-delta { color: var(--green); }

    .toggle {
      display: flex;
      align-items: center;
      gap: 12px;
      flex: 0 0 auto;
      color: var(--muted);
      text-transform: uppercase;
      font-size: 12px;
      line-height: 1;
      user-select: none;
    }

    .toggle-label {
      display: inline-flex;
      align-items: center;
      width: auto;
      height: auto;
      white-space: nowrap;
    }

    .toggle input { display: none; }

    .toggle-control {
      width: 34px;
      height: 19px;
      border-radius: 999px;
      background: #25303a;
      position: relative;
      flex: 0 0 auto;
    }

    .toggle input:checked + .toggle-control { background: #4bbf6a; }

    .toggle-control::after {
      content: "";
      width: 15px;
      height: 15px;
      position: absolute;
      top: 2px;
      left: 2px;
      border-radius: 50%;
      background: #d9e4ec;
      transition: transform 0.16s ease;
    }

    .toggle input:checked + .toggle-control::after { transform: translateX(15px); }

    .log-toolbar {
      gap: 10px;
      padding: 0 18px;
      color: var(--muted);
      font-size: 13px;
    }

    .pause-button, .kebab-button {
      width: 30px;
      height: 28px;
      border: 1px solid var(--line);
      border-radius: 5px;
      background: #121820;
      color: #dce4eb;
      font-weight: 720;
    }

    .pause-button.is-paused {
      border-color: rgba(255, 211, 78, 0.65);
      color: var(--yellow);
      background: rgba(255, 211, 78, 0.1);
    }

    select {
      height: 30px;
      min-width: 88px;
      padding: 0 10px;
    }

    input[type="search"] {
      height: 30px;
      width: min(240px, 28vw);
      padding: 0 12px;
    }

    .checkbox-label {
      display: flex;
      align-items: center;
      gap: 6px;
    }

    .clear-button {
      margin-left: 0;
    }

    .stream-status {
      min-width: 0;
      margin-left: auto;
      padding: 3px 8px;
      border: 1px solid var(--line);
      border-radius: 999px;
      color: #cdd5df;
      background: rgba(255, 255, 255, 0.045);
      font-size: 12px;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }

    .log-table-wrap {
      overflow: auto;
      border-bottom: 1px solid var(--line);
    }

    .log-table {
      width: 100%;
      border-collapse: collapse;
      table-layout: fixed;
      font-family: "SF Mono", Menlo, Consolas, monospace;
      font-size: 12px;
      line-height: 1.42;
    }

    .log-table th {
      height: 30px;
      position: sticky;
      top: 0;
      z-index: 1;
      background: rgba(18, 23, 29, 0.96);
      color: #9ba5ae;
      text-transform: uppercase;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
      font-size: 11px;
      text-align: left;
      border-bottom: 1px solid var(--line);
    }

    .log-table th .label-with-help {
      gap: 5px;
    }

    .log-table th, .log-table td {
      padding: 0 12px;
    }

    .log-table th:nth-child(1), .log-table td:nth-child(1) { width: 112px; }
    .log-table th:nth-child(2), .log-table td:nth-child(2) { width: 82px; }
    .log-table th:nth-child(3), .log-table td:nth-child(3) { width: 130px; }

    .log-table td {
      height: 22px;
      color: #dfe6ee;
      vertical-align: top;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      font-variant-numeric: tabular-nums;
    }

    .log-table tbody tr {
      cursor: default;
    }

    .log-table tbody tr:hover td {
      background: rgba(255, 255, 255, 0.035);
    }

    .log-table tbody tr.selected td {
      background: rgba(83, 167, 255, 0.09);
    }

    .empty-cell {
      height: 54px !important;
      color: var(--muted) !important;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
      text-align: center;
    }

    .log-row-info td:first-child { box-shadow: inset 3px 0 0 rgba(98, 209, 125, 0.45); }
    .log-row-debug td:first-child { box-shadow: inset 3px 0 0 rgba(83, 167, 255, 0.48); }
    .log-row-warning td:first-child { box-shadow: inset 3px 0 0 rgba(255, 211, 78, 0.65); }
    .log-row-critical td:first-child { box-shadow: inset 3px 0 0 rgba(255, 92, 92, 0.72); }

    .level-badge {
      min-width: 56px;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      padding: 2px 7px;
      border: 1px solid currentColor;
      border-radius: 4px;
      font-size: 11px;
      line-height: 1.2;
      font-weight: 820;
    }

    .level-info { color: var(--level-info); background: var(--level-info-bg); }
    .level-warning { color: var(--level-warning); background: var(--level-warning-bg); }
    .level-critical { color: var(--level-critical); background: var(--level-critical-bg); }
    .level-debug { color: var(--level-debug); background: var(--level-debug-bg); }

    .log-detail,
    .alert-detail {
      display: grid;
      gap: 10px;
      padding: 12px 18px;
      border-bottom: 1px solid var(--line);
      background: rgba(18, 23, 29, 0.74);
    }

    .alert-detail {
      border-top: 1px solid var(--line);
    }

    .alert-detail strong {
      color: #e7edf4;
      font-size: 13px;
      line-height: 1.35;
    }

    .log-detail[hidden],
    .alert-detail[hidden] {
      display: none;
    }

    .log-detail-meta,
    .log-detail-actions,
    .alert-detail-meta,
    .alert-detail-actions {
      display: flex;
      align-items: center;
      gap: 10px;
      min-width: 0;
    }

    .log-detail-meta span:not(.level-badge),
    .alert-detail-meta span:not(.level-badge) {
      color: var(--muted);
      font-size: 12px;
      white-space: nowrap;
    }

    .log-detail pre,
    .alert-detail pre {
      margin: 0;
      max-height: 82px;
      overflow: auto;
      white-space: pre-wrap;
      word-break: break-word;
      color: #dfe6ee;
      font: 12px/1.5 "SF Mono", Menlo, Consolas, monospace;
    }

    .alert-detail pre {
      max-height: 160px;
    }

    #detailStatus,
    #alertDetailStatus {
      margin-right: auto;
      color: var(--muted);
      font-size: 12px;
    }

    .chart-panel {
      padding: 12px 18px 14px;
    }

    .chart-toolbar {
      height: 32px;
      display: flex;
      align-items: center;
      gap: 10px;
      color: var(--muted);
      font-size: 13px;
    }

    .chart-toolbar select {
      min-width: 86px;
    }

    .chart-bucket-label {
      color: var(--muted-2);
      font-size: 12px;
      white-space: nowrap;
    }

    .chart-legend {
      display: flex;
      align-items: center;
      gap: 10px;
      min-width: 0;
      color: var(--muted);
      font-size: 12px;
    }

    .chart-legend span {
      display: inline-flex;
      align-items: center;
      gap: 5px;
      white-space: nowrap;
    }

    .legend-swatch {
      width: 8px;
      height: 8px;
      display: inline-block;
      border-radius: 2px;
      background: rgba(134, 144, 156, 0.7);
    }

    .legend-swatch.warn { background: var(--yellow); }
    .legend-swatch.bad { background: var(--red); }

    .chart-now {
      margin-left: auto;
    }

    .chart-toolbar button {
      width: 32px;
      height: 28px;
      border: 1px solid var(--line);
      border-radius: 5px;
      background: #131820;
      color: var(--text);
    }

    .chart-body {
      height: 122px;
      display: grid;
      grid-template-columns: 40px minmax(0, 1fr);
      align-items: stretch;
      margin-top: 4px;
    }

    .volume-axis {
      display: grid;
      grid-template-rows: 1fr 1fr 1fr;
      padding: 10px 8px 20px 0;
      color: var(--muted-2);
      font-size: 11px;
      font-variant-numeric: tabular-nums;
      text-align: right;
    }

    .volume-axis span:nth-child(1) { align-self: start; }
    .volume-axis span:nth-child(2) { align-self: center; }
    .volume-axis span:nth-child(3) { align-self: end; }

    .volume-chart {
      height: 100%;
      display: grid;
      grid-template-columns: repeat(var(--bucket-count, 60), minmax(3px, 1fr));
      align-items: end;
      gap: 3px;
      padding: 10px 4px 20px;
      border-bottom: 1px solid var(--line);
      background:
        repeating-linear-gradient(to top, transparent 0 31px, rgba(255,255,255,0.06) 32px),
        linear-gradient(180deg, transparent, rgba(255,255,255,0.025));
    }

    .volume-chart span {
      height: calc(var(--h) * 1%);
      min-height: 4px;
      background: rgba(134, 144, 156, 0.58);
      border-radius: 2px 2px 0 0;
    }

    .volume-chart span.warn { background: var(--yellow); }
    .volume-chart span.bad { background: var(--red); }

    .volume-timeline {
      height: 20px;
      display: grid;
      grid-template-columns: 40px minmax(0, 1fr);
      align-items: start;
      color: var(--muted-2);
      font-size: 11px;
      font-variant-numeric: tabular-nums;
    }

    .volume-timeline-labels {
      grid-column: 2;
      display: flex;
      justify-content: space-between;
      gap: 10px;
      padding-top: 4px;
    }

    .volume-timeline-labels span {
      white-space: nowrap;
    }

    .tabs {
      display: grid;
      grid-template-columns: minmax(70px, 0.8fr) minmax(84px, 0.9fr) minmax(116px, 1.3fr);
      gap: 8px;
      padding: 0 20px 12px;
    }

    .tab {
      height: 30px;
      min-width: 0;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 6px;
      padding: 0 8px;
      color: #cfd6de;
      white-space: nowrap;
    }

    .tab.active {
      border-color: #5b6570;
      background: #1b222b;
    }

    .tab span {
      min-width: 0;
      margin-left: 0;
    }

    .tab span:first-child {
      overflow: hidden;
      text-overflow: ellipsis;
    }

    .tab span:last-child {
      flex: 0 0 auto;
      color: var(--muted);
      font-variant-numeric: tabular-nums;
    }

    .alert-list, .playback-list {
      min-height: 0;
      display: grid;
      align-content: start;
      overflow: auto;
      overscroll-behavior: contain;
    }

    .alert-row, .play-row {
      min-height: 68px;
      display: grid;
      gap: 4px;
      padding: 12px 20px;
      border-top: 1px solid var(--line);
    }

    .alert-row {
      grid-template-columns: 14px 1fr auto;
      align-items: start;
      cursor: pointer;
    }

    .alert-row:hover,
    .alert-row.selected {
      background: rgba(255, 255, 255, 0.035);
    }

    .alert-dot {
      width: 9px;
      height: 9px;
      margin-top: 4px;
      border-radius: 50%;
      background: var(--yellow);
    }

    .alert-row.info .alert-dot { background: var(--level-info); }
    .alert-row.warning .alert-dot { background: var(--level-warning); }
    .alert-row.critical .alert-dot { background: var(--level-critical); }

    .alert-row.warning strong { color: var(--level-warning); }
    .alert-row.critical strong { color: var(--level-critical); }

    .alert-row strong, .play-row strong {
      font-size: 13px;
      line-height: 1.25;
    }

    .alert-row > div, .play-row > div {
      min-width: 0;
    }

    .alert-row p, .play-row p {
      color: #b3bdc8;
      font-size: 12px;
      line-height: 1.35;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }

    .alert-row p.alert-message {
      display: -webkit-box;
      -webkit-box-orient: vertical;
      -webkit-line-clamp: 3;
      white-space: normal;
    }

    .alert-row p.alert-source {
      color: var(--muted);
    }

    .event-time {
      color: var(--muted);
      font-size: 12px;
      white-space: nowrap;
    }

    .text-link {
      position: relative;
      z-index: 1;
      display: block;
      padding: 14px 20px 20px;
      color: #76aaff;
      background: rgba(18, 23, 29, 0.92);
      text-decoration: none;
      font-weight: 620;
      border-top: 1px solid var(--line);
    }

    .play-row {
      grid-template-columns: 34px 1fr auto;
      align-items: center;
    }

    .play-icon {
      width: 30px;
      height: 30px;
      background: rgba(83, 167, 255, 0.16);
      color: #72b6ff;
    }

    .play-row:first-child .play-icon {
      background: rgba(98, 209, 125, 0.18);
      color: var(--green);
    }

    .empty {
      padding: 14px 20px;
      color: var(--muted);
      font-size: 13px;
    }

    .settings-panel,
    .modal-panel {
      position: fixed;
      inset: 0;
      z-index: 20;
      display: grid;
      justify-content: end;
      background: rgba(0, 0, 0, 0.42);
      backdrop-filter: blur(8px);
    }

    .settings-panel[hidden],
    .modal-panel[hidden] {
      display: none;
    }

    .settings-card,
    .modal-card {
      width: min(520px, 100vw);
      height: 100vh;
      overflow: auto;
      border-left: 1px solid var(--line);
      background: #11161c;
      box-shadow: -30px 0 80px rgba(0, 0, 0, 0.45);
    }

    .settings-head {
      min-height: 74px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 20px;
      padding: 18px 22px;
      border-bottom: 1px solid var(--line);
    }

    .settings-head h2 {
      font-size: 18px;
      line-height: 1.2;
      text-transform: none;
      letter-spacing: 0;
      color: var(--text);
    }

    .settings-head p {
      margin-top: 6px;
      max-width: 390px;
      color: var(--muted);
      font-size: 12px;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }

    .settings-form {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 14px;
      padding: 18px 22px 24px;
    }

    .settings-form label {
      display: grid;
      gap: 7px;
      min-width: 0;
      color: #c8d0d8;
      font-size: 12px;
      font-weight: 650;
    }

    .settings-form label.has-help,
    .source-form label.has-help {
      grid-template-columns: minmax(0, 1fr) auto;
      align-items: center;
      column-gap: 8px;
    }

    .settings-form label.has-help > input:not([type="checkbox"]),
    .settings-form label.has-help > select,
    .settings-form label.has-help > textarea,
    .source-form label.has-help > textarea {
      grid-column: 1 / -1;
    }

    .settings-form label.has-help > .help-icon,
    .source-form label.has-help > .help-icon {
      justify-self: end;
    }

    .settings-form label.full,
    .settings-form .full {
      grid-column: 1 / -1;
    }

    .settings-subhead {
      margin-top: 6px;
      padding-top: 12px;
      display: flex;
      align-items: center;
      gap: 7px;
      border-top: 1px solid var(--line);
      color: #e3e9ef;
      font-size: 12px;
      font-weight: 760;
      text-transform: uppercase;
      letter-spacing: 0.02em;
    }

    .settings-form input[type="text"],
    .settings-form input[type="number"],
    .settings-form select,
    .settings-form textarea {
      width: 100%;
      min-width: 0;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: #0c1117;
      color: var(--text);
      font: 13px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
    }

    .settings-form input[type="text"],
    .settings-form input[type="number"],
    .settings-form select {
      height: 34px;
      padding: 0 10px;
    }

    .settings-form textarea {
      resize: vertical;
      padding: 10px;
      font-family: "SF Mono", Menlo, Consolas, monospace;
    }

    .settings-toggles {
      display: grid;
      gap: 10px;
      padding: 4px 0;
    }

    .settings-toggles label {
      display: flex;
      grid-template-columns: none;
      align-items: center;
      gap: 9px;
      font-size: 13px;
      font-weight: 560;
    }

    .settings-toggles label.has-help {
      grid-template-columns: none;
    }

    .settings-actions {
      display: flex;
      align-items: center;
      justify-content: flex-end;
      gap: 10px;
      padding-top: 8px;
    }

    #settingsStatus {
      margin-right: auto;
      color: var(--muted);
      font-size: 12px;
    }

    .source-card {
      width: min(560px, 100vw);
    }

    .health-card {
      width: min(620px, 100vw);
    }

    .health-detail-body {
      display: grid;
      gap: 18px;
      padding: 18px 22px 24px;
    }

    .detail-section-title {
      margin-bottom: 9px;
      display: inline-flex;
      align-items: center;
      gap: 7px;
      color: #c5ccd5;
      font-size: 12px;
      font-weight: 760;
      text-transform: uppercase;
      letter-spacing: 0.02em;
    }

    .health-trend-detail {
      height: 74px;
      display: grid;
      grid-template-columns: repeat(48, minmax(3px, 1fr));
      gap: 3px;
      align-items: end;
      padding: 10px 0 0;
      border-bottom: 1px solid var(--line);
    }

    .health-trend-detail span {
      min-height: 4px;
      height: calc(var(--h) * 1%);
      border-radius: 3px 3px 0 0;
      background: var(--green);
    }

    .health-trend-detail span.degraded { background: var(--yellow); }
    .health-trend-detail span.critical { background: var(--red); }
    .health-trend-detail span.unknown { background: var(--muted); }

    .health-detail-list {
      display: grid;
      gap: 8px;
    }

    .health-detail-row {
      display: grid;
      gap: 4px;
      padding: 10px 12px;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: rgba(255, 255, 255, 0.025);
    }

    .health-detail-row strong {
      color: var(--text);
      font-size: 13px;
    }

    .health-detail-row.warning strong { color: var(--yellow); }
    .health-detail-row.critical strong { color: var(--red); }

    .health-detail-row span,
    .health-detail-row code {
      min-width: 0;
      color: var(--muted);
      font-size: 12px;
      line-height: 1.35;
    }

    .health-detail-row code {
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .source-detail-list {
      display: grid;
      gap: 10px;
      padding: 16px 22px;
      border-bottom: 1px solid var(--line);
    }

    .source-detail-row {
      display: grid;
      gap: 5px;
      padding: 10px 12px;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: rgba(255, 255, 255, 0.025);
    }

    .source-detail-section {
      display: grid;
      gap: 10px;
    }

    .source-detail-section[open] {
      gap: 12px;
    }

    .source-detail-section summary,
    .source-detail-heading {
      color: #cbd3dc;
      cursor: pointer;
      font-size: 12px;
      font-weight: 720;
      list-style: none;
    }

    .source-detail-section summary::-webkit-details-marker {
      display: none;
    }

    .source-detail-section summary::before {
      content: "›";
      display: inline-block;
      margin-right: 7px;
      transition: transform 0.16s ease;
    }

    .source-detail-section[open] summary::before {
      transform: rotate(90deg);
    }

    .source-detail-section .source-detail-row.inactive {
      border-color: rgba(255, 255, 255, 0.07);
      background: rgba(255, 255, 255, 0.015);
    }

    .source-detail-row strong {
      color: var(--text);
      font-size: 13px;
    }

    .source-detail-row span,
    .source-detail-row code {
      color: var(--muted);
      font-size: 12px;
    }

    .source-detail-row code {
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .source-form {
      display: grid;
      gap: 14px;
      padding: 18px 22px 24px;
    }

    .source-form label {
      display: grid;
      gap: 7px;
      color: #c8d0d8;
      font-size: 12px;
      font-weight: 650;
    }

    .source-form textarea {
      width: 100%;
      min-width: 0;
      resize: vertical;
      padding: 10px;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: #0c1117;
      color: var(--text);
      font: 13px/1.45 "SF Mono", Menlo, Consolas, monospace;
    }

    .source-checkline {
      display: flex !important;
      align-items: center;
      gap: 9px;
    }

    #sourceStatus {
      margin-right: auto;
      color: var(--muted);
      font-size: 12px;
    }

    @media (max-width: 1240px) {
      body { overflow: auto; }
      .app-shell { min-width: 980px; overflow: visible; height: auto; min-height: 100vh; }
      .workspace { grid-template-columns: 280px minmax(440px, 1fr); height: auto; }
      .right-rail {
        grid-column: 1 / -1;
        grid-template-columns: 1fr 1fr;
        grid-template-rows: auto;
        overflow: visible;
        border-left: 0;
        border-top: 1px solid var(--line);
      }
      .right-rail .section { min-height: 420px; }
      .center-pane { min-height: 720px; }
      .topbar { grid-template-columns: 250px 1fr auto; }
      .top-status > span { padding: 0 12px; }
    }

    @media (max-width: 700px) {
      body {
        overflow: auto;
      }

      .app-shell {
        min-width: 0;
        height: auto;
        min-height: 100vh;
        overflow: visible;
      }

      .topbar {
        height: auto;
        grid-template-columns: minmax(0, 1fr);
        align-items: stretch;
        gap: 10px;
        padding: 12px 0;
      }

      .brand,
      .top-actions {
        padding: 0 14px;
      }

      .brand {
        min-width: 0;
      }

      .brand strong {
        min-width: 0;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      .top-actions {
        display: grid;
        grid-template-columns: minmax(0, 1fr) 34px;
        gap: 10px;
      }

      .top-actions .button {
        justify-content: center;
        min-width: 0;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      .top-status {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 6px 10px;
        padding: 0 14px;
        overflow: visible;
        font-size: 12px;
      }

      .top-status > span {
        gap: 4px;
        height: auto;
        min-width: 0;
        padding: 0;
        border-left: 0;
        line-height: 1.25;
        white-space: normal;
      }

      .top-status > span:nth-child(2),
      .top-status strong {
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      .workspace {
        grid-template-columns: minmax(0, 1fr);
        height: auto;
      }

      .left-rail,
      .right-rail,
      .center-pane {
        min-width: 0;
        border: 0;
      }

      .right-rail {
        grid-column: auto;
        grid-template-columns: minmax(0, 1fr);
        grid-template-rows: auto auto;
        overflow: visible;
      }

      .right-rail .section {
        min-height: 0;
      }

      .center-pane {
        min-height: 0;
        grid-template-rows: auto auto minmax(260px, 58vh) auto auto;
      }

      .pane-header,
      .log-toolbar,
      .chart-toolbar {
        height: auto;
        min-height: 44px;
        flex-wrap: wrap;
      }

      .pane-header {
        grid-template-columns: max-content minmax(140px, 1fr) max-content;
        gap: 8px 12px;
        padding: 8px 12px;
      }

      .memory-trend-header {
        max-width: none;
        grid-template-columns: max-content minmax(56px, 1fr) max-content;
        gap: 7px;
      }

      .memory-trend-delta {
        display: none;
      }

      .log-toolbar {
        padding: 8px 12px;
      }

      .log-toolbar input[type="search"] {
        flex: 1 1 160px;
        min-width: 0;
      }

      .chart-panel {
        min-width: 0;
        overflow: hidden;
        padding: 12px 12px 14px;
      }

      .chart-legend {
        flex-wrap: wrap;
        gap: 6px 8px;
      }

      .chart-body,
      .volume-timeline {
        grid-template-columns: 32px minmax(0, 1fr);
        min-width: 0;
      }

      .volume-axis {
        padding-right: 6px;
      }

      .volume-chart {
        grid-template-columns: repeat(var(--bucket-count, 60), minmax(1px, 1fr));
        gap: 1px;
        padding-left: 3px;
        padding-right: 3px;
      }

      .log-table-wrap {
        width: 100%;
        max-width: 100vw;
        overflow-x: auto;
      }

      .log-table {
        min-width: 0;
        font-size: 11px;
      }

      .log-table th,
      .log-table td {
        padding: 0 6px;
      }

      .log-table th:nth-child(1),
      .log-table td:nth-child(1) {
        width: 76px;
      }

      .log-table th:nth-child(2),
      .log-table td:nth-child(2) {
        width: 54px;
      }

      .log-table th:nth-child(3),
      .log-table td:nth-child(3) {
        width: 88px;
      }

      .level-badge {
        min-width: 42px;
        padding: 2px 4px;
        font-size: 10px;
      }

      .health-row,
      .source-row {
        grid-template-columns: 18px minmax(0, 1fr);
        gap: 8px;
      }

      .health-row .row-value,
      .source-row .row-value {
        grid-column: 2;
        justify-self: start;
        white-space: normal;
      }

      .section-footer {
        flex-direction: column;
        align-items: flex-start;
        gap: 10px;
      }

      .modal-panel {
        align-items: stretch;
        padding: 10px;
      }

      .settings-card,
      .modal-card {
        width: 100%;
        max-height: calc(100vh - 20px);
      }

      .source-detail-row code,
      .health-detail-row code {
        white-space: normal;
        overflow-wrap: anywhere;
      }
    }

    @media (max-width: 520px) {
      .pane-header {
        grid-template-columns: minmax(0, 1fr) auto;
      }

      .memory-trend-header {
        grid-column: 1 / -1;
      }
    }
    """

    static let javascript = """
    const UI_STATE_KEY = "roonLogWatcher.uiState.v1";
    const SOURCE_PROMPT_KEY = "roonLogWatcher.sourcePromptDismissed.v1";
    const DEFAULT_LEVEL = "warningCritical";
    const LEVEL_DEFAULT_VERSION = 2;
    const supportedLevels = ["all", "info", "warning", "critical", "warningCritical"];
    const supportedAlertFilters = ["all", "warning", "critical"];
    const supportedWindows = [15, 60, 180, 360];

    function readStoredUIState() {
      try {
        return JSON.parse(localStorage.getItem(UI_STATE_KEY) || "{}") || {};
      } catch {
        return {};
      }
    }

    function storedChoice(value, allowed, fallback) {
      return allowed.includes(value) ? value : fallback;
    }

    function storedWindow(value) {
      const minutes = Number(value);
      return supportedWindows.includes(minutes) ? minutes : 60;
    }

    const storedUIState = readStoredUIState();
    const initialLevel = storedUIState.levelDefaultVersion === LEVEL_DEFAULT_VERSION
      ? storedChoice(storedUIState.level, supportedLevels, DEFAULT_LEVEL)
      : DEFAULT_LEVEL;

    const state = {
      level: initialLevel,
      query: "",
      configDocument: null,
      language: "en",
      paused: false,
      autoScroll: storedUIState.autoScroll !== false,
      pendingSnapshot: null,
      lastSnapshot: null,
      visibleLogs: [],
      filteredLogs: [],
      selectedLogId: null,
      selectedLog: null,
      selectedAlertId: null,
      selectedAlert: null,
      alertFilter: storedChoice(storedUIState.alertFilter, supportedAlertFilters, "all"),
      bufferedCount: 0,
      clearedThroughLogId: 0,
      clearStatusUntil: 0,
      volumeWindowMinutes: storedWindow(storedUIState.volumeWindowMinutes),
      hasStoredVolumeWindow: supportedWindows.includes(Number(storedUIState.volumeWindowMinutes)),
      volumeChartScaleEnd: 0,
      volumeChartScaleMax: 20,
      volumeChartScaleWindow: storedWindow(storedUIState.volumeWindowMinutes),
      sourcePromptShown: false
    };

    const I18N = {
      en: {
        "top.server": "Server",
        "top.localPort": "Local Port",
        "top.uptime": "Uptime",
        "action.openLogs": "Open Logs",
        "action.exportLogs": "Export Logs",
        "action.settings": "Settings",
        "action.manageSources": "Manage Sources...",
        "action.clear": "Clear",
        "action.reload": "Reload",
        "action.saveConfig": "Save Config",
        "action.copy": "Copy",
        "action.close": "Close",
        "action.allSettings": "All Settings",
        "action.saveSources": "Save Sources",
        "action.exportIncident": "Export Diagnosis",
        "section.runtimeHealth": "Runtime Health",
        "section.sources": "Watched Log Sources",
        "section.memoryResources": "Memory & Resources",
        "section.liveLogStream": "Live Log Stream",
        "section.alerts": "Alerts",
        "section.playbackRaat": "Playback & RAAT Events",
        "label.updated": "Updated:",
        "label.autoScroll": "Auto Scroll",
        "label.level": "Level",
        "filter.all": "All",
        "filter.warningCritical": "Warnings + Critical",
        "filter.errors": "Errors",
        "filter.warnings": "Warnings",
        "filter.critical": "Critical",
        "placeholder.filterLogs": "Filter logs...",
        "placeholder.manualDirs": "/Users/you/Library/RoonServer/Logs",
        "table.time": "Time",
        "table.level": "Level",
        "table.source": "Source",
        "table.message": "Message",
        "range.oneHour": "1 hour",
        "range.fifteenMin": "15 min",
        "range.threeHours": "3 hours",
        "range.sixHours": "6 hours",
        "chart.logVolume": "Log Volume",
        "chart.now": "Now",
        "chart.lines": "lines",
        "chart.total": "Total",
        "chart.warning": "Warnings",
        "chart.error": "Errors",
        "chart.bucket": "bucket",
        "memoryTrend.title": "24h Roon Memory",
        "memoryTrend.noData": "Waiting for memory samples",
        "memoryTrend.samples": "samples",
        "link.viewAllAlerts": "View all alerts...",
        "link.viewAllEvents": "View all events...",
        "settings.title": "Configuration",
        "settings.loadingPath": "Loading config path...",
        "settings.language": "Language",
        "settings.dashboardPort": "Dashboard Port",
        "settings.pollingInterval": "Polling Interval",
        "settings.maxFiles": "Max Files / Directory",
        "settings.recentLogs": "Recent Log Lines",
        "settings.historyLogs": "Retained History Lines",
        "settings.maxLogLineLength": "Max Log Line Length",
        "settings.alertDedupe": "Alert Dedupe Seconds",
        "settings.healthRules": "Health Rules",
        "settings.logStaleWarning": "Log stale warning (s)",
        "settings.logStaleCritical": "Log stale critical (s)",
        "settings.raatWarningDisconnects": "RAAT warning disconnects",
        "settings.raatCriticalDisconnects": "RAAT critical disconnects",
        "settings.diskWarningGB": "Disk warning free GB",
        "settings.diskCriticalGB": "Disk critical free GB",
        "settings.cpuWarning": "Process CPU warning %",
        "settings.processMemoryWarning": "Process memory warning MB",
        "settings.logVolumeWindow": "Log Volume Window",
        "settings.baseDirectory": "Base Directory",
        "settings.manualDirs": "Manual Log Directories",
        "settings.filenameIncludes": "Filename Includes",
        "settings.autoDiscover": "Auto-discover Roon log folders",
        "settings.demoFeed": "Use demo feed when no logs are found",
        "settings.watchFromEnd": "Start watching existing logs from end",
        "settings.notifications": "macOS notifications",
        "settings.showAll": "Process all live log lines",
        "sources.title": "Log Sources",
        "sources.noWatchedSources": "No active watched sources",
        "sources.autoDiscoveryOn": "Auto-discovery on",
        "sources.autoDiscoveryOff": "Auto-discovery off",
        "sources.firstRunHint": "No real Roon log source found. Check auto-discovery or add log folders.",
        "sources.current": "Current sources",
        "sources.inactive": "Inactive archives",
        "sources.currentShort": "current",
        "sources.inactiveShort": "inactive",
        "sources.lastSeen": "Last seen",
        "sources.noCurrentSources": "No current log source discovered",
        "health.title": "Roon Health",
        "health.score": "Score",
        "health.state.healthy": "Stable",
        "health.state.degraded": "Needs attention",
        "health.state.critical": "Critical",
        "health.state.unknown": "Unknown",
        "health.noSignals": "No current warning signals.",
        "health.lastLog": "Last log",
        "health.now": "now",
        "health.secondsAgo": "s ago",
        "health.minutesAgo": "m ago",
        "health.hoursAgo": "h ago",
        "health.source.none": "No watched log source",
        "health.source.no_real": "No real Roon log source found",
        "health.source.active": "Log sources active",
        "health.logs.none": "No log lines received yet",
        "health.logs.stale_critical": "Log stream stale",
        "health.logs.stale_warning": "Log stream quiet",
        "health.logs.stale": "Log stream stale",
        "health.logs.fresh": "Log stream fresh",
        "health.events.critical": "Critical events in the recent window",
        "health.events.warning": "Warning burst in the recent window",
        "health.server.exception": "Server exception detected",
        "health.server.exception.warning": "Retryable server exception",
        "health.server.stopped": "Latest server state is stopped",
        "health.database.critical": "Database corruption risk",
        "health.database.warning": "Database warning activity",
        "health.raat.unstable": "RAAT transport interruptions",
        "health.raat.disconnected": "Latest RAAT state disconnected",
        "health.playback.unstable": "Playback timeout or failure activity",
        "health.memory.high": "Memory over threshold",
        "health.memory.near_threshold": "Memory near threshold",
        "health.memory.physical_high": "Physical memory over threshold",
        "health.memory.physical_near_threshold": "Physical memory near threshold",
        "health.memory.managed_high": "Managed memory over threshold",
        "health.memory.managed_near_threshold": "Managed memory near threshold",
        "health.memory.unmanaged_high": "Unmanaged memory over threshold",
        "health.memory.unmanaged_near_threshold": "Unmanaged memory near threshold",
        "health.memory.growth": "Memory growth detected",
        "health.disk.ok": "Log volume has free space",
        "health.disk.low": "Log volume free space is low",
        "health.disk.critical": "Log volume free space is critical",
        "health.system.host.detected": "Local Roon Server detected",
        "health.system.cpu.high": "High Roon process CPU",
        "health.system.memory.high": "High Roon process memory",
        "health.runtime.core": "Roon Core",
        "health.runtime.raat": "RAAT Server",
        "health.runtime.database": "Database",
        "health.runtime.fileWatcher": "File Watcher",
        "health.runtime.logIngestion": "Log Ingestion",
        "health.runtime.disk": "Disk Space",
        "health.detailsTitle": "Health Details",
        "health.trend": "Health Trend",
        "health.signals": "Signals",
        "health.system": "Local System",
        "health.sourceHealth": "Log Sources",
        "health.noTrend": "Not enough trend data yet",
        "health.noSystem": "No local system sample yet",
        "health.noProcesses": "No Roon processes detected",
        "health.hostDetected": "Roon Server host detected",
        "health.hostNotDetected": "No local Roon Server detected",
        "health.processes": "Processes",
        "health.cpu": "CPU",
        "health.memory": "Memory",
        "health.openFiles": "Open files",
        "health.diskFree": "Disk free",
        "health.lastModified": "Modified",
        "health.readable": "Readable",
        "health.notReadable": "Not readable",
        "health.exported": "Diagnosis exported",
        "status.paused": "Paused",
        "status.buffered": "buffered",
        "status.autoScrollOff": "Auto-scroll off",
        "status.filtered": "Filtered",
        "status.copied": "Copied",
        "status.cleared": "Cleared",
        "status.sourcesSaved": "Sources saved",
        "status.sourcesReloaded": "Sources saved and reloaded",
        connected: "Connected",
        idle: "Idle",
        serverRoon: "Roon Server",
        serverDemo: "Demo Roon Server",
        since: "Since",
        active: "active",
        noData: "No data",
        noSource: "No source discovered",
        noAlerts: "No alerts",
        noPlayback: "No playback events",
        waitingLogs: "Waiting for log lines",
        waitingNewLogs: "Waiting for new log lines",
        running: "Running",
        waiting: "Waiting",
        healthy: "Healthy",
        watch: "Watch",
        demo: "Demo",
        live: "Live",
        free: "free",
        rssMemory: "RSS Memory",
        virtualMemory: "Virtual Memory",
        managedMemory: "Managed Memory",
        unmanaged: "Unmanaged",
        cpuUsage: "CPU Usage",
        ioWait: "I/O Wait",
        openFiles: "Open Files",
        savedMessage: "Saved. Use Reload Config in the menu or restart for port changes.",
        reloadedMessage: "Reloaded from disk.",
        configPathUnavailable: "Config path unavailable",
        usingDefaults: "Using defaults"
      },
      de: {
        "top.server": "Server",
        "top.localPort": "Lokaler Port",
        "top.uptime": "Laufzeit",
        "action.openLogs": "Logs öffnen",
        "action.exportLogs": "Logs exportieren",
        "action.settings": "Einstellungen",
        "action.manageSources": "Quellen verwalten...",
        "action.clear": "Leeren",
        "action.reload": "Neu laden",
        "action.saveConfig": "Config speichern",
        "action.copy": "Kopieren",
        "action.close": "Schließen",
        "action.allSettings": "Alle Einstellungen",
        "action.saveSources": "Quellen speichern",
        "action.exportIncident": "Diagnose exportieren",
        "section.runtimeHealth": "Laufzeit-Zustand",
        "section.sources": "Überwachte Logquellen",
        "section.memoryResources": "Speicher & Ressourcen",
        "section.liveLogStream": "Live-Logstream",
        "section.alerts": "Warnungen",
        "section.playbackRaat": "Playback & RAAT-Ereignisse",
        "label.updated": "Aktualisiert:",
        "label.autoScroll": "Auto-Scroll",
        "label.level": "Level",
        "filter.all": "Alle",
        "filter.warningCritical": "Warnung + Kritisch",
        "filter.errors": "Fehler",
        "filter.warnings": "Warnungen",
        "filter.critical": "Kritisch",
        "placeholder.filterLogs": "Logs filtern...",
        "placeholder.manualDirs": "/Users/du/Library/RoonServer/Logs",
        "table.time": "Zeit",
        "table.level": "Level",
        "table.source": "Quelle",
        "table.message": "Nachricht",
        "range.oneHour": "1 Stunde",
        "range.fifteenMin": "15 Min.",
        "range.threeHours": "3 Stunden",
        "range.sixHours": "6 Stunden",
        "chart.logVolume": "Log-Volumen",
        "chart.now": "Jetzt",
        "chart.lines": "Zeilen",
        "chart.total": "Gesamt",
        "chart.warning": "Warnungen",
        "chart.error": "Fehler",
        "chart.bucket": "Bucket",
        "memoryTrend.title": "24h Roon-Speicher",
        "memoryTrend.noData": "Warte auf Speicherwerte",
        "memoryTrend.samples": "Proben",
        "link.viewAllAlerts": "Alle Warnungen anzeigen...",
        "link.viewAllEvents": "Alle Ereignisse anzeigen...",
        "settings.title": "Konfiguration",
        "settings.loadingPath": "Config-Pfad wird geladen...",
        "settings.language": "Sprache",
        "settings.dashboardPort": "Dashboard-Port",
        "settings.pollingInterval": "Polling-Intervall",
        "settings.maxFiles": "Max. Dateien / Ordner",
        "settings.recentLogs": "Letzte Logzeilen",
        "settings.historyLogs": "Behaltene Historienzeilen",
        "settings.maxLogLineLength": "Max. Logzeilenlänge",
        "settings.alertDedupe": "Warnungs-Dedupe Sekunden",
        "settings.healthRules": "Health-Regeln",
        "settings.logStaleWarning": "Log veraltet Warnung (s)",
        "settings.logStaleCritical": "Log veraltet Kritisch (s)",
        "settings.raatWarningDisconnects": "RAAT Warnung Disconnects",
        "settings.raatCriticalDisconnects": "RAAT Kritisch Disconnects",
        "settings.diskWarningGB": "Speicher Warnung frei GB",
        "settings.diskCriticalGB": "Speicher Kritisch frei GB",
        "settings.cpuWarning": "Prozess-CPU Warnung %",
        "settings.processMemoryWarning": "Prozessspeicher Warnung MB",
        "settings.logVolumeWindow": "Log-Volumen-Zeitfenster",
        "settings.baseDirectory": "Basisordner",
        "settings.manualDirs": "Manuelle Logverzeichnisse",
        "settings.filenameIncludes": "Dateiname enthält",
        "settings.autoDiscover": "Roon-Logordner automatisch suchen",
        "settings.demoFeed": "Demo-Feed nutzen, wenn keine Logs gefunden werden",
        "settings.watchFromEnd": "Bestehende Logs ab Dateiende überwachen",
        "settings.notifications": "macOS-Benachrichtigungen",
        "settings.showAll": "Alle Live-Logzeilen verarbeiten",
        "sources.title": "Logquellen",
        "sources.noWatchedSources": "Keine aktiven Logquellen",
        "sources.autoDiscoveryOn": "Automatische Suche aktiv",
        "sources.autoDiscoveryOff": "Automatische Suche aus",
        "sources.firstRunHint": "Keine echte Roon-Logquelle gefunden. Prüfe die automatische Suche oder trage Logordner ein.",
        "sources.current": "Aktuelle Quellen",
        "sources.inactive": "Inaktive Archive",
        "sources.currentShort": "aktuell",
        "sources.inactiveShort": "inaktiv",
        "sources.lastSeen": "Zuletzt",
        "sources.noCurrentSources": "Keine aktuelle Logquelle gefunden",
        "health.title": "Roon Health",
        "health.score": "Score",
        "health.state.healthy": "Stabil",
        "health.state.degraded": "Auffällig",
        "health.state.critical": "Kritisch",
        "health.state.unknown": "Unbekannt",
        "health.noSignals": "Keine aktuellen Warnsignale.",
        "health.lastLog": "Letztes Log",
        "health.now": "jetzt",
        "health.secondsAgo": "s her",
        "health.minutesAgo": "m her",
        "health.hoursAgo": "h her",
        "health.source.none": "Keine überwachte Logquelle",
        "health.source.no_real": "Keine echte Roon-Logquelle gefunden",
        "health.source.active": "Logquellen aktiv",
        "health.logs.none": "Noch keine Logzeilen empfangen",
        "health.logs.stale_critical": "Logstream ist veraltet",
        "health.logs.stale_warning": "Logstream ist ruhig",
        "health.logs.stale": "Logstream ist veraltet",
        "health.logs.fresh": "Logstream ist frisch",
        "health.events.critical": "Kritische Ereignisse im aktuellen Zeitfenster",
        "health.events.warning": "Warnungshäufung im aktuellen Zeitfenster",
        "health.server.exception": "Server-Ausnahme erkannt",
        "health.server.exception.warning": "Wiederholbare Server-Ausnahme",
        "health.server.stopped": "Letzter Serverzustand ist gestoppt",
        "health.database.critical": "Datenbank-Korruptionsrisiko",
        "health.database.warning": "Datenbank-Warnaktivität",
        "health.raat.unstable": "RAAT-Transportunterbrechungen",
        "health.raat.disconnected": "Letzter RAAT-Zustand getrennt",
        "health.playback.unstable": "Playback-Timeouts oder Fehler",
        "health.memory.high": "Speicher über Schwelle",
        "health.memory.near_threshold": "Speicher nahe Schwelle",
        "health.memory.physical_high": "Physical Memory über Schwelle",
        "health.memory.physical_near_threshold": "Physical Memory nahe Schwelle",
        "health.memory.managed_high": "Managed Memory über Schwelle",
        "health.memory.managed_near_threshold": "Managed Memory nahe Schwelle",
        "health.memory.unmanaged_high": "Unmanaged Memory über Schwelle",
        "health.memory.unmanaged_near_threshold": "Unmanaged Memory nahe Schwelle",
        "health.memory.growth": "Speicherwachstum erkannt",
        "health.disk.ok": "Log-Volume hat freien Platz",
        "health.disk.low": "Log-Volume wird knapp",
        "health.disk.critical": "Log-Volume ist kritisch knapp",
        "health.system.host.detected": "Lokaler Roon Server erkannt",
        "health.system.cpu.high": "Hohe Roon-Prozess-CPU",
        "health.system.memory.high": "Hoher Roon-Prozessspeicher",
        "health.runtime.core": "Roon Core",
        "health.runtime.raat": "RAAT Server",
        "health.runtime.database": "Datenbank",
        "health.runtime.fileWatcher": "File Watcher",
        "health.runtime.logIngestion": "Log Ingestion",
        "health.runtime.disk": "Speicherplatz",
        "health.detailsTitle": "Health-Details",
        "health.trend": "Health-Trend",
        "health.signals": "Signale",
        "health.system": "Lokales System",
        "health.sourceHealth": "Logquellen",
        "health.noTrend": "Noch nicht genug Trenddaten",
        "health.noSystem": "Noch keine lokale Systemprobe",
        "health.noProcesses": "Keine Roon-Prozesse erkannt",
        "health.hostDetected": "Roon-Server-System erkannt",
        "health.hostNotDetected": "Kein lokaler Roon Server erkannt",
        "health.processes": "Prozesse",
        "health.cpu": "CPU",
        "health.memory": "Speicher",
        "health.openFiles": "Offene Dateien",
        "health.diskFree": "Speicher frei",
        "health.lastModified": "Geändert",
        "health.readable": "Lesbar",
        "health.notReadable": "Nicht lesbar",
        "health.exported": "Diagnose exportiert",
        "status.paused": "Pausiert",
        "status.buffered": "gepuffert",
        "status.autoScrollOff": "Auto-Scroll aus",
        "status.filtered": "Gefiltert",
        "status.copied": "Kopiert",
        "status.cleared": "Geleert",
        "status.sourcesSaved": "Quellen gespeichert",
        "status.sourcesReloaded": "Quellen gespeichert und neu geladen",
        connected: "Verbunden",
        idle: "Inaktiv",
        serverRoon: "Roon Server",
        serverDemo: "Demo-Roon-Server",
        since: "Seit",
        active: "aktiv",
        noData: "Keine Daten",
        noSource: "Keine Quelle gefunden",
        noAlerts: "Keine Warnungen",
        noPlayback: "Keine Playback-Ereignisse",
        waitingLogs: "Warte auf Logzeilen",
        waitingNewLogs: "Warte auf neue Logzeilen",
        running: "Läuft",
        waiting: "Wartet",
        healthy: "Stabil",
        watch: "Beobachten",
        demo: "Demo",
        live: "Live",
        free: "frei",
        rssMemory: "RSS-Speicher",
        virtualMemory: "Virtueller Speicher",
        managedMemory: "Managed Speicher",
        unmanaged: "Unmanaged",
        cpuUsage: "CPU-Auslastung",
        ioWait: "I/O-Wartezeit",
        openFiles: "Offene Dateien",
        savedMessage: "Gespeichert. Nutze Config neu laden im Menü oder starte für Portänderungen neu.",
        reloadedMessage: "Von Datei neu geladen.",
        configPathUnavailable: "Config-Pfad nicht verfügbar",
        usingDefaults: "Nutze Standardwerte"
      }
    };

    const HELP = {
      en: {
        "common.iconLabel": "Help",
        "top.server": "Shows whether the dashboard process can currently deliver fresh runtime data. Connected means the local web server is reachable; the health score still depends on log and system signals.",
        "top.serverName": "Shows the current operating mode. In live mode this represents the discovered Roon Server host; in demo mode it is synthetic sample data.",
        "top.localPort": "The TCP port used by the local web dashboard on 127.0.0.1. If you change it in settings, reload the config or restart the app.",
        "top.uptime": "How long Roon Log Watcher has been running since this launch. It is useful for judging whether counters and trends cover enough time.",
        "top.since": "Start time of the current watcher session.",
        "top.updated": "Time of the newest dashboard snapshot. System metrics are sampled less frequently than log lines to keep the menu bar app lightweight.",
        "action.exportLogs": "Exports the retained server-side log history as plain text. Local user paths may still be present in raw log lines.",
        "action.exportIncident": "Exports a compact diagnosis bundle with health signals, counters, selected logs, source state and redacted configuration paths.",
        "action.settings": "Opens the local configuration panel. Changes are stored in config.json and some values require Reload Config or a restart.",
        "section.runtimeHealth": "Condensed health view inferred only from log files and local system state. No Roon API or server credentials are used.",
        "section.sources": "Current non-rotated log files. Rotated archives are excluded from the live tailer.",
        "section.memoryResources": "Resource indicators derived from parsed Roon log metrics and local process sampling where available.",
        "section.liveLogStream": "The newest matching log lines. Filtering and pausing affect the visible stream, not the background watcher.",
        "section.alerts": "Deduplicated warnings and critical events extracted from logs. Counts are for the current in-memory dashboard window.",
        "section.playbackRaat": "Playback and RAAT-related events inferred from log patterns, such as buffering, zone changes and RAAT reconnects.",
        "health.card": "Click the health card for details. The score starts at 100 and is reduced by active warning signals such as stale logs, RAAT instability, database issues, high memory or low disk space.",
        "health.score": "Overall inferred health score from 0 to 100. Higher is better; warning and critical log/system signals reduce the score.",
        "health.state": "Human-readable health state derived from the score and signal severity.",
        "health.trend": "Recent health samples. Bars show how the score changed over time; yellow and red indicate degraded or critical periods.",
        "health.signals": "The active reasons behind the current health score, grouped from logs, memory, disk and process state.",
        "health.system": "Local process, CPU, memory, open-file and disk information collected from macOS. Expensive details are sampled less often.",
        "health.sourceHealth": "Per-source readability, file size and last-modified information for watched log files.",
        "sources.count": "Current non-rotated sources being watched in this app run.",
        "sources.throughput": "Current activity state for this source in this app run.",
        "sources.autoDiscover": "When enabled, the app searches common Roon log locations automatically in addition to manual directories.",
        "sources.manualDirs": "One log directory per line. Use this when logs live outside the default Roon locations.",
        "resource.rss": "Resident memory reported by Roon log metrics when available. It approximates physical memory currently held by the process.",
        "resource.virtual": "Virtual memory reported by Roon metrics. This can be much larger than physical memory and is mainly useful for trend changes.",
        "resource.managed": "Managed runtime memory reported by Roon logs, usually related to .NET/Mono managed allocations.",
        "resource.unmanaged": "Native or unmanaged memory reported by Roon logs. Growth here can indicate native buffers or cache pressure.",
        "resource.cpu": "Current Roon-related process CPU percentage from macOS sampling. It is intentionally sampled slowly to reduce background overhead.",
        "resource.ioWait": "Lightweight placeholder for I/O wait pressure until real per-process I/O sampling is added. Treat trends here as contextual only.",
        "resource.openFiles": "Open file descriptors for detected Roon processes. This uses a more expensive system call and is sampled infrequently.",
        "resource.percent": "Relative bar value for quick scanning. Thresholds are conservative visual guides, not hard Roon limits.",
        "logs.autoScroll": "When enabled, the stream stays pinned to the newest log line. Turn it off to inspect older rows without the view jumping.",
        "logs.pause": "Pauses visual updates in the browser. The background watcher continues to read and classify logs.",
        "logs.level": "Limits visible rows by parser level: warnings plus critical, all, warning only, critical only or info.",
        "logs.search": "Filters the in-memory log history by message text. Combine it with Regex for pattern searches.",
        "logs.regex": "Interprets the search field as a case-insensitive regular expression. Invalid expressions fall back to plain text matching.",
        "logs.clear": "Clears the currently visible stream window in the browser. It does not delete log files or stop background ingestion.",
        "logs.table.time": "Precise receive time for the line in the dashboard, including milliseconds.",
        "logs.table.level": "Inferred severity from parser events and keywords such as Warn, Error, Fatal, Debug or Trace.",
        "logs.table.source": "Short name of the log file that produced this line.",
        "logs.table.message": "The log message with the timestamp prefix removed for easier scanning.",
        "chart.range": "Time window represented by the log-volume chart. The default is one hour and can be changed in settings.",
        "chart.volume": "Counts log lines per time bucket. Gray means total volume, yellow includes warnings and red includes critical/errors.",
        "chart.bucket": "Bucket size for each bar, calculated from the selected time window.",
        "chart.legend.total": "All log lines in the bucket.",
        "chart.legend.warning": "Buckets containing warning-level log lines.",
        "chart.legend.error": "Buckets containing critical or error-level log lines.",
        "settings.language": "Switches dashboard labels and help text between German and English.",
        "settings.dashboardPort": "Local HTTP port for the dashboard. Valid ports are 1024 to 65535; a restart may be needed after changing it.",
        "settings.pollingInterval": "How often known log files are checked for appended lines. Lower values feel more live but wake the app more often.",
        "settings.maxFiles": "Maximum number of newest matching current files per log directory. Keeping this moderate limits discovery work.",
        "settings.recentLogs": "Maximum number of recent rows sent to the live stream snapshot. Higher values make each dashboard refresh larger.",
        "settings.historyLogs": "Maximum number of log rows retained server-side for export, diagnosis and chart aggregation. These rows are not sent with every refresh.",
        "settings.maxLogLineLength": "Maximum characters stored per log line. Very long lines are truncated to protect memory and snapshot size.",
        "settings.alertDedupe": "Minimum seconds before the same alert can be added again. This prevents noisy repeated warnings from flooding the panel.",
        "settings.healthRules": "Thresholds used by the inferred Roon Health score. They affect warnings only; they do not change Roon itself.",
        "settings.logStaleWarning": "Seconds without new logs before the stream is considered quiet or stale at warning level.",
        "settings.logStaleCritical": "Seconds without new logs before the stream is considered critically stale.",
        "settings.raatWarningDisconnects": "Number of RAAT disconnect or reconnect events in the window that should trigger a warning.",
        "settings.raatCriticalDisconnects": "Number of RAAT disconnect or reconnect events that should make RAAT health critical.",
        "settings.diskWarningGB": "Free space threshold for a disk warning on the volume containing the watched logs.",
        "settings.diskCriticalGB": "Free space threshold for a critical disk signal on the log volume.",
        "settings.cpuWarning": "CPU percentage for detected Roon processes that should produce a health warning.",
        "settings.processMemoryWarning": "Total memory in MB for detected Roon processes that should produce a health warning.",
        "settings.logVolumeWindow": "Default time window for the log-volume chart.",
        "settings.baseDirectory": "Base folder used for discovery fallbacks and disk-space checks.",
        "settings.manualDirs": "Explicit log directories to watch, one per line. Use absolute macOS paths.",
        "settings.filenameIncludes": "Comma-separated filename fragments. Only files containing one of these fragments are considered logs.",
        "settings.autoDiscover": "Search common Roon locations automatically on this Mac.",
        "settings.demoFeed": "Starts synthetic sample data when no real logs are found. Useful during development; disable for real background use.",
        "settings.watchFromEnd": "When enabled, existing files start at their current end and only new lines are ingested.",
        "settings.notifications": "Allows macOS notifications when inferred Roon Health changes state.",
        "settings.showAll": "Processes every live log line. When disabled, only relevant lines may be highlighted depending on parser rules.",
        "settings.reload": "Reloads config.json from disk without restarting the app.",
        "settings.save": "Writes the current settings to config.json.",
        "alerts.filters": "Filter alert cards by all, errors or warnings. This changes only the visible list.",
        "events.list": "Recent playback and RAAT events inferred from log patterns.",
        "source.path": "Full path to the watched log file.",
        "source.status": "Current watcher status for this file. Rotated archive files are excluded from live watching.",
        "health.detail.signal": "Individual signal that contributed to the health score, including severity, count, source or threshold where available.",
        "health.detail.systemRow": "A local system value sampled from macOS. Some fields may show -- when unavailable or intentionally skipped for efficiency."
      },
      de: {
        "common.iconLabel": "Hilfe",
        "top.server": "Zeigt, ob der Dashboard-Prozess aktuell frische Laufzeitdaten liefern kann. Verbunden bedeutet, dass der lokale Webserver erreichbar ist; der Health-Score hängt trotzdem von Log- und Systemsignalen ab.",
        "top.serverName": "Zeigt den aktuellen Betriebsmodus. Im Live-Modus steht das für den gefundenen Roon-Server-Host; im Demo-Modus sind es synthetische Beispieldaten.",
        "top.localPort": "Der TCP-Port des lokalen Web-Dashboards auf 127.0.0.1. Nach Änderungen in den Einstellungen Config neu laden oder die App neu starten.",
        "top.uptime": "Wie lange Roon Log Watcher seit diesem Start läuft. Hilfreich, um Zähler und Trends zeitlich einzuordnen.",
        "top.since": "Startzeit der aktuellen Watcher-Sitzung.",
        "top.updated": "Zeitpunkt des neuesten Dashboard-Snapshots. Systemwerte werden seltener abgefragt als Logzeilen, damit die Menüleisten-App sparsam bleibt.",
        "action.exportLogs": "Exportiert die serverseitig behaltene Log-Historie als Textdatei. In rohen Logzeilen können lokale Benutzerpfade enthalten sein.",
        "action.exportIncident": "Exportiert ein kompaktes Diagnosepaket mit Health-Signalen, Zählern, ausgewählten Logs, Quellenstatus und redigierten Config-Pfaden.",
        "action.settings": "Öffnet die lokale Konfiguration. Änderungen werden in config.json gespeichert; manche Werte benötigen Config neu laden oder einen Neustart.",
        "section.runtimeHealth": "Kompakte Health-Ansicht, ausschließlich aus Logdateien und lokalem Systemzustand abgeleitet. Es wird keine Roon-API und kein Serverzugang verwendet.",
        "section.sources": "Aktuelle nicht-rotierte Logdateien. Rotierte Archive werden nicht live überwacht.",
        "section.memoryResources": "Ressourcenwerte aus geparsten Roon-Logmetriken und lokalen Prozessproben, soweit verfügbar.",
        "section.liveLogStream": "Die neuesten passenden Logzeilen. Filter und Pause betreffen nur die Anzeige, nicht den Hintergrund-Watcher.",
        "section.alerts": "Deduplizierte Warnungen und kritische Ereignisse aus den Logs. Die Zähler beziehen sich auf das aktuelle In-Memory-Fenster.",
        "section.playbackRaat": "Playback- und RAAT-Ereignisse aus Logmustern, zum Beispiel Buffering, Zonenwechsel und RAAT-Reconnects.",
        "health.card": "Klicke die Health-Karte für Details. Der Score startet bei 100 und sinkt durch aktive Warnsignale wie veraltete Logs, RAAT-Probleme, Datenbankhinweise, hohen Speicher oder knappen Speicherplatz.",
        "health.score": "Abgeleiteter Gesamtzustand von 0 bis 100. Höher ist besser; Warnungen und kritische Log-/Systemsignale reduzieren den Score.",
        "health.state": "Lesbarer Health-Zustand, abgeleitet aus Score und Signal-Schweregrad.",
        "health.trend": "Jüngste Health-Proben. Die Balken zeigen, wie sich der Score verändert hat; Gelb und Rot markieren auffällige oder kritische Phasen.",
        "health.signals": "Aktive Gründe hinter dem aktuellen Health-Score, gruppiert aus Logs, Speicher, Speicherplatz und Prozesszustand.",
        "health.system": "Lokale Prozess-, CPU-, Speicher-, Datei- und Plattenwerte von macOS. Teure Details werden seltener abgefragt.",
        "health.sourceHealth": "Lesbarkeit, Dateigröße und Änderungszeit je überwachter Logdatei.",
        "sources.count": "Aktuelle nicht-rotierte Quellen, die in diesem App-Lauf überwacht werden.",
        "sources.throughput": "Aktueller Aktivitätsstatus dieser Quelle in diesem App-Lauf.",
        "sources.autoDiscover": "Wenn aktiv, sucht die App zusätzlich zu manuellen Ordnern automatisch an üblichen Roon-Logorten.",
        "sources.manualDirs": "Ein Logordner pro Zeile. Nützlich, wenn Logs außerhalb der Standard-Roon-Orte liegen.",
        "resource.rss": "Residenter Speicher aus Roon-Logmetriken, wenn verfügbar. Näherung für aktuell physisch belegten Prozessspeicher.",
        "resource.virtual": "Virtueller Speicher aus Roon-Metriken. Kann deutlich größer sein als physischer Speicher und ist vor allem für Trends hilfreich.",
        "resource.managed": "Managed Runtime Memory aus Roon-Logs, typischerweise .NET/Mono-verwaltete Allokationen.",
        "resource.unmanaged": "Nativer oder unmanaged Speicher aus Roon-Logs. Wachstum kann auf native Puffer oder Cache-Druck hinweisen.",
        "resource.cpu": "Aktuelle CPU-Prozentwerte erkannter Roon-Prozesse aus macOS-Proben. Wird bewusst langsam abgefragt, um Ressourcen zu sparen.",
        "resource.ioWait": "Leichter Platzhalter für I/O-Druck, bis echte prozessbezogene I/O-Proben ergänzt sind. Trends hier nur als Kontext verstehen.",
        "resource.openFiles": "Offene Dateideskriptoren erkannter Roon-Prozesse. Diese teurere Systemabfrage läuft nur gelegentlich.",
        "resource.percent": "Relative Balkenanzeige zum schnellen Scannen. Die Schwellen sind visuelle Orientierung, keine harten Roon-Grenzen.",
        "logs.autoScroll": "Wenn aktiv, bleibt der Stream bei der neuesten Logzeile. Ausschalten, um ältere Zeilen zu prüfen, ohne dass die Ansicht springt.",
        "logs.pause": "Pausiert nur die sichtbaren Updates im Browser. Der Hintergrund-Watcher liest und klassifiziert weiter.",
        "logs.level": "Begrenzt sichtbare Zeilen nach Parser-Level: Warnung plus kritisch, alle, nur Warnung, nur kritisch oder Info.",
        "logs.search": "Filtert die In-Memory-Loghistorie nach Nachrichtentext. Zusammen mit Regex sind Mustersuchen möglich.",
        "logs.regex": "Interpretiert das Suchfeld als case-insensitive regulären Ausdruck. Ungültige Ausdrücke fallen auf Textsuche zurück.",
        "logs.clear": "Leert das aktuell sichtbare Stream-Fenster im Browser. Logdateien werden nicht gelöscht und Ingestion läuft weiter.",
        "logs.table.time": "Präzise Empfangszeit der Zeile im Dashboard inklusive Millisekunden.",
        "logs.table.level": "Abgeleiteter Schweregrad aus Parser-Ereignissen und Begriffen wie Warn, Error, Fatal, Debug oder Trace.",
        "logs.table.source": "Kurzname der Logdatei, aus der diese Zeile stammt.",
        "logs.table.message": "Lognachricht ohne Zeitstempelpräfix, damit sie leichter zu scannen ist.",
        "chart.range": "Zeitfenster des Log-Volumen-Diagramms. Standard ist eine Stunde und kann in den Einstellungen geändert werden.",
        "chart.volume": "Zählt Logzeilen pro Zeit-Bucket. Grau ist Gesamtvolumen, Gelb enthält Warnungen, Rot enthält Fehler/kritische Zeilen.",
        "chart.bucket": "Größe eines Balken-Buckets, berechnet aus dem ausgewählten Zeitfenster.",
        "chart.legend.total": "Alle Logzeilen im Bucket.",
        "chart.legend.warning": "Buckets mit Warnungs-Logzeilen.",
        "chart.legend.error": "Buckets mit kritischen oder Fehler-Logzeilen.",
        "settings.language": "Schaltet Dashboard-Beschriftungen und Hilfetexte zwischen Deutsch und Englisch um.",
        "settings.dashboardPort": "Lokaler HTTP-Port für das Dashboard. Gültig sind 1024 bis 65535; nach Änderung kann ein Neustart nötig sein.",
        "settings.pollingInterval": "Wie oft bekannte Logdateien auf neue Zeilen geprüft werden. Niedrigere Werte wirken direkter, wecken die App aber häufiger.",
        "settings.maxFiles": "Maximale Anzahl neuester passender aktueller Dateien pro Logordner. Moderate Werte begrenzen die Discovery-Arbeit.",
        "settings.recentLogs": "Maximale Anzahl jüngster Zeilen im Live-Stream-Snapshot. Höhere Werte machen jede Dashboard-Aktualisierung größer.",
        "settings.historyLogs": "Maximale Anzahl serverseitig behaltener Logzeilen für Export, Diagnose und Chart-Aggregation. Diese Zeilen werden nicht bei jeder Aktualisierung gesendet.",
        "settings.maxLogLineLength": "Maximale Anzahl gespeicherter Zeichen pro Logzeile. Sehr lange Zeilen werden gekürzt, um Speicher und Snapshot-Größe zu schützen.",
        "settings.alertDedupe": "Mindestsekunden, bevor dieselbe Warnung erneut aufgenommen wird. Verhindert, dass wiederholte Meldungen das Panel fluten.",
        "settings.healthRules": "Schwellenwerte für den abgeleiteten Roon-Health-Score. Sie beeinflussen nur Warnungen, nicht Roon selbst.",
        "settings.logStaleWarning": "Sekunden ohne neue Logs, bevor der Stream als ruhig oder veraltet auf Warnlevel gilt.",
        "settings.logStaleCritical": "Sekunden ohne neue Logs, bevor der Stream als kritisch veraltet gilt.",
        "settings.raatWarningDisconnects": "Anzahl RAAT-Disconnect- oder Reconnect-Ereignisse im Fenster, ab der gewarnt wird.",
        "settings.raatCriticalDisconnects": "Anzahl RAAT-Disconnect- oder Reconnect-Ereignisse, ab der RAAT kritisch wird.",
        "settings.diskWarningGB": "Freier Speicher in GB, ab dem das Log-Volume eine Warnung erzeugt.",
        "settings.diskCriticalGB": "Freier Speicher in GB, ab dem das Log-Volume kritisch bewertet wird.",
        "settings.cpuWarning": "CPU-Prozentwert erkannter Roon-Prozesse, ab dem eine Health-Warnung entsteht.",
        "settings.processMemoryWarning": "Gesamtspeicher in MB erkannter Roon-Prozesse, ab dem eine Health-Warnung entsteht.",
        "settings.logVolumeWindow": "Standard-Zeitfenster für das Log-Volumen-Diagramm.",
        "settings.baseDirectory": "Basisordner für Discovery-Fallbacks und Speicherplatzprüfungen.",
        "settings.manualDirs": "Explizite Logordner, einer pro Zeile. Absolute macOS-Pfade verwenden.",
        "settings.filenameIncludes": "Kommagetrennte Dateinamen-Fragmente. Nur Dateien mit einem dieser Fragmente werden als Logs betrachtet.",
        "settings.autoDiscover": "Sucht auf diesem Mac automatisch an üblichen Roon-Orten.",
        "settings.demoFeed": "Startet synthetische Beispieldaten, wenn keine echten Logs gefunden werden. Für Entwicklung nützlich; für echten Hintergrundbetrieb deaktivieren.",
        "settings.watchFromEnd": "Wenn aktiv, starten vorhandene Dateien am aktuellen Dateiende und nur neue Zeilen werden ingestiert.",
        "settings.notifications": "Erlaubt macOS-Benachrichtigungen, wenn der abgeleitete Roon-Health-Zustand wechselt.",
        "settings.showAll": "Verarbeitet jede Live-Logzeile. Wenn deaktiviert, werden je nach Parserregeln nur relevante Zeilen hervorgehoben.",
        "settings.reload": "Lädt config.json von der Platte neu, ohne die App neu zu starten.",
        "settings.save": "Schreibt die aktuellen Einstellungen in config.json.",
        "alerts.filters": "Filtert Warnungskarten nach allen, Fehlern oder Warnungen. Das verändert nur die sichtbare Liste.",
        "events.list": "Jüngste Playback- und RAAT-Ereignisse, aus Logmustern abgeleitet.",
        "source.path": "Vollständiger Pfad zur überwachten Logdatei.",
        "source.status": "Aktueller Watcher-Status dieser Datei. Rotierte Archivdateien werden nicht live überwacht.",
        "health.detail.signal": "Einzelnes Signal, das zum Health-Score beiträgt, inklusive Schweregrad, Anzahl, Quelle oder Schwelle, wenn verfügbar.",
        "health.detail.systemRow": "Lokaler Systemwert aus macOS. Manche Felder zeigen --, wenn sie nicht verfügbar sind oder aus Effizienzgründen übersprungen werden."
      }
    };

    const HELP_ICON_SVG = `
      <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
        <path d="M11 18h2v-2h-2v2ZM12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2Zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8Zm0-14c-2.21 0-4 1.79-4 4h2c0-1.1.9-2 2-2s2 .9 2 2c0 2-3 1.75-3 5h2c0-2.25 3-2.5 3-5 0-2.21-1.79-4-4-4Z"></path>
      </svg>
    `;

    function t(key) {
      return I18N[state.language]?.[key] || I18N.en[key] || key;
    }

    function applyI18n() {
      document.documentElement.lang = state.language;
      document.querySelectorAll("[data-i18n]").forEach(element => {
        element.textContent = t(element.dataset.i18n);
      });
      document.querySelectorAll("[data-i18n-placeholder]").forEach(element => {
        element.placeholder = t(element.dataset.i18nPlaceholder);
      });
      document.querySelectorAll("[data-i18n-title]").forEach(element => {
        element.title = t(element.dataset.i18nTitle);
      });
      applyHelpI18n();
    }

    const activeLocale = () => state.language === "de" ? "de-DE" : "en-US";

    const fmtTime = value => {
      if (!value) return "--";
      return new Date(value).toLocaleTimeString(activeLocale(), { hour: "2-digit", minute: "2-digit", second: "2-digit" });
    };

    const escapeHTML = value => String(value ?? "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;");

    function helpText(key) {
      return HELP[state.language]?.[key] || HELP.en[key] || key;
    }

    function help(key, extraClass = "") {
      const text = helpText(key);
      const label = `${helpText("common.iconLabel")}: ${text}`;
      const classes = `help-icon ${extraClass}`.trim();
      return `<span class="${classes}" tabindex="0" role="button" data-help="${escapeHTML(key)}" data-tooltip="${escapeHTML(text)}" aria-label="${escapeHTML(label)}">${HELP_ICON_SVG}</span>`;
    }

    function applyHelpI18n() {
      document.querySelectorAll("[data-help]").forEach(element => {
        const text = helpText(element.dataset.help);
        const label = `${helpText("common.iconLabel")}: ${text}`;
        if (!element.querySelector("svg")) {
          element.innerHTML = HELP_ICON_SVG;
        }
        element.dataset.tooltip = text;
        element.removeAttribute("title");
        element.setAttribute("aria-label", label);
      });
    }

    function helpTooltipElement() {
      let element = document.getElementById("helpTooltip");
      if (!element) {
        element = document.createElement("div");
        element.id = "helpTooltip";
        element.className = "help-tooltip";
        element.hidden = true;
        document.body.appendChild(element);
      }
      return element;
    }

    let pinnedHelpTooltipTarget = { current: null };

    function showHelpTooltip(target, options = {}) {
      const text = target?.dataset?.tooltip || "";
      if (!text) return;
      if (options.pin) pinnedHelpTooltipTarget.current = target;
      const tooltip = helpTooltipElement();
      tooltip.textContent = text;
      tooltip.hidden = false;
      tooltip.style.left = "0px";
      tooltip.style.top = "0px";

      const targetRect = target.getBoundingClientRect();
      const tooltipRect = tooltip.getBoundingClientRect();
      const margin = 8;
      let left = targetRect.left + targetRect.width / 2 - tooltipRect.width / 2;
      left = Math.max(margin, Math.min(left, window.innerWidth - tooltipRect.width - margin));

      let top = targetRect.bottom + margin;
      if (top + tooltipRect.height > window.innerHeight - margin) {
        top = targetRect.top - tooltipRect.height - margin;
      }
      top = Math.max(margin, Math.min(top, window.innerHeight - tooltipRect.height - margin));

      tooltip.style.left = `${Math.round(left)}px`;
      tooltip.style.top = `${Math.round(top)}px`;
    }

    function hideHelpTooltip(options = {}) {
      if (pinnedHelpTooltipTarget.current && !options.force) return;
      const tooltip = document.getElementById("helpTooltip");
      if (tooltip) tooltip.hidden = true;
      pinnedHelpTooltipTarget.current = null;
    }

    const STATIC_HELP_TARGETS = [
      ["#serverState", "top.server"],
      ["#serverName", "top.serverName", "append"],
      ["#localPort", "top.localPort"],
      ["#uptime", "top.uptime"],
      ["#sinceLabel", "top.since"],
      ["#updatedAt", "top.updated"],
      ["#sourceCount", "sources.count"],
      ["#exportLogs", "action.exportLogs"],
      ["#openSettings", "action.settings"],
      ['[data-i18n="section.runtimeHealth"]', "section.runtimeHealth"],
      ['[data-i18n="section.sources"]', "section.sources"],
      ['[data-i18n="section.memoryResources"]', "section.memoryResources"],
      ['[data-i18n="section.alerts"]', "section.alerts"],
      ['[data-i18n="section.playbackRaat"]', "section.playbackRaat"],
      ["#pauseStream", "logs.pause"],
      ['[data-i18n="label.level"]', "logs.level"],
      ["#searchInput", "logs.search"],
      [".checkbox-label", "logs.regex", "append"],
      ["#clearSearch", "logs.clear"],
      ["#chartRange", "chart.range"],
      ['[data-i18n="chart.logVolume"]', "chart.volume"],
      ["#chartBucketLabel", "chart.bucket"],
      ['[data-i18n="chart.total"]', "chart.legend.total"],
      ['[data-i18n="chart.warning"]', "chart.legend.warning"],
      ['[data-i18n="chart.error"]', "chart.legend.error"],
      ['[data-i18n="health.trend"]', "health.trend"],
      ['[data-i18n="health.signals"]', "health.signals"],
      ['[data-i18n="health.system"]', "health.system"],
      ['[data-i18n="health.sourceHealth"]', "health.sourceHealth"],
      ['[data-i18n="settings.language"]', "settings.language"],
      ['[data-i18n="settings.dashboardPort"]', "settings.dashboardPort"],
      ['[data-i18n="settings.pollingInterval"]', "settings.pollingInterval"],
      ['[data-i18n="settings.maxFiles"]', "settings.maxFiles"],
      ['[data-i18n="settings.recentLogs"]', "settings.recentLogs"],
      ['[data-i18n="settings.historyLogs"]', "settings.historyLogs"],
      ['[data-i18n="settings.maxLogLineLength"]', "settings.maxLogLineLength"],
      ['[data-i18n="settings.alertDedupe"]', "settings.alertDedupe"],
      ['[data-i18n="settings.logStaleWarning"]', "settings.logStaleWarning"],
      ['[data-i18n="settings.logStaleCritical"]', "settings.logStaleCritical"],
      ['[data-i18n="settings.raatWarningDisconnects"]', "settings.raatWarningDisconnects"],
      ['[data-i18n="settings.raatCriticalDisconnects"]', "settings.raatCriticalDisconnects"],
      ['[data-i18n="settings.diskWarningGB"]', "settings.diskWarningGB"],
      ['[data-i18n="settings.diskCriticalGB"]', "settings.diskCriticalGB"],
      ['[data-i18n="settings.cpuWarning"]', "settings.cpuWarning"],
      ['[data-i18n="settings.processMemoryWarning"]', "settings.processMemoryWarning"],
      ['[data-i18n="settings.logVolumeWindow"]', "settings.logVolumeWindow"],
      ['[data-i18n="settings.baseDirectory"]', "settings.baseDirectory"],
      ['[data-i18n="settings.manualDirs"]', "settings.manualDirs"],
      ['[data-i18n="settings.filenameIncludes"]', "settings.filenameIncludes"],
      ['[data-i18n="settings.autoDiscover"]', "settings.autoDiscover"],
      ['[data-i18n="settings.demoFeed"]', "settings.demoFeed"],
      ['[data-i18n="settings.watchFromEnd"]', "settings.watchFromEnd"],
      ['[data-i18n="settings.notifications"]', "settings.notifications"],
      ['[data-i18n="settings.showAll"]', "settings.showAll"],
      ["#reloadConfig", "settings.reload"],
      ['#settingsForm button[type="submit"]', "settings.save"],
      ['[data-i18n="action.saveSources"]', "settings.save"],
      ['[data-i18n="action.exportIncident"]', "action.exportIncident"],
      ["#sourceAutoDiscover + span", "settings.autoDiscover"],
    ];

    function installStaticHelp() {
      STATIC_HELP_TARGETS.forEach(([selector, key, placement = "after"]) => {
        document.querySelectorAll(selector).forEach(target => {
          if (target.dataset.helpHost === key) return;
          target.dataset.helpHost = key;
          const html = help(key, helpClasses(target));
          if (placement === "append") {
            target.insertAdjacentHTML("beforeend", html);
          } else {
            target.insertAdjacentHTML("afterend", html);
          }
          const label = target.closest("label");
          if (label && (label.closest(".settings-form") || label.closest(".source-form"))) {
            label.classList.add("has-help");
          }
        });
      });
      applyHelpI18n();
    }

    function helpClasses(target) {
      return [
        needsLeftTooltip(target) ? "tooltip-left" : "",
        needsBelowTooltip(target) ? "tooltip-below" : ""
      ].filter(Boolean).join(" ");
    }

    function needsLeftTooltip(target) {
      return Boolean(target.closest(".left-rail") || target.closest(".log-table") || target.closest(".chart-toolbar"));
    }

    function needsBelowTooltip(target) {
      return Boolean(target.closest(".topbar"));
    }

    const sourceName = value => String(value || "RoonServer").replace(/^.*\\//, "");

    function sourceFileName(item) {
      const value = String(item?.path || item?.name || "");
      const slash = Math.max(value.lastIndexOf("/"), value.lastIndexOf("\\\\"));
      return slash >= 0 ? value.slice(slash + 1) : value;
    }

    function isDemoSource(item) {
      const path = String(item?.path || "");
      return item?.status === "demo" || path.startsWith("/Demo/");
    }

    function isRotatedLogSource(item) {
      const fileName = sourceFileName(item).toLowerCase();
      const dot = fileName.lastIndexOf(".");
      const stem = dot > 0 ? fileName.slice(0, dot) : fileName;
      const suffixStart = stem.lastIndexOf(".");
      if (suffixStart < 0) return false;
      const suffix = stem.slice(suffixStart + 1);
      return /^\\d+$/.test(suffix);
    }

    function isCurrentSource(item) {
      if (isDemoSource(item)) return true;
      return !isRotatedLogSource(item);
    }

    function splitSources(sources = []) {
      const current = [];
      const inactive = [];
      for (const source of sources) {
        (isCurrentSource(source) ? current : inactive).push(source);
      }
      return { current, inactive };
    }

    function sourceActivityLabel(item) {
      if (isDemoSource(item)) return t("demo");
      if (item?.status === "live") return t("live");
      if (item?.lastSeenAt) return `${t("sources.lastSeen")} ${fmtTime(item.lastSeenAt)}`;
      return isRotatedLogSource(item) ? t("sources.inactive") : t("waiting");
    }
    const portFromURL = value => {
      try { return new URL(value).port || "--"; } catch { return "--"; }
    };

    function setText(id, value) {
      const element = document.getElementById(id);
      if (element) element.textContent = value;
    }

    function setValue(id, value) {
      const element = document.getElementById(id);
      if (element) element.value = value ?? "";
    }

    function setChecked(id, value) {
      const element = document.getElementById(id);
      if (element) element.checked = Boolean(value);
    }

    function saveUIState() {
      try {
        localStorage.setItem(UI_STATE_KEY, JSON.stringify({
          level: state.level,
          levelDefaultVersion: LEVEL_DEFAULT_VERSION,
          autoScroll: state.autoScroll,
          alertFilter: state.alertFilter,
          volumeWindowMinutes: state.volumeWindowMinutes
        }));
      } catch {
        // Ignore storage errors in private windows or restricted browser contexts.
      }
    }

    function applyUIStateToControls() {
      setValue("levelFilter", state.level);
      setChecked("autoScrollToggle", state.autoScroll);
      setValue("chartRange", String(state.volumeWindowMinutes));
      setValue("configVolumeWindow", String(state.volumeWindowMinutes));
      document.querySelectorAll("[data-alert-filter]").forEach(button => {
        button.classList.toggle("active", button.dataset.alertFilter === state.alertFilter);
      });
    }

    function setVolumeWindow(value, persist = true) {
      const minutes = Number(value);
      state.volumeWindowMinutes = supportedWindows.includes(minutes) ? minutes : 60;
      state.hasStoredVolumeWindow = state.hasStoredVolumeWindow || persist;
      if (state.volumeChartScaleWindow !== state.volumeWindowMinutes) {
        state.volumeChartScaleEnd = 0;
        state.volumeChartScaleMax = 20;
        state.volumeChartScaleWindow = state.volumeWindowMinutes;
      }
      setValue("chartRange", String(state.volumeWindowMinutes));
      setValue("configVolumeWindow", String(state.volumeWindowMinutes));
      if (persist) saveUIState();
    }

    function renderList(id, items, render, empty = "No data") {
      const element = document.getElementById(id);
      if (!element) return;
      element.innerHTML = items && items.length ? items.map(render).join("") : `<div class="empty">${empty}</div>`;
    }

    function uptime(runStartedAt) {
      const started = new Date(runStartedAt).getTime();
      if (!Number.isFinite(started)) return "--";
      const total = Math.max(0, Math.floor((Date.now() - started) / 1000));
      const hours = Math.floor(total / 3600);
      const minutes = Math.floor((total % 3600) / 60);
      const seconds = total % 60;
      return `${hours}h ${minutes}m ${seconds}s`;
    }

    function levelFromLine(item) {
      const severity = String(item.severity || "").toLowerCase();
      if (severity === "critical") return "critical";
      if (severity === "warning") return "warning";
      if (severity === "info") {
        const text = String(item.text || "").toLowerCase();
        if (text.includes("debug") || text.includes("trace")) return "debug";
        return "info";
      }
      const text = String(item.text || "").toLowerCase();
      if (text.includes("fatal") || text.includes("panic") || text.includes("corrupt")) return "critical";
      if (text.includes("warning") || text.includes("timeout")) return "warning";
      if (text.includes("debug") || text.includes("trace")) return "debug";
      return "info";
    }

    function messageWithoutPrefix(text) {
      return String(text || "").replace(/^\\d{2}\\/\\d{2}\\s+\\d{2}:\\d{2}:\\d{2}\\s+/, "");
    }

    function matchesQuery(item) {
      if (!state.query) return true;
      const text = String(item.text || "");
      const query = state.query;
      if (document.getElementById("regexInput")?.checked) {
        try {
          return new RegExp(query, "i").test(text);
        } catch {
          return text.toLowerCase().includes(query.toLowerCase());
        }
      }
      return text.toLowerCase().includes(query.toLowerCase());
    }

    function filterLogItems(logs) {
      return (logs || []).filter(item => {
        if (state.clearedThroughLogId && item.id <= state.clearedThroughLogId) return false;
        const level = levelFromLine(item);
        const matchesLevel = state.level === "all"
          || state.level === level
          || (state.level === "warningCritical" && (level === "warning" || level === "critical"));
        return matchesLevel && matchesQuery(item);
      });
    }

    function currentExportLogs() {
      const snapshot = state.lastSnapshot || {};
      return filterLogItems(snapshot.recentLogs || []);
    }

    function updateStreamStatus(totalLogs = 0, visibleLogs = 0) {
      const parts = [];
      if (state.paused) {
        const buffered = state.bufferedCount ? ` · ${state.bufferedCount} ${t("status.buffered")}` : "";
        parts.push(`${t("status.paused")}${buffered}`);
      }
      if (!state.autoScroll) parts.push(t("status.autoScrollOff"));
      if (Date.now() < state.clearStatusUntil) parts.push(t("status.cleared"));
      if (state.query || state.level !== "all") parts.push(`${t("status.filtered")}: ${visibleLogs}/${totalLogs}`);

      const status = document.getElementById("streamStatus");
      if (status) {
        status.hidden = parts.length === 0;
        status.textContent = parts.join(" · ");
      }

      const pause = document.getElementById("pauseStream");
      if (pause) {
        pause.textContent = state.paused ? "▶" : "Ⅱ";
        pause.classList.toggle("is-paused", state.paused);
      }

      const auto = document.getElementById("autoScrollToggle");
      if (auto) auto.checked = state.autoScroll;
    }

    function applyAutoScroll() {
      if (!state.autoScroll || state.paused) return;
      const wrap = document.querySelector(".log-table-wrap");
      if (wrap) wrap.scrollTop = 0;
    }

    function captureScrollAnchor() {
      if (state.autoScroll) return null;
      const wrap = document.querySelector(".log-table-wrap");
      if (!wrap) return null;
      const wrapTop = wrap.getBoundingClientRect().top;
      const rows = Array.from(wrap.querySelectorAll("tr[data-log-id]"));
      const row = rows.find(candidate => candidate.getBoundingClientRect().bottom > wrapTop + 32);
      if (!row) return { scrollTop: wrap.scrollTop };
      return {
        id: Number(row.dataset.logId),
        offset: row.getBoundingClientRect().top - wrapTop,
        scrollTop: wrap.scrollTop
      };
    }

    function restoreScrollAnchor(anchor) {
      if (!anchor || state.autoScroll) return;
      const wrap = document.querySelector(".log-table-wrap");
      if (!wrap) return;
      const row = Number.isFinite(anchor.id) ? wrap.querySelector(`tr[data-log-id="${anchor.id}"]`) : null;
      if (!row) {
        wrap.scrollTop = anchor.scrollTop || 0;
        return;
      }
      const wrapTop = wrap.getBoundingClientRect().top;
      wrap.scrollTop += row.getBoundingClientRect().top - wrapTop - anchor.offset;
    }

    function render(snapshot) {
      state.lastSnapshot = snapshot;
      state.pendingSnapshot = null;
      state.bufferedCount = 0;
      const alerts = snapshot.alerts || [];
      const logs = snapshot.recentLogs || [];
      const chartData = snapshot.volumeBuckets || logs;
      const playback = snapshot.playback || [];

      setText("serverState", snapshot.mode === "idle" ? t("idle") : t("connected"));
      setText("serverName", snapshot.mode === "demo" ? t("serverDemo") : t("serverRoon"));
      setText("localPort", portFromURL(snapshot.dashboardURL));
      setText("uptime", uptime(snapshot.runStartedAt));
      setText("sinceLabel", `${t("since")} ${fmtTime(snapshot.runStartedAt)}`);
      setText("updatedAt", fmtTime(snapshot.generatedAt));
      setText("allAlertCount", alerts.length);
      setText("warningAlertCount", alerts.filter(item => item.severity === "warning").length);
      setText("errorAlertCount", alerts.filter(item => item.severity === "critical").length);

      renderRuntime(snapshot);
      renderSources(snapshot);
      renderResources(snapshot);
      renderMemoryTrend(snapshot);
      const visibleLogCount = renderLogs(logs);
      renderAlerts(alerts);
      renderPlayback(playback);
      renderChart(chartData);
      updateStreamStatus(logs.length, visibleLogCount);
      renderSourcePanel(snapshot);
      renderHealthDetail(snapshot);
      maybeOpenSourcePrompt(snapshot);
    }

    async function loadConfig() {
      const response = await fetch("/api/config", { cache: "no-store" });
      state.configDocument = await response.json();
      fillSettings(state.configDocument);
      if (state.lastSnapshot && !state.paused) render(state.lastSnapshot);
      return state.configDocument;
    }

    function fillSettings(document) {
      const config = document?.config || {};
      state.language = config.language || state.language || "en";
      applyI18n();
      setText("configPath", document?.configPath || t("configPathUnavailable"));
      setValue("configLanguage", state.language);
      setValue("configPort", config.dashboardPort);
      setValue("configPoll", config.pollIntervalSeconds);
      setValue("configMaxFiles", config.maxFilesPerDirectory);
      setValue("configRecentLogs", config.recentLogMaxLines);
      setValue("configHistoryLogs", config.logHistoryMaxLines);
      setValue("configMaxLineLength", config.maxLogLineCharacters);
      setValue("configDedupe", config.alertDedupeSeconds);
      const rules = config.healthRules || {};
      setValue("configLogStaleWarning", rules.logStaleWarningSeconds ?? 180);
      setValue("configLogStaleCritical", rules.logStaleCriticalSeconds ?? 600);
      setValue("configRaatWarning", rules.raatWarningDisconnects ?? 2);
      setValue("configRaatCritical", rules.raatCriticalDisconnects ?? 5);
      setValue("configDiskWarningGB", Number((rules.diskWarningFreeMB ?? 10240) / 1024).toFixed(1));
      setValue("configDiskCriticalGB", Number((rules.diskCriticalFreeMB ?? 2048) / 1024).toFixed(1));
      setValue("configCPUWarning", rules.processCPUWarningPercent ?? 80);
      setValue("configProcessMemoryWarning", rules.processMemoryWarningMB ?? 4096);
      setVolumeWindow(state.hasStoredVolumeWindow ? state.volumeWindowMinutes : (config.logVolumeWindowMinutes || 60), false);
      setValue("configBase", config.baseDirectory);
      setValue("configDirs", (config.logDirectories || []).join("\\n"));
      setValue("configIncludes", (config.fileNameIncludes || []).join(", "));
      setChecked("configAutoDiscover", config.autoDiscoverRoonLogDirectories);
      setChecked("configDemo", config.enableDemoModeWhenNoLogs);
      setChecked("configFromEnd", config.watchExistingLogsFromEnd);
      setChecked("configNotifications", config.sendMacNotifications);
      setChecked("configShowAll", config.showAllLogLines);
      setText("settingsStatus", document?.lastError ? `${t("usingDefaults")}: ${document.lastError}` : "");
      fillSourceForm(config);
      applyUIStateToControls();
    }

    function readSettings() {
      const current = state.configDocument?.config || {};
      return {
        ...current,
        language: document.getElementById("configLanguage").value || "en",
        dashboardPort: Number(document.getElementById("configPort").value || 17666),
        pollIntervalSeconds: Number(document.getElementById("configPoll").value || 0.75),
        maxFilesPerDirectory: Number(document.getElementById("configMaxFiles").value || 50),
        recentLogMaxLines: Number(document.getElementById("configRecentLogs").value || 500),
        logHistoryMaxLines: Number(document.getElementById("configHistoryLogs").value || 5000),
        maxLogLineCharacters: Number(document.getElementById("configMaxLineLength").value || 2000),
        alertDedupeSeconds: Number(document.getElementById("configDedupe").value || 45),
        healthRules: {
          ...(current.healthRules || {}),
          logStaleWarningSeconds: Number(document.getElementById("configLogStaleWarning").value || 180),
          logStaleCriticalSeconds: Number(document.getElementById("configLogStaleCritical").value || 600),
          raatWarningDisconnects: Number(document.getElementById("configRaatWarning").value || 2),
          raatCriticalDisconnects: Number(document.getElementById("configRaatCritical").value || 5),
          diskWarningFreeMB: Number(document.getElementById("configDiskWarningGB").value || 10) * 1024,
          diskCriticalFreeMB: Number(document.getElementById("configDiskCriticalGB").value || 2) * 1024,
          processCPUWarningPercent: Number(document.getElementById("configCPUWarning").value || 80),
          processMemoryWarningMB: Number(document.getElementById("configProcessMemoryWarning").value || 4096)
        },
        logVolumeWindowMinutes: Number(document.getElementById("configVolumeWindow").value || state.volumeWindowMinutes || 60),
        baseDirectory: document.getElementById("configBase").value || "/Volumes/Data",
        logDirectories: document.getElementById("configDirs").value.split(/\\r?\\n/).map(item => item.trim()).filter(Boolean),
        fileNameIncludes: document.getElementById("configIncludes").value.split(",").map(item => item.trim()).filter(Boolean),
        autoDiscoverRoonLogDirectories: document.getElementById("configAutoDiscover").checked,
        enableDemoModeWhenNoLogs: document.getElementById("configDemo").checked,
        watchExistingLogsFromEnd: document.getElementById("configFromEnd").checked,
        sendMacNotifications: document.getElementById("configNotifications").checked,
        showAllLogLines: document.getElementById("configShowAll").checked
      };
    }

    function openSettings() {
      const panel = document.getElementById("settingsPanel");
      if (panel) panel.hidden = false;
      loadConfig().catch(error => setText("settingsStatus", `Could not load config: ${error.message}`));
    }

    function closeSettings() {
      const panel = document.getElementById("settingsPanel");
      if (panel) panel.hidden = true;
    }

    async function saveSettings() {
      const response = await fetch("/api/config", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(readSettings())
      });
      const document = await response.json();
      if (!response.ok) throw new Error(document.message || "Config save failed");
      state.configDocument = document;
      fillSettings(document);
      setText("settingsStatus", t("savedMessage"));
    }

    function fillSourceForm(config = state.configDocument?.config || {}) {
      setChecked("sourceAutoDiscover", config.autoDiscoverRoonLogDirectories);
      setValue("sourceDirs", (config.logDirectories || []).join("\\n"));
    }

    function isSourcePromptDismissed() {
      try {
        return localStorage.getItem(SOURCE_PROMPT_KEY) === "1";
      } catch {
        return false;
      }
    }

    function dismissSourcePrompt() {
      try {
        localStorage.setItem(SOURCE_PROMPT_KEY, "1");
      } catch {
        // Ignore storage errors; the prompt is still guarded for this page lifetime.
      }
    }

    function openSources(options = {}) {
      const panel = document.getElementById("sourcePanel");
      if (panel) panel.hidden = false;
      renderSourcePanel(state.lastSnapshot);
      loadConfig()
        .then(document => {
          fillSourceForm(document.config || {});
          renderSourcePanel(state.lastSnapshot);
          if (options.prompt) setText("sourceStatus", t("sources.firstRunHint"));
        })
        .catch(error => setText("sourceStatus", error.message));
    }

    function closeSources() {
      const panel = document.getElementById("sourcePanel");
      if (panel) panel.hidden = true;
      dismissSourcePrompt();
    }

    function maybeOpenSourcePrompt(snapshot) {
      if (state.sourcePromptShown || isSourcePromptDismissed()) return;
      const sourcePanel = document.getElementById("sourcePanel");
      const settingsPanel = document.getElementById("settingsPanel");
      if ((sourcePanel && !sourcePanel.hidden) || (settingsPanel && !settingsPanel.hidden)) return;

      const config = state.configDocument?.config || {};
      const sources = snapshot?.watchedSources || [];
      const realSources = sources.filter(item => {
        const path = String(item.path || "");
        return item.status !== "demo" && !path.startsWith("/Demo/");
      });
      const hasConfiguredSources = (config.logDirectories || []).length > 0;
      if (realSources.length || hasConfiguredSources) return;

      state.sourcePromptShown = true;
      openSources({ prompt: true });
    }

    function sourceDetailRow(item, inactive = false) {
      return `
        <div class="source-detail-row ${inactive ? "inactive" : ""}">
          <strong class="label-with-help">${escapeHTML(sourceName(item.name))}${help("source.status")}</strong>
          <span>${escapeHTML(sourceActivityLabel(item))} · ${item.isReadable === false ? t("health.notReadable") : t("health.readable")} · ${fmtTime(item.lastSeenAt)}</span>
          <span>${item.fileSizeBytes ? formatBytes(item.fileSizeBytes) : "--"}${item.lastModifiedAt ? ` · ${t("health.lastModified")}: ${fmtTime(item.lastModifiedAt)}` : ""}</span>
          <code class="label-with-help">${escapeHTML(item.path)}${help("source.path")}</code>
        </div>
      `;
    }

    function renderSourcePanel(snapshot = state.lastSnapshot) {
      const panel = document.getElementById("sourcePanel");
      if (!panel || panel.hidden) return;

      const config = state.configDocument?.config || {};
      const sources = snapshot?.watchedSources || [];
      const grouped = splitSources(sources);
      const autoText = config.autoDiscoverRoonLogDirectories ? t("sources.autoDiscoveryOn") : t("sources.autoDiscoveryOff");
      setText("sourceModalSummary", `${grouped.current.length} ${t("sources.currentShort")} · ${grouped.inactive.length} ${t("sources.inactiveShort")} · ${autoText}`);

      const list = document.getElementById("sourceModalList");
      if (!list) return;
      if (!sources.length) {
        list.innerHTML = `<div class="empty">${t("sources.noWatchedSources")}</div>`;
        return;
      }

      list.innerHTML = `
        <div class="source-detail-section">
          <div class="source-detail-heading">${t("sources.current")} · ${grouped.current.length}</div>
          ${grouped.current.length ? grouped.current.map(item => sourceDetailRow(item)).join("") : `<div class="empty">${t("sources.noCurrentSources")}</div>`}
        </div>
        ${grouped.inactive.length ? `
          <details class="source-detail-section">
            <summary>${t("sources.inactive")} · ${grouped.inactive.length}</summary>
            ${grouped.inactive.map(item => sourceDetailRow(item, true)).join("")}
          </details>
        ` : ""}
      `;
    }

    async function saveSources() {
      const current = state.configDocument?.config || {};
      const next = {
        ...current,
        autoDiscoverRoonLogDirectories: document.getElementById("sourceAutoDiscover").checked,
        logDirectories: document.getElementById("sourceDirs").value.split(/\\r?\\n/).map(item => item.trim()).filter(Boolean)
      };
      const response = await fetch("/api/config", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(next)
      });
      const configDocument = await response.json();
      if (!response.ok) throw new Error(configDocument.message || "Source save failed");
      state.configDocument = configDocument;
      fillSettings(configDocument);
      await fetch("/api/watch/reload", { method: "POST" }).catch(() => {});
      renderSourcePanel(state.lastSnapshot);
      dismissSourcePrompt();
      setText("sourceStatus", t("status.sourcesReloaded"));
    }

    function healthStateLabel(stateName) {
      return t(`health.state.${stateName || "unknown"}`);
    }

    function ageLabel(seconds) {
      const value = Number(seconds);
      if (!Number.isFinite(value)) return "--";
      if (value < 5) return t("health.now");
      if (value < 90) return `${Math.round(value)}${t("health.secondsAgo")}`;
      if (value < 5400) return `${Math.round(value / 60)}${t("health.minutesAgo")}`;
      return `${Math.round(value / 3600)}${t("health.hoursAgo")}`;
    }

    function signalTitle(signal) {
      const key = `health.${signal.id}`;
      const translated = t(key);
      return translated === key ? (signal.title || signal.id) : translated;
    }

    function signalDetail(signal) {
      const parts = [];
      if (signal.count) parts.push(`${signal.count}×`);
      if (signal.windowMinutes) parts.push(`${Math.round(signal.windowMinutes)}m`);
      if (Number.isFinite(signal.ageSeconds)) parts.push(ageLabel(signal.ageSeconds));
      if (Number.isFinite(signal.valueMB)) parts.push(formatResource(signal.valueMB, "MB"));
      if (Number.isFinite(signal.deltaMB)) parts.push(`+${formatResource(signal.deltaMB, "MB")}`);
      if (Number.isFinite(signal.thresholdMB)) parts.push(`≤ ${formatResource(signal.thresholdMB, "MB")}`);
      if (signal.zone) parts.push(signal.zone);
      return parts.join(" · ");
    }

    function relevantHealthSignals(health) {
      const signals = health?.signals || [];
      const actionable = signals.filter(signal => signal.severity !== "info" || Number(signal.impact || 0) > 0);
      return actionable.length ? actionable : signals.filter(signal => ["logs.fresh", "source.active", "disk.ok"].includes(signal.id)).slice(0, 3);
    }

    function healthTrendBars(points = [], limit = 24) {
      const rows = points.slice(-limit);
      if (!rows.length) return "";
      return rows.map(point => {
        const score = Math.max(0, Math.min(100, Number(point.score || 0)));
        return `<span class="${escapeHTML(point.state || "unknown")}" style="--h:${Math.max(6, score)}" title="${fmtTime(point.time)} · ${score}"></span>`;
      }).join("");
    }

    function renderRoonHealth(health = {}) {
      const element = document.getElementById("roonHealth");
      if (!element) return;
      const stateName = health.state || "unknown";
      const score = Number.isFinite(health.score) ? health.score : "--";
      const signals = relevantHealthSignals(health).slice(0, 3);
      const lastLog = Number.isFinite(health.lastLogAgeSeconds)
        ? `${t("health.lastLog")}: ${ageLabel(health.lastLogAgeSeconds)}`
        : t("health.logs.none");

      element.className = `roon-health ${stateName}`;
      element.innerHTML = `
        <div class="roon-health-top">
          <div class="health-score-wrap"><div class="health-score">${score}</div></div>
          <div>
            <div class="health-title">
              <span class="label-with-help">${t("health.title")}${help("health.score")}</span>
              <span class="health-state value-with-help">${healthStateLabel(stateName)}${help("health.state")}</span>
            </div>
            <div class="health-summary">${escapeHTML(lastLog)}</div>
          </div>
        </div>
        <div class="health-signals">
          ${(signals.length ? signals : [{ id: "health.noSignals", severity: "info", title: t("health.noSignals") }]).map(signal => {
            const detail = signalDetail(signal);
            return `<div class="health-signal ${escapeHTML(signal.severity || "info")}"><span>${escapeHTML(signalTitle(signal))}${detail ? ` · ${escapeHTML(detail)}` : ""}</span></div>`;
          }).join("")}
        </div>
        <div class="health-trend" aria-label="${escapeHTML(helpText("health.trend"))}">${healthTrendBars(state.lastSnapshot?.healthTrend || [], 24)}</div>
      `;
    }

    function openHealthDetails() {
      const panel = document.getElementById("healthPanel");
      if (panel) panel.hidden = false;
      renderHealthDetail(state.lastSnapshot);
    }

    function closeHealthDetails() {
      const panel = document.getElementById("healthPanel");
      if (panel) panel.hidden = true;
    }

    function renderHealthDetail(snapshot = state.lastSnapshot) {
      const panel = document.getElementById("healthPanel");
      if (!panel || panel.hidden || !snapshot) return;
      const health = snapshot.health || {};
      setText("healthDetailSummary", `${healthStateLabel(health.state || "unknown")} · ${t("health.score")} ${health.score ?? "--"} · ${health.summary || ""}`);

      const trend = document.getElementById("healthTrendDetail");
      if (trend) {
        const bars = healthTrendBars(snapshot.healthTrend || [], 48);
        trend.innerHTML = bars || `<div class="empty">${t("health.noTrend")}</div>`;
      }

      renderList("healthSignalList", health.signals || [], signal => {
        const detail = signalDetail(signal);
        return `
          <div class="health-detail-row ${escapeHTML(signal.severity || "info")}">
            <strong class="label-with-help">${escapeHTML(signalTitle(signal))}${help("health.detail.signal")}</strong>
            <span>${escapeHTML(signal.message || "")}</span>
            ${detail ? `<span>${escapeHTML(detail)}</span>` : ""}
            ${signal.source ? `<code>${escapeHTML(signal.source)}</code>` : ""}
          </div>
        `;
      }, t("health.noSignals"));

      renderSystemDetails(snapshot.system);
      renderSourceDetails(snapshot.watchedSources || []);
    }

    function renderSystemDetails(system) {
      if (!system) {
        renderList("healthSystemList", [], () => "", t("health.noSystem"));
        return;
      }
      const rows = [
        [system.host?.isRoonServerLikely ? t("health.hostDetected") : t("health.hostNotDetected"), system.host?.reason || ""],
        [t("health.processes"), `${system.processes?.length || 0}`],
        [t("health.cpu"), `${Number(system.totalCPUPercent || 0).toFixed(1)}%`],
        [t("health.memory"), formatResource(system.totalMemoryMB || 0, "MB")],
        [t("health.openFiles"), system.openFileCount ?? "--"],
        [t("health.diskFree"), system.logVolumeFreeMB ? `${formatResource(system.logVolumeFreeMB, "MB")} · ${system.logVolumePath || ""}` : "--"]
      ];
      const processRows = (system.processes || []).map(process => [
        process.name,
        `pid ${process.pid} · ${Number(process.cpuPercent || 0).toFixed(1)}% CPU · ${formatResource(process.memoryMB || 0, "MB")}${process.openFiles ? ` · ${process.openFiles} ${t("health.openFiles")}` : ""}`
      ]);
      renderList("healthSystemList", rows.concat(processRows), row => `
        <div class="health-detail-row">
          <strong class="label-with-help">${escapeHTML(row[0])}${help("health.detail.systemRow")}</strong>
          <span>${escapeHTML(row[1])}</span>
        </div>
      `);
    }

    function renderSourceDetails(sources) {
      const element = document.getElementById("healthSourceList");
      if (!element) return;
      if (!sources.length) {
        element.innerHTML = `<div class="empty">${t("sources.noWatchedSources")}</div>`;
        return;
      }

      const grouped = splitSources(sources);
      const row = (source, inactive = false) => {
        const readable = source.isReadable === false ? t("health.notReadable") : t("health.readable");
        const modified = source.lastModifiedAt ? `${t("health.lastModified")}: ${fmtTime(source.lastModifiedAt)}` : "";
        const size = source.fileSizeBytes ? formatBytes(source.fileSizeBytes) : "--";
        return `
          <div class="health-detail-row ${source.isReadable === false ? "critical" : ""} ${inactive ? "inactive" : ""}">
            <strong class="label-with-help">${escapeHTML(sourceName(source.name))}${help("source.status")}</strong>
            <span>${escapeHTML(readable)} · ${escapeHTML(sourceActivityLabel(source))} · ${escapeHTML(size)}${modified ? ` · ${escapeHTML(modified)}` : ""}</span>
            <code class="label-with-help">${escapeHTML(source.path)}${help("source.path")}</code>
          </div>
        `;
      };

      element.innerHTML = `
        <div class="source-detail-section">
          <div class="source-detail-heading">${t("sources.current")} · ${grouped.current.length}</div>
          ${grouped.current.length ? grouped.current.map(source => row(source)).join("") : `<div class="empty">${t("sources.noCurrentSources")}</div>`}
        </div>
        ${grouped.inactive.length ? `
          <details class="source-detail-section">
            <summary>${t("sources.inactive")} · ${grouped.inactive.length}</summary>
            ${grouped.inactive.map(source => row(source, true)).join("")}
          </details>
        ` : ""}
      `;
    }

    function formatBytes(bytes) {
      const value = Number(bytes || 0);
      if (value >= 1024 * 1024 * 1024) return `${(value / (1024 * 1024 * 1024)).toFixed(2)} GB`;
      if (value >= 1024 * 1024) return `${(value / (1024 * 1024)).toFixed(1)} MB`;
      if (value >= 1024) return `${(value / 1024).toFixed(1)} KB`;
      return `${value} B`;
    }

    function redactPath(value) {
      return String(value || "").replace(/\\/Users\\/[^/]+/g, "/Users/<user>");
    }

    function exportIncidentBundle() {
      const snapshot = state.lastSnapshot || {};
      const config = state.configDocument?.config || {};
      const logs = currentExportLogs().slice(0, 250);
      const safeConfig = {
        ...config,
        baseDirectory: redactPath(config.baseDirectory),
        logDirectories: (config.logDirectories || []).map(redactPath)
      };
      const bundle = {
        exportedAt: new Date().toISOString(),
        app: snapshot.appName || "Roon Log Watcher",
        health: snapshot.health,
        healthTrend: snapshot.healthTrend || [],
        system: snapshot.system,
        sources: snapshot.watchedSources || [],
        counters: snapshot.counters || {},
        alerts: snapshot.alerts || [],
        playback: snapshot.playback || [],
        logs,
        config: safeConfig
      };
      const blob = new Blob([JSON.stringify(bundle, null, 2)], { type: "application/json;charset=utf-8" });
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = url;
      link.download = `roon-health-diagnosis-${new Date().toISOString().replace(/[:.]/g, "-")}.json`;
      document.body.appendChild(link);
      link.click();
      link.remove();
      window.setTimeout(() => URL.revokeObjectURL(url), 1000);
      setText("healthDetailStatus", t("health.exported"));
    }

    function strongestSignal(signals, predicate) {
      const matches = (signals || []).filter(predicate);
      return matches.sort((a, b) => {
        const rank = { critical: 3, warning: 2, info: 1 };
        return (rank[b.severity] || 0) - (rank[a.severity] || 0) || Number(b.impact || 0) - Number(a.impact || 0);
      })[0];
    }

    function rowValueForSignal(signal, fallback) {
      if (!signal) return { value: fallback, severity: "info" };
      if (signal.severity === "critical") return { value: t("health.state.critical"), severity: "critical" };
      if (signal.severity === "warning") return { value: t("watch"), severity: "warning" };
      return { value: fallback, severity: "info" };
    }

    function renderRuntime(snapshot) {
      const counters = snapshot.counters || {};
      const health = snapshot.health || {};
      const signals = health.signals || [];
      renderRoonHealth(health);

      const coreSeverity = health.state === "critical" ? "critical" : health.state === "degraded" ? "warning" : "info";
      const raat = rowValueForSignal(strongestSignal(signals, signal => signal.domain === "raat" && signal.severity !== "info"), counters.processedLines ? t("running") : t("waiting"));
      const database = rowValueForSignal(strongestSignal(signals, signal => signal.domain === "database" && signal.severity !== "info"), t("healthy"));
      const source = rowValueForSignal(strongestSignal(signals, signal => signal.domain === "source" && signal.severity !== "info"), t("watch"));
      const logs = rowValueForSignal(strongestSignal(signals, signal => signal.domain === "logs" && signal.severity !== "info"), snapshot.mode === "idle" ? t("idle") : t("live"));
      const diskSignal = strongestSignal(signals, signal => signal.domain === "disk");
      const disk = diskSignal?.valueMB
        ? { value: `${formatResource(diskSignal.valueMB, "MB")} ${t("free")}`, severity: diskSignal.severity || "info" }
        : { value: t("noData"), severity: "warning" };

      const rows = [
        { icon: "◎", label: t("health.runtime.core"), value: healthStateLabel(health.state || "unknown"), severity: coreSeverity, helpKey: "health.score" },
        { icon: "◇", label: t("health.runtime.raat"), ...raat, helpKey: "settings.raatWarningDisconnects" },
        { icon: "▣", label: t("health.runtime.database"), ...database, helpKey: "health.signals" },
        { icon: "⌁", label: t("health.runtime.fileWatcher"), ...source, helpKey: "section.sources" },
        { icon: "↝", label: t("health.runtime.logIngestion"), ...logs, helpKey: "section.liveLogStream" },
        { icon: "▱", label: t("health.runtime.disk"), ...disk, helpKey: "settings.diskWarningGB" }
      ];
      renderList("runtimeList", rows, row => `
        <div class="health-row ${escapeHTML(row.severity || "info")}">
          <span class="status-icon">${row.icon}</span>
          <span class="row-title label-with-help"><span class="help-label-text">${escapeHTML(row.label)}</span>${help(row.helpKey, "tooltip-left")}</span>
          <span class="row-value value-with-help">${escapeHTML(row.value)}${help(row.helpKey)}</span>
        </div>
      `);
    }

    function renderSources(snapshot) {
      const sources = snapshot.watchedSources || [];
      const grouped = splitSources(sources);
      setText("sourceCount", `${grouped.current.length} ${t("sources.currentShort")} · ${grouped.inactive.length} ${t("sources.inactiveShort")}`);
      renderList("sourceList", grouped.current, item => `
        <div class="source-row ${item.status === "live" ? "live" : "waiting"}">
          <span class="source-check">${item.status === "live" ? "✓" : "•"}</span>
          <span class="row-title label-with-help"><span class="help-label-text">${escapeHTML(sourceName(item.name))}</span>${help("source.path", "tooltip-left")}</span>
          <span class="row-value value-with-help">${escapeHTML(sourceActivityLabel(item))}${help("source.status")}</span>
        </div>
      `, t("sources.noCurrentSources"));
    }

    function renderResources(snapshot) {
      const byMetric = Object.fromEntries((snapshot.memory || []).map(item => [item.metric, item]));
      const physical = byMetric["Physical Memory"]?.valueMB || 0;
      const virtual = byMetric["Virtual Memory"]?.valueMB || 0;
      const managed = byMetric["Managed Memory"]?.valueMB || 0;
      const unmanaged = byMetric["Unmanaged Memory"]?.valueMB || 0;
      const rows = [
        [t("rssMemory"), physical, "MB", Math.min(92, physical / 16), false, "resource.rss"],
        [t("virtualMemory"), virtual, "MB", Math.min(92, virtual / 24), false, "resource.virtual"],
        [t("managedMemory"), managed, "MB", Math.min(92, managed / 12), false, "resource.managed"],
        [t("unmanaged"), unmanaged, "MB", Math.min(92, unmanaged / 14), false, "resource.unmanaged"],
        [t("cpuUsage"), 18.6, "%", 42, true, "resource.cpu"],
        [t("ioWait"), 2.1, "%", 18, true, "resource.ioWait"],
        [t("openFiles"), 1243, "", 55, true, "resource.openFiles"]
      ];
      renderList("resourceList", rows, row => `
        <div class="resource-row">
          <span class="row-title label-with-help"><span class="help-label-text">${escapeHTML(row[0])}</span>${help(row[5], "tooltip-left")}</span>
          <span class="row-value value-with-help">${formatResource(row[1], row[2])}${help(row[5])}</span>
          <span class="row-value value-with-help">${Math.round(row[3])}%${help("resource.percent")}</span>
          ${row[4] ? `<div class="spark">${sparkBars(row[0])}</div>` : `<div class="bar-track"><div class="bar-fill" style="--value:${Math.round(row[3])}%"></div></div>`}
        </div>
      `);
    }

    function renderMemoryTrend(snapshot) {
      const element = document.getElementById("memoryTrendHeader");
      if (!element) return;
      const points = (snapshot.memoryTrend24h || [])
        .map(point => ({
          ...point,
          valueMB: Number(point.valueMB),
          timestamp: new Date(point.time).getTime()
        }))
        .filter(point => Number.isFinite(point.valueMB) && Number.isFinite(point.timestamp))
        .sort((a, b) => a.timestamp - b.timestamp);

      if (!points.length) {
        element.className = "memory-trend-header empty";
        element.innerHTML = `
          <span class="memory-trend-title">${escapeHTML(t("memoryTrend.title"))}</span>
          <div class="memory-trend-bars" style="--memory-bars:12"></div>
          <span class="memory-trend-value">${escapeHTML(t("memoryTrend.noData"))}</span>
          <span class="memory-trend-delta">--</span>
        `;
        element.title = t("memoryTrend.noData");
        return;
      }

      const first = points[0];
      const last = points[points.length - 1];
      const values = points.map(point => point.valueMB);
      const min = Math.min(...values);
      const max = Math.max(...values);
      const span = Math.max(1, max - min);
      const delta = last.valueMB - first.valueMB;
      const direction = delta > 50 ? "rising" : delta < -50 ? "falling" : "steady";
      const bars = points.map(point => {
        const height = Math.max(12, Math.round(((point.valueMB - min) / span) * 86 + 8));
        const title = `${fmtTime(point.time)} · ${formatResource(point.valueMB, "MB")}`;
        return `<span style="--h:${height}" title="${escapeHTML(title)}"></span>`;
      }).join("");
      const deltaLabel = formatSignedResource(delta, "MB");

      element.className = `memory-trend-header ${direction}`;
      element.title = `${t("memoryTrend.title")}: ${formatResource(last.valueMB, "MB")} · ${deltaLabel} · ${points.length} ${t("memoryTrend.samples")}`;
      element.innerHTML = `
        <span class="memory-trend-title">${escapeHTML(t("memoryTrend.title"))}</span>
        <div class="memory-trend-bars" style="--memory-bars:${Math.max(1, points.length)}">${bars}</div>
        <span class="memory-trend-value">${formatResource(last.valueMB, "MB")}</span>
        <span class="memory-trend-delta">${deltaLabel}</span>
      `;
    }

    function formatResource(value, unit) {
      if (!unit) return new Intl.NumberFormat().format(value);
      if (unit === "%") return `${Number(value).toFixed(1)}%`;
      if (value >= 1024) return `${(value / 1024).toFixed(2)} GB`;
      return `${Math.round(value)} ${unit}`;
    }

    function formatSignedResource(value, unit) {
      const number = Number(value || 0);
      if (Math.abs(number) < 0.5) return `0 ${unit}`;
      return `${number > 0 ? "+" : "-"}${formatResource(Math.abs(number), unit)}`;
    }

    function sparkBars(seed) {
      let value = seed.split("").reduce((sum, char) => sum + char.charCodeAt(0), 0);
      return Array.from({ length: 18 }, (_, index) => {
        value = (value * 37 + index * 17) % 101;
        return `<span style="--h:${26 + (value % 66)}"></span>`;
      }).join("");
    }

    function renderLogs(logs) {
      const anchor = captureScrollAnchor();
      const filtered = filterLogItems(logs);
      const rows = filtered.slice(0, 26);

      state.visibleLogs = rows;
      state.filteredLogs = filtered;
      const body = document.getElementById("logRows");
      if (!body) return rows.length;
      if (!rows.length) {
        body.innerHTML = `<tr><td class="empty-cell" colspan="4">${state.clearedThroughLogId ? t("waitingNewLogs") : t("waitingLogs")}</td></tr>`;
        hideLogDetail();
        return 0;
      }

      body.innerHTML = rows.map(item => {
        const level = levelFromLine(item);
        const label = level === "critical" ? "ERROR" : level === "warning" ? "WARN" : level === "debug" ? "DEBUG" : "INFO";
        return `
          <tr class="log-row-${level} ${state.selectedLogId === item.id ? "selected" : ""}" data-log-id="${item.id}">
            <td>${fmtPrecise(item.receivedAt)}</td>
            <td><span class="level-badge level-${level}">${label}</span></td>
            <td>${escapeHTML(sourceName(item.source))}</td>
            <td>${escapeHTML(messageWithoutPrefix(item.text))}</td>
          </tr>
        `;
      }).join("");

      if (state.selectedLogId) {
        const selected = rows.find(item => item.id === state.selectedLogId);
        if (selected) renderLogDetail(selected);
      }
      applyAutoScroll();
      restoreScrollAnchor(anchor);
      return filtered.length;
    }

    function fmtPrecise(value) {
      const base = fmtTime(value);
      const millis = String(new Date(value).getMilliseconds()).padStart(3, "0");
      return `${base}.${millis}`;
    }

    function fmtShortTime(timestamp) {
      return new Date(timestamp).toLocaleTimeString(activeLocale(), { hour: "2-digit", minute: "2-digit" });
    }

    function formatAxisValue(value) {
      return new Intl.NumberFormat([], { maximumFractionDigits: 0 }).format(value);
    }

    function formatBucketSize(bucketMs) {
      const seconds = Math.max(1, Math.round(bucketMs / 1000));
      if (seconds < 60) return `${seconds}s/${t("chart.bucket")}`;
      const minutes = Math.max(1, Math.round(seconds / 60));
      return `${minutes}m/${t("chart.bucket")}`;
    }

    function renderLogDetail(item) {
      state.selectedLog = item;
      state.selectedLogId = item.id;
      const level = levelFromLine(item);
      const label = level === "critical" ? "ERROR" : level === "warning" ? "WARN" : level === "debug" ? "DEBUG" : "INFO";
      const panel = document.getElementById("logDetail");
      if (!panel) return;
      panel.hidden = false;
      const badge = document.getElementById("detailLevel");
      if (badge) {
        badge.className = `level-badge level-${level}`;
        badge.textContent = label;
      }
      setText("detailTime", fmtPrecise(item.receivedAt));
      setText("detailSource", sourceName(item.source));
      setText("detailMessage", messageWithoutPrefix(item.text));
      setText("detailStatus", "");
      document.querySelectorAll("tr[data-log-id]").forEach(row => {
        row.classList.toggle("selected", Number(row.dataset.logId) === item.id);
      });
    }

    function hideLogDetail() {
      state.selectedLog = null;
      state.selectedLogId = null;
      const panel = document.getElementById("logDetail");
      if (panel) panel.hidden = true;
      document.querySelectorAll("tr[data-log-id]").forEach(row => row.classList.remove("selected"));
    }

    async function copySelectedLog() {
      if (!state.selectedLog) return;
      const text = `[${fmtPrecise(state.selectedLog.receivedAt)}] ${state.selectedLog.source}: ${state.selectedLog.text}`;
      await copyText(text);
      setText("detailStatus", t("status.copied"));
    }

    async function copyText(text) {
      if (navigator.clipboard?.writeText) {
        try {
          await navigator.clipboard.writeText(text);
          return;
        } catch {
          // Fall through to the textarea fallback for browser contexts without clipboard permission.
        }
      }
      const field = document.createElement("textarea");
      field.value = text;
      field.setAttribute("readonly", "");
      field.style.position = "fixed";
      field.style.opacity = "0";
      document.body.appendChild(field);
      field.select();
      document.execCommand("copy");
      field.remove();
    }

    function alertLevel(item) {
      const severity = String(item?.severity || "info").toLowerCase();
      return severity === "critical" || severity === "warning" ? severity : "info";
    }

    function renderAlertDetail(item) {
      state.selectedAlert = item;
      state.selectedAlertId = item.id;
      const level = alertLevel(item);
      const label = level === "critical" ? "ERROR" : level === "warning" ? "WARN" : "INFO";
      const panel = document.getElementById("alertDetail");
      if (!panel) return;
      panel.hidden = false;
      const badge = document.getElementById("alertDetailLevel");
      if (badge) {
        badge.className = `level-badge level-${level}`;
        badge.textContent = label;
      }
      setText("alertDetailTime", fmtPrecise(item.time));
      setText("alertDetailSource", sourceName(item.source));
      setText("alertDetailTitle", item.title || label);
      setText("alertDetailMessage", item.message || "");
      setText("alertDetailStatus", "");
      document.querySelectorAll("[data-alert-id]").forEach(row => {
        row.classList.toggle("selected", row.dataset.alertId === item.id);
      });
    }

    function hideAlertDetail() {
      state.selectedAlert = null;
      state.selectedAlertId = null;
      const panel = document.getElementById("alertDetail");
      if (panel) panel.hidden = true;
      document.querySelectorAll("[data-alert-id]").forEach(row => row.classList.remove("selected"));
    }

    async function copySelectedAlert() {
      if (!state.selectedAlert) return;
      const text = `[${fmtPrecise(state.selectedAlert.time)}] ${state.selectedAlert.source}: ${state.selectedAlert.title} - ${state.selectedAlert.message}`;
      await copyText(text);
      setText("alertDetailStatus", t("status.copied"));
    }

    function renderAlerts(alerts) {
      document.querySelectorAll("[data-alert-filter]").forEach(button => {
        button.classList.toggle("active", button.dataset.alertFilter === state.alertFilter);
      });
      const filtered = alerts.filter(item => state.alertFilter === "all" || item.severity === state.alertFilter);
      renderList("alertList", filtered.slice(0, 16), item => `
        <div class="alert-row ${escapeHTML(item.severity || "info")} ${state.selectedAlertId === item.id ? "selected" : ""}" data-alert-id="${escapeHTML(item.id)}" role="button" tabindex="0">
          <span class="alert-dot"></span>
          <div>
            <strong>${escapeHTML(item.title)}</strong>
            <p class="alert-message">${escapeHTML(item.message)}</p>
            <p class="alert-source">${escapeHTML(sourceName(item.source))}</p>
          </div>
          <span class="event-time">${fmtTime(item.time)}</span>
        </div>
      `, t("noAlerts"));
      if (state.selectedAlertId) {
        const selected = alerts.find(item => item.id === state.selectedAlertId);
        if (selected) {
          renderAlertDetail(selected);
        } else {
          hideAlertDetail();
        }
      }
    }

    function renderPlayback(events) {
      const fallback = events.length ? events : [];
      renderList("playbackList", fallback.slice(0, 6), item => `
        <div class="play-row">
          <span class="play-icon">${playIcon(item.type)}</span>
          <div>
            <strong>${escapeHTML(item.title)}</strong>
            <p>${escapeHTML(item.zone || item.message || item.source)}</p>
          </div>
          <span class="event-time">${fmtTime(item.time)}</span>
        </div>
      `, t("noPlayback"));
    }

    function playIcon(type) {
      if (String(type).includes("playing")) return "▶";
      if (String(type).includes("raat")) return "⌁";
      if (String(type).includes("buffer")) return "◌";
      return "♪";
    }

    function isServerVolumeBucket(item) {
      return item && Object.prototype.hasOwnProperty.call(item, "startAt") && Object.prototype.hasOwnProperty.call(item, "total");
    }

    function renderChart(data) {
      const chart = document.getElementById("volumeChart");
      if (!chart) return;
      const windowMinutes = state.volumeWindowMinutes || 60;
      const hasServerBuckets = Array.isArray(data) && data.length > 0 && isServerVolumeBucket(data[0]);
      let bucketCount;
      let windowMs;
      let bucketMs;
      let end;
      let start;
      let buckets;

      if (hasServerBuckets) {
        buckets = data.map(bucket => ({
          total: Number(bucket.total || 0),
          warning: Number(bucket.warning || 0),
          critical: Number(bucket.critical || 0)
        }));
        bucketCount = Math.max(1, buckets.length);
        const firstStart = new Date(data[0].startAt).getTime();
        const lastEnd = new Date(data[data.length - 1].endAt).getTime();
        end = Number.isFinite(lastEnd) ? lastEnd : Math.floor(Date.now() / 60000) * 60000 + 60000;
        start = Number.isFinite(firstStart) ? firstStart : end - windowMinutes * 60 * 1000;
        windowMs = Math.max(1000, end - start);
        bucketMs = windowMs / bucketCount;
      } else {
        const logs = data || [];
        bucketCount = 60;
        windowMs = windowMinutes * 60 * 1000;
        bucketMs = windowMs / bucketCount;
        end = Math.floor(Date.now() / 60000) * 60000 + 60000;
        start = end - windowMs;
        buckets = Array.from({ length: bucketCount }, () => ({ total: 0, warning: 0, critical: 0 }));

        logs.forEach(item => {
          const timestamp = new Date(item.receivedAt || item.time || 0).getTime();
          if (!Number.isFinite(timestamp) || timestamp < start || timestamp > end) return;
          const index = Math.min(bucketCount - 1, Math.max(0, Math.floor((timestamp - start) / bucketMs)));
          const bucket = buckets[index];
          bucket.total += 1;
          const level = levelFromLine(item);
          if (level === "critical") bucket.critical += 1;
          if (level === "warning") bucket.warning += 1;
        });
      }

      const max = Math.max(1, ...buckets.map(bucket => bucket.total));
      const targetScale = Math.max(20, Math.ceil(max / 20) * 20);
      if (state.volumeChartScaleEnd !== end || state.volumeChartScaleWindow !== windowMinutes) {
        state.volumeChartScaleEnd = end;
        state.volumeChartScaleWindow = windowMinutes;
        state.volumeChartScaleMax = targetScale;
      } else {
        state.volumeChartScaleMax = Math.max(state.volumeChartScaleMax || 20, targetScale);
      }
      const scaleMax = state.volumeChartScaleMax;
      const axis = document.getElementById("volumeAxis");
      if (axis) {
        axis.innerHTML = `
          <span>${formatAxisValue(scaleMax)}</span>
          <span>${formatAxisValue(Math.round(scaleMax / 2))}</span>
          <span>0</span>
        `;
      }

      const timeline = document.getElementById("volumeTimeline");
      if (timeline) {
        timeline.innerHTML = `
          <div class="volume-timeline-labels">
            <span>${fmtShortTime(start)}</span>
            <span>${fmtShortTime(start + windowMs / 2)}</span>
            <span>${t("chart.now")}</span>
          </div>
        `;
      }

      setText("chartBucketLabel", formatBucketSize(bucketMs));
      chart.style.setProperty("--bucket-count", bucketCount);
      chart.innerHTML = buckets.map(bucket => {
        const h = bucket.total ? Math.max(8, Math.min(100, Math.round((bucket.total / scaleMax) * 100))) : 4;
        const cls = bucket.critical ? "bad" : bucket.warning ? "warn" : "";
        return `<span class="${cls}" title="${bucket.total} ${t("chart.lines")}" style="--h:${h}"></span>`;
      }).join("");
    }

    async function refresh() {
      try {
        const response = await fetch("/api/snapshot", { cache: "no-store" });
        const snapshot = await response.json();
        if (state.paused && state.lastSnapshot) {
          state.pendingSnapshot = snapshot;
          const newestNow = snapshot.recentLogs?.[0]?.id || 0;
          const newestVisible = state.lastSnapshot.recentLogs?.[0]?.id || 0;
          state.bufferedCount = Math.max(0, newestNow - newestVisible);
          updateStreamStatus(state.lastSnapshot.recentLogs?.length || 0, state.filteredLogs.length || state.visibleLogs.length);
          return;
        }
        render(snapshot);
      } catch (error) {
        setText("serverState", state.language === "de" ? "Getrennt" : "Disconnected");
      }
    }

    function togglePaused() {
      state.paused = !state.paused;
      if (!state.paused && state.pendingSnapshot) {
        render(state.pendingSnapshot);
      } else {
        updateStreamStatus(state.lastSnapshot?.recentLogs?.length || 0, state.filteredLogs.length || state.visibleLogs.length);
      }
    }

    document.addEventListener("input", event => {
      if (event.target?.id === "levelFilter") {
        state.level = event.target.value;
        saveUIState();
      }
      if (event.target?.id === "searchInput") state.query = event.target.value;
      if (event.target?.id === "regexInput") state.query = document.getElementById("searchInput")?.value || "";
      if (event.target?.id === "configLanguage") {
        state.language = event.target.value;
        applyI18n();
        setText("settingsStatus", "");
      }
      if (event.target?.id === "chartRange" || event.target?.id === "configVolumeWindow") {
        setVolumeWindow(event.target.value);
      }
      if (state.lastSnapshot && ["levelFilter", "searchInput", "regexInput"].includes(event.target?.id)) {
        render(state.lastSnapshot);
      } else {
        refresh();
      }
    });

    document.addEventListener("change", event => {
      if (event.target?.id === "chartRange" || event.target?.id === "configVolumeWindow") {
        setVolumeWindow(event.target.value);
        refresh();
      }
      if (event.target?.id === "autoScrollToggle") {
        state.autoScroll = event.target.checked;
        saveUIState();
        updateStreamStatus(state.lastSnapshot?.recentLogs?.length || 0, state.filteredLogs.length || state.visibleLogs.length);
        applyAutoScroll();
      }
    });

    document.addEventListener("pointerover", event => {
      const icon = event.target?.closest?.(".help-icon");
      if (icon) showHelpTooltip(icon);
    });

    document.addEventListener("pointerout", event => {
      const icon = event.target?.closest?.(".help-icon");
      if (icon && !icon.contains(event.relatedTarget) && pinnedHelpTooltipTarget.current !== icon) hideHelpTooltip();
    });

    document.addEventListener("focusin", event => {
      const icon = event.target?.closest?.(".help-icon");
      if (icon) showHelpTooltip(icon);
    });

    document.addEventListener("focusout", event => {
      const icon = event.target?.closest?.(".help-icon");
      if (icon && pinnedHelpTooltipTarget.current !== icon) hideHelpTooltip();
    });

    document.addEventListener("scroll", () => hideHelpTooltip({ force: true }), true);
    window.addEventListener("resize", () => hideHelpTooltip({ force: true }));

    document.addEventListener("click", event => {
      const helpIcon = event.target?.closest?.(".help-icon");
      if (helpIcon) {
        event.preventDefault();
        event.stopPropagation();
        const tooltip = document.getElementById("helpTooltip");
        if (pinnedHelpTooltipTarget.current === helpIcon && tooltip && !tooltip.hidden) {
          hideHelpTooltip({ force: true });
        } else {
          showHelpTooltip(helpIcon, { pin: true });
        }
        return;
      }
      hideHelpTooltip({ force: true });
      const alertButton = event.target?.closest?.("[data-alert-filter]");
      if (alertButton) {
        state.alertFilter = alertButton.dataset.alertFilter || "all";
        saveUIState();
        renderAlerts(state.lastSnapshot?.alerts || []);
      }
      const alertRow = event.target?.closest?.("[data-alert-id]");
      if (alertRow) {
        const item = (state.lastSnapshot?.alerts || []).find(alert => alert.id === alertRow.dataset.alertId);
        if (item) renderAlertDetail(item);
      }
      const logRow = event.target?.closest?.("tr[data-log-id]");
      if (logRow) {
        const id = Number(logRow.dataset.logId);
        const item = state.visibleLogs.find(log => log.id === id);
        if (item) renderLogDetail(item);
      }
      if (event.target?.id === "clearSearch") {
        state.query = "";
        state.clearedThroughLogId = state.lastSnapshot?.recentLogs?.[0]?.id || state.clearedThroughLogId || 0;
        state.clearStatusUntil = Date.now() + 3500;
        hideLogDetail();
        const input = document.getElementById("searchInput");
        if (input) input.value = "";
        if (state.lastSnapshot) render(state.lastSnapshot);
      }
      if (event.target?.id === "pauseStream") {
        togglePaused();
      }
      if (event.target?.id === "openSettings") {
        openSettings();
      }
      if (event.target?.id === "closeSettings") {
        closeSettings();
      }
      if (event.target?.id === "manageSources") {
        openSources();
      }
      if (event.target?.closest?.("#roonHealth")) {
        openHealthDetails();
      }
      if (event.target?.id === "closeHealth") {
        closeHealthDetails();
      }
      if (event.target?.id === "exportIncident") {
        exportIncidentBundle();
      }
      if (event.target?.id === "closeSources") {
        closeSources();
      }
      if (event.target?.id === "openSettingsFromSources") {
        closeSources();
        openSettings();
      }
      if (event.target?.id === "closeLogDetail") {
        hideLogDetail();
      }
      if (event.target?.id === "copyLogLine") {
        copySelectedLog().catch(error => setText("detailStatus", error.message));
      }
      if (event.target?.id === "closeAlertDetail") {
        hideAlertDetail();
      }
      if (event.target?.id === "copyAlertMessage") {
        copySelectedAlert().catch(error => setText("alertDetailStatus", error.message));
      }
      if (event.target?.id === "reloadConfig") {
        fetch("/api/config/reload", { method: "POST" })
          .then(response => response.json())
          .then(document => {
            state.configDocument = document;
            fillSettings(document);
            setText("settingsStatus", t("reloadedMessage"));
          })
          .catch(error => setText("settingsStatus", `Reload failed: ${error.message}`));
      }
    });

    document.addEventListener("submit", event => {
      if (event.target?.id === "settingsForm") {
        event.preventDefault();
        saveSettings().catch(error => setText("settingsStatus", error.message));
      }
      if (event.target?.id === "sourceForm") {
        event.preventDefault();
        saveSources().catch(error => setText("sourceStatus", error.message));
      }
    });

    installStaticHelp();
    applyI18n();
    applyUIStateToControls();
    refresh();
    loadConfig().catch(() => {});

    let refreshTimer = null;

    function refreshDelay() {
      if (document.hidden) return 8000;
      return state.paused ? 3000 : 1500;
    }

    function scheduleRefresh() {
      if (refreshTimer) clearTimeout(refreshTimer);
      refreshTimer = setTimeout(async () => {
        await refresh();
        scheduleRefresh();
      }, refreshDelay());
    }

    document.addEventListener("visibilitychange", scheduleRefresh);
    scheduleRefresh();
    """
}
