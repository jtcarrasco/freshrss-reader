import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The FreshRSS dropdown: categories on home, then a category's items, then an
// article. Built from the shell's qs.Ui kit and qs.Commons Color/Style so it
// follows the user's theme, like the built-in panels. Keyboard shortcuts match
// FreshRSS's defaults (j/k, h, n/p, r, f, space, q, a, m, Esc).
Panel {
  id: root
  moduleName: "freshrss-reader"
  ipcTarget: "freshrss-reader"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")
  function backend(args) { return ["python3", root.pluginDir + "/scripts/freshrss_backend.py"].concat(args) }

  property int panelWidth: 600
  property int panelHeight: 800
  property bool expanded: false

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color mutedFg: Qt.darker(fg, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- State --------------------------------------------------------------
  property bool configured: false
  property string serverUrl: ""
  property string username: ""
  property bool settingsView: false
  property int totalUnread: 0
  property var categories: []
  // feedId -> favicon URL, the fallback for items without a thumbnail.
  readonly property var feedIcons: {
    var map = {}
    for (var i = 0; i < root.categories.length; i++) {
      var feeds = root.categories[i].feeds || []
      for (var j = 0; j < feeds.length; j++) if (feeds[j].iconUrl) map[feeds[j].id] = feeds[j].iconUrl
    }
    return map
  }
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

  // One width for every key chip so the action column lines up.
  readonly property real keyChipWidth: keyChipProbe.advanceWidth + Style.spacing.md * 2
  TextMetrics { id: keyChipProbe; text: "Right-click"; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
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
    { key: "q / R", action: "Refresh" },
    { key: "z", action: "Window / dropdown" },
    { key: ",", action: "Settings" },
    { key: "Esc", action: "Back, then close" },
    { key: "Right-click", action: "Toggle read on a row" }
  ]

  readonly property string readingList: "user/-/state/com.google/reading-list"
  readonly property string starredStream: "user/-/state/com.google/starred"

  // ---- Lifecycle ----------------------------------------------------------
  function setExpanded(on) {
    if (on) {
      root.controller.hide()
      root.expanded = true
      popWindow.visible = true
      keyCatcher.forceActiveFocus()
    } else {
      root.expanded = false
      popWindow.visible = false
      root.controller.show()
    }
  }
  function open() {
    if (root.expanded) { popWindow.visible = true; return }
    root.controller.show()
    if (root.configured) root.refresh()
  }
  function close() { root.controller.hide() }
  function toggle() {
    if (root.expanded) { root.expanded = false; popWindow.visible = false; return }
    root.opened ? root.close() : root.open()
  }

  // ---- Navigation -----------------------------------------------------------
  function goHome() {
    if (root.configured) root.settingsView = false
    root.view = "home"
    root.homeCursor = 0
    root.stream = null
    root.article = null
    root.items = []
    root.confirmMarkAll = false
    root.refresh()
  }
  function goBack() {
    if (root.settingsView && root.configured) { root.settingsView = false; return true }
    if (root.view === "article") { root.view = "items"; root.article = null; return true }
    if (root.view === "items") { root.goHome(); return true }
    return false
  }
  function openStream(id, title) {
    root.settingsView = false
    root.stream = { id: id, title: title }
    root.view = "items"
    root.items = []
    root.continuation = ""
    root.cursor = -1
    root.confirmMarkAll = false
    root.loadItems(false)
  }
  function openArticle(index) {
    if (index < 0 || index >= root.items.length) return
    root.cursor = index
    root.article = root.items[index]
    root.view = "article"
    if (!root.article.read) root.setRead(index, true)
  }

  // ---- Data -----------------------------------------------------------------
  // Header button and q/R. The article view only refreshes counts, so the
  // list behind it (and the j/k position) stays put.
  function refreshCurrent() {
    spinHold.restart()
    root.refresh()
    if (root.view === "items") root.loadItems(false)
  }
  readonly property bool refreshing: overviewLoading || itemsLoading || spinHold.running
  function refresh() {
    if (!root.configured || overviewProc.running) return
    root.overviewLoading = true
    overviewProc.running = true
  }
  function loadItems(more) {
    if (!root.stream || itemsProc.running) return
    root.itemsLoading = true
    root.listError = ""
    var args = ["items", root.stream.id, root.unreadOnly ? "unread" : "all"]
    if (more && root.continuation) args.push(root.continuation)
    itemsProc.appending = more
    itemsProc.command = root.backend(args)
    itemsProc.running = true
  }
  function patchItem(index, change) {
    var copy = root.items.slice()
    var it = JSON.parse(JSON.stringify(copy[index]))
    for (var k in change) it[k] = change[k]
    copy[index] = it
    root.items = copy
    if (root.article && root.article.id === it.id) root.article = it
  }
  function runMark(action, id) {
    markQueue.push(root.backend(["mark", action, id]))
    root.drainMarks()
  }
  property var markQueue: []
  function drainMarks() {
    if (markProc.running || root.markQueue.length === 0) return
    markProc.command = root.markQueue.shift()
    markProc.running = true
  }
  function setRead(index, read) {
    var it = root.items[index]
    if (!it || it.read === read) return
    root.patchItem(index, { read: read })
    root.totalUnread = Math.max(0, root.totalUnread + (read ? -1 : 1))
    root.runMark(read ? "read" : "unread", it.id)
  }
  function toggleRead(index) { if (root.items[index]) root.setRead(index, !root.items[index].read) }
  function toggleStar(index) {
    var it = root.items[index]
    if (!it) return
    root.patchItem(index, { starred: !it.starred })
    root.runMark(it.starred ? "unstar" : "star", it.id)
  }
  function openInBrowser(index) {
    var it = root.items[index]
    if (!it || !it.url) return
    if (!it.read) root.setRead(index, true)
    Qt.openUrlExternally(it.url)
  }
  function markAllRead() {
    if (!root.stream) return
    markAllProc.command = root.backend(["mark-all-read", root.stream.id, String(Math.floor(Date.now() / 1000))])
    markAllProc.running = true
  }

  // ---- Keyboard: FreshRSS defaults --------------------------------------------
  readonly property var homeEntries: [
    { id: root.readingList, label: "All unread", unread: root.totalUnread, glyph: "󰑫" },
    { id: root.starredStream, label: "Starred", unread: -1, glyph: "󰓎" }
  ].concat(root.categories.map(function(c) { return { id: c.id, label: c.label, unread: c.unread, glyph: "󰉋" } }))

  function moveCursor(delta) {
    if (root.settingsView) return
    if (root.view === "home") {
      root.homeCursor = Math.max(0, Math.min(root.homeEntries.length - 1, root.homeCursor + delta))
      homeList.positionViewAtIndex(root.homeCursor, ListView.Contain)
      return
    }
    if (root.items.length === 0) return
    root.cursor = Math.max(0, Math.min(root.items.length - 1, root.cursor + delta))
    if (root.view === "article") root.openArticle(root.cursor)
    else itemList.positionViewAtIndex(root.cursor, ListView.Contain)
  }
  function jumpTo(first) {
    if (root.settingsView) return
    if (root.view === "home") { root.homeCursor = first ? 0 : root.homeEntries.length - 1; homeList.positionViewAtIndex(root.homeCursor, ListView.Contain); return }
    if (root.items.length === 0) return
    root.cursor = first ? 0 : root.items.length - 1
    if (root.view === "article") root.openArticle(root.cursor)
    else itemList.positionViewAtIndex(root.cursor, ListView.Contain)
  }
  function nextUnread() {
    for (var i = root.cursor + 1; i < root.items.length; i++) {
      if (!root.items[i].read) { root.cursor = i; if (root.view === "article") root.openArticle(i); else itemList.positionViewAtIndex(i, ListView.Contain); return }
    }
  }
  function stepCategory(delta) {
    if (root.categories.length === 0) return
    var idx = root.stream ? root.categories.findIndex(function(c) { return c.id === root.stream.id }) : -1
    idx = Math.max(0, Math.min(root.categories.length - 1, idx + delta))
    root.openStream(root.categories[idx].id, root.categories[idx].label)
  }
  // Home/End aren't handled by PanelKeyCatcher, so they bubble up to the slot.
  function slotKey(event) {
    if (event.key === Qt.Key_Home) { root.jumpTo(true); event.accepted = true }
    else if (event.key === Qt.Key_End) { root.jumpTo(false); event.accepted = true }
  }
  function handleKey(t) {
    // q is FreshRSS's refresh key; R is the vim-style alias (newsboat, ranger).
    if (t === "q" || t === "R") { root.refreshCurrent(); return }
    // , opens settings (the usual settings shortcut); again to go back.
    if (t === ",") { if (root.configured) root.settingsView = !root.settingsView; return }
    // z: "zoom" between the dropdown and its own window (tmux's zoom key).
    if (t === "z") { root.setExpanded(!root.expanded); return }
    if (t === "a" || t === "A") { searchHint.visible = true; return }
    if (t === "n") { root.stepCategory(1); return }
    if (t === "p") { root.stepCategory(-1); return }
    if (t === "r") { root.toggleRead(root.cursor); return }
    if (t === "f") { root.toggleStar(root.cursor); return }
    if (t === "m") { if (root.continuation) root.loadItems(true); return }
    if (t === " ") { root.openInBrowser(root.cursor); return }
  }

  Component.onCompleted: checkConfigured.running = true

  // Background unread count (the bar badge) every 5 minutes.
  Timer {
    interval: 5 * 60 * 1000
    running: root.configured
    repeat: true
    onTriggered: root.refresh()
  }
  // Keeps the spinner up briefly so a fast refresh still registers.
  Timer { id: spinHold; interval: 600 }
  Timer { id: confirmTimer; interval: 4000; onTriggered: { root.confirmDisconnect = false; root.confirmMarkAll = false } }

  // ---- Processes ------------------------------------------------------------
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
    property string url: ""
    property string user: ""
    stdinEnabled: true
    command: root.backend(["login", url, user])
    onStarted: { write(root.pendingPassword + "\n"); root.pendingPassword = "" }
    stdout: StdioCollector {
      onStreamFinished: {
        root.setupBusy = false
        try {
          var r = JSON.parse(text)
          if (r.ok) {
            passField.text = ""
            root.serverUrl = r.baseUrl
            root.username = loginProc.user
            root.configured = true
            root.settingsView = false
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

  // ---- Chrome ---------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.panelWidth)
    contentHeight: panel.fittedContentHeight(root.panelHeight)
    padding: Style.space(20)
    Item { id: dropdownSlot; anchors.fill: parent; Keys.onPressed: function(e) { root.slotKey(e) } }
  }

  FloatingWindow {
    id: popWindow
    visible: false
    title: "FreshRSS"
    color: Color.popups.background
    implicitWidth: Style.space(820)
    implicitHeight: Style.space(900)
    minimumSize: Qt.size(Style.space(420), Style.space(480))
    onVisibleChanged: if (!visible && root.expanded) root.expanded = false
    Item { id: windowSlot; anchors.fill: parent; anchors.margins: Style.space(20); Keys.onPressed: function(e) { root.slotKey(e) } }
  }

  PanelKeyCatcher {
    id: keyCatcher
    parent: root.expanded ? windowSlot : dropdownSlot
    anchors.fill: parent
    blocked: urlField.activeFocus || userField.activeFocus || passField.activeFocus
    onCloseRequested: { if (!root.goBack()) { if (root.expanded) root.setExpanded(false); else root.close() } }
    // The catcher maps h to "move left"; in FreshRSS h is "next unread".
    onMoveRequested: function(dx, dy) {
      if (dy !== 0) root.moveCursor(dy)
      else if (dx < 0) root.nextUnread()
    }
    // Enter emits return + activate; Space emits only activate. Enter opens the
    // row, Space opens the website (FreshRSS "go_website").
    property bool suppressActivate: false
    onReturnRequested: {
      suppressActivate = true
      if (root.settingsView) return
      if (root.view === "home") { var e = root.homeEntries[root.homeCursor]; if (e) root.openStream(e.id, e.label) }
      else if (root.view === "items") root.openArticle(root.cursor)
    }
    onActivateRequested: {
      if (suppressActivate) { suppressActivate = false; return }
      if (root.view !== "home" && !root.settingsView) root.openInBrowser(root.cursor)
    }
    onTextKey: function(t) { root.handleKey(t) }

    ColumnLayout {
      id: mainColumn
      anchors.fill: parent
      spacing: Style.space(12)

      // ---- Header ------------------------------------------------------------
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.md

        PanelActionButton {
          visible: root.view !== "home" || (root.settingsView && root.configured)
          iconText: "󰁍"; tooltipText: "Back (Esc)"; foreground: root.fg
          onClicked: root.goBack()
        }
        Column {
          Layout.fillWidth: true
          spacing: Style.spacing.xxs
          Text {
            width: parent.width
            text: root.settingsView ? (root.configured ? "Settings" : "Connect to FreshRSS")
              : root.view === "home" ? "FreshRSS"
              : root.view === "items" ? (root.stream ? root.stream.title : "")
              : (root.article ? root.article.feedTitle : "")
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
            elide: Text.ElideRight
          }
          Text {
            visible: root.view === "home" && !root.settingsView && root.configured
            text: root.totalUnread + " unread  ·  " + root.serverUrl
            color: root.mutedFg
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
        PanelActionButton { visible: root.configured; iconText: "󰋜"; tooltipText: "Home"; foreground: root.fg; onClicked: root.goHome() }
        PanelActionButton {
          visible: root.configured && !root.settingsView
          // The glyph moves to the spinning copy below while a refresh runs.
          iconText: root.refreshing ? "" : "󰑐"
          tooltipText: "Refresh (q / R)"
          foreground: root.fg
          onClicked: root.refreshCurrent()
          Text {
            anchors.centerIn: parent
            visible: root.refreshing
            text: "󰑐"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.icon
            RotationAnimation on rotation {
              running: root.refreshing
              from: 0; to: 360
              duration: 900
              loops: Animation.Infinite
            }
          }
        }
        PanelActionButton { iconText: root.expanded ? "󰊔" : "󰊓"; tooltipText: root.expanded ? "Back to the dropdown (z)" : "Open in its own window (z)"; foreground: root.fg; onClicked: root.setExpanded(!root.expanded) }
        PanelActionButton { visible: root.configured; iconText: "󰒓"; tooltipText: "Settings (,)"; foreground: root.fg; onClicked: root.settingsView = !root.settingsView }
      }

      Text {
        id: searchHint
        visible: false
        Layout.fillWidth: true
        text: "Search is coming in a later version."
        color: root.mutedFg
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Timer { running: searchHint.visible; interval: 2500; onTriggered: searchHint.visible = false }
      }

      // ---- Connection form -----------------------------------------------------
      ColumnLayout {
        visible: root.settingsView
        Layout.fillWidth: true
        spacing: Style.spacing.lg
        Text {
          Layout.fillWidth: true
          wrapMode: Text.WordWrap
          text: "Use your FreshRSS API password (Settings → Profile → API password), not your web login password. API access must be enabled in Settings → Authentication. The login token is kept in the system keyring."
          color: root.mutedFg
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        PanelSectionHeader { text: "SERVER"; foreground: root.fg; fontFamily: root.fontFamily }
        TextField { id: urlField; Layout.fillWidth: true; placeholderText: "https://rss.example.com"; text: root.serverUrl; foreground: root.fg; font.family: root.fontFamily }
        PanelSectionHeader { text: "ACCOUNT"; foreground: root.fg; fontFamily: root.fontFamily }
        TextField { id: userField; Layout.fillWidth: true; placeholderText: "Username"; text: root.username; foreground: root.fg; font.family: root.fontFamily }
        TextField { id: passField; Layout.fillWidth: true; placeholderText: "API password"; password: true; foreground: root.fg; font.family: root.fontFamily }
        Text {
          Layout.fillWidth: true
          visible: root.setupError !== ""
          text: root.setupError
          wrapMode: Text.WordWrap
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Button {
          text: root.setupBusy ? "Connecting..." : "Connect"
          bordered: true
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: {
            if (root.setupBusy) return
            root.setupError = ""
            root.setupBusy = true
            root.pendingPassword = passField.text
            loginProc.url = urlField.text.trim()
            loginProc.user = userField.text.trim()
            loginProc.running = true
          }
        }
        PanelSeparator { visible: root.configured; Layout.fillWidth: true; foreground: root.fg }
        Button {
          visible: root.configured
          text: root.confirmDisconnect ? "Click again to disconnect" : "Disconnect"
          bordered: true
          foreground: root.confirmDisconnect ? Color.urgent : root.fg
          fontFamily: root.fontFamily
          onClicked: {
            if (!root.confirmDisconnect) { root.confirmDisconnect = true; confirmTimer.restart(); return }
            confirmTimer.stop()
            disconnectProc.running = true
          }
        }

        // Keyboard reference: the same keys as FreshRSS's defaults.
        PanelSeparator { Layout.fillWidth: true; foreground: root.fg }
        PanelSectionHeader { text: "KEYBOARD"; foreground: root.fg; fontFamily: root.fontFamily }
        Text {
          Layout.fillWidth: true
          wrapMode: Text.WordWrap
          text: "Same shortcuts as the FreshRSS web interface (its defaults)."
          color: root.mutedFg
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        GridLayout {
          Layout.fillWidth: true
          columns: 4
          columnSpacing: Style.spacing.lg
          rowSpacing: Style.spacing.sm
          Repeater {
            model: root.keyHelp
            delegate: Item {
              required property var modelData
              required property int index
              // Each entry fills two grid cells: a key chip, then its action.
              Layout.columnSpan: 2
              Layout.fillWidth: true
              implicitHeight: Math.max(keyChip.height, actionText.implicitHeight)
              Rectangle {
                id: keyChip
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: root.keyChipWidth
                height: keyText.implicitHeight + Style.spacing.xs * 2
                radius: Style.cornerRadius
                color: "transparent"
                border.width: 1
                border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.25)
                Text {
                  id: keyText
                  anchors.centerIn: parent
                  text: modelData.key
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }
              Text {
                id: actionText
                anchors.left: keyChip.right
                anchors.leftMargin: Style.spacing.md
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.action
                elide: Text.ElideRight
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }
      }

      Text {
        Layout.fillWidth: true
        visible: !root.settingsView && root.listError !== ""
        text: root.listError
        wrapMode: Text.WordWrap
        color: Color.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      // ---- Home: streams + categories -----------------------------------------
      ListView {
        id: homeList
        visible: !root.settingsView && root.view === "home"
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        spacing: Style.spacing.xs
        boundsBehavior: Flickable.StopAtBounds
        model: root.homeEntries
        delegate: ListRow {
          width: homeList.width
          glyph: modelData.glyph
          primary: modelData.label
          badge: modelData.unread > 0 ? String(modelData.unread) : ""
          current: index === root.homeCursor
          onActivated: root.openStream(modelData.id, modelData.label)
        }
      }

      // ---- Items -----------------------------------------------------------------
      RowLayout {
        visible: !root.settingsView && root.view === "items"
        Layout.fillWidth: true
        spacing: Style.spacing.lg
        ButtonGroup {
          options: [{ value: "unread", label: "Unread" }, { value: "all", label: "All" }]
          value: root.unreadOnly ? "unread" : "all"
          foreground: root.fg
          fontFamily: root.fontFamily
          focusable: false
          onChanged: function(v) { root.unreadOnly = (v === "unread"); root.loadItems(false) }
        }
        Item { Layout.fillWidth: true }
        Button {
          visible: root.stream !== null && root.stream.id !== root.starredStream
          text: root.confirmMarkAll ? "Click again to mark all read" : "Mark all read"
          bordered: true
          foreground: root.confirmMarkAll ? Color.urgent : root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          onClicked: {
            if (!root.confirmMarkAll) { root.confirmMarkAll = true; confirmTimer.restart(); return }
            confirmTimer.stop()
            root.markAllRead()
          }
        }
      }

      Text {
        Layout.fillWidth: true
        visible: !root.settingsView && root.view === "items" && (root.itemsLoading || root.items.length === 0)
        text: root.itemsLoading ? "Loading..." : (root.unreadOnly ? "Nothing unread here." : "No items.")
        color: root.mutedFg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      ListView {
        id: itemList
        visible: !root.settingsView && root.view === "items"
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        spacing: Style.spacing.xs
        boundsBehavior: Flickable.StopAtBounds
        model: root.items
        onAtYEndChanged: if (atYEnd && root.continuation && !root.itemsLoading && root.items.length > 0) root.loadItems(true)
        delegate: ListRow {
          width: itemList.width
          primary: modelData.title
          secondary: modelData.feedTitle + "  ·  " + Model.relativeTime(modelData.published)
          marker: !modelData.read
          starred: modelData.starred
          dim: modelData.read
          current: index === root.cursor
          thumbSlot: true
          thumb: modelData.thumbnail || ""
          icon: root.feedIcons[modelData.feedId] || ""
          tooltip: modelData.read ? "Right-click or r to mark unread" : "Right-click or r to mark read"
          onActivated: root.openArticle(index)
          onContextActivated: root.toggleRead(index)
        }
      }

      // ---- Article ---------------------------------------------------------------
      ColumnLayout {
        visible: !root.settingsView && root.view === "article" && root.article !== null
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: Style.spacing.lg
        Image {
          id: heroImage
          Layout.fillWidth: true
          Layout.preferredHeight: status === Image.Ready
            ? Math.min(Style.space(260), width * implicitHeight / Math.max(1, implicitWidth)) : 0
          visible: status === Image.Ready
          source: root.article ? (root.article.thumbnail || "") : ""
          asynchronous: true
          cache: true
          fillMode: Image.PreserveAspectCrop
          sourceSize.width: Style.space(1200)
        }
        Text {
          Layout.fillWidth: true
          text: root.article ? root.article.title : ""
          wrapMode: Text.WordWrap
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }
        Text {
          Layout.fillWidth: true
          text: root.article ? (root.article.feedTitle + (root.article.author ? "  ·  " + root.article.author : "") + "  ·  " + Model.formatDate(root.article.published)) : ""
          color: root.mutedFg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
        RowLayout {
          spacing: Style.spacing.lg
          Button { text: "Open in browser (Space)"; bordered: true; foreground: root.fg; fontFamily: root.fontFamily; fontSize: Style.font.bodySmall; onClicked: root.openInBrowser(root.cursor) }
          Button { text: root.article && root.article.starred ? "Unstar (f)" : "Star (f)"; bordered: true; foreground: root.fg; fontFamily: root.fontFamily; fontSize: Style.font.bodySmall; onClicked: root.toggleStar(root.cursor) }
          Button { text: root.article && root.article.read ? "Mark unread (r)" : "Mark read (r)"; bordered: true; foreground: root.fg; fontFamily: root.fontFamily; fontSize: Style.font.bodySmall; onClicked: root.toggleRead(root.cursor) }
        }
        PanelSeparator { Layout.fillWidth: true; foreground: root.fg }
        Flickable {
          id: articleView
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          contentWidth: width
          contentHeight: articleText.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          Text {
            id: articleText
            width: articleView.width
            text: root.article ? (root.article.summary || "No summary. Press space to open the article.") : ""
            wrapMode: Text.WordWrap
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            lineHeight: 1.25
          }
        }
      }

      Item { Layout.fillHeight: true; visible: root.settingsView }
    }
  }

  // One row style: hover/selected fills from the theme, unread dot, star,
  // count badge.
  component ListRow: Item {
    id: row
    property string glyph: ""
    property string primary: ""
    property string secondary: ""
    property string badge: ""
    property string tooltip: ""
    property bool current: false
    property bool marker: false
    property bool starred: false
    property bool dim: false
    // Item rows reserve a thumbnail slot even without an image so titles align.
    property bool thumbSlot: false
    property string thumb: ""
    property string icon: ""
    readonly property int thumbSize: Style.space(52)
    signal activated()
    signal contextActivated()

    implicitHeight: Math.max(Style.spacing.popupRowHeight,
                             textColumn.implicitHeight + Style.spacing.md * 2,
                             row.thumbSlot ? row.thumbSize + Style.spacing.sm * 2 : 0)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: row.current ? Style.selectedFillFor(root.fg, Color.accent)
        : (mouse.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent")
    }
    Text {
      id: glyphText
      visible: row.glyph !== ""
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      width: visible ? Style.font.icon + Style.spacing.sm : 0
      text: row.glyph
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }
    Rectangle {
      id: markerDot
      anchors.left: glyphText.visible ? glyphText.right : parent.left
      anchors.leftMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      width: glyphText.visible ? 0 : Style.space(7)
      height: Style.space(7)
      radius: height / 2
      color: row.marker ? Color.accent : "transparent"
    }
    Rectangle {
      id: thumbBox
      visible: row.thumbSlot
      anchors.left: markerDot.right
      anchors.leftMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      width: visible ? row.thumbSize : 0
      height: row.thumbSize
      radius: Style.cornerRadius
      clip: true
      // Muted tile behind the image; it's all that shows when there's no image.
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
      Image {
        id: thumbImage
        anchors.fill: parent
        source: row.thumb
        visible: status === Image.Ready
        asynchronous: true
        cache: true
        fillMode: Image.PreserveAspectCrop
        sourceSize.width: row.thumbSize * 2
        sourceSize.height: row.thumbSize * 2
        opacity: row.dim && !row.current ? 0.55 : 1
      }
      // No thumbnail (or it failed to load): the feed's favicon, centered.
      Image {
        anchors.centerIn: parent
        width: parent.width * 0.42
        height: width
        visible: thumbImage.status !== Image.Ready && status === Image.Ready
        source: thumbImage.status === Image.Ready ? "" : row.icon
        asynchronous: true
        cache: true
        fillMode: Image.PreserveAspectFit
        sourceSize.width: width * 2
        sourceSize.height: height * 2
        opacity: row.dim && !row.current ? 0.4 : 0.8
      }
    }
    Text {
      id: starMark
      visible: row.starred
      anchors.right: badgePill.visible ? badgePill.left : parent.right
      anchors.rightMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      text: "󰓎"
      color: Color.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }
    Rectangle {
      id: badgePill
      visible: row.badge !== ""
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      width: badgeText.implicitWidth + Style.spacing.lg * 2
      height: badgeText.implicitHeight + Style.spacing.xs * 2
      radius: height / 2
      color: Style.selectedFillFor(root.fg, Color.accent)
      border.width: 1
      border.color: Color.accent
      Text {
        id: badgeText
        anchors.centerIn: parent
        text: row.badge
        color: Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
    Column {
      id: textColumn
      opacity: row.dim && !row.current ? 0.55 : 1
      anchors.left: thumbBox.visible ? thumbBox.right : markerDot.right
      anchors.leftMargin: Style.spacing.lg
      anchors.right: starMark.visible ? starMark.left : (badgePill.visible ? badgePill.left : parent.right)
      anchors.rightMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xxs
      Text {
        width: parent.width
        text: row.primary
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: row.marker
        elide: Text.ElideRight
      }
      Text {
        width: parent.width
        visible: row.secondary !== ""
        text: row.secondary
        color: root.mutedFg
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: function(m) { if (m.button === Qt.RightButton) row.contextActivated(); else row.activated() }
    }
    PanelToolTip {
      visible: mouse.containsMouse && row.tooltip !== ""
      text: row.tooltip
      fontFamily: root.fontFamily
    }
  }
}
