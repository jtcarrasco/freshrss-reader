.pragma library

// Pure display helpers (no QML state), shared by the panel.

// Epoch seconds -> "5m", "3h", "2d", or a date for older items.
function relativeTime(epochSeconds, nowMs) {
  var s = Number(epochSeconds) || 0
  if (s <= 0) return ""
  var diff = Math.max(0, ((nowMs || Date.now()) / 1000) - s)
  if (diff < 60) return "now"
  if (diff < 3600) return Math.floor(diff / 60) + "m"
  if (diff < 86400) return Math.floor(diff / 3600) + "h"
  if (diff < 7 * 86400) return Math.floor(diff / 86400) + "d"
  return formatDate(s)
}

// Epoch seconds -> "Sep 24, 2026".
function formatDate(epochSeconds) {
  var s = Number(epochSeconds) || 0
  if (s <= 0) return ""
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  var d = new Date(s * 1000)
  return months[d.getMonth()] + " " + d.getDate() + ", " + d.getFullYear()
}
