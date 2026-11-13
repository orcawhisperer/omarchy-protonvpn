import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.orcawhisperer.protonvpn"
  ipcTarget: "io.github.orcawhisperer.protonvpn"
  manageIpc: false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // Items inside the lazily built panel content, null until it first opens.
  readonly property Item panelFlick: panel.loadedContent ? panel.loadedContent.panelFlick : null
  readonly property Item countrySearch: panel.loadedContent ? panel.loadedContent.countrySearch : null
  readonly property Item countryList: panel.loadedContent ? panel.loadedContent.countryList : null
  readonly property Item quickRow: panel.loadedContent ? panel.loadedContent.quickRow : null
  readonly property Item settingsColumn: panel.loadedContent ? panel.loadedContent.settingsColumn : null

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Commons.Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Commons.Color.accent) : "transparent"
  readonly property color barIconColor: vpn.connected || vpn.busy ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property bool showCountry: setting("showCountryCode", true) === true && !(bar && bar.vertical)
  readonly property string barLabel: showCountry && vpn.connected && !vpn.disconnecting ? vpn.countryCode : ""

  // ---- cursor ---------------------------------------------------------

  property string focusSection: "header"   // header | quick | settings | countries
  property int quickIndex: 0
  property int settingIndex: 0
  property int chipIndex: 0
  property int countryIndex: 0
  property bool cursorActive: false
  property string countryQuery: ""

  readonly property var quickKinds: Model.QUICK_CONNECTS
  readonly property var filteredCountries: Model.filterCountries(vpn.countries, countryQuery)

  // The settings, in panel order. Choice rows carry their options; the
  // rest are on/off switches.
  readonly property var settingRows: [
    { key: "netshield", kind: "choice", title: strings.t("settings.netshield"), help: strings.t("settings.netshieldHelp"),
      options: [
        { value: "off", label: strings.t("settings.netshieldOff") },
        { value: "malware-only", label: strings.t("settings.netshieldMalware") },
        { value: "malware-ads-trackers", label: strings.t("settings.netshieldAll") }
      ] },
    { key: "kill-switch", kind: "choice", title: strings.t("settings.killSwitch"),
      help: vpn.connected ? strings.t("settings.killSwitchLocked") : strings.t("settings.killSwitchHelp"),
      note: strings.t("settings.killSwitchAdvanced"),
      locked: vpn.connected,
      options: [
        { value: "off", label: strings.t("settings.off") },
        { value: "standard", label: strings.t("settings.standard") }
      ] },
    { key: "port-forwarding", kind: "switch", title: strings.t("settings.portForwarding"), help: strings.t("settings.portForwardingHelp") },
    { key: "vpn-accelerator", kind: "switch", title: strings.t("settings.vpnAccelerator"), help: strings.t("settings.vpnAcceleratorHelp") },
    { key: "moderate-nat", kind: "switch", title: strings.t("settings.moderateNat"), help: strings.t("settings.moderateNatHelp") },
    { key: "ipv6", kind: "switch", title: strings.t("settings.ipv6"), help: strings.t("settings.ipv6Help") }
  ]
  readonly property bool showSettings: vpn.installed && vpn.configLoaded && settingsExpanded
  // Settings fold into one summary row so the country list sits near the
  // top; the choice survives closing the panel.
  property bool settingsExpanded: false

  function optionLabel(key, value) {
    for (var i = 0; i < settingRows.length; i++) {
      var row = settingRows[i]
      if (row.key !== key) continue
      if (row.kind === "choice") {
        for (var j = 0; j < row.options.length; j++) if (row.options[j].value === value) return row.options[j].label
        return value
      }
    }
    return value
  }

  readonly property string settingsSummary: {
    if (!vpn.configLoaded) return strings.t("settings.loading")
    var c = vpn.config
    var parts = [strings.t("settings.summaryNetshield").arg(optionLabel("netshield", c["netshield"])),
                 strings.t("settings.summaryKillSwitch").arg(optionLabel("kill-switch", c["kill-switch"]))]
    var on = []
    if (c["port-forwarding"] === "on") on.push(strings.t("settings.portForwarding"))
    if (c["vpn-accelerator"] === "on") on.push(strings.t("settings.summaryAccelerator"))
    if (c["moderate-nat"] === "on") on.push(strings.t("settings.moderateNat"))
    if (c["ipv6"] === "on") on.push(strings.t("settings.ipv6"))
    if (on.length > 0) parts.push(on.join(", "))
    return parts.join(" · ")
  }

  function toggleSettings() {
    settingsExpanded = !settingsExpanded
    cursorActive = true
    focusSection = "settingsHeader"
    if (settingsExpanded && !vpn.configLoaded) vpn.refreshConfig()
  }

  function quickLabel(kind) { return strings.t("quick." + kind) }
  function quickGlyph(kind) {
    if (kind === "fastest") return "\u{f140b}"
    if (kind === "securecore") return "\u{f099d}"
    if (kind === "p2p") return "\u{f04e1}"
    if (kind === "tor") return "\u{f05f9}"
    return "\u{f049f}"
  }

  function countryName(code) {
    for (var i = 0; i < vpn.countries.length; i++)
      if (vpn.countries[i].code === code) return vpn.countries[i].name
    return code
  }

  // What the busy line names while a connect runs.
  readonly property string targetLabel: {
    var target = vpn.actionTarget
    if (target.indexOf("country:") === 0) return countryName(target.substring(8))
    if (target !== "") return strings.t("quick." + target + "Target")
    return strings.t("quick.fastestTarget")
  }

  readonly property string busyText: {
    if (vpn.actionKind === "connect") return strings.t("action.connectingTo").arg(targetLabel)
    if (vpn.actionKind === "disconnect") return strings.t("action.disconnecting")
    if (vpn.actionKind === "setting") return strings.t("action.applying").arg(settingTitle(vpn.actionTarget.substring(8)))
    return ""
  }

  function settingTitle(key) {
    for (var i = 0; i < settingRows.length; i++) if (settingRows[i].key === key) return settingRows[i].title
    return key
  }

  readonly property string heroTitle: {
    if (vpn.connected && !vpn.connecting && vpn.location !== "") return vpn.location
    if (vpn.connecting && vpn.actionKind === "connect" && vpn.actionTarget.indexOf("country:") === 0) return targetLabel
    if (vpn.connected && vpn.server !== "") return vpn.server
    return strings.t("name")
  }

  readonly property string heroMeta: {
    if (!vpn.installed) return vpn.checkedInstall ? strings.t("state.notInstalled") : strings.t("state.checking")
    if (vpn.phase === "connecting") return strings.t("state.connecting")
    if (vpn.phase === "disconnecting") return strings.t("state.disconnecting")
    if (vpn.connected) return vpn.server !== "" ? strings.t("state.connectedTo").arg(vpn.server) : strings.t("state.connected")
    return strings.t("state.disconnected")
  }

  readonly property string tooltipText: {
    if (!vpn.installed) return vpn.checkedInstall ? strings.t("tooltip.notInstalled") : ""
    var hint = "\n" + strings.t("tooltip.hint")
    if (vpn.phase === "connecting") return strings.t("tooltip.connecting") + hint
    if (vpn.phase === "disconnecting") return strings.t("tooltip.disconnecting") + hint
    if (!vpn.connected) return strings.t("tooltip.disconnected") + hint
    var parts = []
    if (vpn.server !== "") parts.push(strings.t("tooltip.server").arg(vpn.server))
    if (vpn.location !== "") parts.push(strings.t("tooltip.location").arg(vpn.location))
    if (vpn.load >= 0) parts.push(strings.t("tooltip.load").arg(Commons.I18n.formatNumber(vpn.load)))
    if (vpn.protocol !== "") parts.push(strings.t("tooltip.protocol").arg(vpn.protocolText))
    return strings.t("tooltip.connected").arg(parts.join("\n")) + hint
  }

  function sections() {
    var list = ["header"]
    if (vpn.installed) list.push("quick")
    if (vpn.installed) list.push("settingsHeader")
    if (showSettings) list.push("settings")
    if (vpn.installed && filteredCountries.length > 0) list.push("countries")
    return list
  }

  function ensureCursor() {
    var list = sections()
    if (list.indexOf(focusSection) === -1) focusSection = list[list.length - 1]
    quickIndex = Math.max(0, Math.min(quickIndex, quickKinds.length - 1))
    settingIndex = Math.max(0, Math.min(settingIndex, settingRows.length - 1))
    countryIndex = Math.max(0, Math.min(countryIndex, Math.max(0, filteredCountries.length - 1)))
    var row = settingRows[settingIndex]
    if (row && row.kind === "choice") chipIndex = Math.max(0, Math.min(chipIndex, row.options.length - 1))
  }

  function enterSettingRow(index) {
    settingIndex = index
    var row = settingRows[index]
    if (row && row.kind === "choice") {
      var current = 0
      for (var i = 0; i < row.options.length; i++) if (row.options[i].value === vpn.config[row.key]) current = i
      chipIndex = current
    }
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    var list = sections()
    var at = list.indexOf(focusSection)
    if (dx !== 0) {
      if (focusSection === "quick") quickIndex = Math.max(0, Math.min(quickKinds.length - 1, quickIndex + dx))
      else if (focusSection === "settings") {
        var row = settingRows[settingIndex]
        if (row.kind === "choice") chipIndex = Math.max(0, Math.min(row.options.length - 1, chipIndex + dx))
      }
    }
    if (dy > 0) {
      if (focusSection === "settings" && settingIndex < settingRows.length - 1) enterSettingRow(settingIndex + 1)
      else if (focusSection === "countries") { if (countryIndex < filteredCountries.length - 1) countryIndex++ }
      else if (at < list.length - 1) {
        focusSection = list[at + 1]
        if (focusSection === "settings") enterSettingRow(0)
        if (focusSection === "countries") countryIndex = 0
      }
    } else if (dy < 0) {
      if (focusSection === "settings" && settingIndex > 0) enterSettingRow(settingIndex - 1)
      else if (focusSection === "countries" && countryIndex > 0) countryIndex--
      else if (at > 0) {
        focusSection = list[at - 1]
        if (focusSection === "settings") enterSettingRow(settingRows.length - 1)
      }
    }
    ensureCursor()
    scrollCursorIntoView()
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "header") vpn.toggleVpn()
    else if (focusSection === "quick") quickConnect(quickKinds[quickIndex])
    else if (focusSection === "settingsHeader") toggleSettings()
    else if (focusSection === "settings") activateSetting(settingIndex, chipIndex)
    else if (focusSection === "countries") connectCountry(filteredCountries[countryIndex])
  }

  function quickConnect(kind) {
    vpn.connectTo(kind, "", quickLabel(kind))
  }

  function connectCountry(country) {
    if (!country) return
    vpn.connectTo("country", country.code, country.name)
  }

  function activateSetting(index, chip) {
    var row = settingRows[index]
    if (!row || vpn.busy) return
    if (row.kind === "choice") {
      var option = row.options[Math.max(0, Math.min(chip, row.options.length - 1))]
      if (option) vpn.setSetting(row.key, option.value)
    } else {
      vpn.setSetting(row.key, vpn.config[row.key] === "on" ? "off" : "on")
    }
  }

  readonly property string shownIp: vpn.publicIp !== "" ? vpn.publicIp : vpn.entryIp

  function copyIp() {
    var ip = shownIp
    if (ip === "") return
    // argv, never a shell string: the address goes to wl-copy as data.
    Quickshell.execDetached(["wl-copy", "--", ip])
    vpn.actionStatus = strings.t("action.copied").arg(ip)
    copiedTimer.restart()
  }

  function focusSearch() {
    if (!countrySearch || !countrySearch.visible) return
    focusSection = "countries"
    scrollItemIntoView(countrySearch)
    countrySearch.forceActiveFocus()
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item || !panelFlick) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    if (!cursorActive) return
    if (focusSection === "header" && panelFlick) panelFlick.contentY = 0
    else if (focusSection === "quick") scrollItemIntoView(quickRow)
    else if (focusSection === "settingsHeader" && panel.loadedContent) scrollItemIntoView(panel.loadedContent.settingsHeaderRow)
    else if (focusSection === "settings" && settingsColumn && settingIndex < settingsColumn.children.length) scrollItemIntoView(settingsColumn.children[settingIndex])
    else if (focusSection === "countries" && countryList && filteredCountries.length > 0) {
      countryList.positionViewAtIndex(countryIndex, ListView.Contain)
      scrollItemIntoView(countryList)
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    focusSection = "header"
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  } else if (countrySearch && countrySearch.text !== "") {
    // A filter must not survive the panel: reopening to a short list
    // looks like countries are missing.
    countrySearch.text = ""
  }
  onFilteredCountriesChanged: ensureCursor()
  onShowSettingsChanged: ensureCursor()

  Service {
    id: vpn
    settings: root.settings
    panelOpen: root.opened
    tr: function(key, fallback) { return strings.t(key, fallback) }
  }

  Timer {
    id: copiedTimer
    interval: 2000
    onTriggered: if (root.shownIp !== "" && vpn.actionStatus.indexOf(root.shownIp) !== -1) vpn.actionStatus = ""
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { vpn.refreshAll(); return "ok" }
    function connect(): string { vpn.connectFastest(); return "ok" }
    function connectCountry(code: string): string {
      var value = String(code || "").toUpperCase()
      if (!Model.isCountryCode(value)) return "invalid country code"
      vpn.connectTo("country", value, root.countryName(value))
      return "ok"
    }
    function disconnect(): string { vpn.disconnect(); return "ok" }
    function toggleVpn(): string { vpn.toggleVpn(); return "ok" }
    function status(): string { return vpn.statusText }
    function lastError(): string { return vpn.lastError }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelText: root.barLabel
    slotSize: root.barLabel !== "" ? Math.round(Style.bar.iconSlot * 1.8) : Style.bar.iconSlot
    tooltipText: root.opened ? "" : root.tooltipText
    iconComponent: Component {
      Item {
        ShieldIcon {
          x: (parent.width - width) / 2
          y: (parent.height - height) / 2
          iconSize: button.iconSize
          color: root.barIconColor
          mode: vpn.phase
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) vpn.toggleVpn()
      else if (buttonCode === Qt.MiddleButton) vpn.refreshAll()
      else root.toggle()
    }
  }

  // Keep a visible tooltip current as the state changes under the pointer.
  onTooltipTextChanged: if (root.bar && button.tooltipHovered && !root.opened) root.bar.showTooltip(button, tooltipText)

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(640))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias panelFlick: panelFlick
      property alias countrySearch: countrySearch
      property alias countryList: countryList
      property alias quickRow: quickRow
      property alias settingsColumn: settingsColumn
      property alias settingsHeaderRow: settingsHeaderRow
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; root.ensureCursor(); return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "t" || t === "T") vpn.toggleVpn()
        else if (t === "r" || t === "R") vpn.refreshAll()
        else if (t === "c" || t === "C") root.copyIp()
        else if (t === "/") root.focusSearch()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---- hero ----------------------------------------------------
          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.cursorActive && root.focusSection === "header"
            function focusHero() { root.cursorActive = true; root.focusSection = "header" }

            PanelHero {
              id: hero
              width: parent.width
              title: root.heroTitle
              meta: root.heroMeta
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: vpn.connected || vpn.busy ? 1.0 : 0.55
              iconComponent: Component {
                ShieldIcon {
                  iconSize: Style.font.display
                  color: root.foreground
                  mode: vpn.phase
                }
              }
              // The switch stands alone: the title and meta line already name
              // the country and server, and the bar shows the country code.
              trailingControl: Component {
                Row {
                  visible: vpn.installed

                  ToggleSwitch {
                    id: powerSwitch
                    anchors.verticalCenter: parent.verticalCenter
                    checked: vpn.phase === "connected" || vpn.phase === "connecting"
                    busy: vpn.busy
                    hasCursor: header.ringVisible
                    foreground: hero.foreground
                    onHovered: function(on) { if (on) header.focusHero() }
                    onToggled: vpn.toggleVpn()

                    PanelToolTip {
                      visible: powerSwitch.containsMouse
                      text: vpn.connected ? strings.t("action.disconnect") : strings.t("action.connect")
                      fontFamily: hero.fontFamily
                    }
                  }
                }
              }
            }
          }

          // ---- busy / error / confirmation line --------------------------
          Item {
            id: statusLine
            readonly property bool isError: vpn.lastError !== "" && !vpn.busy
            readonly property string message: vpn.busy ? root.busyText : (isError ? vpn.lastError : vpn.actionStatus)
            visible: message !== ""
            width: parent.width
            implicitHeight: Math.max(statusText.implicitHeight, dismissButton.visible ? dismissButton.implicitHeight : 0)

            Text {
              id: statusGlyph
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.top: statusText.top
              text: vpn.busy ? "\u{f0450}" : (statusLine.isError ? "\u{f0026}" : "\u{f012c}")
              color: statusLine.isError ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              width: Style.space(16)
              horizontalAlignment: Text.AlignHCenter

              RotationAnimation on rotation {
                running: vpn.busy && !Style.reduceMotion
                from: 0
                to: 360
                duration: Style.duration(900)
                loops: Animation.Infinite
              }
              onRotationChanged: if (!vpn.busy && rotation !== 0) rotation = 0
            }

            Text {
              id: statusText
              textFormat: Text.PlainText
              anchors.left: statusGlyph.right
              anchors.leftMargin: Style.space(6)
              anchors.right: dismissButton.visible ? dismissButton.left : parent.right
              anchors.rightMargin: dismissButton.visible ? Style.space(6) : 0
              anchors.verticalCenter: parent.verticalCenter
              text: statusLine.message
              color: statusLine.isError ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              maximumLineCount: 4
              elide: Text.ElideRight
            }

            PanelActionButton {
              id: dismissButton
              visible: statusLine.isError
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\u{f0156}"
              tooltipText: strings.t("action.dismiss")
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: vpn.lastError = ""
            }
          }

          // ---- connection details ----------------------------------------
          GridLayout {
            visible: vpn.connected && !vpn.connecting
            width: parent.width
            columns: 4
            columnSpacing: Style.space(16)
            rowSpacing: Style.spacing.labelGap

            InfoLabel { text: strings.t("detail.server") }
            InfoValue { text: vpn.server || strings.t("detail.unknown") }
            InfoLabel { text: strings.t("detail.load") }
            InfoValue {
              text: vpn.load >= 0 ? strings.t("detail.loadValue").arg(Commons.I18n.formatNumber(vpn.load)) : strings.t("detail.unknown")
              color: vpn.load >= 90 ? root.urgent : root.foreground
            }

            InfoLabel { text: strings.t("detail.protocol") }
            InfoValue { text: vpn.protocolText || strings.t("detail.unknown") }
            InfoLabel { text: vpn.publicIp !== "" || vpn.entryIp === "" ? strings.t("detail.ip") : strings.t("detail.serverIp") }
            InfoValue {
              id: ipValue
              text: root.shownIp || strings.t("detail.unknown")

              MouseArea {
                id: ipMouse
                anchors.fill: parent
                enabled: root.shownIp !== ""
                hoverEnabled: enabled
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.copyIp()
              }

              PanelToolTip {
                visible: ipMouse.enabled && ipMouse.containsMouse
                text: strings.t("action.copyIp") + "  (c)"
                fontFamily: root.fontFamily
              }
            }
          }

          // ---- quick connect ---------------------------------------------
          PanelSeparator {
            visible: vpn.installed
            foreground: root.foreground
          }

          Column {
            visible: vpn.installed
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: strings.t("quick.title")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              id: quickRow
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.quickKinds
                QuickTile {
                  required property var modelData
                  required property int index
                  kind: String(modelData)
                  tileIndex: index
                  width: (quickRow.width - quickRow.spacing * (root.quickKinds.length - 1)) / root.quickKinds.length
                }
              }
            }
          }

          // ---- settings --------------------------------------------------
          PanelSeparator {
            visible: vpn.installed
            foreground: root.foreground
          }

          Column {
            visible: vpn.installed
            width: parent.width
            spacing: Style.space(10)

            SettingsHeaderRow {
              id: settingsHeaderRow
              width: parent.width
            }

            Column {
              id: settingsColumn
              visible: root.showSettings
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: root.settingRows
                SettingRow {
                  required property var modelData
                  required property int index
                  width: settingsColumn.width
                  row: modelData
                  rowIndex: index
                }
              }
            }
          }

          // ---- countries -------------------------------------------------
          PanelSeparator {
            visible: vpn.installed
            foreground: root.foreground
          }

          Column {
            visible: vpn.installed
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: {
                var total = vpn.countries.length
                if (total === 0) return strings.t("countries.title")
                if (root.countryQuery.trim() === "") return strings.t("countries.title") + " · " + strings.tn("countries.count", total).arg(Commons.I18n.formatNumber(total))
                return strings.t("countries.title") + " · " + strings.t("countries.filtered").arg(Commons.I18n.formatNumber(root.filteredCountries.length)).arg(Commons.I18n.formatNumber(total))
              }
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            TextField {
              id: countrySearch
              visible: vpn.countriesLoaded
              width: parent.width
              foreground: root.foreground
              placeholderText: strings.t("countries.search")
              onTextChanged: {
                root.countryQuery = text.length > 64 ? text.substring(0, 64) : text
                root.countryIndex = 0
                countryList.positionViewAtBeginning()
              }
              onActiveFocusChanged: if (activeFocus) { root.cursorActive = true; root.focusSection = "countries"; root.countryIndex = 0 }
              // Enter connects to the highlighted match, so "/ jap ⏎" is a
              // complete gesture.
              onAccepted: {
                if (root.filteredCountries.length === 0) return
                root.connectCountry(root.filteredCountries[Math.min(root.countryIndex, root.filteredCountries.length - 1)])
                keyCatcher.forceActiveFocus()
              }
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Down) {
                  root.cursorActive = true
                  root.focusSection = "countries"
                  if (root.countryIndex < root.filteredCountries.length - 1) root.countryIndex++
                  root.scrollCursorIntoView()
                  event.accepted = true
                } else if (event.key === Qt.Key_Up) {
                  if (root.countryIndex > 0) { root.countryIndex--; root.scrollCursorIntoView() }
                  else keyCatcher.forceActiveFocus()
                  event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                  if (countrySearch.text !== "") countrySearch.text = ""
                  else keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: !vpn.countriesLoaded
              width: parent.width
              text: strings.t("countries.loading")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              textFormat: Text.PlainText
              visible: vpn.countriesLoaded && root.filteredCountries.length === 0
              width: parent.width
              text: strings.t("countries.none")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
            }

            ListView {
              id: countryList
              visible: root.filteredCountries.length > 0
              width: parent.width
              height: Math.min(contentHeight, Style.space(250))
              clip: true
              spacing: Style.space(2)
              model: root.filteredCountries
              reuseItems: true
              boundsBehavior: Flickable.StopAtBounds
              flickableDirection: Flickable.VerticalFlick
              interactive: contentHeight > height
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              delegate: CountryRow {
                required property var modelData
                required property int index
                width: countryList.width
                country: modelData
                rowIndex: index
              }
            }
          }
        }
      }
    }
  }

  // ---- row components -------------------------------------------------

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    Layout.fillWidth: true
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    horizontalAlignment: Text.AlignRight
    elide: Text.ElideRight
  }

  component QuickTile: CursorSurface {
    id: tile
    property string kind: ""
    property int tileIndex: 0
    readonly property bool working: vpn.actionKind === "connect" && vpn.actionTarget === kind

    hasCursor: root.cursorActive && root.focusSection === "quick" && root.quickIndex === tileIndex
    current: working
    bordered: true
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    opacity: vpn.busy && !working ? 0.5 : 1.0
    implicitHeight: tileColumn.implicitHeight + Style.space(16)

    Column {
      id: tileColumn
      anchors.centerIn: parent
      width: parent.width - Style.space(6)
      spacing: Style.space(4)

      Text {
        textFormat: Text.PlainText
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.quickGlyph(tile.kind)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.iconLarge

        RotationAnimation on rotation {
          running: tile.working && !Style.reduceMotion
          from: 0
          to: 360
          duration: Style.duration(900)
          loops: Animation.Infinite
        }
        onRotationChanged: if (!tile.working && rotation !== 0) rotation = 0
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: root.quickLabel(tile.kind)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        fontSizeMode: Text.HorizontalFit
        minimumPixelSize: Math.max(7, Style.font.caption - 3)
        elide: Text.ElideRight
      }
    }

    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: vpn.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.focusSection = "quick"; root.quickIndex = tile.tileIndex }
      onClicked: if (!vpn.busy) root.quickConnect(tile.kind)
    }

    PanelToolTip {
      visible: tileMouse.containsMouse
      text: strings.t("quick." + tile.kind + "Help")
      fontFamily: root.fontFamily
    }
  }

  component SettingsHeaderRow: CursorSurface {
    id: headerRow
    hasCursor: root.cursorActive && root.focusSection === "settingsHeader"
    foreground: root.foreground
    fill: root.hoverFill
    implicitHeight: headerInner.implicitHeight + Style.space(12)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.focusSection = "settingsHeader" }
      onClicked: root.toggleSettings()
    }

    RowLayout {
      id: headerInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        text: "\u{f0493}"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: strings.t("settings.title")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: root.settingsSummary
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        textFormat: Text.PlainText
        text: root.settingsExpanded ? "\u{f0140}" : "\u{f0142}"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }

  component SettingRow: CursorSurface {
    id: settingRow
    property var row: ({})
    property int rowIndex: 0
    readonly property string key: String(row.key || "")
    readonly property string value: String(vpn.config[key] || "")
    readonly property bool choice: row.kind === "choice"
    readonly property bool locked: row.locked === true
    readonly property bool working: vpn.actionKind === "setting" && vpn.actionTarget === "setting:" + key
    readonly property bool rowHasCursor: root.cursorActive && root.focusSection === "settings" && root.settingIndex === rowIndex

    // A choice row hands the cursor to its chips; a switch row owns it.
    hasCursor: rowHasCursor && !choice
    foreground: root.foreground
    fill: root.hoverFill
    implicitHeight: settingInner.implicitHeight + Style.space(12)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: settingRow.choice || vpn.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.focusSection = "settings"; if (root.settingIndex !== settingRow.rowIndex) root.enterSettingRow(settingRow.rowIndex) }
      onClicked: if (!settingRow.choice) root.activateSetting(settingRow.rowIndex, 0)
    }

    Column {
      id: settingInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(4)
      spacing: Style.space(6)

      RowLayout {
        width: parent.width
        spacing: Style.space(8)

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(1)

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: settingRow.row.title || ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: settingRow.row.help || ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        ToggleSwitch {
          id: settingSwitch
          visible: !settingRow.choice
          Layout.alignment: Qt.AlignVCenter
          interactive: false
          checked: settingRow.value === "on"
          busy: settingRow.working
          foreground: root.foreground
          opacity: settingRow.value === "" ? 0.4 : 1.0
        }
      }

      Row {
        visible: settingRow.choice
        spacing: Style.space(6)

        Repeater {
          model: settingRow.choice ? settingRow.row.options : []
          Button {
            required property var modelData
            required property int index
            text: String(modelData.label || "")
            fontSize: Style.font.bodySmall
            foreground: root.foreground
            fontFamily: root.fontFamily
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            enabled: !settingRow.locked
            opacity: settingRow.locked ? 0.45 : 1.0
            iconText: settingRow.working && settingRow.value !== modelData.value && root.chipIndex === index ? "\u{f0450}" : ""
            iconSpinning: iconText !== ""
            active: settingRow.value === modelData.value
            hasCursor: settingRow.rowHasCursor && root.chipIndex === index
            onClicked: if (!vpn.busy) root.activateSetting(settingRow.rowIndex, index)
            onHovered: function(isHovered) {
              if (!isHovered) return
              root.cursorActive = true
              root.focusSection = "settings"
              root.settingIndex = settingRow.rowIndex
              root.chipIndex = index
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: (settingRow.row.note || "") !== ""
        width: parent.width
        text: settingRow.row.note || ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.italic: true
        wrapMode: Text.WordWrap
      }
    }
  }

  component CountryRow: CursorSurface {
    id: countryRow
    property var country: null
    property int rowIndex: 0
    readonly property string code: country ? String(country.code || "") : ""
    readonly property string name: country ? String(country.name || "") : ""
    readonly property bool isCurrent: vpn.connected && !vpn.connecting && vpn.countryCode === code
    readonly property bool working: vpn.actionKind === "connect" && vpn.actionTarget === "country:" + code

    hasCursor: root.cursorActive && root.focusSection === "countries" && root.countryIndex === rowIndex
    current: isCurrent || working
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: countryInner.implicitHeight + Style.space(10)

    RowLayout {
      id: countryInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        text: countryRow.working ? "\u{f0450}" : Model.flag(countryRow.code)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        Layout.preferredWidth: Style.space(20)
        horizontalAlignment: Text.AlignHCenter

        RotationAnimation on rotation {
          running: countryRow.working && !Style.reduceMotion
          from: 0
          to: 360
          duration: Style.duration(900)
          loops: Animation.Infinite
        }
        onRotationChanged: if (!countryRow.working && rotation !== 0) rotation = 0
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: countryRow.name
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: countryRow.isCurrent
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        text: countryRow.isCurrent ? strings.t("countries.current") : countryRow.code
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      id: countryMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: vpn.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.focusSection = "countries"; root.countryIndex = countryRow.rowIndex }
      onClicked: if (!vpn.busy) root.connectCountry(countryRow.country)
    }

    PanelToolTip {
      visible: countryMouse.containsMouse && !countryRow.isCurrent
      text: strings.t("countries.connect").arg(countryRow.name)
      fontFamily: root.fontFamily
    }
  }
}
