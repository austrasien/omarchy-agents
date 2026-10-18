import QtQuick
import Quickshell.Io

// One agent's usage record, read straight off the data file that
// omarchy-agent-usage-update maintains. The panel never learns how the
// numbers were made — a record that appears in the usage directory is an
// agent, whoever wrote it.
Item {
  id: root
  visible: false

  property string agentId: ""
  property string path: ""
  property var record: null

  FileView {
    path: root.path
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parse(text())
    onLoadFailed: root.record = null
  }

  function parse(content) {
    try {
      var parsed = JSON.parse(String(content || ""))
      if (parsed && typeof parsed === "object") {
        // The stock collector rewrites claude.json without historyDays and
        // claude_history.py adds them back a moment later; keep the last
        // series in between so the history chart does not blink.
        if (!parsed.historyDays && root.record && root.record.historyDays)
          parsed.historyDays = root.record.historyDays
        // Same for the per-limit forecasts forecast.py adds.
        if (root.record && Array.isArray(parsed.limits) && Array.isArray(root.record.limits)) {
          for (var i = 0; i < parsed.limits.length; i++) {
            var limit = parsed.limits[i]
            if (!limit || limit.forecast) continue
            for (var j = 0; j < root.record.limits.length; j++) {
              var old = root.record.limits[j]
              if (old && old.forecast && old.label === limit.label) limit.forecast = old.forecast
            }
          }
        }
        root.record = parsed
      } else {
        root.record = null
      }
    } catch (e) {
      console.warn("agents", "Ignoring bad usage record", root.path, e)
      root.record = null
    }
  }
}
