.pragma library

var Glyph = {
  docker: String.fromCodePoint(0xF0868),
  play: String.fromCodePoint(0xF040A),
  stop: String.fromCodePoint(0xF04DB),
  restart: String.fromCodePoint(0xF0709),
  logs: String.fromCodePoint(0xF0219),
  copy: String.fromCodePoint(0xF018F),
  refresh: String.fromCodePoint(0xF0450),
  unhealthy: String.fromCodePoint(0xF05D6),
  search: String.fromCodePoint(0xF0349)
}

var UNGROUPED = "\\x00ungrouped"

var UP_STATES = ["running", "restarting", "removing"]

function trim(value) {
  return String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
}

function parseJsonLines(raw) {
  var lines = String(raw || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = trim(lines[i])
    if (line.charAt(0) !== "{") continue
    try {
      out.push(JSON.parse(line))
    } catch (e) {
    }
  }
  return out
}

function labelValue(labels, key) {
  var parts = String(labels || "").split(",")
  for (var i = 0; i < parts.length; i++) {
    var eq = parts[i].indexOf("=")
    if (eq <= 0) continue
    if (trim(parts[i].substring(0, eq)) === key) return trim(parts[i].substring(eq + 1))
  }
  return ""
}

function composeProject(labels) {
  return labelValue(labels, "com.docker.compose.project")
}

function isUp(state) {
  return UP_STATES.indexOf(trim(state).toLowerCase()) !== -1
}

function healthOf(raw) {
  var direct = trim(raw && raw.HealthStatus).toLowerCase()
  if (direct && direct !== "none") return direct
  var match = String(raw && raw.Status || "").match(/\((healthy|unhealthy|health: starting|starting)\)/i)
  if (!match) return ""
  var found = match[1].toLowerCase()
  return found === "health: starting" ? "starting" : found
}

function exitCode(status) {
  var match = String(status || "").match(/^Exited \((\d+)\)/)
  return match ? parseInt(match[1], 10) : -1
}

function isFailing(container) {
  if (!container) return false
  if (container.up) return container.health === "unhealthy"
  return container.exitCode > 0
}

function isAlerting(container) {
  if (!container || !container.up) return false
  return container.health === "unhealthy" || container.state === "restarting"
}

function hostPorts(ports) {
  var seen = {}
  var out = []
  var parts = String(ports || "").split(",")
  for (var i = 0; i < parts.length; i++) {
    var match = trim(parts[i]).match(/:(\d+)(?:-(\d+))?->/)
    if (!match) continue
    var port = match[1]
    if (seen[port]) continue
    seen[port] = true
    out.push(port)
  }
  return out
}

function shortImage(image) {
  var value = trim(image)
  if (!value) return ""
  if (value.indexOf("sha256:") === 0) return value.substring(0, 19)
  var slash = value.indexOf("/")
  if (slash > 0) {
    var host = value.substring(0, slash)
    if (host.indexOf(".") !== -1 || host.indexOf(":") !== -1 || host === "localhost") {
      value = value.substring(slash + 1)
    }
  }
  var colon = value.lastIndexOf(":")
  if (colon > 0 && value.indexOf("/", colon) === -1) value = value.substring(0, colon)
  return value
}

function normalizeContainer(raw) {
  var state = trim(raw && raw.State).toLowerCase()
  var status = trim(raw && raw.Status)
  var container = {
    id: trim(raw && raw.ID),
    name: trim(raw && raw.Names).split(",")[0],
    image: trim(raw && raw.Image),
    shortImage: shortImage(raw && raw.Image),
    state: state,
    status: status,
    health: healthOf(raw),
    exitCode: exitCode(status),
    project: composeProject(raw && raw.Labels),
    service: labelValue(raw && raw.Labels, "com.docker.compose.service"),
    ports: hostPorts(raw && raw.Ports),
    up: isUp(state)
  }
  container.failing = isFailing(container)
  container.alerting = isAlerting(container)
  return container
}

function normalizeContainers(rawList) {
  var out = []
  var list = rawList || []
  for (var i = 0; i < list.length; i++) {
    var container = normalizeContainer(list[i])
    if (container.id) out.push(container)
  }
  return out
}

function parsePercent(value) {
  var match = String(value || "").match(/(-?\d+(?:\.\d+)?)\s*%/)
  if (!match) return -1
  var n = Number(match[1])
  return isFinite(n) ? n : -1
}

function memUsed(usage) {
  return trim(String(usage || "").split("/")[0])
}

function indexStats(rawList) {
  var out = {}
  var list = rawList || []
  for (var i = 0; i < list.length; i++) {
    var row = list[i]
    var id = trim(row && row.ID)
    if (!id) continue
    out[id] = {
      id: id,
      cpu: trim(row.CPUPerc),
      cpuPercent: parsePercent(row.CPUPerc),
      mem: memUsed(row.MemUsage),
      memPercent: parsePercent(row.MemPerc)
    }
  }
  return out
}

function matchesFilter(container, query) {
  var needle = trim(query).toLowerCase()
  if (!needle) return true
  if (!container) return false
  var haystack = [container.name, container.image, container.project, container.service, container.id]
  for (var i = 0; i < haystack.length; i++) {
    if (String(haystack[i] || "").toLowerCase().indexOf(needle) !== -1) return true
  }
  return false
}

function filterContainers(containers, query) {
  var out = []
  var list = containers || []
  for (var i = 0; i < list.length; i++) {
    if (matchesFilter(list[i], query)) out.push(list[i])
  }
  return out
}

function compareContainers(a, b) {
  if (a.up !== b.up) return a.up ? -1 : 1
  if (!a.up && a.failing !== b.failing) return a.failing ? -1 : 1
  return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0)
}

function sectionsFor(containers) {
  var list = (containers || []).slice()
  var byProject = {}
  var order = []

  for (var i = 0; i < list.length; i++) {
    var key = list[i].project || UNGROUPED
    if (!byProject[key]) {
      byProject[key] = []
      order.push(key)
    }
    byProject[key].push(list[i])
  }

  order.sort(function(a, b) {
    if (a === UNGROUPED) return 1
    if (b === UNGROUPED) return -1
    return a < b ? -1 : (a > b ? 1 : 0)
  })

  var sections = []
  for (var j = 0; j < order.length; j++) {
    var members = byProject[order[j]].sort(compareContainers)
    var running = []
    var stopped = []
    for (var k = 0; k < members.length; k++) {
      if (members[k].up) running.push(members[k].id)
      else stopped.push(members[k].id)
    }
    sections.push({
      key: order[j],
      title: order[j] === UNGROUPED ? "Ungrouped" : order[j],
      containers: members,
      runningIds: running,
      stoppedIds: stopped,
      runningCount: running.length,
      total: members.length
    })
  }

  if (sections.length === 1 && sections[0].key === UNGROUPED) sections[0].title = ""
  return sections
}

function rowsFor(sections) {
  var rows = []
  var list = sections || []
  for (var i = 0; i < list.length; i++) {
    var section = list[i]
    for (var j = 0; j < section.containers.length; j++) {
      var c = section.containers[j]
      rows.push({
        key: c.id,
        id: c.id,
        name: c.name,
        subtitle: subtitleText(c),
        status: statusText(c),
        up: c.up,
        failing: c.failing,
        restarting: c.state === "restarting",
        unhealthy: c.health === "unhealthy",
        sectionKey: section.key,
        sectionTitle: j === 0 ? section.title : "",
        sectionRunning: section.runningCount,
        sectionTotal: section.total,
        firstSection: i === 0
      })
    }
  }
  return rows
}

var ROW_FIELDS = ["name", "subtitle", "status", "up", "failing", "restarting",
  "unhealthy", "sectionKey", "sectionTitle", "sectionRunning", "sectionTotal",
  "firstSection"]

function reconcilePlan(currentKeys, nextRows) {
  var keys = (currentKeys || []).slice()
  var next = nextRows || []
  var ops = []

  var wanted = {}
  for (var i = 0; i < next.length; i++) wanted[next[i].key] = true

  for (var r = keys.length - 1; r >= 0; r--) {
    if (wanted[keys[r]]) continue
    ops.push({ op: "remove", index: r })
    keys.splice(r, 1)
  }

  for (var n = 0; n < next.length; n++) {
    if (keys[n] === next[n].key) continue
    var found = keys.indexOf(next[n].key, n)
    if (found > n) {
      ops.push({ op: "move", from: found, to: n })
      keys.splice(n, 0, keys.splice(found, 1)[0])
    } else {
      ops.push({ op: "insert", index: n, row: next[n] })
      keys.splice(n, 0, next[n].key)
    }
  }
  return ops
}

function containerById(containers, id) {
  var list = containers || []
  for (var i = 0; i < list.length; i++) {
    if (list[i].id === id) return list[i]
  }
  return null
}

function containerAtCursor(containers, rows, cursorIndex) {
  var list = rows || []
  if (cursorIndex < 0 || cursorIndex >= list.length) return null
  return containerById(containers, list[cursorIndex].id)
}

function sectionByKey(sections, key) {
  var list = sections || []
  for (var i = 0; i < list.length; i++) {
    if (list[i].key === key) return list[i]
  }
  return null
}

function clampCursor(cursorIndex, total) {
  if (total <= 0) return 0
  if (cursorIndex < 0) return 0
  if (cursorIndex > total - 1) return total - 1
  return cursorIndex
}

function counts(containers) {
  var list = containers || []
  var out = { total: list.length, running: 0, stopped: 0, failing: 0, alerting: 0 }
  for (var i = 0; i < list.length; i++) {
    if (list[i].up) out.running++
    else out.stopped++
    if (list[i].failing) out.failing++
    if (list[i].alerting) out.alerting++
  }
  return out
}

function summaryText(containers, daemonUp) {
  if (!daemonUp) return "Docker daemon unreachable"
  var c = counts(containers)
  if (c.total === 0) return "No containers"
  var base = c.running + " of " + c.total + " running"
  if (c.alerting > 0) return c.alerting + (c.alerting === 1 ? " needs" : " need") + " attention · " + base
  return base
}

function statusText(container) {
  if (!container) return ""
  if (container.up) return trim(container.status).replace(/\s*\((healthy|unhealthy|health: starting|starting)\)\s*$/i, "")
  if (container.exitCode > 0) return "Exited (" + container.exitCode + ")"
  return trim(container.status)
}

function subtitleText(container) {
  if (!container) return ""
  var parts = []
  if (container.service && container.service !== container.name) parts.push(container.service)
  if (container.shortImage) parts.push(container.shortImage)
  var line = parts.join(" · ")
  if (container.ports.length > 0) line += (line ? "  " : "") + ":" + container.ports.join(" :")
  return line
}

function sectionAction(section) {
  if (!section || section.total === 0) return null
  if (section.runningCount > 0) return { verb: "stop", ids: section.runningIds }
  return { verb: "start", ids: section.stoppedIds }
}
