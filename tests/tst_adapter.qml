import QtQuick
import QtTest
import "../FrankAdapter.js" as Adapter

TestCase {
  name: "FrankAdapter"
  when: true
  function entry(id, type, state) {
    return { id: id, type: type, status: state || "open", text: "synthetic todo text",
      structuredJson: {}, title: null, project: null, projectRaw: null,
      tags: ["synthetic"], source: "test", sessionId: null,
      actorType: "agent", actorId: "synthetic", createdAt: "2026-01-01",
      updatedAt: "2026-01-01", closedAt: null, closeNote: null }
  }
  function status() {
    return { active: entry(1, "status"), activeRightNow: [entry(2, "active")],
      activeProjects: [{ name: "test", count: 1, lastType: "todo",
        lastText: "synthetic", updatedAt: "2026-01-01" }],
      recent: [entry(1, "status")], openLoops: [entry(3, "todo")], truncated: false }
  }
  function output(value) { return { exitCode: 0, stdout: JSON.stringify(value) } }
  function page(ids, truncated) {
    return { entries: ids.map(function (id) { return entry(id, "todo") }), truncated: !!truncated }
  }
  function run(s, p, failure) {
    var result
    Adapter.load(function (action, argv, cb) {
      verify(action === "status-view" || action === "open")
      compare(argv[0], "frank-cloud-post.sh")
      compare(argv[1], action)
      cb(failure && failure.action === action ? failure.response : output(action === "open" ? p : s))
    }, function (r) { result = r })
    return result
  }
  function prepare() {
    Adapter.setGuardProbeResult(0)
    verify(run(status(), page([3, 5])).ok)
  }
  function init() { Adapter.resetGuard(); Adapter.summon() }
  function test_guardFailClosed() {
    var called = false
    Adapter.load(function () { called = true }, function (r) { compare(r.category, "helper HTTPS guard not verified") })
    verify(!called)
    verify(!Adapter.setGuardProbeResult(1))
    verify(!Adapter.setGuardProbeResult(-1))
    compare(Adapter.guardState(), "helper HTTPS guard not verified")
  }
  function test_validAndTruncated() {
    Adapter.setGuardProbeResult(0)
    var result = run(status(), { entries: [entry(3, "todo"), entry(4, "blocker")], truncated: true })
    verify(result.ok)
    compare(result.todos.length, 1)
    compare(result.todos[0].id, "3")
    compare(result.truncated, true)
    compare(result.status.active.actorId, undefined)
    result = run(status(), page([]))
    verify(result.ok)
    compare(result.todos.length, 0)
  }
  function test_badShapesAndFailures() {
    Adapter.setGuardProbeResult(0)
    var bad = [{ entries: [] }, { entries: [], truncated: "false" },
      page([0]), page([9007199254740992]),
      { entries: [entry(3, "unknown")], truncated: false },
      { entries: [entry(3, "todo", "closed")], truncated: false }]
    for (var i = 0; i < bad.length; i++)
      compare(run(status(), bad[i]).category, "malformed-response")
    var s = status(); delete s.activeRightNow
    compare(run(s, page([])).category, "malformed-response")
    s = status(); s.activeProjects[0].count = "1"
    compare(run(s, page([])).category, "malformed-response")
    var failures = [{ exitCode: 2, stderr: "synthetic-token synthetic-workspace" },
      { category: "missing-helper", stderr: "synthetic-token" },
      { category: "timeout" }, { exitCode: 0, stdout: "x".repeat(524289) },
      { exitCode: 0, stdout: "{" }]
    for (i = 0; i < failures.length; i++) {
      var result = run(status(), page([]), { action: "open", response: failures[i] })
      verify(!result.ok)
      verify(JSON.stringify(result).indexOf("synthetic-token") < 0)
    }
    compare(Adapter.argv("arbitrary"), null)
    compare(Adapter.argv("close", "3/4"), null)
    compare(Adapter.argv("close", 3)[2], "3")
  }
  function test_invalidIdsAndNoWritesOnReads() {
    prepare()
    var writes = 0
    var invalid = ["3", "3/4", "3?x", 0, -1, 3.5, 9007199254740992, NaN, Infinity, 6, 4]
    for (var i = 0; i < invalid.length; i++)
      verify(!Adapter.closeTodo(invalid[i], function () { writes++ }, function () {}).ok)
    compare(writes, 0)
    // Blockers are filtered even if the server returns one.
    verify(run(status(), {entries: [entry(4, "blocker")], truncated: false}).ok)
    verify(!Adapter.closeTodo(4, function () { writes++ }, function () {}).ok)
    compare(writes, 0)
  }
  function transaction(closeResponse, openPage, readFailure) {
    prepare()
    var calls = [], callbacks = {}, outcome
    var started = Adapter.closeTodo(3, function (action, argv, cb) {
      calls.push(argv)
      callbacks[action] = cb
    }, function (r) { outcome = r })
    verify(started.ok)
    compare(Adapter.closeTodo(3, function () { fail("duplicate write") }, function () {}).category, "busy")
    compare(Adapter.closeTodo(5, function () { fail("competing write") }, function () {}).category, "busy")
    compare(Adapter.closeTodo(3).category, "busy")
    Adapter.load(function () { fail("refresh must not dispatch during close") },
      function (r) { compare(r.category, "busy") })
    compare(calls.length, 1)
    compare(calls[0].join(" "), "frank-cloud-post.sh close 3")
    callbacks.close(closeResponse)
    compare(calls.length, 3)
    compare(calls[1][1], "status-view")
    compare(calls[2][1], "open")
    callbacks["status-view"](readFailure || output(status()))
    callbacks.open(readFailure || output(openPage))
    verify(!Adapter.isClosePending())
    compare(calls.length, 3) // no automatic write retry
    return outcome
  }
  function test_truthTable() {
    var confirmed = output({entry: entry(3, "todo", "closed")})
    var invalid = [output({entry: entry(5, "todo", "closed")}),
      output({entry: entry(3, "todo", "open")}), {exitCode: 0, stdout: "{"},
      {exitCode: 2}, {category: "timeout"}]
    var r = transaction(confirmed, page([5]))
    compare(r.mark.outcome, "confirmed")
    compare(r.projection.todos.length, 1)
    compare(r.mark.evidence.command, "close")
    compare(r.mark.evidence.target, "3")
    verify(r.mark.evidence.httpStatus.length > 0)
    verify(r.mark.evidence.timestamp.length > 0)
    verify(r.mark.evidence.validated)
    Adapter.summon()
    r = transaction(confirmed, page([3]))
    compare(r.mark.outcome, "unknown") // conflicting fresh open row wins
    for (var i = 0; i < invalid.length; i++) {
      Adapter.summon()
      r = transaction(invalid[i], page([3]))
      compare(r.mark.outcome, "still-open")
      Adapter.summon()
      r = transaction(invalid[i], page([], true))
      compare(r.mark.outcome, "unknown") // even a truncated missing row proves nothing
      compare(r.mark.text, "synthetic todo text")
    }
    Adapter.summon()
    r = transaction(confirmed, page([]), { category: "timeout" })
    compare(r.mark.outcome, "confirmed-refresh-failed")
    compare(r.projection, null)
    Adapter.summon()
    r = transaction(invalid[0], page([]), { category: "helper" })
    compare(r.mark.outcome, "unknown")
    compare(r.projection, null)
  }
  function test_storeWinsAndReadOnlyRecheck() {
    prepare()
    var callback, result
    Adapter.closeTodo(3, function (action, args, cb) {
      if (action === "close") cb({category: "timeout"})
      else if (action === "status-view") cb(output(status()))
      else cb(output(page([], true)))
    }, function (r) { result = r })
    compare(result.mark.outcome, "unknown")
    compare(result.projection.todos.length, 0)
    result = run(status(), page([3])) // another agent or delayed view: store truth
    verify(result.ok)
    compare(result.todos[0].id, "3")
    compare(Adapter.closeMarks().filter(function (m) { return m.id === "3" })[0].outcome, "still-open")
    result = run(status(), page([]))
    verify(result.ok)
    // No matching closed entry, so absence on next load is not confirmation.
    compare(Adapter.closeMarks().filter(function (m) { return m.id === "3" })[0].outcome, "unknown")
  }
  function test_generationsAndQueuedRead() {
    prepare()
    var pending = {}, applied = 0, queued = 0, actions = []
    Adapter.closeTodo(3, function (action, argv, cb) { pending[action] = cb; actions.push(action) }, function () { applied++ })
    Adapter.hide()
    Adapter.summon()
    verify(Adapter.queueVisibleRead(function (action, args, cb) {
      queued++; cb(output(action === "open" ? page([5]) : status()))
    }, function (r) { verify(r.ok); compare(r.todos[0].id, "5") }))
    verify(Adapter.isClosePending())
    pending.close({category: "timeout"})
    pending["status-view"](output(status()))
    pending.open(output(page([])))
    compare(applied, 0) // invalidated close projection not applied
    compare(queued, 2) // one status + one open for new generation
    verify(!Adapter.isClosePending())
    compare(Adapter.closeMarks().filter(function (m) { return m.id === "3" })[0].outcome, "unknown")
    // Hide during close; terminal callback cleans up but cannot reopen or read.
    prepare()
    pending = {}; queued = 0
    Adapter.closeTodo(3, function (action, args, cb) { pending[action] = cb }, function () { applied++ })
    Adapter.hide()
    pending.close({category: "helper"})
    pending["status-view"](output(status()))
    pending.open(output(page([3])))
    compare(applied, 0)
    compare(queued, 0)
    verify(!Adapter.isClosePending())
  }
  function test_reconcileFailureAfterReopen() {
    prepare()
    var callbacks = {}, queued = 0, surfaced = 0
    Adapter.closeTodo(3, function (action, args, cb) { callbacks[action] = cb }, function () { surfaced++ })
    Adapter.hide(); Adapter.summon()
    Adapter.queueVisibleRead(function (action, args, cb) {
      queued++
      cb(output(action === "open" ? page([5]) : status()))
    }, function (r) { verify(r.ok) })
    callbacks.close(output({entry: entry(3, "todo", "closed")}))
    callbacks["status-view"]({category: "timeout"})
    callbacks.open(output(page([])))
    compare(surfaced, 0)
    compare(queued, 2)
    verify(!Adapter.isClosePending())
    compare(Adapter.closeMarks().filter(function (m) { return m.id === "3" })[0].outcome, "confirmed-refresh-failed")
  }
  function test_budgetTerminalAndLateCallbacks() {
    prepare()
    var pending = {}, queued = 0
    Adapter.closeTodo(3, function (action, argv, cb) { pending[action] = cb }, function () { fail("stale completion") })
    Adapter.hide(); Adapter.summon()
    Adapter.queueVisibleRead(function (action, argv, cb) {
      queued++; cb(output(action === "open" ? page([]) : status()))
    }, function (r) { verify(r.ok) })
    Adapter.timeoutClose()
    verify(!Adapter.isClosePending())
    compare(queued, 2)
    pending.close(output({entry: entry(3, "todo", "closed")}))
    compare(queued, 2)
    // A late read from summon N must not overwrite summon N+1.
    var stale = [], current = [], oldDone = false, newDone = false
    Adapter.load(function (a, args, cb) { stale.push(cb) }, function () { oldDone = true })
    Adapter.summon()
    Adapter.load(function (a, args, cb) { current.push(cb) }, function (r) { newDone = r.ok })
    current[0](output(status())); current[1](output(page([5])))
    stale[0](output(status())); stale[1](output(page([3])))
    verify(newDone); verify(!oldDone)
  }
}
