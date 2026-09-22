import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Detail popup for the glucose pill.
//
// This is the piece the official apps get wrong: an arbitrary time window over
// real history, with the target band, the gaps and the reading age all visible
// instead of hidden behind an 8-hour scrollback.
Panel {
  id: root
  moduleName: "wildpig.glucose"
  ipcTarget: "wildpig.glucose"
  // The bar widget owns the polling loop and the IPC surface, so the panel
  // does not register its own conflicting target.
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- host data (reactive: `payload` lives on the bar widget) ------------

  readonly property var payload: hostWidget ? hostWidget.payload : null
  readonly property var series: payload && payload.series ? payload.series : []
  readonly property var sensor: payload && payload.sensor ? payload.sensor : ({})
  readonly property string lang: hostWidget ? hostWidget.lang : "zh"
  readonly property string unit: hostWidget ? hostWidget.unit : "mmol/L"
  readonly property string palette: hostWidget ? hostWidget.palette : "traffic"
  readonly property int nowSec: hostWidget ? hostWidget.nowSec : Math.floor(Date.now() / 1000)
  readonly property string errorText: hostWidget ? hostWidget.lastError : ""
  readonly property bool sampleData: payload && (payload.seriesSource || payload.source) === "mock"
  readonly property real targetLow: hostWidget ? hostWidget.targetLow : 70
  readonly property real targetHigh: hostWidget ? hostWidget.targetHigh : 180

  readonly property bool zh: lang === "zh"
  function t(key) { return Model.label(key, lang) }

  // ---- view state ---------------------------------------------------------

  property int windowHours: 6
  property int dayOffset: 0
  property bool initialised: false

  readonly property int windowEndSec: nowSec - dayOffset * 86400
  readonly property var windowPoints: Model.sliceWindow(series, windowEndSec, windowHours)
  readonly property var windowStats: Model.stats(windowPoints, targetLow, targetHigh)
  readonly property var domain: Model.valueDomain(windowPoints, targetLow, targetHigh)
  readonly property int maxDayOffset: {
    if (series.length === 0) return 0
    return Math.max(0, Math.floor((nowSec - Number(series[0].t)) / 86400))
  }
  readonly property var current: hostWidget ? hostWidget.current : null
  readonly property string state: current ? Model.rangeState(current.v, targetLow, targetHigh) : "unknown"
  readonly property color stateColor: Model.stateColor(
    state, palette, Color.foreground, Color.urgent
  )

  readonly property var rangeText: {
    var start = windowEndSec - windowHours * 3600
    if (windowHours >= 24) {
      if (dayOffset === 0) return t("today")
      if (dayOffset === 1) return t("yesterday")
      return dayOffset + " " + t("daysAgo")
    }
    return Model.formatClock(start) + " \u2013 " + Model.formatClock(windowEndSec)
  }

  // ---- lifecycle ----------------------------------------------------------

  function open() {
    if (hostWidget && hostWidget.refresh) hostWidget.refresh()
    if (!initialised) {
      initialised = true
      windowHours = hostWidget ? Math.max(1, hostWidget.defaultWindowHours) : 6
    }
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function openFromHotkey() { open() }
  function closeForPopoutSwitch() { root.controller.hide() }

  function shiftDay(delta) {
    var next = dayOffset + delta
    if (next < 0) next = 0
    if (next > maxDayOffset) next = maxDayOffset
    dayOffset = next
  }

  // The bar widget calls this after each refresh (it owns the polling loop).
  // A method, not an onPayloadChanged handler: handlers are signals and must
  // not be invoked directly, and the widget already repaints on every poll.
  function repaintChart() { chart.requestPaint() }
  onWindowHoursChanged: chart.requestPaint()
  onDayOffsetChanged: chart.requestPaint()
  onNowSecChanged: chart.requestPaint()

  // IPC lives on the bar widget (it owns the polling loop and exists even
  // while this panel is unloaded). A second handler on the same target would
  // fight it for the route.

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(470))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onReturnRequested: if (root.hostWidget && root.hostWidget.refresh) root.hostWidget.refresh()
      onTextKey: function(text) {
        if (text === "r") { if (root.hostWidget && root.hostWidget.refresh) root.hostWidget.refresh() }
        else if (text === "1") root.windowHours = 3
        else if (text === "2") root.windowHours = 6
        else if (text === "3") root.windowHours = 12
        else if (text === "4") root.windowHours = 24
        else if (text === "[") root.shiftDay(1)
        else if (text === "]") root.shiftDay(-1)
      }

      Column {
        id: column
        width: keyCatcher.width
        spacing: Style.spacing.lg

        // ---- hero ---------------------------------------------------------
        Item {
          width: parent.width
          height: Math.max(heroValue.implicitHeight, heroRight.implicitHeight)

          Row {
            id: heroValue
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.sm

            Text {
              id: valueText
              text: root.current ? Model.formatValue(root.current.v, root.unit) : "--"
              color: root.stateColor
              font.family: Style.font.family
              font.pixelSize: Style.font.displayLarge
              renderType: Text.NativeRendering
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              spacing: 0

              Text {
                text: root.current ? Model.trendGlyph(root.current.tr) : ""
                color: root.stateColor
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
                renderType: Text.NativeRendering
              }

              Text {
                text: Model.unitSuffix(root.unit)
                color: Color.foreground
                opacity: 0.6
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                renderType: Text.NativeRendering
              }
            }
          }

          Column {
            id: heroRight
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xxs

            Text {
              anchors.right: parent.right
              text: {
                if (!root.current) return root.t("noData")
                return Model.ageText(root.hostWidget ? root.hostWidget.ageSec : 0, root.lang)
              }
              color: root.hostWidget && root.hostWidget.stale ? Color.urgent : Color.foreground
              opacity: root.hostWidget && root.hostWidget.stale ? 1 : 0.7
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              renderType: Text.NativeRendering
            }

            Text {
              anchors.right: parent.right
              text: root.payload && root.payload.sourceLabel ? root.payload.sourceLabel : ""
              color: Color.foreground
              opacity: 0.55
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              renderType: Text.NativeRendering
            }

            Text {
              anchors.right: parent.right
              visible: text !== ""
              text: Model.sensorText(root.sensor, root.lang, root.nowSec)
              color: Color.foreground
              opacity: 0.45
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              renderType: Text.NativeRendering
            }
          }
        }

              // Sample data gets its own banner that never goes away: a widget that
        // looks plausible while showing synthetic numbers is a hazard.
        Rectangle {
          width: parent.width
          height: mockText.implicitHeight + Style.spacing.md * 2
          visible: root.sampleData
          color: Model.rgbaOf(Color.urgent, 0.12)
          border.width: Style.normalBorderWidth
          border.color: Model.rgbaOf(Color.urgent, 0.5)
          radius: Style.cornerRadius

          Text {
            id: mockText
            anchors.fill: parent
            anchors.margins: Style.spacing.md
            text: root.t("mockWarn")
            color: Color.foreground
            wrapMode: Text.WordWrap
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            renderType: Text.NativeRendering
          }
        }

        Rectangle {
          width: parent.width
          height: bannerText.implicitHeight + Style.spacing.md * 2
          visible: root.errorText !== "" || ((root.hostWidget && root.hostWidget.stale) && root.current !== null)
          color: Style.normalFillFor(Color.foreground, Color.accent, Color.urgent)
          border.width: Style.normalBorderWidth
          border.color: Style.normalBorderFor(Color.foreground, Color.accent, Color.urgent)
          radius: Style.cornerRadius

          Text {
            id: bannerText
            anchors.fill: parent
            anchors.margins: Style.spacing.md
            text: {
              if (root.errorText !== "") return root.t("error") + ": " + root.errorText
              var age = Model.ageText(root.hostWidget ? root.hostWidget.ageSec : 0, root.lang)
              return root.t("staleHint").replace("%1", age)
            }
            color: Color.foreground
            wrapMode: Text.WordWrap
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            renderType: Text.NativeRendering
          }
        }

        // ---- chart --------------------------------------------------------
        Item {
          width: parent.width
          height: Style.space(158)

          Canvas {
            id: chart
            anchors.fill: parent
            antialiasing: true
            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              var w = width
              var h = height
              if (w <= 0 || h <= 0) return

              var points = root.windowPoints
              var domain = root.domain
              var targetLow = root.targetLow
              var targetHigh = root.targetHigh

              // y-axis gutter for labels
              var left = Style.space(34)
              var right = w
              var top = Style.space(8)
              var bottom = h - Style.space(16)
              var plotW = Math.max(1, right - left)
              var plotH = Math.max(1, bottom - top)

              function yFor(value) {
                return top + plotH - ((value - domain.min) / Math.max(1, domain.max - domain.min)) * plotH
              }

              // target band
              var yTargetHigh = yFor(targetHigh)
              var yTargetLow = yFor(targetLow)
              ctx.fillStyle = Model.rgbaOf(Color.accent, 0.10)
              ctx.fillRect(left, yTargetHigh, plotW, Math.max(1, yTargetLow - yTargetHigh))
              ctx.strokeStyle = Model.rgbaOf(Color.accent, 0.45)
              ctx.lineWidth = 1
              ctx.beginPath()
              ctx.moveTo(left, yTargetHigh)
              ctx.lineTo(right, yTargetHigh)
              ctx.moveTo(left, yTargetLow)
              ctx.lineTo(right, yTargetLow)
              ctx.stroke()

              // y-axis labels
              ctx.fillStyle = Model.rgbaOf(Color.foreground, 0.5)
              ctx.font = Style.font.caption + "px " + Style.font.family
              ctx.textAlign = "right"
              ctx.textBaseline = "middle"
              var ticks = [domain.min, targetLow, targetHigh, domain.max]
              for (var tick = 0; tick < ticks.length; tick++) {
                var label = Model.formatValue(ticks[tick], root.unit)
                ctx.fillText(label, left - Style.space(4), yFor(ticks[tick]))
              }

              if (points.length === 0) {
                ctx.fillStyle = Model.rgbaOf(Color.foreground, 0.45)
                ctx.textAlign = "center"
                ctx.font = Style.font.body + "px " + Style.font.family
                ctx.fillText(root.t("noData"), left + plotW / 2, top + plotH / 2)
                return
              }

              var startSec = root.windowEndSec - root.windowHours * 3600
              var endSec = root.windowEndSec
              var runs = Model.segments(points, 1800)

              ctx.lineWidth = Math.max(1.5, Style.space(2))
              ctx.lineJoin = "round"
              ctx.lineCap = "round"
              for (var runIndex = 0; runIndex < runs.length; runIndex++) {
                var geom = Model.chartPoints(runs[runIndex], plotW, plotH, domain, startSec, endSec)
                if (geom.length === 0) continue
                ctx.strokeStyle = Model.rgbaOf(Color.foreground, 0.85)
                ctx.beginPath()
                for (var index = 0; index < geom.length; index++) {
                  var x = left + geom[index].x
                  var y = top + geom[index].y
                  if (index === 0) ctx.moveTo(x, y)
                  else ctx.lineTo(x, y)
                }
                ctx.stroke()
              }

              // out-of-range markers, so excursions survive the downscale
              for (var runIndex2 = 0; runIndex2 < runs.length; runIndex2++) {
                var geom2 = Model.chartPoints(runs[runIndex2], plotW, plotH, domain, startSec, endSec)
                for (var index2 = 0; index2 < geom2.length; index2++) {
                  var point = geom2[index2]
                  if (!point.out) continue
                  var pointState = Model.rangeState(point.v, targetLow, targetHigh)
                  ctx.fillStyle = Model.paintColor(pointState)
                  ctx.beginPath()
                  ctx.arc(left + point.x, top + point.y, Math.max(1.5, Style.space(2)), 0, Math.PI * 2)
                  ctx.fill()
                }
              }

              // newest reading in the visible window
              var geomAll = Model.chartPoints(points, plotW, plotH, domain, startSec, endSec)
              if (geomAll.length > 0) {
                var last = geomAll[geomAll.length - 1]
                ctx.fillStyle = root.stateColor
                ctx.beginPath()
                ctx.arc(left + last.x, top + last.y, Math.max(2.5, Style.space(3.5)), 0, Math.PI * 2)
                ctx.fill()
              }

              // x-axis labels
              ctx.fillStyle = Model.rgbaOf(Color.foreground, 0.5)
              ctx.font = Style.font.caption + "px " + Style.font.family
              ctx.textBaseline = "alphabetic"
              ctx.textAlign = "left"
              ctx.fillText(Model.formatClock(startSec), left, h - Style.space(3))
              ctx.textAlign = "right"
              ctx.fillText(Model.formatClock(endSec), right, h - Style.space(3))
            }
          }
        }

        // ---- window controls ---------------------------------------------
        Row {
          width: parent.width
          spacing: Style.spacing.sm

          ButtonGroup {
            id: windowPicker
            options: [
              { value: "3", label: "3h" },
              { value: "6", label: "6h" },
              { value: "12", label: "12h" },
              { value: "24", label: "24h" }
            ]
            foreground: Color.foreground
            background: Color.background
            accent: Color.accent
            onChanged: function(next) {
              var hours = parseInt(String(next), 10)
              if (!isNaN(hours) && hours !== root.windowHours) root.windowHours = hours
            }
            Component.onCompleted: value = String(root.windowHours)
            // The picker cannot keep a binding on `value` (it writes the
            // property itself on click), so mirror keyboard-driven changes
            // back into it explicitly.
            Connections {
              target: root
              function onWindowHoursChanged() { windowPicker.value = String(root.windowHours) }
            }
          }

          Item { width: Style.spacing.lg; height: 1 }

          Button {
            visible: root.windowHours >= 24
            text: "\u2039"
            tooltipText: root.zh ? "前一天" : "Previous day"
            foreground: Color.foreground
            enabled: root.dayOffset < root.maxDayOffset
            onClicked: root.shiftDay(1)
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.windowHours >= 24
            text: root.rangeText
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            renderType: Text.NativeRendering
          }

          Button {
            visible: root.windowHours >= 24
            text: "\u203a"
            tooltipText: root.zh ? "后一天" : "Next day"
            foreground: Color.foreground
            enabled: root.dayOffset > 0
            onClicked: root.shiftDay(-1)
          }

          Item { width: Style.spacing.sm; height: 1 }

          Button {
            text: root.t("refresh")
            tooltipText: root.zh ? "快捷键：R" : "Shortcut: R"
            foreground: Color.foreground
            onClicked: if (root.hostWidget && root.hostWidget.refresh) root.hostWidget.refresh()
          }
        }

        // ---- statistics ---------------------------------------------------
        Row {
          width: parent.width
          spacing: Style.spacing.xxl

          Repeater {
            model: [
              { key: "low", value: Model.formatValue(root.windowStats.min, root.unit) },
              { key: "high", value: Model.formatValue(root.windowStats.max, root.unit) },
              { key: "average", value: Model.formatValue(root.windowStats.avg, root.unit) },
              {
                key: "tir",
                value: root.windowStats.tir === null ? "--" : root.windowStats.tir + "%"
              },
              {
                key: "gap",
                // The cloud publishes about every 15 minutes, so a 15-minute
                // gap is the normal cadence and only >30 minutes means the
                // phone actually lost the sensor.
                value: root.windowStats.count > 1
                  ? String(Model.largestGapMinutes(root.windowPoints)) + " " + root.t("minutes")
                  : "--",
                urgent: root.windowStats.count > 1
                  && Model.largestGapMinutes(root.windowPoints) > 30
              }
            ]

            Column {
              required property var modelData
              spacing: 0

              Text {
                text: root.t(modelData.key)
                color: Color.foreground
                opacity: 0.55
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                renderType: Text.NativeRendering
              }

              Text {
                text: modelData.value
                color: modelData.urgent === true ? Color.urgent : Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                renderType: Text.NativeRendering
              }
            }
          }
        }

        // ---- secondary line ------------------------------------------------
        Text {
          width: parent.width
          visible: root.windowStats.count > 0
          text: {
            var excursions = Model.excursionPercents(root.windowStats)
            var parts = []
            parts.push(root.windowStats.count + " " + root.t("points"))
            if (excursions.below !== null) parts.push(root.t("below") + " " + excursions.below + "%")
            if (excursions.above !== null) parts.push(root.t("above") + " " + excursions.above + "%")
            parts.push(root.t("target") + " "
              + Model.formatValue(root.targetLow, root.unit) + "\u2013"
              + Model.formatValue(root.targetHigh, root.unit) + " " + Model.unitSuffix(root.unit))
            return parts.join("  \u00b7  ")
          }
          color: Color.foreground
          opacity: 0.45
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          renderType: Text.NativeRendering
          wrapMode: Text.WordWrap
        }

        // ---- optional Jev interpretation ------------------------------------
        // Informational only: it never hides a reading and never changes an
        // alert. Empty unless jev.enabled (or --interpret) produced a label.
        Text {
          width: parent.width
          visible: text !== ""
          text: Model.interpretationText(
            root.payload ? root.payload.interpretation : null, root.lang)
          color: Color.foreground
          opacity: 0.6
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          renderType: Text.NativeRendering
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
