import QtQuick
import QtTest
import "../FrankAdapter.js" as Adapter

TestCase {
  name: "FrankAdapterMarks"
  when: true
  function entry(id, type, state) {
    return { id: id, type: type, status: state || "open", text: "synthetic todo text",
      structuredJson: {}, title: null, project: null, projectRaw: null,
      tags: ["synthetic"], source: "test", sessionId: null,
      actorType: "agent", actorId: "synthetic", createdAt: "2026-01-01",
      updatedAt: "2026-01-01", closedAt: null, closeNote: null }
  }
  function status() {
    return { active: null, activeRightNow: [], activeProjects: [], recent: [], truncated: false }
  }
  function output(value) { return { exitCode: 0, stdout: JSON.stringify(value) } }
  function page(ids) {
    return { entries: ids.map(function (id) { return entry(id, "todo") }), truncated: false }
  }
  function load(ids) {
    var result
    Adapter.load(function (action, argv, cb) {
      cb(output(action === "open" ? page(ids) : status()))
    }, function (r) { result = r })
    verify(result.ok)
  }
  function closeWith(id, closeResponse, openIds) {
    var result
    Adapter.closeTodo(id, function (action, args, cb) {
      if (action === "close") cb(closeResponse)
      else if (action === "status-view") cb(output(status()))
      else cb(output(page(openIds)))
    }, function (r) { result = r })
    return result
  }
  function init() { Adapter.resetGuard(); Adapter.summon() }
  function test_guardQuery() {
    verify(!Adapter.isGuardVerified())
    Adapter.setGuardProbeResult(0)
    verify(Adapter.isGuardVerified())
    Adapter.resetGuard()
    verify(!Adapter.isGuardVerified())
  }
  function test_marksOrderedByRecencyAndConfirmedPruned() {
    Adapter.setGuardProbeResult(0)
    load([30, 50])
    // Higher ID first: the latest mark must be the most recent close, not the largest ID.
    compare(closeWith(50, { exitCode: 2 }, [30, 50]).mark.outcome, "still-open")
    compare(closeWith(30, { category: "timeout" }, [50]).mark.outcome, "unknown")
    var marks = Adapter.closeMarks()
    compare(marks[marks.length - 1].id, "30")
    compare(closeWith(50, output({ entry: entry(50, "todo", "closed") }), []).mark.outcome, "confirmed")
    load([30])
    closeWith(30, { exitCode: 2 }, [30])
    // A settled confirmed close is dropped once a newer close finishes.
    compare(Adapter.closeMarks().filter(function (m) { return m.id === "50" }).length, 0)
    marks = Adapter.closeMarks()
    compare(marks[marks.length - 1].id, "30")
  }
  function test_closeFromLoadedRowId() {
    // The overlay closes using a loaded row's ID, which the read model stores as a string.
    Adapter.setGuardProbeResult(0)
    var loaded
    Adapter.load(function (action, argv, cb) {
      cb(output(action === "open" ? page([70]) : status()))
    }, function (r) { loaded = r })
    var rowId = loaded.todos[0].id
    compare(typeof rowId, "string")
    compare(Adapter.closeTodo(rowId, function () { fail("string ID must not write") }, function () {}).category, "invalid-id")
    var argv = null, result
    verify(Adapter.closeTodo(Number(rowId), function (action, args, cb) {
      if (action === "close") { argv = args; cb(output({ entry: entry(70, "todo", "closed") })) }
      else cb(output(action === "open" ? page([]) : status()))
    }, function (r) { result = r }).ok)
    compare(argv.join(" "), "frank-cloud-post.sh close 70")
    compare(result.mark.outcome, "confirmed")
  }
}
