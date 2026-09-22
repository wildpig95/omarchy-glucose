// Pure helpers for the glucose widget: unit conversion, range classification,
// chart geometry and localized labels. No Qt objects, no side effects, so the
// bar pill and the panel can share exactly one implementation.


var MGDL_PER_MMOL = 18.0182

var TREND_GLYPHS = {
  0: "\u00b7",
  1: "\u2193",
  2: "\u2198",
  3: "\u2192",
  4: "\u2197",
  5: "\u2191"
}

// mg/dL thresholds are the clinical ones; they are converted for display.
var VERY_LOW_MGDL = 54
var VERY_HIGH_MGDL = 250

function trendGlyph(trend) {
  var key = Math.round(Number(trend) || 0)
  return TREND_GLYPHS[key] !== undefined ? TREND_GLYPHS[key] : TREND_GLYPHS[0]
}

function toMmol(mgdl) {
  return Number(mgdl) / MGDL_PER_MMOL
}

function convert(mgdl, unit) {
  return String(unit || "mg/dL").toLowerCase().indexOf("mmol") === 0 ? toMmol(mgdl) : Number(mgdl)
}

function unitSuffix(unit) {
  return String(unit || "mg/dL").toLowerCase().indexOf("mmol") === 0 ? "mmol/L" : "mg/dL"
}

// One decimal for mmol/L (5.6), integer for mg/dL (101).
function formatValue(mgdl, unit) {
  if (mgdl === null || mgdl === undefined || isNaN(Number(mgdl))) return "--"
  var value = convert(mgdl, unit)
  return String(unit || "mg/dL").toLowerCase().indexOf("mmol") === 0
    ? value.toFixed(1)
    : String(Math.round(value))
}

function rangeState(mgdl, low, high) {
  var value = Number(mgdl)
  if (isNaN(value)) return "unknown"
  var lo = Number(low) || 70
  var hi = Number(high) || 180
  if (value < VERY_LOW_MGDL) return "veryLow"
  if (value < lo) return "low"
  if (value > VERY_HIGH_MGDL) return "veryHigh"
  if (value > hi) return "high"
  return "inRange"
}

var TRAFFIC = {
  veryLow: "#e0574f",
  low: "#e07a4f",
  inRange: "#63bd7a",
  high: "#e0b24a",
  veryHigh: "#e08a3c",
  unknown: "#8b939c"
}

// "traffic" keeps the clinical signal readable on any theme; "theme" leans on
// the Omarchy palette so the pill disappears into the bar when in range.
function stateColor(state, palette, themeForeground, themeUrgent) {
  if (String(palette || "traffic") === "theme") {
    if (state === "unknown") return themeForeground
    return state === "inRange" ? themeForeground : themeUrgent
  }
  return TRAFFIC[state] || TRAFFIC.unknown
}

function isOutOfRange(state) {
  return state !== "inRange" && state !== "unknown"
}

function paintColor(state) {
  return TRAFFIC[state] || TRAFFIC.unknown
}

// Points inside [endSec - hours*3600, endSec].
function sliceWindow(series, endSec, hours) {
  var points = series || []
  var end = Number(endSec)
  var start = end - Number(hours) * 3600
  var out = []
  for (var index = 0; index < points.length; index++) {
    var point = points[index]
    if (!point || point.t === undefined) continue
    if (point.t >= start && point.t <= end) out.push(point)
  }
  return out
}

function stats(points, low, high) {
  var result = {
    count: 0,
    min: null,
    max: null,
    avg: null,
    tir: null,
    veryLow: 0,
    low: 0,
    inRange: 0,
    high: 0,
    veryHigh: 0
  }
  var total = 0
  for (var index = 0; index < (points || []).length; index++) {
    var value = Number(points[index].v)
    if (isNaN(value)) continue
    result.count++
    total += value
    if (result.min === null || value < result.min) result.min = value
    if (result.max === null || value > result.max) result.max = value
    var state = rangeState(value, low, high)
    if (result[state] !== undefined) result[state]++
  }
  if (result.count > 0) {
    result.avg = total / result.count
    // Time in range is strictly 70-180 mg/dL: low and high are excursions.
    result.tir = Math.round((result.inRange / result.count) * 100)
  }
  return result
}

// Chart vertical domain: always show the target band, pad the data range, and
// snap to round numbers so the axis labels look intentional.
function valueDomain(points, low, high) {
  var lo = Number(low) || 70
  var hi = Number(high) || 180
  var min = lo
  var max = hi
  for (var index = 0; index < (points || []).length; index++) {
    var value = Number(points[index].v)
    if (isNaN(value)) continue
    if (value < min) min = value
    if (value > max) max = value
  }
  var padding = Math.max(10, (max - min) * 0.12)
  min = Math.max(30, Math.floor((min - padding) / 10) * 10)
  max = Math.ceil((max + padding) / 10) * 10
  if (max - min < 60) max = min + 60
  // low/high ride along so chartPoints can flag out-of-range dots without a
  // second parameter.
  return { min: min, max: max, low: lo, high: hi }
}

// Map points to canvas coordinates. Returns [] when there is nothing to draw.
function chartPoints(points, width, height, domain, startSec, endSec) {
  var list = points || []
  if (list.length === 0 || width <= 0 || height <= 0) return []
  var span = Math.max(1, Number(endSec) - Number(startSec))
  var range = Math.max(1, domain.max - domain.min)
  var out = []
  for (var index = 0; index < list.length; index++) {
    var point = list[index]
    var value = Number(point.v)
    if (isNaN(value)) continue
    var x = ((Number(point.t) - Number(startSec)) / span) * width
    var y = height - ((value - domain.min) / range) * height
    out.push({
      x: x,
      y: y,
      v: value,
      t: point.t,
      tr: point.tr,
      out: isOutOfRange(rangeState(value, domain.low, domain.high))
    })
  }
  return out
}

function ageMinutes(epoch, nowSec) {
  if (!epoch) return null
  return Math.max(0, Math.round((Number(nowSec) - Number(epoch)) / 60))
}

// Longest stretch with no reading, in minutes. This is the number that makes a
// dropped Bluetooth link visible: LibreLinkUp simply omits readings, so a
// healthy window shows ~5 and a phone-in-the-wrong-pocket window shows 90.
function largestGapMinutes(points) {
  var list = points || []
  var worst = 0
  for (var index = 1; index < list.length; index++) {
    var delta = (Number(list[index].t) - Number(list[index - 1].t)) / 60
    if (delta > worst) worst = delta
  }
  return list.length > 1 ? Math.round(worst) : 0
}

// Share of readings below / above the target band, as whole percents.
function excursionPercents(stats) {
  if (!stats || !stats.count) return { below: null, above: null }
  return {
    below: Math.round(((stats.veryLow + stats.low) / stats.count) * 100),
    above: Math.round(((stats.high + stats.veryHigh) / stats.count) * 100)
  }
}

function two(value) {
  return (Number(value) < 10 ? "0" : "") + String(Math.round(Number(value)))
}

function formatClock(epoch) {
  if (!epoch) return "--:--"
  var date = new Date(Number(epoch) * 1000)
  return two(date.getHours()) + ":" + two(date.getMinutes())
}

function formatDay(epoch, lang) {
  if (!epoch) return ""
  var date = new Date(Number(epoch) * 1000)
  var month = date.getMonth() + 1
  var day = date.getDate()
  return String(lang || "zh") === "zh"
    ? month + "月" + day + "日"
    : month + "/" + day
}

function ageText(ageSec, lang) {
  if (ageSec === null || ageSec === undefined) return ""
  var minutes = Math.round(Number(ageSec) / 60)
  var zh = String(lang || "zh") === "zh"
  if (minutes < 1) return zh ? "刚刚" : "just now"
  if (minutes < 60) return zh ? minutes + " 分钟前" : minutes + " min ago"
  var hours = Math.floor(minutes / 60)
  var rest = minutes % 60
  if (zh) return rest > 0 ? hours + " 小时 " + rest + " 分前" : hours + " 小时前"
  return rest > 0 ? hours + "h " + rest + "m ago" : hours + "h ago"
}

function sensorText(sensor, lang, nowSec) {
  if (!sensor || !sensor.expiresAt) return ""
  var minutesLeft = Math.round((Number(sensor.expiresAt) - Number(nowSec)) / 60)
  if (minutesLeft <= 0) return String(lang || "zh") === "zh" ? "传感器已到期" : "sensor expired"
  var days = Math.floor(minutesLeft / (24 * 60))
  var hours = Math.floor((minutesLeft % (24 * 60)) / 60)
  if (String(lang || "zh") === "zh") return "传感器剩余 " + days + " 天 " + hours + " 小时"
  return "sensor " + days + "d " + hours + "h left"
}

var STRINGS = {
  zh: {
    title: "血糖",
    now: "现在",
    trend: "趋势",
    source: "数据源",
    refresh: "刷新",
    low: "最低",
    high: "最高",
    average: "平均",
    tir: "达标率",
    gap: "最大缺口",
    below: "低于",
    above: "高于",
    minutes: "分钟",
    window: "时间窗口",
    today: "今天",
    yesterday: "昨天",
    daysAgo: "天前",
    noData: "暂无数据",
    stale: "数据已过期",
    staleHint: "云端最新读数距今 %1。请确认手机上的瞬感宝在运行、有网络、且已开启共享。",
    error: "读取失败",
    mockWarn: "示例数据（mock）：还没有接入真实数据源，这些数字是合成的，不要据此判断血糖。改 ~/.config/omarchy/glucose/config.json 里的 source。",
    hint: "左键打开面板 · 中键刷新",
    target: "目标区间",
    points: "条读数",
    settings: "设置",
    configMissing: "尚未配置账号：见插件 README"
  },
  en: {
    title: "Glucose",
    now: "now",
    trend: "trend",
    source: "source",
    refresh: "Refresh",
    low: "Low",
    high: "High",
    average: "Avg",
    tir: "TIR",
    gap: "Max gap",
    below: "Below",
    above: "Above",
    minutes: "min",
    window: "Window",
    today: "Today",
    yesterday: "Yesterday",
    daysAgo: "days ago",
    noData: "No data",
    stale: "Stale",
    staleHint: "Newest cloud reading is %1 old. Check that the Libre app is running, online, and sharing.",
    error: "Fetch failed",
    mockWarn: "Sample data (mock): no real source is connected, these numbers are synthetic. Set `source` in ~/.config/omarchy/glucose/config.json.",
    hint: "Left click opens the panel - middle click refreshes",
    target: "Target",
    points: "readings",
    settings: "Settings",
    configMissing: "No account configured yet - see the plugin README"
  }
}

function label(key, lang) {
  var table = STRINGS[String(lang || "zh") === "zh" ? "zh" : "en"]
  return table[key] !== undefined ? table[key] : key
}

// Optional Jev interpretation. Jev classifies the trace into a fixed label;
// the words, the thresholds and every safety decision live in code here.
var PATTERN_LABELS = {
  stable_in_range: { zh: "区间内平稳", en: "stable in range" },
  post_meal_excursion: { zh: "餐后波动", en: "post-meal excursion" },
  rising_fast: { zh: "快速上升", en: "rising fast" },
  falling_fast: { zh: "快速下降", en: "falling fast" },
  low_recovering: { zh: "低值回升", en: "recovering from low" },
  possible_artifact: { zh: "可能是传感器伪值", en: "possible sensor artifact" }
}

function patternLabel(pattern, lang) {
  var entry = PATTERN_LABELS[String(pattern || "")]
  if (!entry) return ""
  return String(lang || "zh") === "zh" ? entry.zh : entry.en
}

// "" when there is nothing worth showing (disabled, error, unknown label).
function interpretationText(interp, lang) {
  if (!interp || interp.error) return ""
  var zh = String(lang || "zh") === "zh"
  var parts = []
  var label = patternLabel(interp.pattern, lang)
  if (label) parts.push(label)
  if (typeof interp.patternConfidence === "number") {
    parts.push((zh ? "置信 " : "conf ") + Math.round(interp.patternConfidence * 100) + "%")
  }
  if (typeof interp.artifactLikely === "number" && interp.artifactLikely >= 0.3) {
    parts.push((zh ? "伪值 " : "artifact ") + Math.round(interp.artifactLikely * 100) + "%")
  }
  if (interp.cached) parts.push(zh ? "缓存" : "cached")
  if (parts.length === 0) return ""
  return "Jev: " + parts.join(" · ")
}

// Canvas fill/stroke styles need an "rgba(...)" string; QML colour objects are
// handed to the painter as strings only by accident, so build one explicitly.
function rgbaOf(color, alpha) {
  if (color === undefined || color === null) return "rgba(255,255,255," + alpha + ")"
  var r = Math.round(Number(color.r) * 255)
  var g = Math.round(Number(color.g) * 255)
  var b = Math.round(Number(color.b) * 255)
  if (isNaN(r) || isNaN(g) || isNaN(b)) return "rgba(255,255,255," + alpha + ")"
  return "rgba(" + r + "," + g + "," + b + "," + alpha + ")"
}

// Break a point list into continuous runs: LibreLinkUp silently drops readings
// when the phone loses the sensor, and a straight line across a two-hour hole
// would read as real data.
function segments(points, maxGapSeconds) {
  var gap = Number(maxGapSeconds) || 900
  var runs = []
  var run = []
  for (var index = 0; index < (points || []).length; index++) {
    var point = points[index]
    if (run.length > 0 && Number(point.t) - Number(run[run.length - 1].t) > gap) {
      runs.push(run)
      run = []
    }
    run.push(point)
  }
  if (run.length > 0) runs.push(run)
  return runs
}
