import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Blood glucose pill for the Omarchy bar.
//
// The widget owns the polling loop, so the value keeps updating whether or not
// the detail panel is open; the panel is a pure view over `payload`.
//
// Data arrives from scripts/glucose-fetch.py, which normalizes LibreLinkUp,
// Nightscout or mock data into one schema (everything mg/dL + UTC seconds).
BarWidget {
  id: root
  moduleName: "wildpig.glucose"

  // ---- settings (inline in ~/.config/omarchy/shell.json) ------------------

  // shell.json stores booleans as strings (enum schema), so normalize both.
  function boolSetting(name, fallback) {
    var raw = setting(name, fallback)
    if (raw === true || raw === false) return raw
    var text = String(raw).toLowerCase()
    if (text === "true" || text === "1" || text === "yes" || text === "on") return true
    if (text === "false" || text === "0" || text === "no" || text === "off" || text === "") return false
    return !!fallback
  }

  readonly property string unit: String(setting("unit", "mmol/L"))
  readonly property string palette: String(setting("palette", "traffic"))
  readonly property string lang: String(setting("lang", "zh"))
  readonly property bool showTrend: boolSetting("showTrend", true)
  readonly property bool showUnit: boolSetting("showUnit", false)
  readonly property int staleMinutes: Math.max(5, parseInt(setting("staleMinutes", 35), 10) || 35)
  readonly property int refreshSeconds: Math.max(15, parseInt(setting("refreshIntervalSec", 60), 10) || 60)
  readonly property string sourceOverride: String(setting("source", ""))
  readonly property int defaultWindowHours: Math.max(1, parseInt(setting("windowHours", 6), 10) || 6)
  readonly property bool alerts: boolSetting("alerts", false)
  readonly property int alertRepeatMinutes: Math.max(5, parseInt(setting("alertRepeatMinutes", 15), 10) || 15)
  readonly property bool sparkline: boolSetting("sparkline", false)

  // ---- paths --------------------------------------------------------------

  // Qt.resolvedUrl(".") points at the plugin directory; Process needs a real
  // filesystem path, not a file:// URL.
  readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, ""))
  readonly property string fetchScript: pluginDir + "scripts/glucose-fetch.py"
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/glucose/config.json"
  readonly property string cachePath: Quickshell.env("HOME") + "/.local/state/glucose/last.json"

  // ---- state --------------------------------------------------------------

  property var payload: null
  property string lastError: ""
  property string lastErrorCode: ""
  property bool fetching: false
  property double nowSec: Math.floor(Date.now() / 1000)

  readonly property var series: payload && payload.series ? payload.series : []
  readonly property var sensor: payload && payload.sensor ? payload.sensor : ({})

  readonly property var current: {
    if (payload && payload.current) return payload.current
    return series.length > 0 ? series[series.length - 1] : null
  }

  readonly property real targetLow: payload && payload.targetLow ? Number(payload.targetLow) : 70
  readonly property real targetHigh: payload && payload.targetHigh ? Number(payload.targetHigh) : 180

  readonly property int ageSec: current && current.t ? Math.max(0, nowSec - Number(current.t)) : -1
  readonly property bool stale: ageSec < 0 ? true : ageSec > staleMinutes * 60
  readonly property string state: current ? Model.rangeState(current.v, targetLow, targetHigh) : "unknown"
  readonly property bool outOfRange: Model.isOutOfRange(state)

  // True while the numbers on screen come from the synthetic mock source. The
  // bar pill refuses to print them: a glanceable fake glucose number is worse
  // than no number at all.
  readonly property bool sampleData: payload && (payload.seriesSource || payload.source) === "mock"

  readonly property string displayText: {
    if (sampleData) return "--"
    if (!current) return "--"
    var text = Model.formatValue(current.v, unit)
    if (showTrend) text += " " + Model.trendGlyph(current.tr)
    if (showUnit) text += " " + Model.unitSuffix(unit)
    return text
  }

  readonly property string tooltip: {
    var lines = []
    var zh = lang === "zh"
    if (sampleData) lines.push(zh ? "示例数据（mock），不是真实血糖" : "sample data (mock), not real glucose")
    if (lastError !== "") lines.push((Model.label("error", lang)) + ": " + lastError)
    if (current) {
      lines.push(Model.label("source", lang) + ": " + (payload && payload.sourceLabel ? payload.sourceLabel : "?"))
      lines.push(Model.label("trend", lang) + ": " + Model.trendGlyph(current.tr) + "  " + Model.ageText(ageSec, lang))
    }
    if (stale && !lastError) lines.push(zh ? "云端读数已过期" : "cloud reading is stale")
    lines.push(Model.label("hint", lang))
    return lines.join("\n")
  }

  // Optional inline sparkline of the last three hours, for people who want the
  // shape of the day in the bar without opening the panel.
  readonly property var sparkPoints: {
    if (!sparkline || !payload || series.length < 2) return []
    // 30 minutes rather than the 15-minute cadence: LibreLinkUp publishes
    // roughly every 15 minutes and lags behind by 5-15 more, so a 20-minute-old
    // reading is normal operation and would break the line for no reason.
    var points = Model.sliceWindow(series, nowSec, 3)
    if (points.length <= 40) return points
    // Downsample for a 38px canvas; every point would just add noise.
    var out = []
    var step = (points.length - 1) / 39
    for (var index = 0; index < 40; index++) out.push(points[Math.round(index * step)])
    return out
  }
  readonly property bool sparkVisible: sparkline && !vertical && sparkPoints.length > 1

  onSparkPointsChanged: if (spark) spark.requestPaint()
  onNowSecChanged: if (spark && root.sparkVisible) spark.requestPaint()

  readonly property color stateColor: Model.stateColor(
    state,
    palette,
    bar ? bar.barForeground : Color.foreground,
    bar ? bar.urgent : Color.urgent
  )

  // ---- alerts ------------------------------------------------------------
  //
  // Only rising edges fire: a value that stays low must not re-notify every
  // poll, but it should re-notify if it stays low for alertRepeatMinutes. Data
  // we already consider stale is never alerted on, because a two-hour-old
  // reading is not news about right now.
  property string alertedState: ""
  property double alertedAt: 0
  property string alertedSensor: ""
  readonly property double createdSec: Math.floor(Date.now() / 1000)

  function evaluateAlerts() {
    if (!alerts) return
    if (!current || ageSec < 0) return
    // Swallow the first two minutes after a shell restart so a fresh widget
    // does not replay an alert the user already saw.
    if (nowSec - createdSec < 120) return

    if (stale) return

    if (!Model.isOutOfRange(state)) {
      alertedState = state
      return
    }

    var repeat = alertRepeatMinutes * 60
    if (state === alertedState && nowSec - alertedAt < repeat) return
    alertedState = state
    alertedAt = nowSec
    sendAlert(state)
  }

  function sendAlert(state) {
    var lowish = state === "low" || state === "veryLow"
    var urgent = state !== "high"
    var value = Model.formatValue(current.v, unit) + " " + Model.unitSuffix(unit)
    var headline = (lang === "zh"
      ? (lowish ? "\u8840\u7cd6\u504f\u4f4e " : "\u8840\u7cd6\u504f\u9ad8 ")
      : (lowish ? "Low glucose " : "High glucose ")) + value
    var body = Model.ageText(ageSec, lang) + " \u00b7 " + Model.trendGlyph(current.tr)
      + " \u00b7 " + (payload && payload.sourceLabel ? payload.sourceLabel : "")

    Util.execArgv([
      "omarchy-notification-send",
      "--app-name", "glucose",
      "-u", urgent ? "critical" : "normal",
      // One stable replaces-id: a new alert supersedes the previous one instead
      // of stacking up a tower of notifications.
      "-r", "91700",
      "-g", Model.trendGlyph(current.tr),
      headline, body,
      "--exec", "omarchy-shell", "wildpig.glucose", "toggle"
    ])
    console.log("glucose: alert " + state + " " + value)
  }

  // Sensor expiry is a once-per-sensor event, not a repeating state.
  function evaluateSensorAlert() {
    if (!alerts || !sensor || !sensor.expiresAt) return
    var key = String(sensor.serial || "?") + "@" + String(sensor.expiresAt)
    if (key === alertedSensor) return
    var minutesLeft = (Number(sensor.expiresAt) - nowSec) / 60
    if (minutesLeft <= 0 || minutesLeft > 24 * 60) return
    alertedSensor = key
    var hours = Math.max(1, Math.round(minutesLeft / 60))
    Util.execArgv([
      "omarchy-notification-send",
      "--app-name", "glucose",
      "-u", "normal",
      "-r", "91701",
      lang === "zh" ? "\u4f20\u611f\u5668\u5373\u5c06\u5230\u671f" : "Sensor expiring soon",
      lang === "zh" ? "\u5269\u4f59 " + hours + " \u5c0f\u65f6" : hours + " hours left"
    ])
  }

  // ---- fetching -----------------------------------------------------------

  function refresh() {
    if (fetchProc.running) return
    var argv = ["python3", fetchScript, "--config", configPath, "--cache", cachePath]
    if (sourceOverride !== "") argv.push("--source", sourceOverride)
    fetchProc.command = argv
    fetching = true
    fetchProc.running = true
  }

  function applyPayload(raw) {
    var text = String(raw || "").trim()
    if (text === "") {
      lastError = "helper produced no output"
      lastErrorCode = "protocol"
      return
    }
    var parsed = null
    try {
      parsed = JSON.parse(text)
    } catch (error) {
      lastError = "helper produced invalid JSON: " + error
      lastErrorCode = "protocol"
      return
    }
    if (!parsed || typeof parsed !== "object") {
      lastError = "helper produced an unexpected payload"
      lastErrorCode = "protocol"
      return
    }

    payload = parsed
    if (parsed.ok === false) {
      lastError = parsed.error || "unknown error"
      lastErrorCode = parsed.code || "unknown"
    } else {
      lastError = ""
      lastErrorCode = ""
    }
    nowSec = Math.floor(Date.now() / 1000)
    if (panelLoader.item && panelLoader.item.onPayloadChanged) panelLoader.item.onPayloadChanged()
    evaluateAlerts()
    evaluateSensorAlert()
  }

  // Show the last good payload immediately at login instead of an empty pill
  // until the first network round trip lands.
  FileView {
    path: root.cachePath
    watchChanges: false
    printErrors: false
    onLoaded: {
      if (root.payload !== null) return
      try {
        var cached = JSON.parse(String(text() || ""))
        if (cached && cached.series) {
          root.payload = cached
          if (cached.ok === false && cached.error) root.lastError = cached.error
        }
      } catch (error) {
        // A missing or half-written cache is not worth reporting.
      }
    }
  }

  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPayload(String(text || ""))
    }
    onExited: root.fetching = false
  }

  Timer {
    id: pollTimer
    interval: root.refreshSeconds * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Ages and the stale flag tick independently of the poll, so "3 分钟前"
  // stays honest between refreshes.
  Timer {
    interval: 20000
    repeat: true
    running: true
    onTriggered: root.nowSec = Math.floor(Date.now() / 1000)
  }

  // ---- panel plumbing -----------------------------------------------------

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item && panelLoader.item.closeForPopoutSwitch) panelLoader.item.closeForPopoutSwitch()
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "wildpig.glucose"

    function refresh(): void { root.broadcast("refresh") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.displayText
    foreground: root.bar ? root.bar.barForeground : Color.foreground
    active: root.outOfRange
    activeColor: root.stateColor
    dimmed: root.stale && root.current !== null
    tooltipText: root.tooltip
    horizontalMargin: 8.5

    // With the sparkline on, the built-in centred label is hidden and the
    // sparkline plus value are painted as children instead; the button still
    // owns click handling, tooltips and the bar's click registration.
    labelVisible: !root.sparkVisible
    fixedWidth: root.sparkVisible
      ? Style.space(38) + Style.space(4) + valueMetrics.width + 2 * button.scaledHorizontalMargin
      : -1

    onPressed: function(button) {
      if (button === Qt.MiddleButton) root.refresh()
      else if (button === Qt.RightButton) root.refresh()
      else root.togglePanel()
    }

    TextMetrics {
      id: valueMetrics
      font.family: button.fontFamily
      font.pixelSize: button.fontSize
      text: root.displayText
    }

    Row {
      visible: root.sparkVisible
      anchors.centerIn: parent
      spacing: Style.space(4)

      Canvas {
        id: spark
        width: Style.space(38)
        height: Math.max(10, Math.round(Style.bar.iconSlot * 0.42))
        anchors.verticalCenter: parent.verticalCenter
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var points = root.sparkPoints
          if (points.length < 2) return

          var domain = Model.valueDomain(points, root.targetLow, root.targetHigh)
          var geom = Model.chartPoints(points, width, height, domain, points[0].t, points[points.length - 1].t)
          if (geom.length < 2) return

          ctx.lineWidth = 1.5
          ctx.lineJoin = "round"
          ctx.lineCap = "round"
          ctx.strokeStyle = Model.rgbaOf(button.active ? root.stateColor : button.foreground, 0.85)
          ctx.beginPath()
          for (var index = 0; index < geom.length; index++) {
            if (index === 0) ctx.moveTo(geom[index].x, geom[index].y)
            else ctx.lineTo(geom[index].x, geom[index].y)
          }
          ctx.stroke()

          var last = geom[geom.length - 1]
          ctx.fillStyle = root.stateColor
          ctx.beginPath()
          ctx.arc(last.x, last.y, 1.8, 0, Math.PI * 2)
          ctx.fill()
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.displayText
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
      }
    }
  }
}
