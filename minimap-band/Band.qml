import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons

// Claude's three limits on a band of austraz.minimap's rim (installed by
// linking this folder as the minimap's bands/ai). Three gauges, apart from
// the clock around them: the 5-hour session at the top right, the week at
// the bottom, the week's Fable share on the left, each labelled in the gap
// before it and filling clockwise to its own 100 %.
//
// In each gauge: the share used, solid; a pale arc on to where the
// forecast lands at the reset; a notch for how much of the window has
// gone by (past it, the pace would not last). Neutral while the forecast
// stays under 80 %, amber over it, red when the limit would be hit before
// the reset. Hovering a gauge holds its details in the middle circle (the
// minimap's OSD face, faded in); clicking opens the My Agents panel. A
// gauge turning red blinks and shows its details for a few seconds, once
// per window. Data older than 15 minutes fades the band and sends no alert.
//
// Reads what My Agents writes (usage/claude.json, its `limits` and their
// `forecast`, see forecast.py); nothing is fetched here.
Item {
  id: band

  required property var minimap
  property real radius: 100          // the band's centre line, set by the minimap
  property real thickness: 8

  readonly property real k: minimap.uiScale || 1
  readonly property real cx: width / 2
  readonly property real cy: height / 2
  readonly property string path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
    + "/omarchy/agents/usage/claude.json"

  readonly property color amber: "#e0af68"
  readonly property color red: Color.urgent
  readonly property color neutral: Qt.alpha(Color.foreground, 0.7)

  // ---- data

  property var limits: []
  property real updatedAt: 0          // epoch seconds

  FileView {
    id: file
    path: band.path
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: band.take(text())
  }
  // The file is replaced on every refresh, which can drop the watch.
  Timer { interval: 60000; running: true; repeat: true; onTriggered: file.reload() }

  function take(raw) {
    try {
      var d = JSON.parse(String(raw || "{}"))
      band.limits = Array.isArray(d.limits) ? d.limits : []
      band.updatedAt = band.epoch(d.updatedAt)
    } catch (e) {}
  }

  // ISO times with microseconds, which Date.parse does not take.
  function epoch(iso) {
    var t = Date.parse(String(iso || "").replace(/(\.\d{3})\d+/, "$1"))
    return isNaN(t) ? 0 : t / 1000
  }

  readonly property real now: minimap.nowSec
  readonly property bool stale: updatedAt > 0 && now - updatedAt > 900

  // Clock degrees (0 at noon, clockwise); each gauge spans from..to.
  readonly property var specs: [
    { key: "session", from: 10, to: 110, gap: 0, label: "5h", name: "Session 5 h", span: 5 * 3600, glyph: 0xF051F, match: /session/i },
    { key: "weekly", from: 130, to: 230, gap: 120, label: "7j", name: "Semaine", span: 7 * 86400, glyph: 0xF00ED, match: /^weekly/i },
    { key: "fable", from: 250, to: 350, gap: 240, label: "F", name: "Fable · semaine", span: 7 * 86400, glyph: 0xF09D1, match: /fable/i }
  ]

  readonly property var gauges: {
    var out = []
    for (var i = 0; i < specs.length; i++) {
      var s = specs[i], limit = null
      for (var j = 0; j < limits.length; j++)
        if (s.match.test(String(limits[j].label || ""))) { limit = limits[j]; break }
      if (!limit) { out.push({ spec: s, known: false }); continue }
      var used = Math.max(0, Number(limit.percent) || 0)
      var f = limit.forecast || {}
      var forecast = Math.max(used, Number(f.mid) || used)
      var reset = epoch(limit.resetsAt)
      var cap = epoch(f.capAt)
      var full = used >= 1 || forecast >= 1 || (cap > 0 && (reset === 0 || cap < reset))
      out.push({
        spec: s, known: true, used: used, forecast: forecast, reset: reset, cap: cap,
        elapsed: reset > 0 ? Math.max(0, Math.min(1, 1 - (reset - now) / s.span)) : -1,
        risk: full ? "full" : forecast >= 0.8 ? "warn" : "ok",
        window: s.key + "|" + String(limit.resetsAt || "")
      })
    }
    return out
  }

  function riskColor(g) { return g.risk === "full" ? red : g.risk === "warn" ? amber : neutral }

  // ---- details, in the middle circle

  readonly property var days: ["dim.", "lun.", "mar.", "mer.", "jeu.", "ven.", "sam."]
  function clock(sec) {
    var d = new Date(sec * 1000), today = new Date(now * 1000)
    var hm = ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2)
    return d.toDateString() === today.toDateString() ? hm : days[d.getDay()] + " " + hm
  }

  function detail(g, quiet) {
    var lines = [g.spec.name]
    if (g.known) {
      lines.push(g.risk === "full" && g.cap > 0 ? "plein vers " + clock(g.cap)
        : "~" + Math.round(g.forecast * 100) + " % au reset")
      if (g.reset > 0) lines.push("reset " + clock(g.reset))
    } else {
      lines.push("pas de données")
    }
    if (stale) lines.push("relevé il y a " + Math.round((now - updatedAt) / 60) + " min")
    return {
      iconKey: "ai",
      icon: String.fromCodePoint(g.spec.glyph),
      message: g.known ? Math.round(g.used * 100) + " %" : "",
      detail: lines.join("\n"),
      hasProgress: g.known,
      value: g.known ? g.used * 100 : 0,
      maxValue: 100,
      ghost: g.known ? Math.min(1, g.forecast) : 0,
      color: g.known && g.risk !== "ok" ? String(riskColor(g)) : String(Color.accent),
      quiet: quiet
    }
  }

  // ---- hover and click

  property int hovered: -1
  function gaugeAt(x, y) {
    var a = Math.atan2(x - cx, cy - y) * 180 / Math.PI
    if (a < 0) a += 360
    for (var i = 0; i < specs.length; i++) if (a >= specs[i].from && a <= specs[i].to) return i
    return -1
  }
  onHoveredChanged: hovered < 0 ? minimap.releaseOsd() : minimap.holdOsd(detail(gauges[hovered], true))
  onGaugesChanged: {
    if (hovered >= 0) minimap.holdOsd(detail(gauges[hovered], true))
    checkAlerts()
  }
  Component.onDestruction: if (hovered >= 0) minimap.releaseOsd()

  MouseArea {
    anchors.fill: parent
    visible: band.limits.length > 0
    hoverEnabled: true
    cursorShape: band.hovered >= 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
    containmentMask: QtObject {
      function contains(p: point): bool {
        var d = Math.hypot(p.x - band.cx, p.y - band.cy)
        return Math.abs(d - band.radius) <= band.thickness / 2 + 1.5 * band.k
      }
    }
    onPositionChanged: function(mouse) { band.hovered = band.gaugeAt(mouse.x, mouse.y) }
    onExited: band.hovered = -1
    onClicked: if (band.hovered >= 0) Quickshell.execDetached(["omarchy-shell", "omarchy.agents", "toggle"])
  }

  // ---- alerts: a gauge turning red, once per window. Those already red
  // when the band starts (a shell restart) stay quiet.

  property var told: ({})
  property bool primed: false
  function checkAlerts() {
    if (stale || !limits.length) return
    var next = null
    for (var i = 0; i < gauges.length; i++) {
      var g = gauges[i]
      if (!g.known || g.risk !== "full" || told[g.window]) continue
      if (!next) next = Object.assign({}, told)
      next[g.window] = true
      if (primed) {
        minimap.flashOsd(detail(g, false), 6000)
        blinkIndex = i
        blink.restart()
      }
    }
    if (next) told = next
    primed = true
  }

  property int blinkIndex: -1
  property real blinkLevel: 1
  SequentialAnimation {
    id: blink
    loops: 4
    NumberAnimation { target: band; property: "blinkLevel"; to: 0.2; duration: 260 }
    NumberAnimation { target: band; property: "blinkLevel"; to: 1; duration: 260 }
    onFinished: band.blinkIndex = -1
  }

  // ---- drawing

  visible: limits.length > 0
  opacity: stale ? 0.4 : 1

  Repeater {
    model: band.gauges
    delegate: Shape {
      id: gauge
      required property var modelData
      required property int index
      readonly property var g: modelData
      readonly property real span: g.spec.to - g.spec.from
      readonly property real start: g.spec.from - 90       // Qt's angles start at three o'clock
      readonly property color ink: g.known ? band.riskColor(g) : band.neutral
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer
      opacity: band.blinkIndex === index ? band.blinkLevel : 1

      ShapePath {
        strokeColor: Qt.alpha(Color.foreground, band.hovered === gauge.index ? 0.2 : 0.1)
        strokeWidth: band.thickness
        fillColor: "transparent"
        capStyle: ShapePath.FlatCap
        PathAngleArc { centerX: band.cx; centerY: band.cy; radiusX: band.radius; radiusY: band.radius; startAngle: gauge.start; sweepAngle: gauge.span }
      }
      // The forecast, pale, from the share used on.
      ShapePath {
        strokeColor: Qt.alpha(gauge.ink, 0.3)
        strokeWidth: band.thickness
        fillColor: "transparent"
        capStyle: ShapePath.FlatCap
        PathAngleArc {
          centerX: band.cx; centerY: band.cy; radiusX: band.radius; radiusY: band.radius
          startAngle: gauge.start + gauge.span * Math.min(1, gauge.g.used || 0)
          sweepAngle: gauge.g.known ? gauge.span * Math.max(0, Math.min(1, gauge.g.forecast) - Math.min(1, gauge.g.used)) : 0
        }
      }
      ShapePath {
        strokeColor: gauge.ink
        strokeWidth: band.thickness
        fillColor: "transparent"
        capStyle: ShapePath.FlatCap
        PathAngleArc {
          centerX: band.cx; centerY: band.cy; radiusX: band.radius; radiusY: band.radius
          startAngle: gauge.start
          sweepAngle: gauge.g.known ? gauge.span * Math.min(1, gauge.g.used) : 0
        }
      }
      // How much of the window has gone by.
      ShapePath {
        id: notch
        readonly property real a: (gauge.g.spec.from + gauge.span * Math.max(0, gauge.g.elapsed)) * Math.PI / 180
        readonly property real r0: band.radius - band.thickness / 2 - 1.5 * band.k
        readonly property real r1: band.radius + band.thickness / 2 + 1.5 * band.k
        strokeColor: gauge.g.known && gauge.g.elapsed >= 0 ? Color.foreground : "transparent"
        strokeWidth: 1.5 * band.k
        fillColor: "transparent"
        capStyle: ShapePath.FlatCap
        startX: band.cx + r0 * Math.sin(a); startY: band.cy - r0 * Math.cos(a)
        PathLine { x: band.cx + notch.r1 * Math.sin(notch.a); y: band.cy - notch.r1 * Math.cos(notch.a) }
      }
    }
  }

  // The labels, in the gap before each gauge.
  Repeater {
    model: band.specs
    delegate: Text {
      required property var modelData
      readonly property real a: modelData.gap * Math.PI / 180
      x: band.cx + band.radius * Math.sin(a) - width / 2
      y: band.cy - band.radius * Math.cos(a) - height / 2
      text: modelData.label
      color: Qt.alpha(Color.foreground, 0.6)
      font.family: Style.fontFamily
      font.pixelSize: Math.round(band.thickness * 1.05)
      font.bold: true
    }
  }
}
