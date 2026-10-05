import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "Model.js" as Model

// DankMaterialShell bar widget for the FreshRSS plugin. DMS creates one of
// these per bar, so it holds no state of its own: the unread poll, IPC handler,
// login and article lists live once in the daemon (FreshRSSDaemon.qml), and
// this file only draws them. DMS also rebuilds popoutContent each time the
// popout opens.
PluginComponent {
  id: root

  layerNamespacePlugin: "freshrss-reader"
  popoutWidth: Math.round(Theme.fontSizeMedium * 43)

  // The plugin's single daemon instance; null for a moment while DMS spawns it.
  readonly property var core: pluginService ? (pluginService.pluginDaemonInstances[pluginId] || null) : null
  readonly property int unread: core ? core.totalUnread : 0

  // Sizes the popout uses, derived from Theme tokens.
  readonly property real listHeight: Math.round(Theme.fontSizeMedium * 51)
  readonly property real smallButtonHeight: Theme.iconSize + Theme.spacingS

  pillRightClickAction: () => { if (root.core) root.core.refreshCurrent() }

  // Register with the daemon so its IPC calls can find this bar.
  property var registeredWith: null
  function attach() {
    if (registeredWith === core) return
    if (registeredWith) registeredWith.unregisterView(root)
    registeredWith = core
    if (core) core.registerView(root)
  }
  onCoreChanged: attach()
  Component.onCompleted: attach()
  Component.onDestruction: if (registeredWith) registeredWith.unregisterView(root)

  // ---- Bar pill: RSS icon + unread count -------------------------------------
  horizontalBarPill: Component {
    Row {
      spacing: Theme.spacingXS
      opacity: root.core && root.core.configured ? 1 : 0.5
      DankIcon {
        anchors.verticalCenter: parent.verticalCenter
        name: "rss_feed"
        size: root.iconSize
        color: root.unread > 0 ? Theme.primary : Theme.widgetIconColor
      }
      StyledText {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.unread > 0
        text: String(root.unread)
        font.pixelSize: Theme.fontSizeSmall
        font.weight: Font.Bold
        color: Theme.primary
      }
    }
  }
  verticalBarPill: Component {
    Column {
      spacing: Theme.spacingXXS
      DankIcon {
        anchors.horizontalCenter: parent.horizontalCenter
        name: "rss_feed"
        size: root.iconSize
        color: root.unread > 0 ? Theme.primary : Theme.widgetIconColor
      }
      StyledText {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.unread > 0
        text: String(root.unread)
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
        readonly property bool compact: root.core.settingsView
        implicitHeight: compact ? body.implicitHeight + Theme.spacingM : root.listHeight

        // DMS's popout container takes focus when it opens and only handles
        // Esc (close). This item takes focus right after it and handles the
        // plugin's keys; anything it doesn't accept (Esc with nothing to go
        // back from) bubbles up to the container. Keys the text fields don't
        // use bubble up here too.
        focus: true
        Timer { interval: 50; running: true; onTriggered: bodyHost.forceActiveFocus() }
        // DMS's container can take focus back after the timer above (it grabs
        // focus again once the popout becomes visible), and Tab can move focus
        // onto a button. Whenever focus lands anywhere but here or a text
        // field, take it back so keys keep working.
        readonly property Item focusNow: Window.activeFocusItem
        onFocusNowChanged: if (focusNow !== bodyHost && !anyFieldFocused()) refocus.restart()
        Timer { id: refocus; interval: 30; onTriggered: if (!bodyHost.anyFieldFocused()) bodyHost.forceActiveFocus() }
        Component.onCompleted: if (root.core.configured) root.core.refresh()

        function anyFieldFocused() {
          return urlField.getActiveFocus() || userField.getActiveFocus() || passField.getActiveFocus()
        }
        function scrollToCursor() {
          if (root.core.view === "home") homeList.positionViewAtIndex(root.core.homeCursor, ListView.Contain)
          else if (root.core.view === "items" && root.core.cursor >= 0) itemList.positionViewAtIndex(root.core.cursor, ListView.Contain)
        }

        Keys.onPressed: function(event) {
          var k = event.key
          var t = event.text
          if (anyFieldFocused()) {
            if (k === Qt.Key_Escape) { bodyHost.forceActiveFocus(); event.accepted = true }
            return
          }
          event.accepted = true
          if (k === Qt.Key_Escape) event.accepted = root.core.goBack()
          else if (k === Qt.Key_Down || t === "j") { if (root.core.moveCursor(1)) scrollToCursor() }
          else if (k === Qt.Key_Up || t === "k") { if (root.core.moveCursor(-1)) scrollToCursor() }
          else if (k === Qt.Key_Home) { if (root.core.jumpTo(true)) scrollToCursor() }
          else if (k === Qt.Key_End) { if (root.core.jumpTo(false)) scrollToCursor() }
          else if (k === Qt.Key_Return || k === Qt.Key_Enter) root.core.activateSelected()
          else if (k === Qt.Key_Tab || k === Qt.Key_Backtab) {}   // swallow: don't move focus onto buttons
          else if (k === Qt.Key_Space) { if (root.core.view !== "home" && !root.core.settingsView) root.core.openInBrowser(root.core.cursor) }
          else if (t === "h") { if (root.core.nextUnread()) scrollToCursor() }
          else if (t === "n") root.core.stepCategory(1)
          else if (t === "p") root.core.stepCategory(-1)
          else if (t === "r") root.core.toggleRead(root.core.cursor)
          else if (t === "f") root.core.toggleStar(root.core.cursor)
          else if (t === "m") { if (root.core.continuation) root.core.loadItems(true) }
          else if (t === "u") { if (root.core.view === "items") { root.core.unreadOnly = !root.core.unreadOnly; root.core.loadItems(false) } }
          else if (t === "q" || t === "R") root.core.refreshCurrent()
          else if (t === ",") { if (root.core.configured) root.core.settingsView = !root.core.settingsView }
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
              visible: root.core.view !== "home" || (root.core.settingsView && root.core.configured)
              iconName: "arrow_back"
              tooltipText: "Back (Esc)"
              onClicked: root.core.goBack()
            }
            Column {
              Layout.fillWidth: true
              spacing: Theme.spacingXXS
              StyledText {
                width: parent.width
                text: root.core.settingsView ? (root.core.configured ? "Settings" : "Connect to FreshRSS")
                  : root.core.view === "home" ? "FreshRSS"
                  : root.core.view === "items" ? root.core.streamTitle
                  : (root.core.article ? root.core.article.feedTitle : "")
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Bold
                color: Theme.surfaceText
                elide: Text.ElideRight
              }
              StyledText {
                visible: root.core.view === "home" && !root.core.settingsView && root.core.configured
                text: root.core.totalUnread + " unread  ·  " + root.core.serverUrl
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
              }
            }
            DankActionButton {
              visible: root.core.configured
              iconName: "home"
              tooltipText: "Home"
              onClicked: root.core.goHome()
            }
            DankActionButton {
              id: refreshButton
              visible: root.core.configured && !root.core.settingsView
              iconName: "refresh"
              tooltipText: "Refresh (q / R)"
              onClicked: root.core.refreshCurrent()
              // The button is circular, so spinning the whole thing reads as
              // a spinning icon.
              RotationAnimation on rotation {
                running: root.core.refreshing
                from: 0; to: 360
                duration: 900
                loops: Animation.Infinite
                onRunningChanged: if (!running) refreshButton.rotation = 0
              }
            }
            DankActionButton {
              visible: root.core.configured
              iconName: "settings"
              tooltipText: "Settings (,)"
              onClicked: root.core.settingsView = !root.core.settingsView
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
            visible: root.core.settingsView
            Layout.fillWidth: true
            spacing: Theme.spacingS

            StyledText {
              Layout.fillWidth: true
              wrapMode: Text.WordWrap
              text: "Use your FreshRSS API password (Settings → Profile → API password), not your web login password. API access must be enabled in Settings → Authentication. The login token is kept in the system keyring."
              color: Theme.surfaceVariantText
              font.pixelSize: Theme.fontSizeSmall
            }
            DankTextField { id: urlField; Layout.fillWidth: true; placeholderText: "Server URL, e.g. https://rss.example.com"; text: root.core.serverUrl }
            DankTextField { id: userField; Layout.fillWidth: true; placeholderText: "Username"; text: root.core.username }
            DankTextField { id: passField; Layout.fillWidth: true; placeholderText: "API password"; echoMode: TextInput.Password; showPasswordToggle: true }
            Connections { target: root.core; function onLoginSucceeded() { passField.text = "" } }

            StyledText {
              Layout.fillWidth: true
              visible: root.core.setupError !== ""
              text: root.core.setupError
              wrapMode: Text.WordWrap
              color: Theme.error
              font.pixelSize: Theme.fontSizeSmall
            }
            DankButton {
              text: root.core.setupBusy ? "Connecting..." : "Connect"
              iconName: "login"
              onClicked: root.core.login(urlField.text.trim(), userField.text.trim(), passField.text)
            }
            DankButton {
              visible: root.core.configured
              Layout.topMargin: Theme.spacingS
              text: root.core.confirmDisconnect ? "Click again to disconnect" : "Disconnect"
              iconName: "logout"
              backgroundColor: root.core.confirmDisconnect ? Theme.error : Theme.surfaceContainerHigh
              textColor: root.core.confirmDisconnect ? Theme.primaryText : Theme.surfaceText
              onClicked: root.core.disconnectClicked()
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
                model: root.core.keyHelp
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
            visible: !root.core.settingsView && root.core.listError !== ""
            text: root.core.listError
            wrapMode: Text.WordWrap
            color: Theme.error
            font.pixelSize: Theme.fontSizeSmall
          }

          // ---- Home: streams + categories ---------------------------------------
          DankListView {
            id: homeList
            visible: !root.core.settingsView && root.core.view === "home"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: Theme.spacingXS
            model: root.core.homeEntries
            delegate: ListRow {
              width: homeList.width
              icon: modelData.icon
              primary: modelData.label
              badge: modelData.unread > 0 ? String(modelData.unread) : ""
              selected: index === root.core.homeCursor
              onActivated: root.core.openStream(modelData.id, modelData.label)
            }
          }

          // ---- Items ---------------------------------------------------------------
          RowLayout {
            visible: !root.core.settingsView && root.core.view === "items"
            Layout.fillWidth: true
            spacing: Theme.spacingS
            DankButtonGroup {
              model: ["Unread", "All"]
              currentIndex: root.core.unreadOnly ? 0 : 1
              onSelectionChanged: function(index, selected) {
                if (!selected) return
                root.core.unreadOnly = index === 0
                root.core.loadItems(false)
              }
            }
            Item { Layout.fillWidth: true }
            DankButton {
              visible: root.core.stream !== null && root.core.stream.id !== root.core.starredStream
              text: root.core.confirmMarkAll ? "Confirm" : "Mark all read"
              iconName: "done_all"
              buttonHeight: root.smallButtonHeight
              backgroundColor: root.core.confirmMarkAll ? Theme.error : Theme.surfaceContainerHigh
              textColor: root.core.confirmMarkAll ? Theme.primaryText : Theme.surfaceText
              onClicked: root.core.markAllClicked()
            }
          }

          StyledText {
            Layout.fillWidth: true
            visible: !root.core.settingsView && root.core.view === "items" && (root.core.itemsLoading || root.core.items.length === 0)
            text: root.core.itemsLoading ? "Loading..." : (root.core.unreadOnly ? "Nothing unread here." : "No items.")
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
          }

          DankListView {
            id: itemList
            visible: !root.core.settingsView && root.core.view === "items"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: Theme.spacingXS
            model: root.core.items
            onAtYEndChanged: if (atYEnd && root.core.continuation && !root.core.itemsLoading && root.core.items.length > 0) root.core.loadItems(true)
            delegate: ListRow {
              width: itemList.width
              thumbSlot: true
              thumb: modelData.thumbnail || ""
              favicon: root.core.feedIcons[modelData.feedId] || ""
              primary: modelData.title
              secondary: modelData.feedTitle + "  ·  " + Model.relativeTime(modelData.published)
              marker: !modelData.read
              starred: modelData.starred
              dim: modelData.read
              selected: index === root.core.cursor
              tooltip: modelData.read ? "Right-click or r to mark unread" : "Right-click or r to mark read"
              onActivated: root.core.openArticle(index)
              onContextActivated: root.core.toggleRead(index)
            }
          }

          // ---- Article ---------------------------------------------------------------
          ColumnLayout {
            visible: !root.core.settingsView && root.core.view === "article" && root.core.article !== null
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Theme.spacingS
            Image {
              Layout.fillWidth: true
              Layout.preferredHeight: status === Image.Ready
                ? Math.min(Theme.fontSizeMedium * 17, width * implicitHeight / Math.max(1, implicitWidth)) : 0
              visible: status === Image.Ready
              source: root.core.article ? (root.core.article.thumbnail || "") : ""
              asynchronous: true
              cache: true
              fillMode: Image.PreserveAspectCrop
              // Crop from the top, where news photos usually put faces.
              verticalAlignment: Image.AlignTop
              sourceSize.width: root.popoutWidth * 2
            }
            StyledText {
              Layout.fillWidth: true
              text: root.core.article ? root.core.article.title : ""
              wrapMode: Text.WordWrap
              font.pixelSize: Theme.fontSizeLarge
              font.weight: Font.Bold
              color: Theme.surfaceText
            }
            StyledText {
              Layout.fillWidth: true
              text: root.core.article ? (root.core.article.feedTitle + (root.core.article.author ? "  ·  " + root.core.article.author : "") + "  ·  " + Model.formatDate(root.core.article.published)) : ""
              font.pixelSize: Theme.fontSizeSmall
              color: Theme.surfaceVariantText
              elide: Text.ElideRight
            }
            RowLayout {
              spacing: Theme.spacingS
              DankButton { text: "Open in browser (Space)"; iconName: "open_in_new"; buttonHeight: root.smallButtonHeight; onClicked: root.core.openInBrowser(root.core.cursor) }
              DankButton {
                text: root.core.article && root.core.article.starred ? "Unstar (f)" : "Star (f)"
                iconName: "star"
                buttonHeight: root.smallButtonHeight
                backgroundColor: Theme.surfaceContainerHigh
                textColor: Theme.surfaceText
                onClicked: root.core.toggleStar(root.core.cursor)
              }
              DankButton {
                text: root.core.article && root.core.article.read ? "Mark unread (r)" : "Mark read (r)"
                iconName: "mark_email_read"
                buttonHeight: root.smallButtonHeight
                backgroundColor: Theme.surfaceContainerHigh
                textColor: Theme.surfaceText
                onClicked: root.core.toggleRead(root.core.cursor)
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
                text: root.core.article ? (root.core.article.summary || "No summary. Press Space to open the article.") : ""
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

    readonly property real thumbSize: Theme.iconSizeLarge + Theme.spacingL + Theme.spacingXS
    implicitHeight: Math.max(Theme.iconSize + Theme.spacingL + Theme.spacingXS, textCol.implicitHeight + Theme.spacingS * 2,
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
      width: Theme.spacingXXS
      radius: width / 2
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
      width: Theme.spacingS
      height: Theme.spacingS
      radius: width / 2
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
      spacing: Theme.spacingXXS
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
