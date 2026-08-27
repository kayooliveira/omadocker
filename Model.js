.pragma library

// Everything Omadocker can decide without running a command.
//
// A QML `.pragma library` script: `var` and `function` declarations only, no
// imports, no QML objects, no side effects. That is what lets tests/ run it
// under plain node, so decisions belong here rather than in Panel.qml.

// Built from code points rather than pasted: editing tools mangle multi-byte
// sequences in QML, and the result is a blank box with nothing in any log.
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

// Section key for containers with no Compose project. Leading space so it
// cannot collide with a project genuinely named "ungrouped".
var UNGROUPED = "\\x00ungrouped"

// `restarting` and `removing` count as up: they hold resources, and neither
// is something you start.
var UP_STATES = ["running", "restarting", "removing"]

function trim(value) {
  return String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
}

// One JSON object per line. Parsed line by line rather than through `jq -s`
// so one malformed line loses one container instead of the whole list.
function parseJsonLines(raw) {
  var lines = String(raw || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = trim(lines[i])
    if (line.charAt(0) !== "{") continue
    try {
      out.push(JSON.parse(line))
    } catch (e) {
      // One unreadable line is not worth losing the rest of the list over.
    }
  }
  return out
}

// Labels arrive as one comma-separated `key=value` string whose values may
// themselves contain commas (compose writes a path list into `config_files`),
// so only fragments that look like a fresh pair are treated as one.
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

// `HealthStatus` on modern daemons, a "(healthy)" suffix on the status line
// everywhere else. It is the literal string "none" without a HEALTHCHECK.
function healthOf(raw) {
  var direct = trim(raw && raw.HealthStatus).toLowerCase()
  if (direct && direct !== "none") return direct
  var match = String(raw && raw.Status || "").match(/\((healthy|unhealthy|health: starting|starting)\)/i)
  if (!match) return ""
  var found = match[1].toLowerCase()
  return found === "health: starting" ? "starting" : found
}

// Exit code out of "Exited (137) 2 hours ago", or -1 if it has not exited —
// so callers tell a clean stop (0) from a running container without a
// second state check.
function exitCode(status) {
  var match = String(status || "").match(/^Exited \((\d+)\)/)
  return match ? parseInt(match[1], 10) : -1
}

// Two questions, deliberately not the same one.
//
// `failing` — "this ended badly" — colours the row's own status line.
// `alerting` — "this needs you now" — is the only thing that turns the bar
// glyph urgent. A non-zero exit from yesterday is the first but not the
// second: a widget that goes red for it stays red until someone prunes, and
// a permanently red icon is one nobody reads.
function isFailing(container) {
  if (!container) return false
  if (container.health === "unhealthy") return true
  return !container.up && container.exitCode > 0
}

function isAlerting(container) {
  if (!container) return false
  return container.health === "unhealthy" || container.state === "restarting"
}

// Published host ports, deduplicated. Docker prints one mapping per address
// family, so `-p 3000:3000` arrives twice and would read as two ports.
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

// "ghcr.io/xpto/xpto:1" -> "xpto/xpto". The row has
// one line for this, and the registry is never the identifying part.
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

// "0.75%" -> 0.75, or -1 when unreadable, so a meter can tell "no reading
// yet" from "idle" instead of drawing a confident empty bar.
function parsePercent(value) {
  var match = String(value || "").match(/(-?\d+(?:\.\d+)?)\s*%/)
  if (!match) return -1
  var n = Number(match[1])
  return isFinite(n) ? n : -1
}

// "238.5MiB / 31.21GiB" -> "238.5MiB". The limit is the host's total unless
// the container set one, so printing it repeats one number down the list.
function memUsed(usage) {
  return trim(String(usage || "").split("/")[0])
}

// Both commands report the same short id, so this is a plain hash join
// rather than the prefix matching the two-id format invites.
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

// Running first, then failing, then by name — so the row someone opened the
// panel to find is near the top of its section.
function compareContainers(a, b) {
  if (a.up !== b.up) return a.up ? -1 : 1
  if (!a.up && a.failing !== b.failing) return a.failing ? -1 : 1
  return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0)
}

// Group by Compose project: it is the unit people start and stop. Loose
// containers get one trailing section, whose header is dropped when it is the
// only one — three loose containers should not be labelled "ungrouped".
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

  // One unnamed section is just a list; labelling it adds a header that says
  // nothing the rows do not already say.
  if (sections.length === 1 && sections[0].key === UNGROUPED) sections[0].title = ""
  return sections
}

// One row per container, each carrying the header it should draw above
// itself. Headers as rows of their own would make the cursor index differ
// from the row index; this way they are the same number.
function rowsFor(sections) {
  var rows = []
  var list = sections || []
  for (var i = 0; i < list.length; i++) {
    var section = list[i]
    for (var j = 0; j < section.containers.length; j++) {
      rows.push({
        key: section.containers[j].id,
        container: section.containers[j],
        section: section,
        sectionTitle: j === 0 ? section.title : "",
        firstSection: i === 0
      })
    }
  }
  return rows
}

// Resolved on read rather than stored: rows are rebuilt whenever the list
// changes shape, and a container that disappears should move the cursor
// rather than leave a stale reference behind.
function containerAtCursor(rows, cursorIndex) {
  var list = rows || []
  return (cursorIndex >= 0 && cursorIndex < list.length) ? list[cursorIndex].container : null
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

// The line under the panel title, and the bar tooltip. Trouble leads the
// tally when there is any.
function summaryText(containers, daemonUp) {
  if (!daemonUp) return "Docker daemon unreachable"
  var c = counts(containers)
  if (c.total === 0) return "No containers"
  var base = c.running + " of " + c.total + " running"
  if (c.alerting > 0) return c.alerting + (c.alerting === 1 ? " needs" : " need") + " attention · " + base
  return base
}

// Docker's own status line reads well enough; it just repeats the health the
// row already draws, and buries a bad exit code in prose.
function statusText(container) {
  if (!container) return ""
  if (container.up) return trim(container.status).replace(/\s*\((healthy|unhealthy|health: starting|starting)\)\s*$/i, "")
  if (container.exitCode > 0) return "Exited (" + container.exitCode + ")"
  return trim(container.status)
}

// What it is, and where to reach it. The service name leads because four
// services in a project can share one image.
function subtitleText(container) {
  if (!container) return ""
  var parts = []
  if (container.service && container.service !== container.name) parts.push(container.service)
  if (container.shortImage) parts.push(container.shortImage)
  var line = parts.join(" · ")
  if (container.ports.length > 0) line += (line ? "  " : "") + ":" + container.ports.join(" :")
  return line
}

// Panel.qml reassigns `containers` only when this changes: an equal-but-new
// array rebuilds every delegate, which drops the scroll position and hover,
// and can move a row between a click's press and release. Stats are out of it
// on purpose — they change every poll and repaint one meter instead.
function signatureOf(containers) {
  var list = containers || []
  var parts = []
  for (var i = 0; i < list.length; i++) {
    var c = list[i]
    parts.push([c.id, c.state, c.exitCode, c.health, c.project, c.name].join(" "))
  }
  return parts.join(" ")
}

// A project with anything running is asking to be brought down; one entirely
// stopped is asking to come up.
function sectionAction(section) {
  if (!section || section.total === 0) return null
  if (section.runningCount > 0) return { verb: "stop", ids: section.runningIds }
  return { verb: "start", ids: section.stoppedIds }
}
