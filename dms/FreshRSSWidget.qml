import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "Model.js" as Model

// DankMaterialShell version of the FreshRSS plugin. The shell-independent
// parts (Model.js and the Python backend) are shared with the Omarchy plugin
// at the repo root (tools/sync-dms.sh).
//
// DMS rebuilds popoutContent every time the popout opens, so all state lives
// here on the PluginComponent root and the popout only renders it.
PluginComponent {
  id: root

  layerNamespacePlugin: "freshrss-reader"
  popoutWidth: 600

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
    if (!it || !it.url) return
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
    { key: "q / R", action: "Refresh" },
    { key: ",", action: "Settings" },
    { key: "Esc", action: "Back, then close" },
    { key: "Right-click", action: "Toggle read on a row" }
  ]

  pillRightClickAction: () => root.refreshCurrent()

  Component.onCompleted: checkConfigured.running = true

  // Background unread count (the bar badge) every 5 minutes.
  Timer {
    interval: 5 * 60 * 1000
    running: root.configured
    repeat: true
    onTriggered: root.refresh()
  }
  Timer { id: confirmTimer; interval: 4000; onTriggered: { root.confirmDisconnect = false; root.confirmMarkAll = false } }

  IpcHandler {
    target: "freshrssReader"
    function toggle(): void { root.triggerPopout() }
    function refresh(): void { root.refreshCurrent() }
    function openUnread(): void { root.openStream(root.readingList, "All unread"); root.triggerPopout() }
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

  // ---- Bar pill: RSS icon + unread count -------------------------------------
  horizontalBarPill: Component {
    Row {
      spacing: 4
      opacity: root.configured ? 1 : 0.5
      DankIcon {
        anchors.verticalCenter: parent.verticalCenter
        name: "rss_feed"
        size: root.iconSize
        color: root.totalUnread > 0 ? Theme.primary : Theme.widgetIconColor
      }
      StyledText {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.totalUnread > 0
        text: String(root.totalUnread)
        font.pixelSize: Theme.fontSizeSmall
        font.weight: Font.Bold
        color: Theme.primary
      }
    }
  }
  verticalBarPill: Component {
    Column {
      spacing: 2
      DankIcon {
        anchors.horizontalCenter: parent.horizontalCenter
        name: "rss_feed"
        size: root.iconSize
        color: root.totalUnread > 0 ? Theme.primary : Theme.widgetIconColor
      }
      StyledText {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.totalUnread > 0
        text: String(root.totalUnread)
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.primary
      }
    }
  }

  // ---- Popout ----------------------------------------------------------------
  popoutContent: Component {
    PopoutComponent {
      id: pop

      Item {
        id: bodyHost
        width: parent.width
        // Settings sizes to its content; the lists get a fixed height.
        readonly property bool compact: root.settingsView
        implicitHeight: compact ? body.implicitHeight + Theme.spacingM : 720

        // DMS's popout container takes focus when it opens and only handles
        // Esc (close). This item takes focus right after it and handles the
        // plugin's keys; anything it doesn't accept (Esc with nothing to go
        // back from) bubbles up to the container. Keys the text fields don't
        // use bubble up here too.
        focus: true
        Timer { interval: 50; running: true; onTriggered: bodyHost.forceActiveFocus() }
        Component.onCompleted: if (root.configured) root.refresh()

        function anyFieldFocused() {
          return urlField.getActiveFocus() || userField.getActiveFocus() || passField.getActiveFocus()
        }
        function scrollToCursor() {
          if (root.view === "home") homeList.positionViewAtIndex(root.homeCursor, ListView.Contain)
          else if (root.view === "items" && root.cursor >= 0) itemList.positionViewAtIndex(root.cursor, ListView.Contain)
        }

        Keys.onPressed: function(event) {
          var k = event.key
          var t = event.text
          if (anyFieldFocused()) {
            if (k === Qt.Key_Escape) { bodyHost.forceActiveFocus(); event.accepted = true }
            return
          }
          event.accepted = true
          if (k === Qt.Key_Escape) event.accepted = root.goBack()
          else if (k === Qt.Key_Down || t === "j") { if (root.moveCursor(1)) scrollToCursor() }
          else if (k === Qt.Key_Up || t === "k") { if (root.moveCursor(-1)) scrollToCursor() }
          else if (k === Qt.Key_Home) { if (root.jumpTo(true)) scrollToCursor() }
          else if (k === Qt.Key_End) { if (root.jumpTo(false)) scrollToCursor() }
          else if (k === Qt.Key_Return || k === Qt.Key_Enter) root.activateSelected()
          else if (k === Qt.Key_Space) { if (root.view !== "home" && !root.settingsView) root.openInBrowser(root.cursor) }
          else if (t === "h") { if (root.nextUnread()) scrollToCursor() }
          else if (t === "n") root.stepCategory(1)
          else if (t === "p") root.stepCategory(-1)
          else if (t === "r") root.toggleRead(root.cursor)
          else if (t === "f") root.toggleStar(root.cursor)
          else if (t === "m") { if (root.continuation) root.loadItems(true) }
          else if (t === "q" || t === "R") root.refreshCurrent()
          else if (t === ",") { if (root.configured) root.settingsView = !root.settingsView }
          else if (t === "a") searchHint.visible = true
          else event.accepted = false
        }

        ColumnLayout {
          id: body
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: bodyHost.compact ? implicitHeight : bodyHost.height
          spacing: Theme.spacingM

          // ---- Header ------------------------------------------------------
          RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingS

            DankActionButton {
              visible: root.view !== "home" || (root.settingsView && root.configured)
              iconName: "arrow_back"
              tooltipText: "Back (Esc)"
              onClicked: root.goBack()
            }
            Column {
              Layout.fillWidth: true
              spacing: 2
              StyledText {
                width: parent.width
                text: root.settingsView ? (root.configured ? "Settings" : "Connect to FreshRSS")
                  : root.view === "home" ? "FreshRSS"
                  : root.view === "items" ? (root.stream ? root.stream.title : "")
                  : (root.article ? root.article.feedTitle : "")
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Bold
                color: Theme.surfaceText
                elide: Text.ElideRight
              }
              StyledText {
                visible: root.view === "home" && !root.settingsView && root.configured
                text: root.totalUnread + " unread  ·  " + root.serverUrl
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
              }
            }
            DankActionButton {
              visible: root.configured
              iconName: "home"
              tooltipText: "Home"
              onClicked: root.goHome()
            }
            DankActionButton {
              id: refreshButton
              visible: root.configured && !root.settingsView
              iconName: "refresh"
              tooltipText: "Refresh (q / R)"
              onClicked: root.refreshCurrent()
              // The button is circular, so spinning the whole thing reads as
              // a spinning icon.
              RotationAnimation on rotation {
                running: root.refreshing
                from: 0; to: 360
                duration: 900
                loops: Animation.Infinite
                onRunningChanged: if (!running) refreshButton.rotation = 0
              }
            }
            DankActionButton {
              visible: root.configured
              iconName: "settings"
              tooltipText: "Settings (,)"
              onClicked: root.settingsView = !root.settingsView
            }
            DankActionButton {
              iconName: "close"
              tooltipText: "Close (Esc)"
              onClicked: pop.closePopout && pop.closePopout()
            }
          }

          StyledText {
            id: searchHint
            visible: false
            Layout.fillWidth: true
            text: "Search is coming in a later version."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            Timer { running: searchHint.visible; interval: 2500; onTriggered: searchHint.visible = false }
          }

          // ---- Connection form -----------------------------------------------
          ColumnLayout {
            visible: root.settingsView
            Layout.fillWidth: true
            spacing: Theme.spacingS

            StyledText {
              Layout.fillWidth: true
              wrapMode: Text.WordWrap
              text: "Use your FreshRSS API password (Settings → Profile → API password), not your web login password. API access must be enabled in Settings → Authentication. The login token is kept in the system keyring."
              color: Theme.surfaceVariantText
              font.pixelSize: Theme.fontSizeSmall
            }
            DankTextField { id: urlField; Layout.fillWidth: true; placeholderText: "Server URL, e.g. https://rss.example.com"; text: root.serverUrl }
            DankTextField { id: userField; Layout.fillWidth: true; placeholderText: "Username"; text: root.username }
            DankTextField { id: passField; Layout.fillWidth: true; placeholderText: "API password"; echoMode: TextInput.Password; showPasswordToggle: true }
            Connections { target: root; function onLoginSucceeded() { passField.text = "" } }

            StyledText {
              Layout.fillWidth: true
              visible: root.setupError !== ""
              text: root.setupError
              wrapMode: Text.WordWrap
              color: Theme.error
              font.pixelSize: Theme.fontSizeSmall
            }
            DankButton {
              text: root.setupBusy ? "Connecting..." : "Connect"
              iconName: "login"
              onClicked: {
                if (root.setupBusy) return
                root.setupError = ""
                root.setupBusy = true
                root.loginUrl = urlField.text.trim()
                root.loginUser = userField.text.trim()
                root.pendingPassword = passField.text
                loginProc.running = true
              }
            }
            DankButton {
              visible: root.configured
              Layout.topMargin: Theme.spacingS
              text: root.confirmDisconnect ? "Click again to disconnect" : "Disconnect"
              iconName: "logout"
              backgroundColor: root.confirmDisconnect ? Theme.error : Theme.surfaceContainerHigh
              textColor: root.confirmDisconnect ? Theme.primaryText : Theme.surfaceText
              onClicked: {
                if (!root.confirmDisconnect) { root.confirmDisconnect = true; confirmTimer.restart(); return }
                confirmTimer.stop()
                disconnectProc.running = true
              }
            }

            // Keyboard reference: FreshRSS's own default shortcuts.
            StyledText {
              Layout.fillWidth: true
              Layout.topMargin: Theme.spacingM
              text: "Keyboard"
              font.pixelSize: Theme.fontSizeMedium
              font.weight: Font.Bold
              color: Theme.surfaceText
            }
            StyledText {
              Layout.fillWidth: true
              wrapMode: Text.WordWrap
              text: "Same shortcuts as the FreshRSS web interface (its defaults)."
              font.pixelSize: Theme.fontSizeSmall
              color: Theme.surfaceVariantText
            }
            TextMetrics { id: keyChipProbe; text: "Right-click"; font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Bold }
            GridLayout {
              Layout.fillWidth: true
              columns: 4
              columnSpacing: Theme.spacingM
              rowSpacing: Theme.spacingXS
              Repeater {
                model: root.keyHelp
                delegate: Item {
                  required property var modelData
                  // Each entry spans two cells: a key chip, then its action.
                  Layout.columnSpan: 2
                  Layout.fillWidth: true
                  implicitHeight: Math.max(keyChip.height, actionText.implicitHeight)
                  Rectangle {
                    id: keyChip
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: keyChipProbe.advanceWidth + Theme.spacingM * 2
                    height: keyText.implicitHeight + Theme.spacingXS * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh
                    StyledText {
                      id: keyText
                      anchors.centerIn: parent
                      text: modelData.key
                      font.pixelSize: Theme.fontSizeSmall
                      font.weight: Font.Bold
                      color: Theme.primary
                    }
                  }
                  StyledText {
                    id: actionText
                    anchors.left: keyChip.right
                    anchors.leftMargin: Theme.spacingS
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.action
                    elide: Text.ElideRight
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                  }
                }
              }
            }
          }

          StyledText {
            Layout.fillWidth: true
            visible: !root.settingsView && root.listError !== ""
            text: root.listError
            wrapMode: Text.WordWrap
            color: Theme.error
            font.pixelSize: Theme.fontSizeSmall
          }

          // ---- Home: streams + categories ---------------------------------------
          DankListView {
            id: homeList
            visible: !root.settingsView && root.view === "home"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: Theme.spacingXS
            model: root.homeEntries
            delegate: ListRow {
              width: homeList.width
              icon: modelData.icon
              primary: modelData.label
              badge: modelData.unread > 0 ? String(modelData.unread) : ""
              selected: index === root.homeCursor
              onActivated: root.openStream(modelData.id, modelData.label)
            }
          }

          // ---- Items ---------------------------------------------------------------
          RowLayout {
            visible: !root.settingsView && root.view === "items"
            Layout.fillWidth: true
            spacing: Theme.spacingS
            DankButtonGroup {
              model: ["Unread", "All"]
              currentIndex: root.unreadOnly ? 0 : 1
              onSelectionChanged: function(index, selected) {
                if (!selected) return
                root.unreadOnly = index === 0
                root.loadItems(false)
              }
            }
            Item { Layout.fillWidth: true }
            DankButton {
              visible: root.stream !== null && root.stream.id !== root.starredStream
              text: root.confirmMarkAll ? "Click again to mark all read" : "Mark all read"
              iconName: "done_all"
              buttonHeight: 32
              backgroundColor: root.confirmMarkAll ? Theme.error : Theme.surfaceContainerHigh
              textColor: root.confirmMarkAll ? Theme.primaryText : Theme.surfaceText
              onClicked: {
                if (!root.confirmMarkAll) { root.confirmMarkAll = true; confirmTimer.restart(); return }
                confirmTimer.stop()
                root.markAllRead()
              }
            }
          }

          StyledText {
            Layout.fillWidth: true
            visible: !root.settingsView && root.view === "items" && (root.itemsLoading || root.items.length === 0)
            text: root.itemsLoading ? "Loading..." : (root.unreadOnly ? "Nothing unread here." : "No items.")
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
          }

          DankListView {
            id: itemList
            visible: !root.settingsView && root.view === "items"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: Theme.spacingXS
            model: root.items
            onAtYEndChanged: if (atYEnd && root.continuation && !root.itemsLoading && root.items.length > 0) root.loadItems(true)
            delegate: ListRow {
              width: itemList.width
              thumbSlot: true
              thumb: modelData.thumbnail || ""
              favicon: root.feedIcons[modelData.feedId] || ""
              primary: modelData.title
              secondary: modelData.feedTitle + "  ·  " + Model.relativeTime(modelData.published)
              marker: !modelData.read
              starred: modelData.starred
              dim: modelData.read
              selected: index === root.cursor
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
            spacing: Theme.spacingS
            Image {
              Layout.fillWidth: true
              Layout.preferredHeight: status === Image.Ready
                ? Math.min(240, width * implicitHeight / Math.max(1, implicitWidth)) : 0
              visible: status === Image.Ready
              source: root.article ? (root.article.thumbnail || "") : ""
              asynchronous: true
              cache: true
              fillMode: Image.PreserveAspectCrop
              sourceSize.width: 1200
            }
            StyledText {
              Layout.fillWidth: true
              text: root.article ? root.article.title : ""
              wrapMode: Text.WordWrap
              font.pixelSize: Theme.fontSizeLarge
              font.weight: Font.Bold
              color: Theme.surfaceText
            }
            StyledText {
              Layout.fillWidth: true
              text: root.article ? (root.article.feedTitle + (root.article.author ? "  ·  " + root.article.author : "") + "  ·  " + Model.formatDate(root.article.published)) : ""
              font.pixelSize: Theme.fontSizeSmall
              color: Theme.surfaceVariantText
              elide: Text.ElideRight
            }
            RowLayout {
              spacing: Theme.spacingS
              DankButton { text: "Open in browser (Space)"; iconName: "open_in_new"; buttonHeight: 32; onClicked: root.openInBrowser(root.cursor) }
              DankButton {
                text: root.article && root.article.starred ? "Unstar (f)" : "Star (f)"
                iconName: "star"
                buttonHeight: 32
                backgroundColor: Theme.surfaceContainerHigh
                textColor: Theme.surfaceText
                onClicked: root.toggleStar(root.cursor)
              }
              DankButton {
                text: root.article && root.article.read ? "Mark unread (r)" : "Mark read (r)"
                iconName: "mark_email_read"
                buttonHeight: 32
                backgroundColor: Theme.surfaceContainerHigh
                textColor: Theme.surfaceText
                onClicked: root.toggleRead(root.cursor)
              }
            }
            Flickable {
              id: articleView
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              contentWidth: width
              contentHeight: articleText.implicitHeight
              boundsBehavior: Flickable.StopAtBounds
              StyledText {
                id: articleText
                width: articleView.width
                text: root.article ? (root.article.summary || "No summary. Press Space to open the article.") : ""
                wrapMode: Text.WordWrap
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceText
                lineHeight: 1.25
              }
            }
          }
        }
      }
    }
  }

  // ---- One row style: home entries and articles -------------------------------
  component ListRow: Item {
    id: row
    property string icon: ""
    property string primary: ""
    property string secondary: ""
    property string badge: ""
    property string tooltip: ""
    property bool selected: false
    property bool marker: false
    property bool starred: false
    property bool dim: false
    // Article rows reserve a thumbnail slot even without an image so titles
    // align; the feed's favicon fills it when there's no thumbnail.
    property bool thumbSlot: false
    property string thumb: ""
    property string favicon: ""
    signal activated()
    signal contextActivated()

    readonly property int thumbSize: 52
    implicitHeight: Math.max(44, textCol.implicitHeight + Theme.spacingS * 2,
                             row.thumbSlot ? row.thumbSize + Theme.spacingXS * 2 : 0)

    StyledRect {
      anchors.fill: parent
      radius: Theme.cornerRadius
      color: (mouse.containsMouse || row.selected) ? Theme.surfaceHover : "transparent"
    }
    // Keyboard selection: a thin primary-colored bar on the left edge.
    Rectangle {
      visible: row.selected
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.topMargin: Theme.spacingXS
      anchors.bottomMargin: Theme.spacingXS
      width: 3
      radius: 1.5
      color: Theme.primary
    }

    DankIcon {
      id: glyph
      visible: row.icon !== ""
      anchors.left: parent.left
      anchors.leftMargin: Theme.spacingM
      anchors.verticalCenter: parent.verticalCenter
      name: row.icon
      size: Theme.iconSize - 2
      color: Theme.surfaceText
    }
    Rectangle {
      id: markerDot
      visible: row.thumbSlot
      anchors.left: parent.left
      anchors.leftMargin: Theme.spacingM
      anchors.verticalCenter: parent.verticalCenter
      width: 7
      height: 7
      radius: 3.5
      color: row.marker ? Theme.primary : "transparent"
    }
    Rectangle {
      id: thumbBox
      visible: row.thumbSlot
      anchors.left: markerDot.right
      anchors.leftMargin: Theme.spacingS
      anchors.verticalCenter: parent.verticalCenter
      width: visible ? row.thumbSize : 0
      height: row.thumbSize
      radius: Theme.cornerRadius
      color: Theme.surfaceContainerHigh
      clip: true
      opacity: row.dim && !row.selected ? 0.55 : 1
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
      }
      Image {
        anchors.centerIn: parent
        width: parent.width * 0.42
        height: width
        visible: thumbImage.status !== Image.Ready && status === Image.Ready
        source: thumbImage.status === Image.Ready ? "" : row.favicon
        asynchronous: true
        cache: true
        fillMode: Image.PreserveAspectFit
        sourceSize.width: width * 2
        sourceSize.height: height * 2
      }
    }

    DankIcon {
      id: starMark
      visible: row.starred
      anchors.right: badgePill.visible ? badgePill.left : parent.right
      anchors.rightMargin: Theme.spacingM
      anchors.verticalCenter: parent.verticalCenter
      name: "star"
      size: Theme.iconSize - 4
      color: Theme.primary
    }
    Rectangle {
      id: badgePill
      visible: row.badge !== ""
      anchors.right: parent.right
      anchors.rightMargin: Theme.spacingM
      anchors.verticalCenter: parent.verticalCenter
      width: badgeText.implicitWidth + Theme.spacingM * 2
      height: badgeText.implicitHeight + Theme.spacingXS * 2
      radius: height / 2
      color: Theme.primarySelected
      StyledText {
        id: badgeText
        anchors.centerIn: parent
        text: row.badge
        font.pixelSize: Theme.fontSizeSmall
        font.weight: Font.Bold
        color: Theme.primary
      }
    }

    Column {
      id: textCol
      opacity: row.dim && !row.selected ? 0.55 : 1
      anchors.left: thumbBox.visible ? thumbBox.right : (glyph.visible ? glyph.right : parent.left)
      anchors.leftMargin: Theme.spacingM
      anchors.right: starMark.visible ? starMark.left : (badgePill.visible ? badgePill.left : parent.right)
      anchors.rightMargin: Theme.spacingM
      anchors.verticalCenter: parent.verticalCenter
      spacing: 2
      StyledText {
        width: parent.width
        text: row.primary
        font.pixelSize: Theme.fontSizeMedium
        font.weight: row.marker ? Font.Bold : Font.Normal
        color: Theme.surfaceText
        elide: Text.ElideRight
      }
      StyledText {
        width: parent.width
        visible: row.secondary !== ""
        text: row.secondary
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        elide: Text.ElideRight
      }
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: function(m) {
        if (m.button === Qt.RightButton) row.contextActivated()
        else row.activated()
      }
    }

    DankTooltipV2 {
      id: tip
    }
    Timer {
      interval: 600
      running: mouse.containsMouse && row.tooltip !== ""
      onTriggered: tip.show(row.tooltip, row, 0, 0, "top")
    }
    Connections {
      target: mouse
      function onContainsMouseChanged() { if (!mouse.containsMouse) tip.hide() }
    }
  }
}
