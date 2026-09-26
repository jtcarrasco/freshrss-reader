import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar entry point: an RSS glyph plus the unread count, hosting the dropdown in
// Panel.qml (same host/panel split as the Todoist and Audiobookshelf plugins).
// Panel owns all FreshRSS state; this file only reads the unread count back.
BarWidget {
  id: root
  moduleName: "freshrss-reader"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  readonly property int unread: panelLoader.item ? panelLoader.item.totalUnread : 0
  readonly property bool configured: panelLoader.item ? panelLoader.item.configured === true : false

  readonly property string tooltipText: !configured ? "FreshRSS: not connected"
    : unread > 0 ? "FreshRSS: " + unread + " unread" : "FreshRSS: all caught up"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "freshrss-reader"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { if (panelLoader.item) panelLoader.item.refresh() }
    function popOut(): void { if (panelLoader.item) panelLoader.item.setExpanded(true) }
    // Jump straight to the unread list (handy as a keybind target).
    function openSettings(): void { if (panelLoader.item) { root.open(); panelLoader.item.settingsView = true } }
    function openUnread(): void { if (panelLoader.item) { root.open(); panelLoader.item.openStream(panelLoader.item.readingList, "All unread") } }
  }

  TextMetrics {
    id: countMetrics
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.bar.iconFont
    text: "999"
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.tooltipText
    labelVisible: false
    hasVisualContent: true
    // Unread count uses the bar's highlight color, like other widgets' active state.
    active: root.unread > 0
    dimmed: !root.configured
    fixedWidth: root.vertical ? -1
      : Math.ceil(Style.space(12) + (root.unread > 0 ? Style.space(4) + countMetrics.width : 0) + Style.spaceReal(horizontalMargin) * 2)
    fixedHeight: root.vertical ? Math.ceil(row.implicitHeight + Style.spaceReal(verticalPadding) * 2) : -1

    Row {
      id: row
      anchors.centerIn: parent
      spacing: Style.space(4)
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "󰑫"
        color: root.bar ? root.bar.barForeground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.bar.iconFont
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.unread > 0
        text: root.unread > 999 ? "999+" : String(root.unread)
        color: root.bar ? root.bar.urgent : Color.urgent
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.bar.iconFont
      }
    }

    onPressed: function(b) {
      if (b === Qt.MiddleButton) { if (panelLoader.item) panelLoader.item.refresh() }
      else root.togglePanel()
    }
  }
}
