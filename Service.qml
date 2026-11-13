import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// State and commands for the Proton VPN widget.
//
// The CLI is a Python program (~0.7 s per call), so it is asked as little as
// possible: NetworkManager events (`nmcli monitor`) and a cheap `nmcli`
// probe drive the bar between polls, and `protonvpn status` runs on a slow
// timer, after tunnel events, and when the panel opens. Settings and the
// country list are only read for the panel.
Item {
  id: root

  property var settings: ({})
  property var tr: function(key, fallback) { return fallback !== undefined ? fallback : key }

  property bool installed: false
  property bool checkedInstall: false

  // Authoritative state from `protonvpn status`, sharpened by NetworkManager.
  property bool connected: false
  property bool statusKnown: false
  property string server: ""
  property string location: ""
  property int load: -1
  property string protocol: ""
  property string publicIp: ""        // as reported by `protonvpn connect`
  property string entryIp: ""         // WireGuard endpoint from NetworkManager
  property var _lastConnection: ({ server: "", ip: "" })
  property string tunnelUuid: ""
  property string nmState: ""          // connecting | disconnecting | "" from nmcli monitor
  property bool killSwitchArmed: false // pvpn-killswitch interface present

  property var config: ({})
  property bool configLoaded: false
  property var countries: []
  property bool countriesLoaded: false
  property double _countriesAt: 0

  // One user-initiated command at a time.
  property string actionKind: ""     // connect | disconnect | setting | toggle
  property string actionTarget: ""   // fastest, country:JP, setting:netshield, …
  property string actionStatus: ""   // last success message, fades out
  property string lastError: ""      // last failure, kept until the next action
  property string _pendingTargetLabel: ""
  // Which way a right-click toggle is heading, fixed when it starts: the
  // tunnel probe flips `connected` halfway through.

  readonly property bool connecting: (actionKind === "connect") || (actionKind === "" && nmState === "connecting")
  readonly property bool disconnecting: (actionKind === "disconnect") || (actionKind === "" && nmState === "disconnecting")
  readonly property bool busy: actionKind !== ""
  readonly property bool refreshing: statusProcess.running || configProcess.running || countriesProcess.running
  readonly property string phase: connecting ? "connecting" : (disconnecting ? "disconnecting" : (connected ? "connected" : "disconnected"))
  readonly property string countryCode: Model.countryFromServer(server)
  readonly property string protocolText: Model.protocolLabel(protocol)
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 60, 10, 3600)

  // English for the IPC status() call.
  readonly property string statusText: {
    if (!installed) return checkedInstall ? "Not installed" : "Checking"
    if (phase === "connecting") return "Connecting"
    if (phase === "disconnecting") return "Disconnecting"
    if (!connected) return "Disconnected"
    var parts = ["Connected"]
    if (server !== "") parts.push(server)
    if (location !== "") parts.push(location)
    return parts.join(" · ")
  }

  property bool panelOpen: false
  onPanelOpenChanged: if (panelOpen) refreshAll()

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function t(key, fallback) { return tr(key, fallback) }

  // ---- reads ----------------------------------------------------------

  function refresh() {
    if (!installed) {
      if (!whichProcess.running) whichProcess.running = true
      return
    }
    probeTunnel()
    refreshStatus()
  }

  function refreshAll() {
    refresh()
    if (!installed) return
    refreshConfig()
    if (!countriesLoaded || Date.now() - _countriesAt > 6 * 3600 * 1000) refreshCountries()
  }

  function probeTunnel() {
    if (nmProcess.running) return
    nmProcess.running = true
    armWatchdog()
  }

  function refreshStatus() {
    // A connect or disconnect in flight answers for itself when it exits.
    if (!installed || statusProcess.running || actionProcess.running) return
    statusProcess.running = true
    armWatchdog()
  }

  function refreshConfig() {
    if (!installed || configProcess.running) return
    configProcess.running = true
    armWatchdog()
  }

  function refreshCountries() {
    if (!installed || countriesProcess.running) return
    countriesProcess.running = true
    armWatchdog()
  }

  function armWatchdog() {
    if (!readWatchdog.running) readWatchdog.start()
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed.ok) {
      statusKnown = false
      lastError = t("error.statusUnreadable", "Couldn't read protonvpn status")
      console.warn("io.github.orcawhisperer.protonvpn: unexpected status output")
      return
    }
    statusKnown = true
    var wasConnected = connected
    connected = parsed.connected
    if (connected) {
      server = parsed.server
      location = parsed.location
      load = parsed.load
      protocol = parsed.protocol
      adoptLastConnection()
      if (entryIp === "" || !wasConnected) fetchEndpoint()
    } else {
      clearConnection()
    }
  }

  function clearConnection() {
    server = ""
    location = ""
    load = -1
    protocol = ""
    publicIp = ""
    entryIp = ""
  }

  // The public IP only comes from a connect's own output; remember it so a
  // shell restart does not lose it while the same server stays connected.
  function adoptLastConnection() {
    if (publicIp === "" && server !== "" && _lastConnection.server === server) publicIp = _lastConnection.ip
  }

  function rememberConnection(serverName, ip) {
    _lastConnection = { server: serverName, ip: ip }
    lastConnectionFile.setText(JSON.stringify(_lastConnection) + "\n")
  }

  function applyTunnel(raw) {
    var tunnel = Model.parseActiveConnections(raw)
    killSwitchArmed = tunnel.killSwitch
    var changed = tunnel.up !== connected || (tunnel.up && tunnel.server !== "" && tunnel.server !== server)
    tunnelUuid = tunnel.uuid
    if (tunnel.up) {
      // NetworkManager knows the server before the CLI is asked again.
      if (tunnel.server !== "" && tunnel.server !== server) {
        server = tunnel.server
        location = ""
        load = -1
        publicIp = ""
        entryIp = ""
      }
      connected = true
      adoptLastConnection()
      if (entryIp === "") fetchEndpoint()
    } else if (connected && !busy) {
      connected = false
      clearConnection()
    }
    if (changed) statusDebounce.restart()
  }

  function fetchEndpoint() {
    if (tunnelUuid === "" || endpointProcess.running) return
    endpointProcess.command = ["nmcli", "-g", "wireguard.peers", "connection", "show", "uuid", tunnelUuid]
    endpointProcess.running = true
  }

  function handleMonitorLine(line) {
    var event = Model.monitorEvent(line)
    if (!event.relevant) return
    if (event.state === "connecting" || event.state === "disconnecting") nmState = event.state
    else if (event.state !== "") nmState = ""
    probeDebounce.restart()
    statusDebounce.restart()
  }

  // ---- commands -------------------------------------------------------

  function canAct() {
    return installed && !actionProcess.running
  }

  function startAction(kind, target, command) {
    if (!canAct() || !command) return false
    lastError = ""
    actionStatus = ""
    actionStatusTimer.stop()
    actionKind = kind
    actionTarget = target
    actionProcess.command = command
    actionProcess.running = true
    actionWatchdog.restart()
    return true
  }

  function connectTo(kind, value, label) {
    var args = Model.connectArgs(kind, value)
    if (!args) return
    _pendingTargetLabel = String(label || "")
    startAction("connect", kind === "country" ? "country:" + value : kind, args)
  }

  function connectFastest() { connectTo("fastest", "", "") }

  function disconnect() {
    startAction("disconnect", "", ["protonvpn", "disconnect"])
  }

  function toggleVpn() {
    if (connected) disconnect()
    else connectFastest()
  }

  function setSetting(name, value) {
    if (config[name] === value) return
    var args = Model.settingArgs(name, value)
    if (!args) return
    if (name === "kill-switch" && connected) {
      lastError = t("error.killSwitchConnected", "Disconnect before changing the kill switch.")
      return
    }
    startAction("setting", "setting:" + name, args)
  }

  function finishAction(exitCode, stdout, stderr) {
    var kind = actionKind
    actionWatchdog.stop()
    // `protonvpn disconnect` can exit non-zero after it has already printed
    // "Disconnected." (a post-disconnect kill switch task failing); the
    // tunnel is down, so that is a success.
    if (exitCode !== 0 && kind === "disconnect" && /^Disconnected\.\s*$/m.test(String(stdout || ""))) exitCode = 0
    if (exitCode === 0) {
      lastError = ""
      if (kind === "connect") {
        var out = Model.parseConnectOutput(stdout)
        if (out.server !== "") {
          connected = true
          server = out.server
          location = out.location
          load = -1
        }
        if (out.ip !== "") publicIp = out.ip
        if (out.server !== "" && out.ip !== "") rememberConnection(out.server, out.ip)
      } else if (kind === "disconnect") {
        connected = false
        clearConnection()
      } else if (kind === "setting") {
        actionStatus = Model.firstLine(stdout)
        actionStatusTimer.restart()
      }
    } else {
      var fallback = kind === "connect" ? t("error.connectFailed", "Couldn't connect")
        : (kind === "disconnect" ? t("error.disconnectFailed", "Couldn't disconnect")
          : t("error.settingFailed", "Couldn't change the setting"))
      lastError = Model.cliError(stdout, stderr, fallback)
    }
    actionKind = ""
    actionTarget = ""
    nmState = ""
    if (kind === "setting") refreshConfig()
    probeTunnel()
    refreshStatus()
  }

  // ---- timers ---------------------------------------------------------

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: probeDebounce
    interval: 250
    onTriggered: root.probeTunnel()
  }

  Timer {
    // Tunnel events arrive in bursts (device, profile, connectivity); ask the
    // CLI once they settle.
    id: statusDebounce
    interval: 1500
    onTriggered: root.refreshStatus()
  }

  Timer {
    id: actionStatusTimer
    interval: 4000
    onTriggered: root.actionStatus = ""
  }

  Timer {
    // A read that never exits would block every later refresh, since each
    // is skipped while its process runs.
    id: readWatchdog
    interval: 20000
    onTriggered: {
      if (statusProcess.running) statusProcess.running = false
      if (configProcess.running) configProcess.running = false
      if (countriesProcess.running) countriesProcess.running = false
      if (nmProcess.running) nmProcess.running = false
      if (endpointProcess.running) endpointProcess.running = false
    }
  }

  Timer {
    // Connects normally take 3–6 s; anything past this is stuck.
    id: actionWatchdog
    interval: 90000
    onTriggered: {
      if (actionProcess.running) actionProcess.running = false
      root.lastError = root.t("error.timedOut", "The command timed out")
      root.actionKind = ""
      root.actionTarget = ""
      root.refresh()
    }
  }

  Timer {
    id: monitorRestart
    interval: 5000
    onTriggered: if (!monitorProcess.running) monitorProcess.running = true
  }

  // ---- processes ------------------------------------------------------

  FileView {
    id: lastConnectionFile
    path: (Quickshell.env("XDG_CACHE_HOME") || ((Quickshell.env("HOME") || "") + "/.cache")) + "/omarchy-protonvpn.json"
    printErrors: false
    onLoaded: {
      root._lastConnection = Model.parseLastConnection(text())
      root.adoptLastConnection()
    }
  }

  Process {
    id: whichProcess
    command: ["which", "protonvpn"]
    onExited: function(exitCode) {
      root.checkedInstall = true
      root.installed = exitCode === 0
      if (root.installed) {
        monitorProcess.running = true
        root.probeTunnel()
        root.refreshStatus()
        if (root.panelOpen) root.refreshAll()
      }
    }
  }

  Process {
    id: monitorProcess
    command: ["nmcli", "monitor"]
    environment: ({ LC_ALL: "C" })
    stdout: SplitParser { onRead: function(line) { root.handleMonitorLine(line) } }
    onExited: monitorRestart.restart()
  }

  Process {
    id: nmProcess
    command: ["nmcli", "-t", "-f", "NAME,TYPE,DEVICE,UUID", "connection", "show", "--active"]
    environment: ({ LC_ALL: "C" })
    stdout: StdioCollector { id: nmOut; waitForEnd: true }
    onExited: function(exitCode) { if (exitCode === 0) root.applyTunnel(nmOut.text) }
  }

  Process {
    id: endpointProcess
    environment: ({ LC_ALL: "C" })
    stdout: StdioCollector { id: endpointOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0 || !root.connected) return
      var ip = Model.parseEndpoint(endpointOut.text)
      if (ip !== "") root.entryIp = ip
    }
  }

  Process {
    id: statusProcess
    command: ["protonvpn", "status"]
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    stderr: StdioCollector { id: statusErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyStatus(statusOut.text)
      else {
        root.statusKnown = false
        root.lastError = Model.cliError(statusOut.text, statusErr.text, root.t("error.statusFailed", "protonvpn status failed"))
      }
    }
  }

  Process {
    id: configProcess
    command: ["protonvpn", "config", "list"]
    stdout: StdioCollector { id: configOut; waitForEnd: true }
    stderr: StdioCollector { id: configErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        var parsed = Model.parseConfig(configOut.text)
        root.config = parsed
        root.configLoaded = Model.hasConfig(parsed)
        if (!root.configLoaded) root.lastError = root.t("error.configUnreadable", "Couldn't read protonvpn settings")
      } else {
        root.lastError = Model.cliError(configOut.text, configErr.text, root.t("error.configFailed", "protonvpn config list failed"))
      }
    }
  }

  Process {
    id: countriesProcess
    command: ["protonvpn", "countries", "list"]
    stdout: StdioCollector { id: countriesOut; waitForEnd: true }
    stderr: StdioCollector { id: countriesErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        var list = Model.parseCountries(countriesOut.text)
        if (list.length > 0) {
          root.countries = list
          root.countriesLoaded = true
          root._countriesAt = Date.now()
          return
        }
      }
      root.lastError = Model.cliError(countriesOut.text, countriesErr.text, root.t("error.countriesFailed", "Couldn't load the country list"))
    }
  }

  Process {
    id: actionProcess
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) { root.finishAction(exitCode, actionOut.text, actionErr.text) }
  }
}
