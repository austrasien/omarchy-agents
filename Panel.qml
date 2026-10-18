import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "omarchy.agents"
  ipcTarget: "omarchy.agents"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color contrast: Color.accent
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var providers: usage.enabledProviders
  // The selection follows the provider, not the slot it happens to sit in: a
  // provider whose first scan lands while the panel is open would otherwise
  // shift the list underneath you and swap out what you were reading.
  property string selectedProviderId: ""
  readonly property int providerIndex: {
    for (var i = 0; i < providers.length; i++)
      if (providers[i].providerId === selectedProviderId) return i
    return 0
  }
  readonly property var provider: providers.length > 0 ? providers[providerIndex] : null

  property bool cursorActive: false

  // Countdowns and "updated" read this instead of Date.now() so the
  // panel keeps telling the truth while it sits open.
  property double nowMs: Date.now()
  property int funFactIndex: 0
  // Same three inks as austraz.network: upload blue, ping green, download fuchsia.
  readonly property string cyclePastColor: "#5aa8ff"
  readonly property string cycleOkColor: "#3dd68c"
  readonly property string cycleCrashColor: "#ff2ec4"
  readonly property var achievements: root.achievementList(root.provider, root.nowMs)

  readonly property var limits: shownLimitWindows(provider)
  readonly property var models: modelRows(provider)
  readonly property var headline: bindingWindow(provider)
  readonly property var balance: provider ? (provider.balance || null) : null
  // A prepaid account runs low the way a subscription window fills up: the
  // last 10% of the funded credits lights the same alarm.
  readonly property bool balanceAlarming: !!balance && balance.funded > 0
    && balance.remaining / balance.funded <= 0.1
  // 90% already used is too late for a 30-day pool: the bar also lights when
  // either the weekday projection or the last-7-days pace would land above cap.
  readonly property bool alarming: anyProviderAlarming() || balanceAlarming

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function selectProvider(index) {
    if (providers.length === 0) return
    var wrapped = ((index % providers.length) + providers.length) % providers.length
    selectedProviderId = providers[wrapped].providerId
  }

  function refreshNow() {
    usage.refreshAll(true)
  }

  function launchAgent() {
    if (root.bar) root.bar.run("omarchy-agent --pick")
    root.close()
  }

  // ---------------------------------------------------------------- limits
  //
  // Both providers report the same two shapes: a short rolling session window
  // and a long weekly one. Everything below normalizes them into one record so
  // the meters and the hero speak a single language.

  // Claude spells its windows out ("Session (5-hour)"), Codex abbreviates
  // them ("5h window", "30m window"). Both have to land on the same record.
  function windowIsLong(text) {
    return text.indexOf("week") >= 0 || text.indexOf("7-day") >= 0 || text.indexOf("seven") >= 0
      || text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0
  }

  function windowSpanMs(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0) return 30 * 24 * 3600 * 1000
    if (windowIsLong(text)) return 7 * 24 * 3600 * 1000
    var hours = text.match(/(\d+)\s*-?\s*h(?:our)?\b/)
    if (hours) return Number(hours[1]) * 3600 * 1000
    var minutes = text.match(/(\d+)\s*-?\s*m(?:in(?:ute)?s?)?\b/)
    if (minutes) return Number(minutes[1]) * 60 * 1000
    return 0
  }

  function windowTitle(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0) return "Monthly"
    if (windowIsLong(text)) return "Weekly"
    if (text.indexOf("session") >= 0 || windowSpanMs(label) > 0) return "Session"
    var plain = String(label || "").replace(/\s*\(.*\)\s*/, "").trim()
    return plain === "" ? "Limit" : plain
  }

  // A collector that already knows which window a limit belongs to says so,
  // and that beats reading it back out of the label: a model-scoped limit is
  // titled after its model, and a name like "Opus 5 (1M context)" would parse
  // as a one-minute window.
  function limitWindow(label, percent, resetAt, title, forecast) {
    return {
      title: String(title || "") !== "" ? String(title) : windowTitle(label),
      percent: Number(percent),
      resetAt: String(resetAt || ""),
      forecast: forecast || null
    }
  }

  // forecast.py's landing for the window, or null once it has rolled over.
  function forecastFor(w) {
    if (!w || !w.forecast || resetMsFor(w) < 0) return null
    var f = w.forecast
    if (!(Number(f.mid) >= 0)) return null
    return f
  }

  // Projected landing → ink: green up to 60%, then through yellow (80%) and
  // orange (95%) to red at the cap and beyond.
  readonly property var paceStops: [
    [0.60, 0x3d, 0xd6, 0x8c],
    [0.80, 0xf5, 0xd5, 0x47],
    [0.95, 0xff, 0x9a, 0x3d],
    [1.00, 0xff, 0x4d, 0x4d]
  ]

  function paceColor(mid) {
    var stops = root.paceStops
    var v = Number(mid) || 0
    if (v <= stops[0][0]) return Qt.rgba(stops[0][1] / 255, stops[0][2] / 255, stops[0][3] / 255, 1)
    for (var i = 1; i < stops.length; i++) {
      if (v <= stops[i][0]) {
        var a = stops[i - 1]
        var b = stops[i]
        var t = (v - a[0]) / (b[0] - a[0])
        return Qt.rgba((a[1] + (b[1] - a[1]) * t) / 255, (a[2] + (b[2] - a[2]) * t) / 255,
          (a[3] + (b[3] - a[3]) * t) / 255, 1)
      }
    }
    var last = stops[stops.length - 1]
    return Qt.rgba(last[1] / 255, last[2] / 255, last[3] / 255, 1)
  }

  // Resets come back a few hundred ms either side of the minute.
  function roundedToMinute(iso) {
    var ms = new Date(iso).getTime()
    return new Date(Math.round(ms / 60000) * 60000)
  }

  function forecastText(f) {
    if (!f) return ""
    var low = Math.round(f.low * 100)
    var high = Math.round(f.high * 100)
    var range = low === high ? "" : low + "–" + high + "%"
    var est = f.method === "cost" ? " · est." : ""
    var capMs = f.capAt ? new Date(f.capAt).getTime() : NaN
    if (isFinite(capMs) && capMs > root.nowMs)
      return "Cap " + Qt.formatDateTime(new Date(capMs), "ddd HH:mm") + " at usual pace (→ "
        + Math.round(f.mid * 100) + "%" + (range ? ", " + range : "") + ")" + est
    return "Usual pace → " + Math.round(f.mid * 100) + "%" + (range ? " (" + range + ")" : "") + est
  }

  function forecastTooltip(f) {
    if (!f) return ""
    var source = f.method === "cost"
      ? "Estimated from this machine's API-priced usage until the limit log covers 3 days."
      : "From the logged limit percentages."
    return "Expected burn per hour from the last " + f.days + " days (weekday / weekend, hour of day),"
      + " summed until the reset. The band is the quieter / busier quarter of past days. " + source
  }

  function limitWindows(p) {
    if (!p) return []
    var out = []
    var list = p.limits || []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i] || {}
      var percent = Number(entry.percent)
      if (percent >= 0) out.push(limitWindow(entry.label, percent, entry.resetsAt, entry.title, entry.forecast))
    }
    return out
  }

  // Cursor Models is the same $ pool the hero already shows; Other Models at
  // 0% is noise. On-Demand stays, even empty — that is the paid overflow.
  function shownLimitWindows(p) {
    if (!p) return []
    var chart = cycleChartData(p)
    var centsHero = !!(chart && chart.unit === "cents" && chart.allowance > 0)
    var out = []
    var list = p.limits || []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i] || {}
      var percent = Number(entry.percent)
      if (!(percent >= 0)) continue
      var label = String(entry.label || "").toLowerCase()
      var title = String(entry.title || "").toLowerCase()
      if (centsHero && (label.indexOf("cursor models") >= 0 || title.indexOf("cursor models") >= 0))
        continue
      if ((label.indexOf("other models") >= 0 || title.indexOf("other models") >= 0) && percent === 0)
        continue
      out.push(limitWindow(entry.label, percent, entry.resetsAt, entry.title, entry.forecast))
    }
    return out
  }

  // The window that decides how much room is left — the fullest one, since
  // that is what stops the next prompt.
  function bindingWindow(p) {
    var windows = limitWindows(p)
    var best = null
    for (var i = 0; i < windows.length; i++) {
      if (!best || windows[i].percent > best.percent) best = windows[i]
    }
    return best
  }

  function resetMsFor(w) {
    if (!w || w.resetAt === "") return -1
    var ms = new Date(w.resetAt).getTime()
    return isFinite(ms) ? ms - root.nowMs : -1
  }

  function formatDuration(ms) {
    if (!(ms > 0)) return "now"
    var minutes = Math.floor(ms / 60000)
    var hours = Math.floor(minutes / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return days + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + (minutes % 60) + "m"
    return Math.max(1, minutes) + "m"
  }

  // "in 3d 1h" for every window; a window longer than a day also names the
  // local weekday and time it rolls over, since a countdown in days is hard
  // to place on a calendar.
  function resetTextFor(w) {
    var remainingMs = resetMsFor(w)
    if (!(remainingMs > 0)) return ""
    var text = "↻ " + formatDuration(remainingMs)
    if (remainingMs >= 24 * 3600 * 1000)
      text += " · " + Qt.formatDateTime(roundedToMinute(w.resetAt), "ddd HH:mm")
    return text
  }

  // ---------------------------------------------------------------- balance
  //
  // Prepaid agents report a credit ledger instead of rate-limit windows: the
  // record's balance object carries remaining, funded, and spent amounts.

  function currencyPrefix(currency) {
    var code = String(currency || "USD").toUpperCase()
    if (code === "USD") return "$"
    if (code === "EUR") return "€"
    if (code === "GBP") return "£"
    return code + " "
  }

  function formatMoney(value, currency) {
    var amount = Number(value)
    if (!isFinite(amount)) amount = 0
    var abs = Math.abs(amount).toFixed(2)
    return (amount < 0 ? "-" : "") + currencyPrefix(currency) + abs
  }

  function cssRgba(c, a) {
    return "rgba(" + Math.round(c.r * 255) + ", " + Math.round(c.g * 255) + ", "
      + Math.round(c.b * 255) + ", " + a + ")"
  }

  function balanceDetailText(b) {
    if (!b || !(b.funded > 0)) return ""
    var text = formatMoney(b.spent, b.currency) + " spent of " + formatMoney(b.funded, b.currency) + " funded"
    if (b.estimated) text += " · estimated"
    return text
  }

  // ---------------------------------------------------------------- content

  // The plan you pay for, under the name of the tool it pays for. Limits live
  // in their own section; the hero just says what this is.
  function heroMeta(p) {
    if (!p) return ""
    if (String(p.usageStatusText || "") !== "") return p.usageStatusText
    var tier = String(p.tierLabel || "")
    if (tier === "") return "Subscription"
    return tier.charAt(0).toUpperCase() + tier.slice(1)
  }

  function heroDetail(p) {
    var chart = cycleChartData(p)
    if (!chart || chart.unit !== "cents" || !(chart.allowance > 0)) return ""
    return formatMoney(chart.total / 100, "USD") + " / " + formatMoney(chart.allowance / 100, "USD")
  }

  // Local calendar date, recomputed from nowMs so a panel left open across
  // midnight moves the "Today" row with the clock.
  function todayDate() {
    var now = new Date(root.nowMs)
    return now.getFullYear()
      + "-" + String(now.getMonth() + 1).padStart(2, "0")
      + "-" + String(now.getDate()).padStart(2, "0")
  }

  function dayName(date) {
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(date || "")
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][parsed.getDay()]
  }

  function dayLabel(date, today) {
    if (today) return "Today"
    return dayName(date)
  }

  function dayTooltip(day, today, medal) {
    if (!day) return ""
    var parsed = new Date(String(day.date) + "T00:00:00")
    var label = isNaN(parsed.getTime())
      ? String(day.date)
      : dayName(day.date) + " " + (parsed.getMonth() + 1) + "/" + parsed.getDate()
    var text = label + " · " + usage.formatTokenCount(Number(day.messageCount || 0)) + " tokens"
    // Prompt and session counts only exist for today, so they ride along here
    // instead of taking a section of their own. Billing-API agents never
    // count prompts, and "0 prompts" would read as a quiet day, not a gap.
    if (today && provider && provider.hasPromptStats !== false)
      text += " · " + Number(provider.todayPrompts || 0) + " prompts · "
        + Number(provider.todaySessions || 0) + " sessions"
    if (medal > 0) text += " · #" + medal + " of the last 30 days"
    return text
  }

  function weekPeak(p) {
    var days = p ? (p.recentDays || []) : []
    var peak = 0
    for (var i = 0; i < days.length; i++) peak = Math.max(peak, Number(days[i].messageCount || 0))
    return peak
  }

  // Busiest day in the TOKENS BY DAY window — the one that gets the cup.
  // Podium of the last 30 days, today included: date → 1, 2 or 3. The long
  // series is historyDays; the week rows' own counts win for their dates so a
  // medal always matches the number printed next to it.
  function monthPodium(p) {
    if (!p) return ({})
    var cutoff = new Date(root.nowMs)
    cutoff.setHours(0, 0, 0, 0)
    cutoff.setDate(cutoff.getDate() - 29)
    var from = cutoff.getFullYear() + "-" + String(cutoff.getMonth() + 1).padStart(2, "0")
      + "-" + String(cutoff.getDate()).padStart(2, "0")
    var totals = {}
    var history = p.historyDays || []
    for (var i = 0; i < history.length; i++) {
      var h = history[i] || {}
      if (String(h.date) >= from) totals[String(h.date)] = Number(h.tokens || 0)
    }
    var recent = p.recentDays || []
    for (var j = 0; j < recent.length; j++) {
      var r = recent[j] || {}
      if (String(r.date) >= from) totals[String(r.date)] = Number(r.messageCount || 0)
    }
    var ranked = Object.keys(totals).filter(function(d) { return totals[d] > 0 })
    ranked.sort(function(a, b) { return totals[b] - totals[a] })
    var podium = {}
    for (var k = 0; k < Math.min(3, ranked.length); k++) podium[ranked[k]] = k + 1
    return podium
  }

  readonly property var medalColors: ["", "#ffd34d", "#c9d1d9", "#cd7f32"]

  function shortMonthDay(isoDate) {
    var parsed = new Date(String(isoDate || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(isoDate || "")
    return ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][parsed.getMonth()]
      + " " + parsed.getDate()
  }

  // Included plan quota as a fraction, skipping On-Demand. The fullest
  // remaining pool is the one that actually caps included usage.
  function includedFraction(p) {
    if (!p || !p.limits) return -1
    var best = -1
    var list = p.limits
    for (var i = 0; i < list.length; i++) {
      var entry = list[i] || {}
      var label = String(entry.label || "").toLowerCase()
      if (label.indexOf("on-demand") >= 0 || label.indexOf("on demand") >= 0) continue
      var percent = Number(entry.percent)
      if (isFinite(percent) && percent > best) best = percent
    }
    return best
  }

  function cycleChartData(p) {
    if (!p || !p.periodDays || p.periodDays.length < 2) return null
    var t0 = Number(p.periodT0)
    var t1 = Number(p.periodT1)
    if (!(t1 > t0)) {
      t0 = Number(p.periodDays[0].t)
      t1 = Number(p.periodDays[p.periodDays.length - 1].t)
      if (!(t1 > t0)) t1 = t0 + 86400000
    }
    var cap = Number(p.periodCap || 0)
    var unit = String(p.periodUnit || "")
    var cents = unit === "cents" && cap > 0
    return {
      days: p.periodDays,
      t0: t0,
      t1: t1,
      start: String(p.periodStart || ""),
      end: String(p.periodEnd || ""),
      total: Number(p.periodTotal || 0),
      allowance: cents ? cap : includedAllowanceFromTokens(p),
      unit: cents ? "cents" : "tokens"
    }
  }

  function includedAllowanceFromTokens(p) {
    var frac = includedFraction(p)
    var total = Number(p && p.periodTotal || 0)
    if (!(frac > 0) || !(total >= 0) || !isFinite(total)) return 0
    return total / frac
  }

  function formatCycleValue(n) {
    var chart = periodSection.chart
    if (chart && chart.unit === "cents")
      return root.formatMoney(Number(n) / 100, "USD")
    return usage.formatTokenCount(n)
  }

  function formatCyclePeak(n) {
    var chart = periodSection.chart
    var value = Number(n)
    if (!isFinite(value)) value = 0
    if (chart && chart.unit === "cents") {
      var dollars = Math.round(value / 100)
      if (dollars === 0) return "$0"
      return (dollars > 0 ? "+" : "−") + "$" + Math.abs(dollars)
    }
    var tokens = usage.formatTokenCount(Math.abs(value))
    return (value > 0 ? "+" : (value < 0 ? "−" : "")) + tokens
  }

  function modelAllTime(p) {
    var usageByModel = p ? (p.modelUsage || {}) : {}
    var total = 0
    var n = 0
    for (var id in usageByModel) {
      var bucket = usageByModel[id] || {}
      total += Number(bucket.inputTokens || 0)
        + Number(bucket.outputTokens || 0)
        + Number(bucket.cacheReadInputTokens || 0)
        + Number(bucket.cacheCreationInputTokens || 0)
      n += 1
    }
    return { total: total, models: n }
  }

  // TrafficChart speaks {t, down}. One signed écart: réel − even-pace
  // optimal. Future days add weekday-average spend so the last point is
  // landing − cap. Zero is on track.
  function isoFromDate(d) {
    if (!d || isNaN(d.getTime())) return ""
    return d.getFullYear()
      + "-" + String(d.getMonth() + 1).padStart(2, "0")
      + "-" + String(d.getDate()).padStart(2, "0")
  }

  function weekdayAverages(history, centsMode, skipDate, scale) {
    var sums = [0, 0, 0, 0, 0, 0, 0]
    var counts = [0, 0, 0, 0, 0, 0, 0]
    var list = history || []
    var skip = String(skipDate || "")
    var mul = Number(scale)
    if (!isFinite(mul) || mul <= 0) mul = 1
    for (var i = 0; i < list.length; i++) {
      var row = list[i]
      if (!row) continue
      var iso = String(row.date || "")
      if (iso.length !== 10 || iso === skip) continue
      var parsed = new Date(iso + "T00:00:00")
      if (isNaN(parsed.getTime())) continue
      var wd = parsed.getDay()
      var value = centsMode ? Number(row.cents) : Number(row.tokens || row.messageCount || 0)
      if (!isFinite(value) || value < 0) value = 0
      sums[wd] += value * mul
      counts[wd] += 1
    }
    var avgs = [0, 0, 0, 0, 0, 0, 0]
    var samples = 0
    for (var w = 0; w < 7; w++) {
      if (counts[w] > 0) {
        avgs[w] = sums[w] / counts[w]
        samples += counts[w]
      }
    }
    return { avgs: avgs, samples: samples }
  }

  // Auto chargedCents overshoot the Cursor Models meter; réel is scaled to
  // autoPercentUsed × $70. Apply the same factor so moy histo shares that axis.
  function historyMeterScale(chart, history) {
    if (!chart || String(chart.unit || "") !== "cents") return 1
    var used = Number(chart.total || 0)
    if (!(used > 0)) return 1
    var start = String(chart.start || "")
    var today = root.todayDate()
    var raw = 0
    var list = history || []
    for (var i = 0; i < list.length; i++) {
      var row = list[i]
      if (!row) continue
      var iso = String(row.date || "")
      if (iso.length !== 10) continue
      if (start && iso < start) continue
      if (iso > today) continue
      var cents = Number(row.cents)
      if (isFinite(cents) && cents > 0) raw += cents
    }
    if (!(raw > 0)) return 1
    return used / raw
  }

  function historyDayValue(row, centsMode, scale) {
    if (!row) return 0
    var mul = Number(scale)
    if (!isFinite(mul) || mul <= 0) mul = 1
    var value = centsMode ? Number(row.cents) : Number(row.tokens || row.messageCount || 0)
    if (!isFinite(value) || value < 0) value = 0
    return value * mul
  }

  // Mean of the last seven complete calendar days (today is still open).
  function trailingDailyAverage(chart, history, nDays) {
    var want = nDays > 0 ? nDays : 7
    var cents = !!(chart && String(chart.unit || "") === "cents")
    var scale = root.historyMeterScale(chart, history)
    var today = root.todayDate()
    var end = new Date(today + "T00:00:00")
    if (isNaN(end.getTime())) return { value: 0, samples: 0 }
    end.setDate(end.getDate() - 1)
    var byDate = {}
    var list = history || []
    for (var i = 0; i < list.length; i++) {
      var row = list[i]
      if (!row) continue
      var iso = String(row.date || "")
      if (iso.length !== 10) continue
      byDate[iso] = root.historyDayValue(row, cents, scale)
    }
    var sum = 0
    var cursor = new Date(end.getTime())
    for (var d = 0; d < want; d++) {
      var key = root.isoFromDate(cursor)
      sum += Object.prototype.hasOwnProperty.call(byDate, key) ? byDate[key] : 0
      cursor.setDate(cursor.getDate() - 1)
    }
    return { value: sum / want, samples: want }
  }

  function periodOptimalAt(t, t0, t1, cap) {
    var span = t1 - t0
    if (!(span > 0) || !(cap > 0)) return 0
    var r = (Number(t) - t0) / span
    if (r < 0) r = 0
    if (r > 1) r = 1
    return cap * r
  }

  function periodPoints(chart, history) {
    if (!chart || !chart.days) return []
    var t0 = Number(chart.t0)
    var t1 = Number(chart.t1)
    var cap = Number(chart.allowance || 0)
    var cents = String(chart.unit || "") === "cents"
    var scale = root.historyMeterScale(chart, history)
    var week = root.weekdayAverages(history, cents, root.todayDate(), scale)
    var avgs = week.avgs
    var byDate = {}
    var days = chart.days
    for (var i = 0; i < days.length; i++) {
      var day = days[i]
      if (!day || !day.date) continue
      byDate[String(day.date)] = day
    }

    var start = new Date(String(chart.start || "") + "T00:00:00")
    var end = new Date(String(chart.end || "") + "T00:00:00")
    var today = root.todayDate()
    if (isNaN(start.getTime()) || isNaN(end.getTime()) || end < start) {
      var outOld = []
      var lastCum = 0
      for (var k = 0; k < days.length; k++) {
        var row = days[k]
        if (!row) continue
        var tOld = Number(row.t)
        var cumulative = Number(row.cumulative || row.value || 0)
        if (!isFinite(tOld)) continue
        if (!isFinite(cumulative) || cumulative < 0) cumulative = 0
        lastCum = cumulative
        outOld.push({ t: tOld, down: cumulative - periodOptimalAt(tOld, t0, t1, cap) })
      }
      if (outOld.length > 0 && isFinite(t1) && outOld[outOld.length - 1].t < t1)
        outOld.push({ t: t1, down: lastCum - periodOptimalAt(t1, t0, t1, cap) })
      return outOld
    }

    var lastActualIso = ""
    var lastActualCum = 0
    var cursor = new Date(start.getTime())
    while (cursor.getTime() <= end.getTime()) {
      var isoScan = root.isoFromDate(cursor)
      var actualScan = byDate[isoScan]
      if (actualScan && isoScan <= today) {
        var cumScan = Number(actualScan.cumulative || actualScan.value || 0)
        if (!isFinite(cumScan) || cumScan < 0) cumScan = 0
        lastActualIso = isoScan
        lastActualCum = cumScan
      }
      cursor.setDate(cursor.getDate() + 1)
    }

    var out = []
    var firstNoon = new Date(root.isoFromDate(start) + "T12:00:00").getTime()
    if (isFinite(t0) && t0 < firstNoon)
      out.push({ t: t0, down: 0 })

    var proj = lastActualCum
    cursor = new Date(start.getTime())
    while (cursor.getTime() <= end.getTime()) {
      var iso = root.isoFromDate(cursor)
      var noon = new Date(iso + "T12:00:00").getTime()
      var t = noon
      if (isFinite(t0) && t < t0) t = t0
      if (isFinite(t1) && t > t1) t = t1
      var actual = byDate[iso]
      var cumul = lastActualCum
      if (actual && iso <= today) {
        cumul = Number(actual.cumulative || actual.value || 0)
        if (!isFinite(cumul) || cumul < 0) cumul = 0
      } else if (lastActualIso !== "" && iso > lastActualIso) {
        proj += avgs[cursor.getDay()]
        cumul = proj
      } else if (iso <= today) {
        cumul = lastActualCum
      } else {
        cumul = proj
      }
      var gap = cumul - periodOptimalAt(t, t0, t1, cap)
      var pt = { t: t }
      if (iso <= today) pt.down = gap
      if (iso >= today) pt.hist = gap
      out.push(pt)
      cursor.setDate(cursor.getDate() + 1)
    }
    if (out.length > 0 && isFinite(t1) && out[out.length - 1].t < t1)
      out.push({ t: t1, hist: proj - periodOptimalAt(t1, t0, t1, cap) })
    return out
  }

  function cycleLanding(chart, history) {
    if (!chart) return null
    var cap = Number(chart.allowance || 0)
    var points = root.periodPoints(chart, history)
    if (!points || points.length === 0) return null
    var last = points[points.length - 1]
    var gap = Number(last.hist)
    if (!isFinite(gap)) gap = Number(last.down)
    if (!isFinite(gap)) gap = 0
    var proj = cap + gap
    return { proj: proj, cap: cap, gap: gap, over: proj > cap }
  }

  function formatCycleWhole(n, unit) {
    if (String(unit) === "cents")
      return root.currencyPrefix("USD") + Math.round(Number(n) / 100)
    return usage.formatTokenCount(n)
  }

  function cycleDaysLeft(chart) {
    if (!chart) return -1
    var t1 = Number(chart.t1)
    if (!(t1 > 0)) return -1
    var ms = t1 - root.nowMs
    if (!(ms > 0)) return 0
    return Math.ceil(ms / 86400000)
  }

  // Same remaining days as the weekday curve, but every day costs the last
  // seven complete days' mean instead of that weekday's two-month mean.
  function cycleLanding7d(chart, history) {
    if (!chart) return null
    var cap = Number(chart.allowance || 0)
    var used = Number(chart.total || 0)
    var avg = root.trailingDailyAverage(chart, history, 7)
    var left = root.cycleDaysLeft(chart)
    if (left < 0) left = 0
    var proj = used + Number(avg.value) * left
    return { proj: proj, cap: cap, gap: proj - cap, over: proj > cap }
  }

  function providerProjectsOverCap(p) {
    var chart = root.cycleChartData(p)
    if (!chart || !(chart.allowance > 0)) return false
    var history = p ? (p.historyDays || []) : []
    var landing = root.cycleLanding(chart, history)
    if (landing && landing.over) return true
    var seven = root.cycleLanding7d(chart, history)
    return !!(seven && seven.over)
  }

  // Remaining included pool (spend anytime until reset), today's meter
  // spend, and the even slice of what's left — a budget, not a quest.
  function cycleEconomy(chart, history) {
    if (!chart) return null
    var cap = Number(chart.allowance || 0)
    var used = Number(chart.total || 0)
    if (!(cap > 0)) return null
    var bag = cap - used
    if (bag < 0) bag = 0
    var left = root.cycleDaysLeft(chart)
    if (left < 0) left = 0
    var slice = left > 0 ? bag / left : bag
    var todayIso = root.todayDate()
    var todaySpent = 0
    var quiet = 0
    var prev = 0
    var days = chart.days || []
    for (var i = 0; i < days.length; i++) {
      var day = days[i]
      if (!day) continue
      var iso = String(day.date || "")
      var cum = Number(day.cumulative || day.value || 0)
      if (!isFinite(cum) || cum < 0) cum = 0
      var delta = cum - prev
      if (delta < 0) delta = 0
      if (iso === todayIso) todaySpent = delta
      if (iso !== "" && iso <= todayIso && iso >= String(chart.start || "") && !(delta > 0.5))
        quiet += 1
      prev = cum
    }
    var landing = root.cycleLanding(chart, history)
    var leftover = 0
    if (landing && isFinite(landing.proj) && cap > landing.proj)
      leftover = cap - landing.proj
    return {
      bag: bag,
      slice: slice,
      today: todaySpent,
      leftover: leftover,
      quiet: quiet,
      daysLeft: left
    }
  }

  function spendStreak(history, centsMode, scale) {
    var byDate = {}
    var list = history || []
    var mul = Number(scale)
    if (!isFinite(mul) || mul <= 0) mul = 1
    for (var i = 0; i < list.length; i++) {
      var row = list[i]
      if (!row) continue
      var iso = String(row.date || "")
      if (iso.length !== 10) continue
      byDate[iso] = root.historyDayValue(row, centsMode, mul)
    }
    var cursor = new Date(root.todayDate() + "T00:00:00")
    if (isNaN(cursor.getTime())) return 0
    var n = 0
    var first = root.isoFromDate(cursor)
    if (!(byDate[first] > 0)) cursor.setDate(cursor.getDate() - 1)
    for (var s = 0; s < 62; s++) {
      var key = root.isoFromDate(cursor)
      if (!(byDate[key] > 0)) break
      n += 1
      cursor.setDate(cursor.getDate() - 1)
    }
    return n
  }

  function cycleFunFacts(p) {
    var facts = []
    if (!p) return facts
    var chart = root.cycleChartData(p)
    var history = p.historyDays || []
    var eco = root.cycleEconomy(chart, history)
    var all = root.modelAllTime(p)
    if (all && all.total > 0) {
      var xp = usage.formatTokenCount(all.total) + " XP"
      if (all.models > 0) xp += " · " + all.models + " models"
      facts.push(xp)
    }
    if (eco && eco.quiet > 0)
      facts.push(eco.quiet + " quiet day" + (eco.quiet === 1 ? "" : "s") + " banked this cycle")
    var cents = !!(chart && chart.unit === "cents")
    var streak = root.spendStreak(history, cents, root.historyMeterScale(chart, history))
    if (streak > 1) facts.push("streak " + streak + "d")
    if (eco && eco.leftover > 50)
      facts.push("usual keeps " + root.formatCycleWhole(eco.leftover, chart.unit) + " for later")
    if (p.hasPromptStats !== false && Number(p.todayPrompts || 0) > 0)
      facts.push(Number(p.todayPrompts || 0) + " prompts · " + Number(p.todaySessions || 0) + " sessions today")
    var cache = 0
    var tokens = 0
    var grok = false
    var usageByModel = p.modelUsage || {}
    for (var id in usageByModel) {
      var bucket = usageByModel[id] || {}
      var input = Number(bucket.inputTokens || 0)
      var output = Number(bucket.outputTokens || 0)
      var cacheRead = Number(bucket.cacheReadInputTokens || 0)
      var cacheWrite = Number(bucket.cacheCreationInputTokens || 0)
      cache += cacheRead + cacheWrite
      tokens += input + output + cacheRead + cacheWrite
      if (String(id).toLowerCase().indexOf("grok") >= 0) grok = true
    }
    if (tokens > 0 && cache > 0)
      facts.push("cache " + Math.round(100 * cache / tokens) + "% of tokens")
    if (cents && grok) facts.push("Partner Grok skips the $70")
    if (eco && chart && cents) {
      var week = root.weekdayAverages(history, true, root.todayDate(), root.historyMeterScale(chart, history))
      var wd = new Date(root.todayDate() + "T00:00:00").getDay()
      var typical = week && week.avgs ? Number(week.avgs[wd] || 0) : 0
      if (typical > 50) {
        var pct = Math.round(100 * eco.today / typical)
        facts.push("today " + pct + "% of a usual " + root.dayName(root.todayDate()))
      }
    }
    return facts
  }

  function anyProviderAlarming() {
    var list = root.providers
    for (var i = 0; i < list.length; i++) {
      var p = list[i]
      var win = root.bindingWindow(p)
      if (win && win.percent >= 0.9) return true
      if (root.providerProjectsOverCap(p)) return true
    }
    return false
  }

  function cycleAxis(points) {
    var high = 1
    if (!points) return high
    for (var i = 0; i < points.length; i++) {
      var p = points[i]
      if (!p) continue
      var d = Number(p.down)
      var h = Number(p.hist)
      if (isFinite(d) && Math.abs(d) > high) high = Math.abs(d)
      if (isFinite(h) && Math.abs(h) > high) high = Math.abs(h)
    }
    return high
  }

  function modelRows(p) {
    var usageByModel = p ? (p.modelUsage || {}) : {}
    var rows = []
    for (var id in usageByModel) {
      var bucket = usageByModel[id] || {}
      var input = Number(bucket.inputTokens || 0)
      var output = Number(bucket.outputTokens || 0)
      var cacheRead = Number(bucket.cacheReadInputTokens || 0)
      var cacheWrite = Number(bucket.cacheCreationInputTokens || 0)
      rows.push({
        name: usage.friendlyModelName(id),
        total: input + output + cacheRead + cacheWrite,
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite
      })
    }
    rows.sort(function(a, b) { return b.total - a.total })
    return rows.slice(0, 4)
  }

  function modelTooltip(row) {
    if (!row) return ""
    return "In " + usage.formatTokenCount(row.input)
      + " · out " + usage.formatTokenCount(row.output)
      + " · cache read " + usage.formatTokenCount(row.cacheRead)
      + " · cache write " + usage.formatTokenCount(row.cacheWrite)
  }

  function historyTokenMap(p) {
    var map = {}
    var list = p ? (p.historyDays || []) : []
    for (var i = 0; i < list.length; i++) {
      var row = list[i]
      if (!row) continue
      var iso = String(row.date || "")
      if (iso.length !== 10) continue
      var n = Number(row.tokens)
      if (!isFinite(n) || n < 0) n = Number(row.messageCount || 0)
      if (!isFinite(n) || n < 0) n = 0
      map[iso] = n
    }
    return map
  }

  // Claude's ledger (claude_history.py) as one bar per day, oldest first,
  // padded back to `span` days so the axis stays put while history fills in.
  function longHistoryBars(p, span) {
    var map = root.historyTokenMap(p)
    var today = root.todayDate()
    var bars = []
    for (var i = span - 1; i >= 0; i--) {
      var iso = root.addDaysIso(today, -i)
      bars.push({ date: iso, tokens: root.historyDayTokens(map, iso) })
    }
    return bars
  }

  function historyDayTokens(map, iso) {
    if (!map || !iso) return 0
    var n = Number(map[iso])
    return isFinite(n) && n > 0 ? n : 0
  }

  function addDaysIso(iso, delta) {
    var d = new Date(String(iso) + "T00:00:00")
    if (isNaN(d.getTime())) return ""
    d.setDate(d.getDate() + delta)
    return root.isoFromDate(d)
  }

  function mondayIso(iso) {
    var d = new Date(String(iso) + "T00:00:00")
    if (isNaN(d.getTime())) return ""
    var wd = d.getDay()
    d.setDate(d.getDate() - (wd === 0 ? 6 : wd - 1))
    return root.isoFromDate(d)
  }

  function weekTokens(map, monday, fromIso, toIso) {
    var sum = 0
    var d = new Date(String(monday) + "T00:00:00")
    if (isNaN(d.getTime())) return 0
    for (var i = 0; i < 7; i++) {
      var iso = root.isoFromDate(d)
      if ((!fromIso || iso >= fromIso) && (!toIso || iso <= toIso))
        sum += root.historyDayTokens(map, iso)
      d.setDate(d.getDate() + 1)
    }
    return sum
  }

  function maxDaysExcept(map, fromIso, toIso, skipIso) {
    var peak = 0
    if (!fromIso || !toIso) return 0
    var d = new Date(fromIso + "T00:00:00")
    var end = new Date(toIso + "T00:00:00")
    if (isNaN(d.getTime()) || isNaN(end.getTime()) || end < d) return 0
    while (d.getTime() <= end.getTime()) {
      var iso = root.isoFromDate(d)
      if (iso !== skipIso) {
        var v = root.historyDayTokens(map, iso)
        if (v > peak) peak = v
      }
      d.setDate(d.getDate() + 1)
    }
    return peak
  }

  function weekdayAvgExcluding(map, today) {
    var parsed = new Date(String(today) + "T00:00:00")
    if (isNaN(parsed.getTime())) return { avg: 0, samples: 0 }
    var wd = parsed.getDay()
    var sum = 0
    var n = 0
    for (var iso in map) {
      if (!iso || iso.length !== 10 || iso === today) continue
      var d = new Date(iso + "T00:00:00")
      if (isNaN(d.getTime()) || d.getDay() !== wd) continue
      sum += root.historyDayTokens(map, iso)
      n += 1
    }
    return { avg: n > 0 ? sum / n : 0, samples: n }
  }

  function formatRecordRatio(num, den) {
    var n = Number(num)
    var d = Number(den)
    if (!(n > 0)) return "—"
    if (!(d > 0)) return usage.formatTokenCount(n)
    var r = n / d
    if (r >= 10) return Math.round(r) + "×"
    var tenth = Math.round(r * 10) / 10
    if (tenth === Math.floor(tenth)) return String(tenth) + "×"
    return tenth.toFixed(1) + "×"
  }

  // Eight spend-max records. Locked tiles stay grey; unlocked take loot color.
  function achievementList(p, _nowMs) {
    var today = root.todayDate()
    var map = root.historyTokenMap(p)
    var todayN = root.historyDayTokens(map, today)
    var monthStart = today.length === 10 ? today.slice(0, 8) + "01" : ""
    var y1 = root.historyDayTokens(map, root.addDaysIso(today, -1))
    var y2 = root.historyDayTokens(map, root.addDaysIso(today, -2))
    var weekday = root.weekdayAvgExcluding(map, today)
    var mon = root.mondayIso(today)
    var thisWeek = root.weekTokens(map, mon, "", today)
    var thisMonthWeek = monthStart !== "" ? root.weekTokens(map, mon, monthStart, today) : 0
    var prev1 = root.weekTokens(map, root.addDaysIso(mon, -7), "", today)
    var prev2 = root.weekTokens(map, root.addDaysIso(mon, -14), "", today)
    var prev3 = root.weekTokens(map, root.addDaysIso(mon, -21), "", today)
    var prev4 = root.weekTokens(map, root.addDaysIso(mon, -28), "", today)
    var record15 = todayN > root.maxDaysExcept(map, root.addDaysIso(today, -14), today, today)
    var champ7 = todayN > 0 && todayN > root.maxDaysExcept(map, root.addDaysIso(today, -6), today, today)
    var cycleDay = monthStart !== "" && todayN > 0 && todayN > root.maxDaysExcept(map, monthStart, today, today)
    var peakWeek = 0
    if (monthStart !== "" && thisMonthWeek > 0) {
      var cursor = new Date(monthStart + "T00:00:00")
      var end = new Date(today + "T00:00:00")
      var seen = {}
      if (!isNaN(cursor.getTime()) && !isNaN(end.getTime())) {
        while (cursor.getTime() <= end.getTime()) {
          var iso = root.isoFromDate(cursor)
          var otherMon = root.mondayIso(iso)
          if (otherMon !== mon && !seen[otherMon]) {
            seen[otherMon] = true
            var other = root.weekTokens(map, otherMon, monthStart, today)
            if (other > peakWeek) peakWeek = other
          }
          cursor.setDate(cursor.getDate() + 1)
        }
      }
    }
    var cycleWeekOn = monthStart !== "" && thisMonthWeek > 0 && thisMonthWeek > peakWeek
    var peak4 = Math.max(prev1, prev2, prev3, prev4)
    var streak = 0
    if (todayN > 0) streak = 1
    if (todayN > y1) streak = 2
    if (todayN > y1 && y1 > y2) streak = 3

    var white = "#e6e6e6"
    var green = "#3dd68c"
    var blue = "#5aa8ff"
    var purple = "#c084fc"
    var orange = "#f59e0b"

    return [
      { id: "weekday", icon: "󰃭", label: "Type", on: todayN > 0 && weekday.samples > 0 && todayN > weekday.avg, color: green, hint: "Today beats your average for this weekday.", qty: root.formatRecordRatio(todayN, weekday.avg) },
      { id: "champ", icon: "󰔯", label: "7 j", on: champ7, color: green, hint: "Today is the busiest of the last 7 days.", qty: root.formatRecordRatio(todayN, root.maxDaysExcept(map, root.addDaysIso(today, -6), today, today)) },
      { id: "streak", icon: "󰕌", label: "Série", on: todayN > y1 && y1 > y2, color: blue, hint: "Three days in a row, each higher than the last.", qty: streak + "/3" },
      { id: "d15", icon: "󰓅", label: "15 j", on: todayN > 0 && record15, color: blue, hint: "Today is the busiest of the last 15 days.", qty: root.formatRecordRatio(todayN, root.maxDaysExcept(map, root.addDaysIso(today, -14), today, today)) },
      { id: "wprev", icon: "󰁝", label: "S−1", on: thisWeek > 0 && thisWeek > prev1, color: white, hint: "This week (Mon–Sun) beats last week.", qty: root.formatRecordRatio(thisWeek, prev1) },
      { id: "wcycle", icon: "󰨳", label: "Sem.", on: cycleWeekOn, color: purple, hint: "This week is the busiest of the calendar month.", qty: root.formatRecordRatio(thisMonthWeek, peakWeek) },
      { id: "dcycle", icon: "󰝪", label: "Cycle", on: cycleDay, color: purple, hint: "Today is the busiest day of the calendar month.", qty: root.formatRecordRatio(todayN, root.maxDaysExcept(map, monthStart, today, today)) },
      { id: "w4", icon: "󰀎", label: "×4", on: thisWeek > 0 && thisWeek > prev1 && thisWeek > prev2 && thisWeek > prev3 && thisWeek > prev4, color: orange, hint: "This week beats each of the previous 4 weeks.", qty: root.formatRecordRatio(thisWeek, peak4) }
    ]
  }

  // Only speaks up when the numbers cover more than this machine.
  function footerText() {
    if (usage.syncStatusText !== "") return usage.syncStatusText
    if (provider && provider.syncEnabled && provider.syncDeviceCount > 0)
      return "Merged from " + provider.syncDeviceCount + " device" + (provider.syncDeviceCount === 1 ? "" : "s")
    return ""
  }

  // Agents that ship a white mark carry an `assets/<id>-light.svg` twin for
  // light surfaces; marks that work on both (Claude's brand-orange) ship one
  // file. The luminance check decides which candidate to try first.
  function colorChannelLuminance(value) {
    var channel = Number(value)
    if (!isFinite(channel)) return 0
    return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function colorLuminance(color) {
    return 0.2126 * colorChannelLuminance(color.r)
      + 0.7152 * colorChannelLuminance(color.g)
      + 0.0722 * colorChannelLuminance(color.b)
  }

  // Marks resolve by convention, so a new agent's data file needs nothing
  // from this panel: assets/<id>.svg if it ships one, the module's bar glyph
  // if it doesn't.
  function iconCandidatesForProvider(p, surfaceColor) {
    if (!p) return []
    var candidates = []
    if (colorLuminance(surfaceColor || Color.background) >= 0.5)
      candidates.push(Qt.resolvedUrl("assets/" + p.providerId + "-light.svg"))
    candidates.push(Qt.resolvedUrl("assets/" + p.providerId + ".svg"))
    return candidates
  }

  // Nothing to report, nothing in the bar: Bar.qml collapses a slot whose item
  // is invisible, so the icon appears the moment the first scan finds usage and
  // stays away entirely on a machine that has never run either CLI.
  visible: providers.length > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onProviderIndexChanged: if (panelFlick) panelFlick.contentY = 0
  onOpenedChanged: if (opened) {
    cursorActive = false
    nowMs = Date.now()
    funFactIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    usage.refreshLimits()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Main {
    id: usage
    settings: root.settings
  }

  // Cheap enough to keep running: it only re-evaluates text bindings, and a
  // stale "resets in 2h" on a panel that is open is worse than a timer.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    interval: 8000
    running: root.opened
    repeat: true
    onTriggered: root.funFactIndex += 1
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function next(): string { root.selectProvider(root.providerIndex + 1); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󱚣"
    active: root.alarming
    useActiveColor: false
    foreground: root.barForeground
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.launchAgent()
      else if (buttonCode === Qt.MiddleButton) root.selectProvider(root.providerIndex + 1)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // Dashboard: grow with the records grid instead of clipping the last row
    // at a 900px cap. Screen edge still clamps via availableCardHeight.
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.cursorActive = true
          root.selectProvider(root.providerIndex + dx)
        }
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refreshNow() }

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

          // ---------- Hero: provider mark · name · plan ----------
          PanelHero {
            id: hero
            visible: !!root.provider
            width: parent.width
            title: root.provider ? root.provider.providerName : ""
            meta: root.heroMeta(root.provider)
            detail: root.heroDetail(root.provider)
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Item {
                id: heroMark
                property var candidates: root.iconCandidatesForProvider(root.provider, root.surface)
                // Provider objects are rebuilt on every refresh, which churns the
                // array's identity without changing its content. Restart the fallback
                // walk only when the URLs change: re-pointing source at a URL whose
                // load already failed emits no statusChanged, so an identity-only
                // reset would strand the walker on a missing -light twin.
                property string candidatesKey: candidates.join("\n")
                property int candidateIndex: 0
                onCandidatesKeyChanged: candidateIndex = 0

                width: Style.font.display
                height: Style.font.display

                Image {
                  id: heroMarkImage
                  anchors.fill: parent
                  source: heroMark.candidateIndex < heroMark.candidates.length ? heroMark.candidates[heroMark.candidateIndex] : ""
                  sourceSize.width: Style.font.display * 2
                  sourceSize.height: Style.font.display * 2
                  fillMode: Image.PreserveAspectFit
                  // Advancing source from inside its own status change trips the
                  // binding-loop detector; defer the step one tick.
                  onStatusChanged: if (status === Image.Error && heroMark.candidateIndex < heroMark.candidates.length)
                    Qt.callLater(function() { heroMark.candidateIndex++ })
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  visible: heroMarkImage.status !== Image.Ready
                  text: button.text
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }
          }

          Text {
            visible: root.providers.length === 0
            width: parent.width
            topPadding: Style.space(24)
            text: "No AI coding subscriptions found.\nAgents show up here once you've used them."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // ---------- Provider switch ----------
          // Inset + floored cell widths so the 1px Button stroke stays inside
          // the Flickable clip (same idea as recordsHost). Without this the
          // left hairline of the first chip is clipped and leftover slack
          // piles up only on the right.
          Item {
            id: providerSwitchHost
            visible: root.providers.length > 1
            width: parent.width
            height: providerSwitch.height
            readonly property real inset: Style.space(4)
            readonly property real inner: Math.max(1, width - inset * 2)

            Row {
              id: providerSwitch
              x: providerSwitchHost.inset
                + Math.max(0, Math.floor((providerSwitchHost.inner - providerSwitch.used) / 2))
              width: used
              spacing: Style.spacing.md

              readonly property real cellWidth: root.providers.length > 0
                ? Math.floor((providerSwitchHost.inner - spacing * (root.providers.length - 1))
                             / root.providers.length)
                : 0
              readonly property real used: root.providers.length > 0
                ? cellWidth * root.providers.length + spacing * (root.providers.length - 1)
                : 0

              Repeater {
                model: root.providers

                Button {
                  required property var modelData
                  required property int index

                  width: providerSwitch.cellWidth
                  text: modelData.providerName
                  selected: index === root.providerIndex
                  hasCursor: root.cursorActive && index === root.providerIndex
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  verticalPadding: Style.spacing.controlPaddingY
                  onClicked: {
                    root.cursorActive = true
                    root.selectProvider(index)
                  }
                  onHovered: function(isHovered) { if (isHovered) root.cursorActive = true }
                }
              }
            }
          }

          // ---------- Status ----------
          BorderSurface {
            visible: !!root.provider && String(root.provider.usageStatusText || "") !== ""
            width: parent.width
            implicitHeight: statusText.implicitHeight + Style.spacing.xl * 2
            color: root.alpha(root.urgent, 0.10)
            borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              id: statusText
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: root.provider ? String(root.provider.authHelpText || "") : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Balance / limits ----------
          PanelSeparator {
            visible: balanceSection.visible || limitsSection.visible
            foreground: root.foreground
          }

          Column {
            id: balanceSection
            visible: !!root.balance
            width: parent.width
            spacing: Style.space(10)

            // The meter shows what is left, not what is used: a prepaid
            // account drains toward empty rather than filling toward a cap.
            readonly property real ratio: root.balance && root.balance.funded > 0
              ? root.clamp(root.balance.remaining / root.balance.funded, 0, 1)
              : -1

            PanelSectionHeader {
              width: parent.width
              text: "BALANCE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(balanceLabel.implicitHeight, balanceValue.implicitHeight)

              Text {
                id: balanceLabel
                text: "Prepaid credits"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: balanceValue
                textFormat: Text.PlainText
                text: root.balance ? root.formatMoney(root.balance.remaining, root.balance.currency) : ""
                color: root.balanceAlarming ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Meter {
              visible: balanceSection.ratio >= 0
              width: parent.width
              value: balanceSection.ratio
              alarming: root.balanceAlarming
            }

            Text {
              textFormat: Text.PlainText
              visible: text !== ""
              width: parent.width
              text: root.balanceDetailText(root.balance)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Column {
            id: limitsSection
            visible: root.limits.length > 0
            width: parent.width
            spacing: Style.space(10)

            // Each LimitRow carries its own reset: the session and the weekly
            // windows roll over on different clocks.
            PanelSectionHeader {
              text: "LIMITS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.limits

              LimitRow {
                required property var modelData
                width: limitsSection.width
                window: modelData
              }
            }
          }

          // ---------- Billing period cumulative ----------
          PanelSeparator {
            visible: periodSection.visible
            foreground: root.foreground
          }

          Column {
            id: periodSection
            visible: !!(root.provider && root.provider.periodDays && root.provider.periodDays.length >= 2)
            width: parent.width
            spacing: Style.space(8)

            readonly property var chart: root.cycleChartData(root.provider)
            readonly property var history: root.provider ? (root.provider.historyDays || []) : []
            readonly property var points: root.periodPoints(periodSection.chart, periodSection.history)
            readonly property real axis: root.cycleAxis(periodSection.points)
            readonly property var landing: root.cycleLanding(periodSection.chart, periodSection.history)
            readonly property var landing7: root.cycleLanding7d(periodSection.chart, periodSection.history)
            readonly property bool over: !!(periodSection.landing && periodSection.landing.over)
            readonly property bool over7: !!(periodSection.landing7 && periodSection.landing7.over)
            readonly property string futureColor: periodSection.over ? root.cycleCrashColor : root.cycleOkColor
            readonly property var weekAvg: root.trailingDailyAverage(periodSection.chart, periodSection.history, 7)
            readonly property var economy: root.cycleEconomy(periodSection.chart, periodSection.history)
            readonly property var funFacts: root.cycleFunFacts(root.provider)
            readonly property string unit: periodSection.chart ? String(periodSection.chart.unit || "") : ""
            readonly property double nowT: {
              var chart = periodSection.chart
              if (!chart) return 0
              var t0 = Number(chart.t0)
              var t1 = Number(chart.t1)
              var n = root.nowMs
              if (n < t0) return t0
              if (n > t1) return t1
              return n
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(periodHeader.implicitHeight, periodLanding.implicitHeight)

              PanelSectionHeader {
                id: periodHeader
                text: "THIS CYCLE"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.right: periodLanding.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
              }

              Row {
                id: periodLanding
                visible: !!periodSection.landing
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                Text {
                  textFormat: Text.PlainText
                  text: periodSection.landing
                    ? root.formatCycleWhole(periodSection.landing.proj, periodSection.unit) + " usual"
                    : ""
                  color: periodSection.futureColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                Text {
                  visible: !!periodSection.landing7
                  textFormat: Text.PlainText
                  text: " · "
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  visible: !!periodSection.landing7
                  textFormat: Text.PlainText
                  text: periodSection.landing7
                    ? root.formatCycleWhole(periodSection.landing7.proj, periodSection.unit) + " 7d"
                    : ""
                  color: periodSection.over7 ? root.cycleCrashColor : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                Text {
                  textFormat: Text.PlainText
                  text: periodSection.landing
                    ? " · " + root.formatCycleWhole(periodSection.landing.cap, periodSection.unit)
                    : ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            TrafficChart {
              objectName: "agentsCycleChart"
              width: parent.width
              height: Style.space(72)
              points: periodSection.points
              t0: periodSection.chart ? Number(periodSection.chart.t0) : 0
              t1: periodSection.chart ? Number(periodSection.chart.t1) : 1
              downMax: periodSection.axis
              upMax: periodSection.axis
              showDown: true
              showUp: false
              showHist: true
              showPing: false
              showLoss: false
              signedAxis: true
              peakCount: 5
              markerT: periodSection.nowT
              downColor: root.cyclePastColor
              downFill: "rgba(90, 168, 255, 0.16)"
              histColor: periodSection.futureColor
              fontFamily: root.fontFamily
              gridColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12).toString()
              formatDown: function(n) { return root.formatCyclePeak(n) }
              formatUp: function(n) { return root.formatCyclePeak(n) }
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(periodRange.implicitHeight, periodPace.implicitHeight)

              Text {
                id: periodRange
                textFormat: Text.PlainText
                text: periodSection.chart
                  ? root.shortMonthDay(periodSection.chart.start) + " – " + root.shortMonthDay(periodSection.chart.end)
                  : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: periodPace
                textFormat: Text.PlainText
                text: {
                  var bits = []
                  var avg = periodSection.weekAvg
                  if (avg && avg.samples > 0)
                    bits.push("7d " + root.formatCycleValue(avg.value) + "/d")
                  var left = root.cycleDaysLeft(periodSection.chart)
                  if (left >= 0) bits.push(left + "d left")
                  return bits.join(" · ")
                }
                color: periodSection.over7 ? root.cycleCrashColor : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Item {
              visible: !!periodSection.economy
              width: parent.width
              implicitHeight: Math.max(periodBag.implicitHeight, periodSlice.implicitHeight)

              Text {
                id: periodBag
                textFormat: Text.PlainText
                text: periodSection.economy
                  ? "bag " + root.formatCycleWhole(periodSection.economy.bag, periodSection.unit)
                  : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: periodSlice
                textFormat: Text.PlainText
                text: periodSection.economy
                  ? "today " + root.formatCycleValue(periodSection.economy.today)
                    + " / " + root.formatCycleValue(periodSection.economy.slice)
                  : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: periodSection.funFacts.length > 0
              width: parent.width
              text: {
                var facts = periodSection.funFacts
                if (!facts || facts.length === 0) return ""
                return facts[((root.funFactIndex % facts.length) + facts.length) % facts.length]
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
            }
          }

          // ---------- Claude history ----------
          // Daily tokens only: Claude caps on 5-hour and weekly windows in
          // percent, so there is no monthly allowance to project against.
          PanelSeparator {
            visible: historySection.visible
            foreground: root.foreground
          }

          Column {
            id: historySection
            visible: !!root.provider && root.provider.providerId === "claude"
              && root.provider.historyDays && root.provider.historyDays.length > 0
            width: parent.width
            spacing: Style.spacing.md

            readonly property int span: 90
            readonly property var bars: root.longHistoryBars(root.provider, historySection.span)
            readonly property real peak: {
              var max = 1
              for (var i = 0; i < bars.length; i++) max = Math.max(max, bars[i].tokens)
              return max
            }
            readonly property real total: {
              var sum = 0
              for (var i = 0; i < bars.length; i++) sum += bars[i].tokens
              return sum
            }
            readonly property real gap: 1
            readonly property real barWidth: Math.max(1, (width - gap * (span - 1)) / span)

            Item {
              width: parent.width
              implicitHeight: Math.max(historyHeader.implicitHeight, historyTotal.implicitHeight)

              PanelSectionHeader {
                id: historyHeader
                text: "LAST " + historySection.span + " DAYS"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.right: historyTotal.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: historyTotal
                textFormat: Text.PlainText
                text: "total " + usage.formatTokenCount(historySection.total)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Item {
              id: historyPlot
              width: parent.width
              height: Style.space(56)

              Repeater {
                model: historySection.bars

                Rectangle {
                  required property var modelData
                  required property int index

                  readonly property bool isToday: modelData.date === root.todayDate()

                  x: index * (historySection.barWidth + historySection.gap)
                  y: historyPlot.height - height
                  width: historySection.barWidth
                  height: modelData.tokens > 0
                    ? Math.max(2, historyPlot.height * modelData.tokens / historySection.peak)
                    : 1
                  color: modelData.tokens > 0
                    ? (isToday ? root.foreground : root.alpha(root.foreground, 0.55))
                    : root.track
                }
              }
            }

            // Short month name under the first day of each month.
            Item {
              width: parent.width
              height: historyMonthProbe.implicitHeight

              Text {
                id: historyMonthProbe
                visible: false
                text: "M"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Repeater {
                model: historySection.bars

                Text {
                  required property var modelData
                  required property int index

                  visible: String(modelData.date).slice(8) === "01"
                  x: Math.min(index * (historySection.barWidth + historySection.gap), parent.width - implicitWidth)
                  textFormat: Text.PlainText
                  text: Qt.locale().monthName(Number(String(modelData.date).slice(5, 7)) - 1, Locale.ShortFormat)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // ---------- Usage ----------
          PanelSeparator {
            visible: usageSection.visible
            foreground: root.foreground
          }

          Column {
            id: usageSection
            visible: !!root.provider && root.provider.recentDays && root.provider.recentDays.length > 0
            width: parent.width
            spacing: Style.spacing.md

            readonly property var days: root.provider ? (root.provider.recentDays || []) : []
            readonly property real peak: Math.max(1, root.weekPeak(root.provider))
            readonly property var podium: root.monthPodium(root.provider)
            readonly property bool meterCaption: !!(root.provider && String(root.provider.periodUnit || "") === "cents")

            Item {
              width: parent.width
              implicitHeight: Math.max(usageHeader.implicitHeight, usageCaption.implicitHeight)

              PanelSectionHeader {
                id: usageHeader
                text: "TOKENS BY DAY"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.right: usageCaption.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: usageCaption
                textFormat: Text.PlainText
                visible: usageSection.meterCaption
                text: "tokens ≠ meter"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Repeater {
              model: usageSection.days

              DayRow {
                required property var modelData
                required property int index

                width: usageSection.width
                day: modelData
                ratio: Number(modelData.messageCount || 0) / usageSection.peak
                // By date, not by position: the Claude stats-cache fallback can
                // hand us a window that stops short of today.
                today: String(modelData.date || "") === root.todayDate()
                medal: usageSection.podium[String(modelData.date || "")] || 0
              }
            }
          }

          // ---------- Models ----------
          PanelSeparator {
            visible: modelSection.visible
            foreground: root.foreground
          }

          Column {
            id: modelSection
            visible: root.models.length > 0
            width: parent.width
            spacing: Style.spacing.md

            readonly property var allTime: root.modelAllTime(root.provider)

            Item {
              width: parent.width
              implicitHeight: Math.max(modelHeader.implicitHeight, modelAllTime.implicitHeight)

              PanelSectionHeader {
                id: modelHeader
                text: "TOKENS BY MODEL"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.right: modelAllTime.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: modelAllTime
                textFormat: Text.PlainText
                text: {
                  var info = modelSection.allTime
                  if (!(info.total > 0)) return "all-time"
                  var text = usage.formatTokenCount(info.total) + " all-time"
                  if (info.models > root.models.length)
                    text += " · " + info.models + " models"
                  return text
                }
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Repeater {
              model: root.models

              ModelRow {
                required property var modelData
                width: modelSection.width
                row: modelData
                // Scaled to the heaviest model, so the top row is always full —
                // the same scale-to-peak the weekly chart uses for its busiest day.
                share: modelData.total / Math.max(1, root.models[0].total)
              }
            }
          }

          // ---------- Achievements ----------
          PanelSeparator {
            visible: recordsSection.visible
            foreground: root.foreground
          }

          Column {
            id: recordsSection
            visible: !!root.provider && root.achievements && root.achievements.length > 0
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              width: parent.width
              text: "ACHIEVMENTS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              id: recordsHost
              width: parent.width
              readonly property real gap: Style.space(6)
              // Keep the 1px tile stroke inside the Flickable clip and off the
              // panel chrome; leftover pixels stay centered.
              readonly property real inset: Style.space(4)
              readonly property real inner: Math.max(1, width - inset * 2)
              readonly property real cell: Math.max(1, Math.floor((inner - gap * 3) / 4))
              readonly property real used: cell * 4 + gap * 3
              height: cell * 2 + gap

              Grid {
                id: recordsGrid
                x: recordsHost.inset + Math.max(0, Math.floor((recordsHost.inner - recordsHost.used) / 2))
                y: 0
                width: recordsHost.used
                height: parent.height
                columns: 4
                columnSpacing: recordsHost.gap
                rowSpacing: recordsHost.gap

                Repeater {
                  model: root.achievements

                  AchievementTile {
                    required property var modelData
                    width: recordsHost.cell
                    height: recordsHost.cell
                    tile: modelData
                  }
                }
              }
            }

            Item { width: 1; height: Style.space(2) }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            topPadding: Style.space(2)
            text: root.footerText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // One of the eight spend records: grey outline when locked, loot color when on.
  component AchievementTile: Item {
    id: achTile
    property var tile: null

    readonly property bool unlocked: !!(tile && tile.on)
    readonly property color ink: {
      if (!unlocked) return root.dim
      var hex = tile && tile.color ? String(tile.color) : ""
      return hex !== "" ? hex : root.foreground
    }

    BorderSurface {
      anchors.fill: parent
      anchors.margins: 1
      color: achTile.unlocked ? Qt.rgba(achTile.ink.r, achTile.ink.g, achTile.ink.b, 0.12) : "transparent"
      borderSpec: Border.flat(achTile.unlocked ? achTile.ink : root.alpha(root.foreground, 0.22), 1)
      radius: Style.cornerRadius
    }

    Column {
      anchors.fill: parent
      anchors.topMargin: Style.space(6)
      anchors.bottomMargin: Style.space(6)
      spacing: 0

      Text {
        width: parent.width
        height: parent.height - labelLine.height - qtyLine.height
        textFormat: Text.PlainText
        text: achTile.tile ? String(achTile.tile.icon || "") : ""
        color: achTile.ink
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }

      Text {
        id: labelLine
        width: parent.width
        textFormat: Text.PlainText
        text: achTile.tile ? String(achTile.tile.label || "") : ""
        color: achTile.ink
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
      }

      Text {
        id: qtyLine
        width: parent.width
        textFormat: Text.PlainText
        text: achTile.tile ? String(achTile.tile.qty || "") : ""
        color: achTile.ink
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        horizontalAlignment: Text.AlignHCenter
      }
    }

    MouseArea {
      id: achHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      z: 2

      PanelToolTip {
        visible: achHover.containsMouse && achTile.tile && String(achTile.tile.hint || "") !== ""
        text: achTile.tile ? String(achTile.tile.hint || "") : ""
        fontFamily: root.fontFamily
        delay: 200
        // Default placement is below the tile; the records grid sits on the
        // card's bottom edge, so flip the bubble up into the panel.
        y: -implicitHeight - Style.space(8)
        x: Math.round((achHover.width - implicitWidth) / 2)
      }
    }
  }

  // A limit window: label, percentage, and meter.
  component LimitRow: Column {
    id: limitRow
    property var window: null

    readonly property bool alarming: window && window.percent >= 0.9
    readonly property var forecast: root.forecastFor(window)
    readonly property bool forecastOver: !!forecast && forecast.mid > 1

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)

      Text {
        id: limitLabel
        textFormat: Text.PlainText
        // A model-scoped window is titled after its model, and those names run
        // long enough to reach the percentage, so the title gives way first.
        text: limitRow.window ? limitRow.window.title : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: limitReset.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: limitReset
        textFormat: Text.PlainText
        text: root.resetTextFor(limitRow.window)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: limitValue.left
        anchors.rightMargin: text === "" ? 0 : Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: limitValue
        textFormat: Text.PlainText
        text: limitRow.window && limitRow.window.percent >= 0
          ? Math.round(limitRow.window.percent * 100) + "%"
          : "—"
        color: limitRow.alarming ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      width: parent.width
      value: limitRow.window ? limitRow.window.percent : -1
      forecast: limitRow.forecast
    }

    Text {
      id: limitForecast
      visible: !!limitRow.forecast
      width: parent.width
      textFormat: Text.PlainText
      text: root.forecastText(limitRow.forecast)
      color: limitRow.forecastOver ? root.paceColor(limitRow.forecast.mid) : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight

      MouseArea {
        id: forecastHover
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
      }

      PanelToolTip {
        visible: forecastHover.containsMouse
        text: root.forecastTooltip(limitRow.forecast)
        fontFamily: root.fontFamily
      }
    }
  }

  // Rounded track showing the percentage of the allowance used.
  component Meter: Item {
    id: meter
    property real value: -1
    // forecast.py's landing: the low–high band faint, the run to the usual
    // pace stronger, both behind the used fill so only what is to come shows.
    property var forecast: null
    readonly property color forecastInk: root.paceColor(forecast ? forecast.mid : 0)
    property bool alarming: false
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      visible: !!meter.forecast && meter.forecast.high > meter.value
      x: meterTrack.width * root.clamp(meter.forecast ? Math.max(meter.forecast.low, meter.value) : 0, 0, 1)
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.forecast ? meter.forecast.high : 0, 0, 1) - x
      color: root.alpha(meter.forecastInk, 0.2)
    }

    Rectangle {
      visible: !!meter.forecast && meter.forecast.mid > meter.value
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.forecast ? meter.forecast.mid : 0, 0, 1)
      color: root.alpha(meter.forecastInk, 0.45)

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : root.foreground

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

  }

  // One row per day: label, bar, tokens. Today is picked out in full
  // foreground so the week reads as a run-up to right now. A day on the
  // last 30 days' podium gets a gold, silver or bronze cup.
  component DayRow: Item {
    id: dayRow
    property var day: null
    property real ratio: 0
    property bool today: false
    // 1-3 on the last 30 days' podium, 0 off it.
    property int medal: 0

    readonly property color ink: today ? root.foreground : root.dim
    readonly property color fill: today ? root.foreground : root.alpha(root.foreground, 0.55)

    implicitHeight: Math.max(dayLabel.implicitHeight, dayValue.implicitHeight) + Style.spacing.sm

    Text {
      id: dayLabel
      textFormat: Text.PlainText
      text: root.dayLabel(dayRow.day ? dayRow.day.date : "", dayRow.today)
      color: dayRow.ink
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayRow.today
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    Rectangle {
      id: dayTrack
      anchors.left: dayLabel.right
      anchors.right: dayValue.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      radius: height / 2
      color: root.track

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: parent.width * root.clamp(dayRow.ratio, 0, 1)
        color: dayRow.fill

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      id: dayValue
      textFormat: Text.PlainText
      text: usage.formatTokenCount(dayRow.day ? Number(dayRow.day.messageCount || 0) : 0)
      color: dayRow.ink
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    // Overlay: does not steal track width. Centered in the gap between the
    // bar's right edge and the actual start of the token text.
    Text {
      id: medalCup
      visible: dayRow.medal > 0
      z: 1
      textFormat: Text.PlainText
      text: "\uf091"
      color: root.medalColors[dayRow.medal] || root.contrast
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.verticalCenter: parent.verticalCenter
      x: {
        var barEnd = dayTrack.x + dayTrack.width
        var numStart = dayValue.x + dayValue.width - dayValue.contentWidth
        return barEnd + (numStart - barEnd - implicitWidth) / 2
      }
    }

    MouseArea {
      id: dayHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: dayHover.containsMouse
      text: root.dayTooltip(dayRow.day, dayRow.today, dayRow.medal)
      fontFamily: root.fontFamily
    }
  }

  // Model rows read as a table: the share bar fills the row behind the label
  // instead of stacking under it, which keeps the whole dashboard on one screen.
  component ModelRow: Item {
    id: modelRow
    property var row: null
    property real share: 0

    implicitHeight: modelName.implicitHeight + Style.spacing.lg

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.05)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(modelRow.share, 0, 1)
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.14)

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Text {
      id: modelName
      textFormat: Text.PlainText
      text: modelRow.row ? modelRow.row.name : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: modelTokens.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: modelTokens
      textFormat: Text.PlainText
      text: modelRow.row ? usage.formatTokenCount(modelRow.row.total) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: modelHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: modelHover.containsMouse
      text: root.modelTooltip(modelRow.row)
      fontFamily: root.fontFamily
    }
  }
}
