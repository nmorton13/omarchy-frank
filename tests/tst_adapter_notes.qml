import QtQuick
import QtTest
import "../FrankAdapter.js" as Adapter

TestCase {
  name: "FrankAdapterNotes"
  when: true
  function entry(id, type, project, createdAt) {
    return { id: id, type: type, status: "open", text: "synthetic " + type + " " + id,
      structuredJson: {}, title: null, project: project, projectRaw: null,
      tags: ["synthetic"], source: "test", sessionId: null,
      actorType: "agent", actorId: "synthetic", createdAt: createdAt || "2026-01-01T00:00:00Z",
      updatedAt: "2026-01-01", closedAt: null, closeNote: null }
  }
  function output(value) { return { exitCode: 0, stdout: JSON.stringify(value) } }
  function status() {
    return { active: null, activeRightNow: [], activeProjects: [], recent: [], truncated: false }
  }
  function loadTodos(todos) {
    var result
    Adapter.load(function (action, argv, cb) {
      cb(output(action === "open" ? { entries: todos, truncated: false } : status()))
    }, function (r) { result = r })
    verify(result.ok)
  }
  function init() {
    Adapter.resetGuard(); Adapter.summon(); Adapter.setGuardProbeResult(0)
    loadTodos([entry(1, "todo", "edward"), entry(2, "todo", null), entry(3, "todo", "--limit")])
  }
  function notes(key, response) {
    var argv = null, result = null, calls = 0
    Adapter.loadNotes(key, function (action, args, cb) {
      calls++
      compare(action, "notes")
      argv = args
      cb(response)
    }, function (r) { result = r })
    return { argv: argv, result: result, calls: calls }
  }
  function test_projectNotesReadOnlyArgv() {
    var r = notes("project:edward", output({ entries: [
      entry(10, "note", "edward", "2026-01-01T00:00:00Z"),
      entry(11, "note", "edward", "2026-02-01T00:00:00Z")], truncated: false }))
    compare(r.argv.join(" "), "frank-cloud-post.sh list --type note --project edward --limit 50")
    verify(r.result.ok)
    compare(r.result.notes.map(function (n) { return n.id }).join(","), "11,10") // newest first
    // Cached for this summon: no second helper call.
    compare(notes("project:edward", null).calls, 0)
    // A new summon drops the cache.
    Adapter.summon()
    loadTodos([entry(1, "todo", "edward")])
    compare(notes("project:edward", output({ entries: [], truncated: false })).calls, 1)
  }
  function test_projectNameIsOneArgument() {
    // A project named like a flag stays the --project value, never a new option.
    var r = notes("project:--limit", output({ entries: [], truncated: false }))
    compare(r.argv.length, 8)
    compare(r.argv[4], "--project")
    compare(r.argv[5], "--limit")
  }
  function test_unassignedFiltersClientSide() {
    var r = notes("unassigned", output({ entries: [
      entry(20, "note", null), entry(21, "note", "edward")], truncated: true }))
    compare(r.argv.join(" "), "frank-cloud-post.sh list --type note --limit 50")
    compare(r.result.notes.length, 1)
    compare(r.result.notes[0].id, "20")
    compare(r.result.truncated, true)
  }
  function test_rejectsUnknownProjectsAndBadShapes() {
    compare(notes("project:nobody", null).result.category, "unknown-project")
    compare(notes("project:nobody", null).calls, 0)
    var bad = [output({ entries: [entry(30, "todo", "edward")], truncated: false }),
      output({ entries: [] }), { exitCode: 1, stdout: "" }, { category: "timeout" }]
    for (var i = 0; i < bad.length; i++) {
      Adapter.summon(); loadTodos([entry(1, "todo", "edward")])
      verify(!notes("project:edward", bad[i]).result.ok)
    }
    Adapter.resetGuard()
    compare(notes("project:edward", null).result.category, "helper HTTPS guard not verified")
  }
  function test_lateAnswersDropped() {
    var pending = [], results = []
    Adapter.loadNotes("project:edward", function (a, args, cb) { pending.push(cb) }, function (r) { results.push("edward") })
    Adapter.loadNotes("unassigned", function (a, args, cb) { pending.push(cb) }, function (r) { results.push("unassigned") })
    pending[0](output({ entries: [], truncated: false })) // cursor already moved on
    pending[1](output({ entries: [], truncated: false }))
    compare(results.join(","), "unassigned")
  }
}
