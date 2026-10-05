import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins
import "Model.js" as Model

// The DankMaterialShell plugin's daemon surface. DMS creates one instance of
// it for the session, while the bar widget (FreshRSSWidget.qml) gets one
// instance per bar. Everything that must exist once lives here: the unread
// poll, the IPC handler, the login, the article lists and read/star syncing.
// The bar widgets and their popouts only render this state.
//
// The shell-independent parts (Model.js and the Python backend) are shared
// with the Omarchy plugin at the repo root (tools/sync-dms.sh).
PluginComponent {
  id: root

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")
  function backend(args) {
    return ["python3", root.pluginDir + "/scripts/freshrss_backend.py"].concat(args)
  }

  // ---- State ---------------------------------------------------------------
  property bool configured: false
  property string serverUrl: ""
  property string username: ""
  property bool settingsView: false
  property int totalUnread: 0
  property var categories: []
  property bool overviewLoading: false

  // view: "home" | "items" | "article"
  property string view: "home"
  property var stream: null            // {id, title}
  property bool unreadOnly: true
  property var items: []
  property string continuation: ""
  property bool itemsLoading: false
  property int cursor: -1
  property int homeCursor: 0
  property var article: null
  property string listError: ""
  property bool confirmMarkAll: false

  property string setupError: ""
  property bool setupBusy: false
  property string pendingPassword: ""
  property bool confirmDisconnect: false
  property string loginUrl: ""
  property string loginUser: ""
  // The popout clears its password field when this fires.
  signal loginSucceeded()

  // The reading list is "All unread" or "All items" depending on the filter.
  readonly property string streamTitle: !stream ? ""
    : (stream.id === readingList && !unreadOnly) ? "All items" : stream.title
  readonly property string readingList: "user/-/state/com.google/reading-list"
  readonly property string starredStream: "user/-/state/com.google/starred"

  // feedId -> favicon URL, the fallback for items without a thumbnail.
  readonly property var feedIcons: {
    var map = {}
    for (var i = 0; i < categories.length; i++) {
      var feeds = categories[i].feeds || []
      for (var j = 0; j < feeds.length; j++) if (feeds[j].iconUrl) map[feeds[j].id] = feeds[j].iconUrl
    }
    return map
  }
  readonly property var homeEntries: [
    { id: readingList, label: "All unread", unread: totalUnread, icon: "rss_feed" },
    { id: starredStream, label: "Starred", unread: -1, icon: "star" }
  ].concat(categories.map(function(c) { return { id: c.id, label: c.label, unread: c.unread, icon: "folder" } }))

  // ---- Navigation ----------------------------------------------------------
  function goHome() {
    if (configured) settingsView = false
    view = "home"
    homeCursor = 0
    stream = null
    article = null
    items = []
    confirmMarkAll = false
    refresh()
  }
  function goBack() {
    if (settingsView && configured) { settingsView = false; return true }
    if (view === "article") { view = "items"; article = null; return true }
    if (view === "items") { goHome(); return true }
    return false
  }
  function openStream(id, title) {
    settingsView = false
    stream = { id: id, title: title }
    view = "items"
    items = []
    continuation = ""
    cursor = -1
    confirmMarkAll = false
    loadItems(false)
  }
  function openArticle(index) {
    if (index < 0 || index >= items.length) return
    cursor = index
    article = items[index]
    view = "article"
    if (!article.read) setRead(index, true)
  }

  // ---- Data ----------------------------------------------------------------
  // The refresh icon spins while loading, and for at least a moment.
  readonly property bool refreshing: overviewLoading || itemsLoading || spinHold.running
  Timer { id: spinHold; interval: 600 }

  function refresh() {
    if (!configured || overviewProc.running) return
    overviewLoading = true
    overviewProc.running = true
  }
  // Header button and q/R. The article view only refreshes counts, so the
  // list behind it (and the j/k position) stays put.
  function refreshCurrent() {
    spinHold.restart()
    refresh()
    if (view === "items") loadItems(false)
  }
  function loadItems(more) {
    if (!stream || itemsProc.running) return
    itemsLoading = true
    listError = ""
    var args = ["items", stream.id, unreadOnly ? "unread" : "all"]
    if (more && continuation) args.push(continuation)
    itemsProc.appending = more
    itemsProc.command = backend(args)
    itemsProc.running = true
  }
  function patchItem(index, change) {
    var copy = items.slice()
    var it = JSON.parse(JSON.stringify(copy[index]))
    for (var k in change) it[k] = change[k]
    copy[index] = it
    items = copy
    if (article && article.id === it.id) article = it
  }
  property var markQueue: []
  function runMark(action, id) {
    markQueue.push(backend(["mark", action, id]))
    drainMarks()
  }
  function drainMarks() {
    if (markProc.running || markQueue.length === 0) return
    markProc.command = markQueue.shift()
    markProc.running = true
  }
  function setRead(index, read) {
    var it = items[index]
    if (!it || it.read === read) return
    patchItem(index, { read: read })
    totalUnread = Math.max(0, totalUnread + (read ? -1 : 1))
    runMark(read ? "read" : "unread", it.id)
  }
  function toggleRead(index) { if (items[index]) setRead(index, !items[index].read) }
  function toggleStar(index) {
    var it = items[index]
    if (!it) return
    patchItem(index, { starred: !it.starred })
    runMark(it.starred ? "unstar" : "star", it.id)
  }
  function openInBrowser(index) {
    var it = items[index]
    // Web links only (the backend filters too): never hand file:// or
    // app-handler URLs from a feed to the desktop.
    if (!it || !/^https?:\/\//i.test(it.url)) return
    if (!it.read) setRead(index, true)
    Qt.openUrlExternally(it.url)
  }
  function markAllRead() {
    if (!stream) return
    markAllProc.command = backend(["mark-all-read", stream.id, String(Math.floor(Date.now() / 1000))])
    markAllProc.running = true
  }

  // ---- Keyboard: FreshRSS's default shortcuts -------------------------------
  // The popout body calls these; list scrolling happens there.
  function moveCursor(delta) {
    if (settingsView) return false
    if (view === "home") {
      homeCursor = Math.max(0, Math.min(homeEntries.length - 1, homeCursor + delta))
      return true
    }
    if (items.length === 0) return false
    cursor = Math.max(0, Math.min(items.length - 1, cursor + delta))
    if (view === "article") openArticle(cursor)
    return true
  }
  function jumpTo(first) {
    if (settingsView) return false
    if (view === "home") { homeCursor = first ? 0 : homeEntries.length - 1; return true }
    if (items.length === 0) return false
    cursor = first ? 0 : items.length - 1
    if (view === "article") openArticle(cursor)
    return true
  }
  function nextUnread() {
    for (var i = cursor + 1; i < items.length; i++) {
      if (!items[i].read) {
        cursor = i
        if (view === "article") openArticle(i)
        return true
      }
    }
    return false
  }
  function stepCategory(delta) {
    if (categories.length === 0) return
    var idx = stream ? categories.findIndex(function(c) { return c.id === stream.id }) : -1
    idx = Math.max(0, Math.min(categories.length - 1, idx + delta))
    openStream(categories[idx].id, categories[idx].label)
  }
  // Enter: open the selected category or article.
  function activateSelected() {
    if (settingsView) return
    if (view === "home") {
      var e = homeEntries[homeCursor]
      if (e) openStream(e.id, e.label)
    } else if (view === "items") {
      openArticle(cursor)
    }
  }

  readonly property var keyHelp: [
    { key: "j / k", action: "Next / previous item" },
    { key: "h", action: "Next unread item" },
    { key: "n / p", action: "Next / previous category" },
    { key: "Home / End", action: "First / last item" },
    { key: "Enter", action: "Open item or category" },
    { key: "Space", action: "Open in browser" },
    { key: "r", action: "Toggle read" },
    { key: "f", action: "Toggle star" },
    { key: "m", action: "Load more" },
    { key: "u", action: "Unread only / all" },
    { key: "q / R", action: "Refresh" },
    { key: ",", action: "Settings" },
    { key: "Esc", action: "Back, then close" },
    { key: "Right-click", action: "Toggle read on a row" }
  ]

  Component.onCompleted: checkConfigured.running = true

  // Background unread count (the bar badge) every 5 minutes.
  Timer {
    interval: 5 * 60 * 1000
    running: root.configured
    repeat: true
    onTriggered: root.refresh()
  }
  Timer { id: confirmTimer; interval: 4000; onTriggered: { root.confirmDisconnect = false; root.confirmMarkAll = false } }

  // ---- Called from the popout ----------------------------------------------
  function login(url, user, password) {
    if (setupBusy) return
    setupError = ""
    setupBusy = true
    loginUrl = url
    loginUser = user
    pendingPassword = password
    loginProc.running = true
  }

  // Disconnect and Mark all read take two clicks: the first arms the button,
  // a second within 4s acts.
  function disconnectClicked() {
    if (!confirmDisconnect) { confirmDisconnect = true; confirmTimer.restart(); return }
    confirmTimer.stop()
    disconnectProc.running = true
  }
  function markAllClicked() {
    if (!confirmMarkAll) { confirmMarkAll = true; confirmTimer.restart(); return }
    confirmTimer.stop()
    markAllRead()
  }

  // ---- Bar widgets ---------------------------------------------------------
  // Every bar shows its own copy of the widget. They register here so the IPC
  // calls open the popout on the focused screen only.
  property var views: []

  function registerView(view) {
    if (views.indexOf(view) === -1) views = views.concat([view])
  }

  function unregisterView(view) {
    views = views.filter(function(v) { return v !== view })
  }

  function togglePopout() {
    var focused = BarWidgetService.getFocusedScreenName()
    var target = views.find(function(v) { return v.parentScreen && v.parentScreen.name === focused }) || views[0]
    if (target) target.triggerPopout()
  }

  IpcHandler {
    target: "freshrssReader"
    function toggle(): void { root.togglePopout() }
    function refresh(): void { root.refreshCurrent() }
    function openUnread(): void { root.openStream(root.readingList, "All unread"); root.togglePopout() }
  }

  // ---- Processes -----------------------------------------------------------
  Process {
    id: checkConfigured
    command: root.backend(["check-configured"])
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var r = JSON.parse(text)
          root.configured = r.configured === true
          root.serverUrl = r.baseUrl || ""
          root.username = r.username || ""
        } catch (e) {}
        if (!root.configured) root.settingsView = true
        else root.refresh()
      }
    }
  }
  Process {
    id: overviewProc
    command: root.backend(["overview"])
    stdout: StdioCollector {
      onStreamFinished: {
        root.overviewLoading = false
        try {
          var r = JSON.parse(text)
          if (r.error) { root.listError = r.error; return }
          root.listError = ""
          root.totalUnread = r.totalUnread || 0
          root.categories = r.categories || []
        } catch (e) { root.listError = "Couldn't read the overview from the backend" }
      }
    }
  }
  Process {
    id: itemsProc
    property bool appending: false
    stdout: StdioCollector {
      onStreamFinished: {
        root.itemsLoading = false
        try {
          var r = JSON.parse(text)
          if (r.error) { root.listError = r.error; return }
          root.items = itemsProc.appending ? root.items.concat(r.items) : r.items
          root.continuation = r.continuation || ""
          if (!itemsProc.appending) root.cursor = root.items.length > 0 ? 0 : -1
        } catch (e) { root.listError = "Couldn't read the items from the backend" }
      }
    }
  }
  Process {
    id: markProc
    stdout: StdioCollector {
      onStreamFinished: {
        try { var r = JSON.parse(text); if (r.error) root.listError = r.error } catch (e) {}
        root.drainMarks()
      }
    }
  }
  Process {
    id: markAllProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.confirmMarkAll = false
        try { var r = JSON.parse(text); if (r.error) { root.listError = r.error; return } } catch (e) {}
        root.items = root.items.map(function(it) { var c = JSON.parse(JSON.stringify(it)); c.read = true; return c })
        root.refresh()
        if (root.unreadOnly) root.loadItems(false)
      }
    }
  }
  Process {
    id: loginProc
    // stdin stays enabled for the life of this Process (Quickshell never
    // re-enables it once closed); the backend reads one line per attempt.
    stdinEnabled: true
    command: root.backend(["login", root.loginUrl, root.loginUser])
    onStarted: { write(root.pendingPassword + "\n"); root.pendingPassword = "" }
    stdout: StdioCollector {
      onStreamFinished: {
        root.setupBusy = false
        try {
          var r = JSON.parse(text)
          if (r.ok) {
            root.serverUrl = r.baseUrl
            root.username = root.loginUser
            root.configured = true
            root.settingsView = false
            root.loginSucceeded()
            root.goHome()
          } else root.setupError = r.error || "Connection failed"
        } catch (e) { root.setupError = "Unexpected response from the backend" }
      }
    }
  }
  Process {
    id: disconnectProc
    command: root.backend(["disconnect"])
    stdout: StdioCollector {
      onStreamFinished: {
        root.configured = false
        root.serverUrl = ""
        root.categories = []
        root.items = []
        root.totalUnread = 0
        root.view = "home"
        root.confirmDisconnect = false
        root.settingsView = true
      }
    }
  }
}
