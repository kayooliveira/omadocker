import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root

  moduleName: "kayooliveira.omadocker"
  ipcTarget: "kayooliveira.omadocker"
  manageIpc: false

  readonly property int refreshIntervalSec: Math.max(5, Number(setting("refreshIntervalSec", 15)))
  readonly property bool showStopped: setting("showStopped", true) === true
  readonly property bool showStats: setting("showStats", true) === true
  readonly property bool hideWhenEmpty: setting("hideWhenEmpty", false) === true

  property var containers: []
  property var stats: ({})
  property bool daemonReachable: true
  property bool permissionDenied: false
  property bool loading: false
  property bool everLoaded: false
  property string filterText: ""

  property string pendingId: ""

  property int cursorIndex: 0
  property bool cursorActive: false
  property bool cursorFromKeyboard: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var visibleContainers: Model.filterContainers(containers, filterText)
  readonly property var sections: Model.sectionsFor(visibleContainers)
  readonly property var rows: Model.rowsFor(sections)
  readonly property var counts: Model.counts(containers)
  readonly property var cursorContainer: Model.containerAtCursor(containers, rows, cursorIndex)
  readonly property bool filterable: containers.length > 6

  ListModel { id: rowModel }

  function syncRows() {
    var next = root.rows
    var keys = []
    for (var i = 0; i < rowModel.count; i++) keys.push(rowModel.get(i).key)

    var ops = Model.reconcilePlan(keys, next)
    for (var o = 0; o < ops.length; o++) {
      var op = ops[o]
      if (op.op === "remove") rowModel.remove(op.index)
      else if (op.op === "move") rowModel.move(op.from, op.to, 1)
      else rowModel.insert(op.index, op.row)
    }

    for (var n = 0; n < next.length; n++) {
      var current = rowModel.get(n)
      for (var f = 0; f < Model.ROW_FIELDS.length; f++) {
        var field = Model.ROW_FIELDS[f]
        if (current[field] !== next[n][field]) rowModel.setProperty(n, field, next[n][field])
      }
    }

    root.cursorIndex = Model.clampCursor(root.cursorIndex, rowModel.count)
  }

  onRowsChanged: syncRows()
  Component.onCompleted: syncRows()

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

  function toggleSection(sectionKey) {
    var action = Model.sectionAction(Model.sectionByKey(sections, sectionKey))
    if (action) runAction(action.ids, action.verb)
  }

  function stopEverything() {
    var ids = []
    for (var i = 0; i < containers.length; i++) {
      if (containers[i].up) ids.push(containers[i].id)
    }
    runAction(ids, "stop")
  }

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

  function moveCursor(delta) {
    if (rowModel.count === 0) return
    cursorActive = true
    cursorFromKeyboard = true
    cursorIndex = Model.clampCursor(cursorIndex + delta, rowModel.count)
  }

  function setCursor(index) {
    cursorActive = true
    cursorFromKeyboard = false
    cursorIndex = Model.clampCursor(index, rowModel.count)
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
        root.permissionDenied = /permission denied|dial unix|connect: permission/i.test(message)
        root.containers = []
        root.stats = ({})
        return
      }

      root.daemonReachable = true
      root.permissionDenied = false

      root.containers = Model.normalizeContainers(Model.parseJsonLines(listOut.text))
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

  implicitWidth: button.visible ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

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

        ListView {
          id: listView
          visible: rowModel.count > 0
          width: parent.width
          height: visible ? Math.min(contentHeight, Style.space(560)) : 0
          spacing: Style.spacing.sm
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: rowModel
          currentIndex: root.cursorIndex

          onCurrentIndexChanged: {
            if (currentIndex >= 0 && root.cursorFromKeyboard) Qt.callLater(keepCurrentVisible)
          }
          function keepCurrentVisible() {
            if (currentIndex >= 0 && root.cursorFromKeyboard) positionViewAtIndex(currentIndex, ListView.Contain)
          }

          delegate: Column {
            id: rowGroup
            required property var model
            required property int index

            width: ListView.view.width
            spacing: Style.spacing.sm

            SectionHeader {
              visible: rowGroup.model.sectionTitle !== ""
              height: visible ? implicitHeight : 0
              width: parent.width
              title: rowGroup.model.sectionTitle
              sectionKey: rowGroup.model.sectionKey
              running: rowGroup.model.sectionRunning
              total: rowGroup.model.sectionTotal
              first: rowGroup.model.firstSection
            }

            ContainerRow {
              width: parent.width
              row: rowGroup.model
              rowIndex: rowGroup.index
            }
          }
        }

        Column {
          visible: rowModel.count === 0
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

  component SectionHeader: Item {
    id: header

    required property string title
    required property string sectionKey
    required property int running
    required property int total
    property bool first: false

    readonly property bool anyRunning: running > 0

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
      text: header.title.toUpperCase()
      textFormat: Text.PlainText
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
        text: header.running + "/" + header.total
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      PanelActionButton {
        enabled: !actionProcess.running
        iconText: header.anyRunning ? Model.Glyph.stop : Model.Glyph.play
        tooltipText: (header.anyRunning ? "Stop " : "Start ") + header.title
        foreground: root.foreground
        hoverColor: header.anyRunning ? Color.urgent : root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.iconSmall
        size: Style.space(20)
        onClicked: root.toggleSection(header.sectionKey)
      }
    }
  }

  component ContainerRow: CursorSurface {
    id: rowSurface

    required property var row
    required property int rowIndex

    readonly property var containerStats: root.stats[row.id]
    readonly property bool busy: root.pendingId === row.id
    readonly property var container: Model.containerById(root.containers, row.id)

    hasCursor: root.cursorActive && rowIndex === root.cursorIndex
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.xxl
    height: implicitHeight

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.setCursor(rowSurface.rowIndex)
      onClicked: root.copyText(rowSurface.row.id)
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
          color: rowSurface.row.failing ? Color.urgent
            : (rowSurface.row.up ? Color.accent : "transparent")
          border.width: !rowSurface.row.up && !rowSurface.row.failing ? 1 : 0
          border.color: root.dim

          SequentialAnimation on opacity {
            running: rowSurface.row.restarting
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
              text: rowSurface.row.name
              textFormat: Text.PlainText
              width: Math.min(implicitWidth, parent.width - (healthGlyph.visible ? healthGlyph.implicitWidth + Style.spacing.md : 0))
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              id: healthGlyph
              visible: rowSurface.row.unhealthy
              anchors.verticalCenter: parent.verticalCenter
              text: Model.Glyph.unhealthy
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.iconSmall
            }
          }

          Text {
            width: parent.width
            text: rowSurface.row.subtitle
            textFormat: Text.PlainText
            visible: text !== ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            visible: !rowSurface.row.up
            text: rowSurface.row.status
            textFormat: Text.PlainText
            color: rowSurface.row.failing ? Color.urgent : root.dim
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
            visible: rowSurface.row.up
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
            iconText: rowSurface.row.up ? Model.Glyph.stop : Model.Glyph.play
            tooltipText: rowSurface.row.up ? "Stop  (enter)" : "Start  (enter)"
            foreground: root.foreground
            hoverColor: rowSurface.row.up ? Color.urgent : root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.iconSmall
            size: Style.space(22)
            onClicked: root.toggleContainer(rowSurface.container)
          }
        }
      }

      Row {
        visible: root.showStats && rowSurface.row.up
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
      textFormat: Text.PlainText
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
