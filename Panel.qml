import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Omadocker: the bar button and the panel behind it.
//
// This file is the Process plumbing and the bindings. Everything that can be
// decided without running a command — parsing, grouping, sorting, the text on
// a row — lives in Model.js, which is the half tests/ covers. See
// ARCHITECTURE.md.
Panel {
  id: root

  moduleName: "kayooliveira.omadocker"
  ipcTarget: "kayooliveira.omadocker"
  // manageIpc: false so this file can own the single IpcHandler the target
  // permits, and add refresh() to the open/close/toggle the base provides.
  manageIpc: false

  // ---------------------------------------------------------------- settings

  readonly property int refreshIntervalSec: Math.max(5, Number(setting("refreshIntervalSec", 15)))
  readonly property bool showStopped: setting("showStopped", true) === true
  readonly property bool showStats: setting("showStats", true) === true
  readonly property bool hideWhenEmpty: setting("hideWhenEmpty", false) === true

  // ------------------------------------------------------------------- state

  property var containers: []
  // Short id -> { cpu, cpuPercent, mem, memPercent }. Held apart from
  // `containers` so a stats poll repaints meters without rebuilding rows.
  property var stats: ({})
  property string signature: ""
  property bool daemonReachable: true
  property bool permissionDenied: false
  property bool loading: false
  property bool everLoaded: false
  property string filterText: ""

  // Short id of the container an action is in flight for, or "" — the row it
  // names disables its buttons until Docker answers, so a double click cannot
  // queue a stop behind a start.
  property string pendingId: ""

  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var visibleContainers: Model.filterContainers(containers, filterText)
  readonly property var sections: Model.sectionsFor(visibleContainers)
  readonly property var rows: Model.rowsFor(sections)
  readonly property var counts: Model.counts(containers)
  readonly property var cursorContainer: Model.containerAtCursor(rows, cursorIndex)
  readonly property bool filterable: containers.length > 6

  // ----------------------------------------------------------------- polling

  function refresh() {
    if (listProcess.running) return
    loading = true
    listProcess.running = true
  }

  function refreshStats() {
    if (!showStats || statsProcess.running || !opened) return
    if (counts.running === 0) return
    statsProcess.running = true
  }

  // The bar polls on the user's interval whether or not the panel is open,
  // because the glyph is the whole point of the widget when it is closed. The
  // panel polls faster while it is open, since that is when someone is
  // watching a container come up.
  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 3000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  // `docker stats --no-stream` samples every running container over a full
  // second before it prints, so it is an order of magnitude more expensive
  // than `docker ps` and gets a slower timer of its own rather than riding
  // along with the list.
  Timer {
    interval: 5000
    running: root.opened && root.showStats
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshStats()
  }

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      cursorIndex = 0
      filterText = ""
      refresh()
    } else {
      stats = ({})
    }
  }

  // ----------------------------------------------------------------- actions

  function runAction(ids, verb) {
    if (!ids || ids.length === 0 || actionProcess.running) return
    root.pendingId = ids.length === 1 ? ids[0] : ""
    actionProcess.command = ["docker", verb].concat(ids)
    actionProcess.running = true
  }

  function toggleContainer(container) {
    if (!container) return
    runAction([container.id], container.up ? "stop" : "start")
  }

  function restartContainer(container) {
    if (container && container.up) runAction([container.id], "restart")
  }

  function toggleSection(section) {
    var action = Model.sectionAction(section)
    if (action) runAction(action.ids, action.verb)
  }

  function stopEverything() {
    var ids = []
    for (var i = 0; i < containers.length; i++) {
      if (containers[i].up) ids.push(containers[i].id)
    }
    runAction(ids, "stop")
  }

  // Arguments, not `sh -c`: a container name is user-supplied text and the
  // only safe way to hand it to a process is as its own argv entry.
  function copyText(value) {
    if (!value || copyProcess.running) return
    copyProcess.command = ["wl-copy", "--trim-newline", String(value)]
    copyProcess.running = true
  }

  function viewLogs(container) {
    if (!container) return
    root.close()
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=org.omarchy.docker-logs", "--hold", "--",
      "docker", "logs", "--tail", "200", "--follow", container.id])
  }

  function launchTui() {
    root.close()
    Quickshell.execDetached(["omarchy-launch-or-focus-tui", "lazydocker"])
  }

  // ---------------------------------------------------------------- keyboard

  function moveCursor(delta) {
    if (rows.length === 0) return
    cursorActive = true
    cursorIndex = Model.clampCursor(cursorIndex + delta, rows.length)
  }

  function setCursor(index) {
    cursorActive = true
    cursorIndex = Model.clampCursor(index, rows.length)
  }

  function handleTextKey(key) {
    if (key === "/" && filterable) { filterField.forceActiveFocus(); return }
    if (key === "u") { refresh(); refreshStats(); return }
    if (key === "d") { launchTui(); return }
    if (!cursorActive || !cursorContainer) return
    if (key === "o") viewLogs(cursorContainer)
    else if (key === "r") restartContainer(cursorContainer)
    else if (key === "c") copyText(cursorContainer.id)
    else if (key === "n") copyText(cursorContainer.name)
  }

  // --------------------------------------------------------------- processes

  // `{{json .}}` rather than a hand-built format string: Docker does its own
  // escaping, so an image or label containing a quote stays valid JSON instead
  // of silently truncating the list at that container.
  Process {
    id: listProcess
    command: root.showStopped
      ? ["sh", "-c", "docker ps --all --format '{{json .}}' | head -c 1M"]
      : ["sh", "-c", "docker ps --format '{{json .}}' | head -c 1M"]
    stdout: StdioCollector { id: listOut; waitForEnd: true }
    stderr: StdioCollector { id: listErr; waitForEnd: true }

    onExited: function(code) {
      root.loading = false
      root.everLoaded = true

      if (code !== 0) {
        var message = String(listErr.text || "")
        root.daemonReachable = false
        // Two different failures with two different fixes, and telling them
        // apart is the difference between a useful empty state and a shrug.
        // Omarchy leaves accounts out of the root-equivalent docker group by
        // default, so "permission denied" is the common case on a fresh
        // install and has a one-command remedy.
        root.permissionDenied = /permission denied|dial unix|connect: permission/i.test(message)
        root.containers = []
        root.signature = ""
        root.stats = ({})
        return
      }

      root.daemonReachable = true
      root.permissionDenied = false

      var parsed = Model.normalizeContainers(Model.parseJsonLines(listOut.text))
      var next = Model.signatureOf(parsed)
      // Only swap the array when something the list is laid out from actually
      // changed. See Model.signatureOf.
      if (next !== root.signature) {
        root.signature = next
        root.containers = parsed
        root.cursorIndex = Model.clampCursor(root.cursorIndex, root.rows.length)
      }

      root.refreshStats()
    }
  }

  Process {
    id: statsProcess
    command: ["sh", "-c", "docker stats --no-stream --format '{{json .}}' | head -c 1M"]
    stdout: StdioCollector { id: statsOut; waitForEnd: true }

    onExited: function(code) {
      if (code === 0) root.stats = Model.indexStats(Model.parseJsonLines(statsOut.text))
    }
  }

  Process {
    id: actionProcess
    onExited: {
      root.pendingId = ""
      root.refresh()
    }
  }

  Process { id: copyProcess }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function stopAll(): void { root.stopEverything() }
  }

  // -------------------------------------------------------------- bar button

  // The bar sizes each widget slot from the entry point's implicit size, and
  // Panel is a bare Item, so without this the button is laid out into a 0x0
  // slot and never paints.
  implicitWidth: button.visible ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  // Urgent is reserved for the one thing worth interrupting a glance: a
  // container that died badly or whose own healthcheck says it is unwell.
  // A merely idle Docker dims instead, the way Bluetooth dims when it is off.
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.Glyph.docker
    visible: !root.hideWhenEmpty || root.counts.total > 0
    dimmed: root.counts.running === 0
    active: root.counts.alerting > 0 || root.counts.running > 0
    useActiveColor: true
    activeColor: root.counts.alerting > 0 ? Color.urgent : Color.accent
    tooltipText: "OmaDocker · " + Model.summaryText(root.containers, root.daemonReachable)

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  // ------------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The filter field owns the keyboard while it has focus; without this,
      // typing "docker" into it would move the cursor six rows down instead.
      blocked: filterField.activeFocus

      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.toggleContainer(root.cursorContainer)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) { root.handleTextKey(text) }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.spacing.panelGap

        // ---------- hero ----------

        PanelHero {
          title: "OmaDocker"
          meta: Model.summaryText(root.containers, root.daemonReachable)
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.counts.running > 0 ? 1.0 : 0.5

          iconComponent: Text {
            text: Model.Glyph.docker
            color: root.counts.alerting > 0 ? Color.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }

          trailingControl: Row {
            spacing: Style.spacing.sm

            PanelActionButton {
              iconText: Model.Glyph.refresh
              tooltipText: "Refresh  (u)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: { root.refresh(); root.refreshStats() }

              // Only while a refresh is genuinely outstanding: a spinner that
              // never stops reads as a hang rather than as work.
              RotationAnimation on rotation {
                running: root.loading
                from: 0
                to: 360
                duration: 900
                loops: Animation.Infinite
                onRunningChanged: if (!running) rotation = 0
              }
            }

            PanelActionButton {
              visible: root.counts.running > 0
              iconText: Model.Glyph.stop
              tooltipText: "Stop every running container"
              foreground: root.foreground
              hoverColor: Color.urgent
              fontFamily: root.fontFamily
              onClicked: root.stopEverything()
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ---------- filter ----------

        // Only once the list is long enough that scanning it stops working.
        // A filter above four rows is furniture.
        TextField {
          id: filterField
          visible: root.filterable
          height: visible ? implicitHeight : 0
          width: parent.width
          foreground: root.foreground
          placeholderText: Model.Glyph.search + "  Filter containers"
          text: root.filterText
          onTextChanged: {
            root.filterText = text
            root.cursorIndex = 0
          }
          Keys.onEscapePressed: {
            if (text.length > 0) text = ""
            else keyCatcher.forceActiveFocus()
          }
          Keys.onDownPressed: {
            keyCatcher.forceActiveFocus()
            root.moveCursor(0)
          }
        }

        // ---------- list ----------

        ListView {
          id: listView
          visible: root.rows.length > 0
          width: parent.width
          height: visible ? Math.min(contentHeight, Style.space(560)) : 0
          spacing: Style.spacing.sm
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.rows
          // Row index and cursor index are the same number — see Model.rowsFor.
          currentIndex: root.cursorIndex

          // Deferred a turn: the model is replaced whenever the container list
          // changes shape, and positioning against a view that is still
          // rebuilding is a no-op that leaves the cursor off screen.
          onCurrentIndexChanged: if (currentIndex >= 0) Qt.callLater(keepCurrentVisible)
          function keepCurrentVisible() {
            if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
          }

          delegate: Column {
            id: rowGroup
            required property var modelData
            required property int index

            width: ListView.view.width
            spacing: Style.spacing.sm

            SectionHeader {
              visible: rowGroup.modelData.sectionTitle !== ""
              height: visible ? implicitHeight : 0
              width: parent.width
              section: rowGroup.modelData.section
              first: rowGroup.modelData.firstSection
            }

            ContainerRow {
              width: parent.width
              container: rowGroup.modelData.container
              rowIndex: rowGroup.index
            }
          }
        }

        // ---------- empty states ----------

        // Each of these is a different problem with a different fix, so each
        // says which one it is rather than sharing one "nothing here" line.
        Column {
          visible: root.rows.length === 0
          width: parent.width
          spacing: Style.spacing.sm
          topPadding: Style.spacing.lg
          bottomPadding: Style.spacing.lg

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: {
              if (!root.everLoaded) return "Loading containers…"
              if (root.permissionDenied) return "No access to the Docker socket"
              if (!root.daemonReachable) return "Docker daemon unreachable"
              if (root.containers.length > 0) return "No container matches that filter"
              return root.showStopped ? "No containers" : "No running containers"
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Text {
            visible: text !== ""
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: {
              if (root.permissionDenied) return "Omarchy keeps accounts out of the root-equivalent docker group.\nRun  omarchy setup security sudoless-docker  and reboot."
              if (!root.daemonReachable && root.everLoaded) return "Start it with  sudo systemctl start docker"
              return ""
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            lineHeight: 1.3
          }
        }
      }
    }
  }

  // ------------------------------------------------------------- row visuals

  // Compose project header. Doubles as the project's own start/stop control,
  // because a project is the unit people actually bring up and take down.
  component SectionHeader: Item {
    id: header

    required property var section
    property bool first: false

    readonly property bool anyRunning: !!section && section.runningCount > 0

    implicitHeight: headerLabel.implicitHeight + (first ? 0 : Style.spacing.xxl)

    PanelSeparator {
      visible: !header.first
      anchors.top: parent.top
      anchors.topMargin: Style.spacing.lg
      foreground: root.foreground
    }

    PanelSectionHeader {
      id: headerLabel
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      text: header.section ? header.section.title.toUpperCase() : ""
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Row {
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.md
      anchors.bottom: parent.bottom
      spacing: Style.spacing.sm

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: header.section ? header.section.runningCount + "/" + header.section.total : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      PanelActionButton {
        enabled: !actionProcess.running
        iconText: header.anyRunning ? Model.Glyph.stop : Model.Glyph.play
        tooltipText: (header.anyRunning ? "Stop " : "Start ") + (header.section ? header.section.title : "")
        foreground: root.foreground
        hoverColor: header.anyRunning ? Color.urgent : root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.iconSmall
        size: Style.space(20)
        onClicked: root.toggleSection(header.section)
      }
    }
  }

  component ContainerRow: CursorSurface {
    id: rowSurface

    required property var container
    required property int rowIndex

    readonly property var containerStats: container ? root.stats[container.id] : null
    readonly property bool busy: !!container && root.pendingId === container.id

    hasCursor: root.cursorActive && rowIndex === root.cursorIndex
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.xxl
    height: implicitHeight

    // Contract of CursorSurface: hover updates the panel's cursor, and the
    // paint follows the cursor. That is what keeps exactly one row
    // highlighted whether the user is on the mouse or the keyboard.
    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse && rowSurface.container) root.setCursor(rowSurface.rowIndex)
      onClicked: root.copyText(rowSurface.container.id)
    }

    PanelToolTip {
      visible: rowMouse.containsMouse
      text: "Copy container id  (c)"
      fontFamily: root.fontFamily
    }

    Column {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.xl
      anchors.rightMargin: Style.spacing.xl
      spacing: Style.spacing.xs

      Item {
        width: parent.width
        implicitHeight: Math.max(identity.implicitHeight, rowActions.implicitHeight)

        Rectangle {
          id: stateDot
          width: Style.space(7)
          height: width
          radius: width / 2
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          color: {
            if (!rowSurface.container) return "transparent"
            if (rowSurface.container.failing) return Color.urgent
            return rowSurface.container.up ? Color.accent : "transparent"
          }
          border.width: rowSurface.container && !rowSurface.container.up && !rowSurface.container.failing ? 1 : 0
          border.color: root.dim

          // Restarting is the one state worth animating: it is the only one
          // that resolves on its own, and a still dot cannot say so.
          SequentialAnimation on opacity {
            running: !!rowSurface.container && rowSurface.container.state === "restarting"
            loops: Animation.Infinite
            NumberAnimation { to: 0.25; duration: 600; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutQuad }
            onRunningChanged: if (!running) rowSurface.opacity = 1
          }
        }

        Column {
          id: identity
          anchors.left: stateDot.right
          anchors.leftMargin: Style.spacing.xl
          anchors.right: rowActions.left
          anchors.rightMargin: Style.spacing.lg
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.xxs

          Row {
            width: parent.width
            spacing: Style.spacing.md

            Text {
              text: rowSurface.container ? rowSurface.container.name : ""
              textFormat: Text.PlainText
              width: Math.min(implicitWidth, parent.width - (healthGlyph.visible ? healthGlyph.implicitWidth + Style.spacing.md : 0))
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              id: healthGlyph
              visible: !!rowSurface.container && rowSurface.container.health === "unhealthy"
              anchors.verticalCenter: parent.verticalCenter
              text: Model.Glyph.unhealthy
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.iconSmall
            }
          }

          Text {
            width: parent.width
            text: Model.subtitleText(rowSurface.container)
            textFormat: Text.PlainText
            visible: text !== ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            visible: !!rowSurface.container && !rowSurface.container.up
            text: Model.statusText(rowSurface.container)
            textFormat: Text.PlainText
            color: rowSurface.container && rowSurface.container.failing ? Color.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Row {
          id: rowActions
          anchors.right: parent.right
          anchors.rightMargin: Style.spacing.md
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.xxs

          PanelActionButton {
            iconText: Model.Glyph.logs
            tooltipText: "Follow logs in a terminal  (o)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.iconSmall
            size: Style.space(22)
            onClicked: root.viewLogs(rowSurface.container)
          }

          PanelActionButton {
            visible: !!rowSurface.container && rowSurface.container.up
            enabled: !rowSurface.busy && !actionProcess.running
            iconText: Model.Glyph.restart
            tooltipText: "Restart  (r)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.iconSmall
            size: Style.space(22)
            onClicked: root.restartContainer(rowSurface.container)
          }

          PanelActionButton {
            enabled: !rowSurface.busy && !actionProcess.running
            iconText: rowSurface.container && rowSurface.container.up ? Model.Glyph.stop : Model.Glyph.play
            tooltipText: rowSurface.container && rowSurface.container.up ? "Stop  (enter)" : "Start  (enter)"
            foreground: root.foreground
            hoverColor: rowSurface.container && rowSurface.container.up ? Color.urgent : root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.iconSmall
            size: Style.space(22)
            onClicked: root.toggleContainer(rowSurface.container)
          }
        }
      }

      // Meters sit under the identity block rather than beside it so they
      // keep a fixed width regardless of how long the container's name is,
      // which is what lets two rows' bars be compared by eye.
      Row {
        visible: root.showStats && !!rowSurface.container && rowSurface.container.up
        width: parent.width
        spacing: Style.spacing.xxl
        leftPadding: stateDot.width + Style.spacing.xl
        topPadding: Style.spacing.xs

        Meter {
          width: (rowContent.width - stateDot.width - Style.spacing.xl - Style.spacing.xxl) / 2
          caption: "CPU"
          percent: rowSurface.containerStats ? rowSurface.containerStats.cpuPercent : -1
          value: rowSurface.containerStats ? rowSurface.containerStats.cpu : ""
        }

        Meter {
          width: (rowContent.width - stateDot.width - Style.spacing.xl - Style.spacing.xxl) / 2
          caption: "MEM"
          percent: rowSurface.containerStats ? rowSurface.containerStats.memPercent : -1
          value: rowSurface.containerStats ? rowSurface.containerStats.mem : ""
        }
      }
    }
  }

  // Glyph, a hairline track, and the reading. `percent < 0` means the stats
  // poll has not answered yet, and the track stays empty rather than drawing a
  // confident zero.
  component Meter: Item {
    id: meter

    property string caption: ""
    property real percent: -1
    property string value: ""

    readonly property bool known: percent >= 0
    readonly property real fraction: Math.max(0, Math.min(1, percent / 100))

    implicitHeight: Math.max(meterCaption.implicitHeight, meterValue.implicitHeight)
    height: implicitHeight

    Text {
      id: meterCaption
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: meter.caption
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Rectangle {
      id: track
      anchors.left: meterCaption.right
      anchors.leftMargin: Style.spacing.md
      anchors.right: meterValue.left
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      height: Style.space(3)
      radius: height / 2
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

      Rectangle {
        width: meter.known ? parent.width * meter.fraction : 0
        height: parent.height
        radius: parent.radius
        // Urgent only once the reading is genuinely alarming. Colouring a
        // busy-but-fine container red trains people to ignore the colour.
        color: meter.percent >= 85 ? Color.urgent : Color.accent

        Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
      }
    }

    Text {
      id: meterValue
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: meter.value || "—"
      textFormat: Text.PlainText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
