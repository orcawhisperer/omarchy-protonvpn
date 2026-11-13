// Pure parsing and argument building for the Proton VPN widget. Everything
// here treats CLI and NetworkManager output as untrusted: inputs are size
// capped, every field is validated against a narrow pattern, and anything
// that reaches a command line is rebuilt from a fixed table rather than
// passed through. The file is also loaded by node for tests/Model.test.js.

var MAX_INPUT = 65536
var MAX_COUNTRIES = 300

// Settings the panel can change, with the values `protonvpn config set`
// accepts for each. The CLI (1.0.5) only offers off/standard for the kill
// switch; "advanced" was removed upstream because it blocks the connection
// attempt itself while disconnected.
var SETTINGS = {
  "netshield": ["off", "malware-only", "malware-ads-trackers"],
  "kill-switch": ["off", "standard"],
  "port-forwarding": ["off", "on"],
  "vpn-accelerator": ["off", "on"],
  "moderate-nat": ["off", "on"],
  "ipv6": ["off", "on"]
}

var QUICK_CONNECTS = ["fastest", "securecore", "p2p", "tor", "random"]

function bounded(raw, max) {
  var text = String(raw === undefined || raw === null ? "" : raw)
  var limit = max || MAX_INPUT
  return text.length > limit ? text.substring(0, limit) : text
}

// One display line: control characters (including newlines and bidi
// overrides) collapse to spaces and the result is capped.
function cleanText(raw, max) {
  var text = String(raw === undefined || raw === null ? "" : raw)
  text = text.replace(/[\u0000-\u001f\u007f-\u009f‎‏‪-‮⁦-⁩]/g, " ")
  text = text.replace(/\s+/g, " ").trim()
  var limit = max || 120
  return text.length > limit ? text.substring(0, limit - 1) + "…" : text
}

function lines(raw) {
  return bounded(raw).split(/\r?\n/)
}

function isServerName(value) {
  return /^[A-Za-z0-9][A-Za-z0-9#+_-]{0,31}$/.test(String(value || ""))
}

function isCountryCode(value) {
  return /^[A-Z]{2}$/.test(String(value || ""))
}

// "Status: Connected\nServer: IN#37 in Mumbai, India\nLoad: 28%\nProtocol: wireguard"
// or "Status: Disconnected". Anything else reads as unknown rather than as
// a guess, so a changed CLI shows up as an error instead of a wrong state.
function parseStatus(raw) {
  var result = { ok: false, connected: false, server: "", location: "", load: -1, protocol: "" }
  var all = lines(raw)
  for (var i = 0; i < all.length; i++) {
    var match = all[i].match(/^\s*([A-Za-z]+)\s*:\s*(.*?)\s*$/)
    if (!match) continue
    var key = match[1].toLowerCase()
    var value = match[2]
    if (key === "status") {
      if (/^connected$/i.test(value)) { result.ok = true; result.connected = true }
      else if (/^disconnected$/i.test(value)) { result.ok = true; result.connected = false }
    } else if (key === "server") {
      var server = value.match(/^(\S+)(?:\s+in\s+(.+))?$/)
      if (server && isServerName(server[1])) {
        result.server = server[1]
        result.location = cleanText(server[2] || "", 80)
      }
    } else if (key === "load") {
      var load = value.match(/^(\d{1,3})\s*%?$/)
      if (load) result.load = Math.max(0, Math.min(100, parseInt(load[1], 10)))
    } else if (key === "protocol") {
      if (/^[A-Za-z0-9_-]{1,24}$/.test(value)) result.protocol = value.toLowerCase()
    }
  }
  if (!result.connected) {
    result.server = ""
    result.location = ""
    result.load = -1
    result.protocol = ""
  }
  return result
}

function protocolLabel(protocol) {
  var value = String(protocol || "").toLowerCase()
  if (value === "wireguard") return "WireGuard"
  if (value === "openvpn-udp") return "OpenVPN (UDP)"
  if (value === "openvpn-tcp") return "OpenVPN (TCP)"
  if (value === "pro") return "Stealth"
  return cleanText(value, 24)
}

// The second column of `protonvpn config list`. Unknown keys are ignored
// and a value the panel does not know reads as "" (shown as unknown).
function parseConfig(raw) {
  var config = {}
  for (var key in SETTINGS) config[key] = ""
  var all = lines(raw)
  for (var i = 0; i < all.length; i++) {
    var match = all[i].match(/^\s*([a-z][a-z0-9-]{1,40})\s{2,}(\S{1,40})\s*$/)
    if (!match) continue
    var name = match[1]
    var value = match[2].toLowerCase()
    if (!SETTINGS.hasOwnProperty(name)) continue
    if (name === "kill-switch" && value === "disabled") value = "off"
    if (SETTINGS[name].indexOf(value) !== -1) config[name] = value
  }
  return config
}

function hasConfig(config) {
  if (!config) return false
  for (var key in SETTINGS) if (config[key]) return true
  return false
}

// `protonvpn countries list` prints a two-column table, name then code.
function parseCountries(raw) {
  var byCode = {}
  var result = []
  var all = lines(raw)
  var started = false
  for (var i = 0; i < all.length && result.length < MAX_COUNTRIES; i++) {
    var line = all[i]
    if (/^\s*-{3,}\s+-{2,}\s*$/.test(line)) { started = true; continue }
    if (!started) continue
    var match = line.match(/^\s*(\S.*?)\s{2,}([A-Z]{2})\s*$/)
    if (!match) continue
    var code = match[2]
    var name = cleanText(match[1], 48)
    if (name === "" || byCode[code]) continue
    byCode[code] = true
    result.push({ code: code, name: name })
  }
  result.sort(function(a, b) { return a.name.localeCompare(b.name) })
  return result
}

// A country code as its flag: two regional indicator symbols.
function flag(code) {
  if (!isCountryCode(code)) return ""
  return String.fromCodePoint(0x1f1e6 + code.charCodeAt(0) - 65, 0x1f1e6 + code.charCodeAt(1) - 65)
}

function filterCountries(countries, query) {
  var list = Array.isArray(countries) ? countries : []
  var q = String(query || "").trim().toLowerCase()
  if (q === "") return list
  var prefix = []
  var rest = []
  for (var i = 0; i < list.length; i++) {
    var name = String(list[i].name || "").toLowerCase()
    var code = String(list[i].code || "").toLowerCase()
    if (code === q || name.indexOf(q) === 0) prefix.push(list[i])
    else if (name.indexOf(q) !== -1) rest.push(list[i])
  }
  return prefix.concat(rest)
}

// nmcli -t escapes ':' and '\' inside fields with a backslash.
function splitTerse(line) {
  var fields = []
  var current = ""
  var text = String(line || "")
  for (var i = 0; i < text.length; i++) {
    var ch = text.charAt(i)
    if (ch === "\\" && i + 1 < text.length) { current += text.charAt(i + 1); i++ }
    else if (ch === ":") { fields.push(current); current = "" }
    else current += ch
  }
  fields.push(current)
  return fields
}

function serverFromConnectionName(name) {
  var match = String(name || "").match(/^ProtonVPN\s+(\S+)$/)
  return match && isServerName(match[1]) ? match[1] : ""
}

// IN#37 -> IN, CH-JP#1 (Secure Core, exit JP) -> JP, US-FREE#3 -> US.
function countryFromServer(server) {
  if (!isServerName(server)) return ""
  var parts = String(server).split("#")[0].split("-")
  for (var i = parts.length - 1; i >= 0; i--) {
    var part = parts[i].toUpperCase()
    if (isCountryCode(part)) return part
  }
  return ""
}

// `nmcli -t -f NAME,TYPE,DEVICE,UUID connection show --active`
function parseActiveConnections(raw) {
  var result = { up: false, name: "", server: "", uuid: "", killSwitch: false }
  var all = lines(raw)
  for (var i = 0; i < all.length && i < 256; i++) {
    var f = splitTerse(all[i])
    if (f.length < 4) continue
    var name = f[0]
    var type = f[1]
    var device = f[2]
    var uuid = /^[0-9a-fA-F-]{36}$/.test(f[3]) ? f[3] : ""
    if (/^pvpn-killswitch/.test(name)) result.killSwitch = true
    var server = serverFromConnectionName(name)
    if (device === "proton0" || (server !== "" && (type === "wireguard" || type === "vpn"))) {
      result.up = true
      result.name = cleanText(name, 48)
      result.server = server
      result.uuid = uuid
    }
  }
  return result
}

function isIpv4(value) {
  var m = String(value || "").match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/)
  if (!m) return false
  for (var i = 1; i <= 4; i++) if (parseInt(m[i], 10) > 255) return false
  return true
}

function isIpv6(value) {
  var text = String(value || "")
  return text.length <= 45 && text.indexOf(":") !== -1 && /^[0-9a-fA-F:.]+$/.test(text)
}

// `nmcli -g wireguard.peers connection show uuid …` prints
// "<key> allowed-ips=0.0.0.0/0 endpoint=146.70.142.82\:443": the server's
// entry address. The exit address sites see can differ, so the panel labels
// this one "Server IP" and only says "Public IP" for what the CLI reported.
function parseEndpoint(raw) {
  // `nmcli -g` escapes the port's colon as "\:".
  var match = bounded(raw, 4096).match(/endpoint=(\[[0-9a-fA-F:.]+\]|[0-9.]+)\\?:\d+/)
  if (!match) return ""
  var host = match[1].replace(/^\[|\]$/g, "")
  return isIpv4(host) || isIpv6(host) ? host : ""
}

// "Connected to IN#37 in Mumbai, India. \nYour new IP address is 1.2.3.4."
function parseConnectOutput(raw) {
  var result = { server: "", location: "", ip: "" }
  var text = bounded(raw, 8192)
  var connected = text.match(/Connected to (\S+) in ([^\n]+?)\.\s*(?:\n|$)/)
  if (connected && isServerName(connected[1])) {
    result.server = connected[1]
    result.location = cleanText(connected[2], 80)
  }
  var ip = text.match(/IP address is ([0-9a-fA-F:.]+?)\.?\s*(?:\n|$)/)
  if (ip && (isIpv4(ip[1]) || isIpv6(ip[1]))) result.ip = ip[1]
  return result
}

// The small state file that keeps the CLI-reported public IP across shell
// restarts: {"server": "IN#37", "ip": "1.2.3.4"}. Only trusted when the
// server still matches the live connection.
function parseLastConnection(raw) {
  try {
    var data = JSON.parse(bounded(raw, 2048))
    var server = String((data && data.server) || "")
    var ip = String((data && data.ip) || "")
    if (isServerName(server) && (isIpv4(ip) || isIpv6(ip))) return { server: server, ip: ip }
  } catch (e) {}
  return { server: "", ip: "" }
}

// The CLI reports usage errors as "Error: …" after a usage banner, and
// other failures as a bare message or a traceback. Pick the line that says
// what went wrong and drop the banner.
function cliError(stdout, stderr, fallback) {
  var all = lines(String(stderr || "") + "\n" + String(stdout || ""))
  for (var i = 0; i < all.length; i++) {
    var m = all[i].match(/^\s*Error:\s*(.+)$/)
    if (m) return cleanText(m[1], 240)
  }
  var picked = ""
  for (var j = all.length - 1; j >= 0; j--) {
    var line = all[j].trim()
    if (line === "" || /^(Usage:|Try '|Options:|\s*-h, --help)/.test(line)) continue
    picked = line
    break
  }
  return picked !== "" ? cleanText(picked, 240) : String(fallback || "")
}

// First line of a CLI confirmation ("NetShield has been set to …, please
// establish a new VPN connection for changes to take effect.").
function firstLine(raw) {
  var all = lines(raw)
  for (var i = 0; i < all.length; i++) {
    var line = cleanText(all[i], 200)
    if (line !== "") return line
  }
  return ""
}

// `nmcli monitor` lines worth a refresh: anything about the tunnel device,
// a ProtonVPN profile, or the kill switch interfaces. Device state lines
// ("proton0: connecting (prepare)") also say where the tunnel is heading
// before the CLI can.
function monitorEvent(line) {
  var text = bounded(line, 512)
  var relevant = /proton|pvpn/i.test(text)
  var state = ""
  var m = text.match(/^\s*proton0:\s*([a-z ]+?)(?:\s*\(|$)/i)
  if (m) {
    var s = m[1].toLowerCase().trim()
    if (s.indexOf("deactivating") === 0 || s.indexOf("disconnecting") === 0) state = "disconnecting"
    else if (s.indexOf("connecting") === 0) state = "connecting"
    else if (s.indexOf("connected") === 0) state = "connected"
    else if (s.indexOf("disconnected") === 0 || s.indexOf("unavailable") === 0 || s.indexOf("device removed") === 0 || s.indexOf("unmanaged") === 0) state = "disconnected"
  }
  return { relevant: relevant, state: state }
}

// Arguments for `protonvpn connect`, built only from fixed flags and a
// validated country code. Returns null for anything else.
function connectArgs(kind, value) {
  if (kind === "fastest") return ["protonvpn", "connect"]
  if (kind === "securecore") return ["protonvpn", "connect", "--securecore"]
  if (kind === "p2p") return ["protonvpn", "connect", "--p2p"]
  if (kind === "tor") return ["protonvpn", "connect", "--tor"]
  if (kind === "random") return ["protonvpn", "connect", "--random"]
  if (kind === "country" && isCountryCode(value)) return ["protonvpn", "connect", "--country", value]
  return null
}

function settingArgs(name, value) {
  if (!SETTINGS.hasOwnProperty(name)) return null
  if (SETTINGS[name].indexOf(value) === -1) return null
  return ["protonvpn", "config", "set", name, value]
}

if (typeof module !== "undefined") {
  module.exports = {
    SETTINGS: SETTINGS,
    QUICK_CONNECTS: QUICK_CONNECTS,
    cleanText: cleanText,
    isServerName: isServerName,
    isCountryCode: isCountryCode,
    parseStatus: parseStatus,
    protocolLabel: protocolLabel,
    parseConfig: parseConfig,
    hasConfig: hasConfig,
    parseCountries: parseCountries,
    flag: flag,
    filterCountries: filterCountries,
    splitTerse: splitTerse,
    serverFromConnectionName: serverFromConnectionName,
    countryFromServer: countryFromServer,
    parseActiveConnections: parseActiveConnections,
    parseEndpoint: parseEndpoint,
    parseConnectOutput: parseConnectOutput,
    parseLastConnection: parseLastConnection,
    cliError: cliError,
    firstLine: firstLine,
    monitorEvent: monitorEvent,
    connectArgs: connectArgs,
    settingArgs: settingArgs
  }
}
