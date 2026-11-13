// Run with: node tests/Model.test.js
const assert = require("assert")
const path = require("path")
const fs = require("fs")
const M = require(path.join(__dirname, "..", "Model.js"))

let failures = 0
function test(name, fn) {
  try { fn(); console.log("ok   " + name) } catch (e) { failures++; console.log("FAIL " + name + "\n     " + e.message) }
}

test("status: connected", () => {
  const s = M.parseStatus("Status: Connected\nServer: IN#37 in Mumbai, India\nLoad: 28%\nProtocol: wireguard\n")
  assert.deepStrictEqual(s, { ok: true, connected: true, server: "IN#37", location: "Mumbai, India", load: 28, protocol: "wireguard" })
})

test("status: disconnected", () => {
  const s = M.parseStatus("Status: Disconnected\n")
  assert.strictEqual(s.ok, true)
  assert.strictEqual(s.connected, false)
  assert.strictEqual(s.server, "")
})

test("status: secure core location", () => {
  const s = M.parseStatus("Status: Connected\nServer: CH-JP#1 in Tokyo, via Switzerland\nLoad: 9%\nProtocol: wireguard")
  assert.strictEqual(s.server, "CH-JP#1")
  assert.strictEqual(s.location, "Tokyo, via Switzerland")
  assert.strictEqual(M.countryFromServer(s.server), "JP")
})

test("status: garbage is not a state", () => {
  assert.strictEqual(M.parseStatus("Traceback (most recent call last):\n  boom").ok, false)
  assert.strictEqual(M.parseStatus("").ok, false)
})

test("status: markup and control characters stay inert text", () => {
  const s = M.parseStatus("Status: Connected\nServer: IN#1 in <img src=\"https://example.invalid/t\">‮\nLoad: 999%\nProtocol: <b>x</b>")
  assert.strictEqual(s.location, "<img src=\"https://example.invalid/t\">")
  assert.ok(!/[‮\n]/.test(s.location))
  assert.strictEqual(s.load, 100)
  assert.strictEqual(s.protocol, "")
})

test("status: hostile server name rejected", () => {
  const s = M.parseStatus("Status: Connected\nServer: $(rm -rf ~) in X\n")
  assert.strictEqual(s.server, "")
})

test("config list", () => {
  const raw = "\nCurrent configuration\nSetting                  Value\n-----------------------  --------------------\nnetshield                malware-ads-trackers\nkill-switch              standard\nport-forwarding          off\ncustom-dns               off\nvpn-accelerator          on\nmoderate-nat             off\nipv6                     on\nanonymous-crash-reports  on\n"
  const c = M.parseConfig(raw)
  assert.strictEqual(c["netshield"], "malware-ads-trackers")
  assert.strictEqual(c["kill-switch"], "standard")
  assert.strictEqual(c["vpn-accelerator"], "on")
  assert.strictEqual(c["ipv6"], "on")
  assert.strictEqual(c["port-forwarding"], "off")
  assert.ok(M.hasConfig(c))
})

test("config list: unknown values ignored", () => {
  const c = M.parseConfig("netshield                <script>\nkill-switch              Upgrade to enable\n")
  assert.strictEqual(c["netshield"], "")
  assert.strictEqual(c["kill-switch"], "")
  assert.ok(!M.hasConfig(c))
})

test("countries list", () => {
  const raw = "Country                           Code\n--------------------------------  ------\nAfghanistan                       AF\nBosnia and Herzegovina            BA\nIndia                             IN\nIndia                             IN\n<img src=x>                       ZZ\nnot a row\n"
  const list = M.parseCountries(raw)
  assert.deepStrictEqual(list.map(c => c.code), ["ZZ", "AF", "BA", "IN"])
  assert.strictEqual(list[0].name, "<img src=x>")
})

test("countries list is bounded", () => {
  let raw = "Country  Code\n-------  ----\n"
  for (let i = 0; i < 2000; i++) raw += "Land" + i + "    " + String.fromCharCode(65 + (i % 26)) + String.fromCharCode(65 + Math.floor(i / 26) % 26) + "\n"
  assert.ok(M.parseCountries(raw).length <= 300)
})

test("country filter: prefix first, code match", () => {
  const list = [{ code: "IN", name: "India" }, { code: "ID", name: "Indonesia" }, { code: "GB", name: "United Kingdom" }, { code: "US", name: "United States" }]
  assert.deepStrictEqual(M.filterCountries(list, "ind").map(c => c.code), ["IN", "ID"])
  assert.deepStrictEqual(M.filterCountries(list, "us").map(c => c.code), ["US"])
  assert.deepStrictEqual(M.filterCountries(list, "king").map(c => c.code), ["GB"])
})

test("flags", () => {
  assert.strictEqual(M.flag("IN"), "\u{1F1EE}\u{1F1F3}")
  assert.strictEqual(M.flag("in"), "")
})

test("nmcli active connections", () => {
  const raw = "pvpn-killswitch:dummy:pvpnksintrf0:ee6611d2-8a2f-41a7-8f04-d7eb49f22900\nHome WiFi:802-11-wireless:wlan0:a2fedeec-1b3b-4d29-8607-253eac1e6315\nProtonVPN IN#37:wireguard:proton0:530b4693-909b-4a55-84e8-18db75aecf87\n"
  const t = M.parseActiveConnections(raw)
  assert.strictEqual(t.up, true)
  assert.strictEqual(t.server, "IN#37")
  assert.strictEqual(t.uuid, "530b4693-909b-4a55-84e8-18db75aecf87")
  assert.strictEqual(t.killSwitch, true)
  assert.strictEqual(M.parseActiveConnections("Wifi\\:x:802-11-wireless:wlan0:a2fedeec-1b3b-4d29-8607-253eac1e6315").up, false)
})

test("endpoint", () => {
  assert.strictEqual(M.parseEndpoint("abc= allowed-ips=0.0.0.0/0 endpoint=146.70.142.82\\:443"), "146.70.142.82")
  assert.strictEqual(M.parseEndpoint("endpoint=146.70.142.82:443"), "146.70.142.82")
  assert.strictEqual(M.parseEndpoint("endpoint=999.1.1.1:443"), "")
})

test("connect output", () => {
  const out = M.parseConnectOutput("Connected to IN#28 in Mumbai, India. \nYour new IP address is 146.70.142.94.\n")
  assert.deepStrictEqual(out, { server: "IN#28", location: "Mumbai, India", ip: "146.70.142.94" })
})

test("last connection file", () => {
  assert.deepStrictEqual(M.parseLastConnection('{"server":"IN#28","ip":"146.70.142.94"}'), { server: "IN#28", ip: "146.70.142.94" })
  assert.deepStrictEqual(M.parseLastConnection('{"server":"<b>","ip":"x"}'), { server: "", ip: "" })
  assert.deepStrictEqual(M.parseLastConnection("not json"), { server: "", ip: "" })
})

test("cli errors", () => {
  const stderr = "Usage: protonvpn connect [OPTIONS] [SERVER_NAME]\nTry 'protonvpn connect -h' for help.\n\nError: Invalid country code 'XX'. Please use a valid country code.\n"
  assert.strictEqual(M.cliError("", stderr, "fallback"), "Invalid country code 'XX'. Please use a valid country code.")
  assert.strictEqual(M.cliError("", "", "fallback"), "fallback")
  assert.strictEqual(M.cliError("Connection failed. Try again.\n", "", "f"), "Connection failed. Try again.")
  assert.ok(M.cliError("", "Error: " + "x".repeat(5000), "f").length <= 240)
})

test("monitor events", () => {
  assert.deepStrictEqual(M.monitorEvent("proton0: connecting (prepare)"), { relevant: true, state: "connecting" })
  assert.deepStrictEqual(M.monitorEvent("proton0: connected"), { relevant: true, state: "connected" })
  assert.deepStrictEqual(M.monitorEvent("proton0: deactivating"), { relevant: true, state: "disconnecting" })
  assert.deepStrictEqual(M.monitorEvent("proton0: disconnected"), { relevant: true, state: "disconnected" })
  assert.deepStrictEqual(M.monitorEvent("pvpn-killswitch: connection profile created"), { relevant: true, state: "" })
  assert.strictEqual(M.monitorEvent("wlan0: connected").relevant, false)
})

test("connect args are built from a fixed table", () => {
  assert.deepStrictEqual(M.connectArgs("fastest"), ["protonvpn", "connect"])
  assert.deepStrictEqual(M.connectArgs("securecore"), ["protonvpn", "connect", "--securecore"])
  assert.deepStrictEqual(M.connectArgs("country", "JP"), ["protonvpn", "connect", "--country", "JP"])
  assert.strictEqual(M.connectArgs("country", "JP; rm -rf ~"), null)
  assert.strictEqual(M.connectArgs("country", "--help"), null)
  assert.strictEqual(M.connectArgs("bogus"), null)
})

test("setting args are built from a fixed table", () => {
  assert.deepStrictEqual(M.settingArgs("netshield", "off"), ["protonvpn", "config", "set", "netshield", "off"])
  assert.strictEqual(M.settingArgs("kill-switch", "advanced"), null)
  assert.strictEqual(M.settingArgs("custom-dns", "on"), null)
  assert.strictEqual(M.settingArgs("netshield", "off --x"), null)
})

// Every QML Text in the plugin renders as plain text, so CLI output that
// looks like markup is never interpreted.
test("every Text is PlainText", () => {
  const dir = path.join(__dirname, "..")
  for (const file of fs.readdirSync(dir).filter(f => f.endsWith(".qml"))) {
    const src = fs.readFileSync(path.join(dir, file), "utf8")
    const texts = (src.match(/(^|[\s:])Text\s*\{/g) || []).length
    const plain = (src.match(/textFormat:\s*Text\.PlainText/g) || []).length
    assert.strictEqual(plain, texts, file + ": " + texts + " Text items but " + plain + " PlainText formats")
  }
})

if (failures > 0) { console.log(failures + " failed"); process.exit(1) }
console.log("all passed")
