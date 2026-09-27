// In-memory read model. Only fixed helper actions are exposed to the QML host.
var generation = 0;
var closePending = false;
var currentProjection = null;
var marks = {}; // Disposable close outcomes; never used to erase server rows.
var queuedRead = null;
var transaction = null;
var readSerial = 0;
var markSerial = 0;
var guardVerified = false;
var guardFailed = false;
var MAX_OUTPUT = 524288;
var MAX_ID = 9007199254740991;
var NOTES_LIMIT = 50;
var MAX_PROJECT = 200;
var notesCache = {}; // Per-summon read cache keyed by project group key.
var notesSerial = 0;
var actions = {
    "status-view": true,
    "open": true,
    "close": true,
    "notes": true
};

function summon() {
    currentProjection = null;
    notesCache = {};
    return ++generation;
}
function hide() {
    currentProjection = null;
    queuedRead = null;
    notesCache = {};
    return ++generation;
}
function isCurrent(value) {
    return value === generation;
}
function isClosePending() {
    return closePending;
}
function isGuardVerified() {
    return guardVerified;
}
function guardState() {
    return guardVerified ? "verified" : "helper HTTPS guard not verified";
}
function setGuardProbeResult(exitCode) {
    // The isolated probe returns zero only after observing a nonzero helper exit
    // with no fake-curl invocation. Never infer verification from helper stderr.
    guardVerified = exitCode === 0;
    guardFailed = !guardVerified;
    return guardVerified;
}
function resetGuard() {
    guardVerified = false;
    guardFailed = false;
}
function error(category) {
    return {
        ok: false,
        category: category
    };
}
function object(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}
function integer(value) {
    return typeof value === "number" && isFinite(value) && Math.floor(value) === value && value > 0 && value <= MAX_ID;
}
function canonicalId(value) {
    return integer(value) ? String(value) : null;
}
function string(value) {
    return typeof value === "string";
}
function nullableString(value) {
    return value === null || string(value);
}
var types = ["note", "status", "active", "todo", "blocker", "done", "decision", "session"];
function entry(value, expectedStatus) {
    if (!object(value) || !integer(value.id) || types.indexOf(value.type) < 0 || value.status !== expectedStatus || !string(value.text) || !Array.isArray(value.tags) || !value.tags.every(string) || !nullableString(value.title) || !nullableString(value.project) || !nullableString(value.projectRaw) || !nullableString(value.sessionId) || !nullableString(value.closedAt) || !nullableString(value.closeNote) || !string(value.source) || !string(value.actorType) || !string(value.actorId) || !string(value.createdAt) || !string(value.updatedAt) || !object(value.structuredJson))
        throw new Error("entry shape");
    return {
        id: String(value.id),
        type: value.type,
        text: value.text,
        title: value.title,
        project: value.project,
        tags: value.tags.slice(),
        status: value.status,
        createdAt: value.createdAt
    };
}
function status(value) {
    if (!object(value) || !(value.active === null || object(value.active)) || !Array.isArray(value.activeRightNow) || !Array.isArray(value.activeProjects) || !Array.isArray(value.recent) || (value.truncated !== undefined && typeof value.truncated !== "boolean") || (value.openLoops !== undefined && !Array.isArray(value.openLoops)))
        throw new Error("status shape");
    var active = value.active === null ? null : entry(value.active, value.active.status);
    if (active && (active.type !== "status" || (active.status !== "open" && active.status !== "closed")))
        throw new Error("active type");
    var rightNow = value.activeRightNow.map(function (e) {
        var item = entry(e, "open");
        if (item.type !== "active")
            throw new Error("right now type");
        return item;
    });
    var projects = value.activeProjects.map(function (p) {
        if (!object(p) || !string(p.name) || !integer(p.count) || types.indexOf(p.lastType) < 0 || !string(p.lastText) || !string(p.updatedAt))
            throw new Error("project shape");
        return {
            name: p.name,
            count: p.count,
            lastType: p.lastType,
            lastText: p.lastText,
            updatedAt: p.updatedAt
        };
    });
    var recent = value.recent.map(function (e) {
        if (!object(e) || (e.status !== "open" && e.status !== "closed"))
            throw new Error("recent status");
        return entry(e, e.status);
    });
    if (value.openLoops !== undefined)
        value.openLoops.forEach(function (e) {
            var item = entry(e, "open");
            if (item.type !== "todo" && item.type !== "blocker")
                throw new Error("loop type");
        });
    return {
        active: active,
        activeRightNow: rightNow,
        activeProjects: projects,
        recent: recent,
        truncated: value.truncated === true
    };
}
function groupTodosByProject(todos) {
    var groups = [];
    var indexes = {};
    todos.forEach(function (todo) {
        var project = todo.project || "Unassigned";
        var key = todo.project ? "project:" + todo.project : "unassigned";
        var indexKey = "$" + key;
        if (indexes[indexKey] === undefined) {
            indexes[indexKey] = groups.length;
            groups.push({
                key: key,
                project: project,
                todos: []
            });
        }
        groups[indexes[indexKey]].todos.push(todo);
    });
    return groups;
}
function page(value) {
    if (!object(value) || !Array.isArray(value.entries) || typeof value.truncated !== "boolean")
        throw new Error("page shape");
    var todos = [];
    value.entries.forEach(function (raw) {
        var item = entry(raw, "open");
        if (item.type !== "todo" && item.type !== "blocker")
            throw new Error("loop type");
        if (item.type === "todo")
            todos.push(item);
    });
    return {
        todos: todos,
        truncated: value.truncated
    };
}
function notesPage(value) {
    if (!object(value) || !Array.isArray(value.entries) || typeof value.truncated !== "boolean")
        throw new Error("notes shape");
    var notes = value.entries.map(function (raw) {
        if (!object(raw) || (raw.status !== "open" && raw.status !== "closed"))
            throw new Error("note status");
        var item = entry(raw, raw.status);
        if (item.type !== "note")
            throw new Error("note type");
        return item;
    });
    // Newest first; ISO timestamps compare lexically.
    notes.sort(function (a, b) {
        return a.createdAt < b.createdAt ? 1 : a.createdAt > b.createdAt ? -1 : 0;
    });
    return {
        notes: notes,
        truncated: value.truncated
    };
}
function parseResult(result, validator) {
    if (!result || result.category)
        return error(result && result.category || "helper");
    if (result.exitCode !== 0)
        return error("helper");
    if (typeof result.stdout !== "string" || result.stdout.length > MAX_OUTPUT)
        return error("oversized-output");
    try {
        return {
            ok: true,
            value: validator(JSON.parse(result.stdout))
        };
    } catch (e) {
        return error("malformed-response");
    }
}
function argv(action, id) {
    if (!actions[action])
        return null;
    if (action === "close") {
        var canonical = canonicalId(id);
        return canonical === null ? null : ["frank-cloud-post.sh", action, canonical];
    }
    if (action === "notes") {
        // Read-only list; `id` is a project name already taken from a validated read.
        if (id === null)
            return ["frank-cloud-post.sh", "list", "--type", "note", "--limit", String(NOTES_LIMIT)];
        if (!string(id) || !id.length || id.length > MAX_PROJECT || /[\u0000-\u001f\u007f]/.test(id))
            return null;
        return ["frank-cloud-post.sh", "list", "--type", "note", "--project", id, "--limit", String(NOTES_LIMIT)];
    }
    return ["frank-cloud-post.sh", action];
}
// dispatch(action, argv, callback) is supplied by the Process-owning QML host.
function load(dispatch, done) {
    var request = generation;
    var serial = ++readSerial;
    currentProjection = null;
    if (!guardVerified) {
        done(error("helper HTTPS guard not verified"));
        return;
    }
    if (closePending) {
        done(error("busy"));
        return;
    }
    var results = {};
    var finished = false;
    function receive(action, result) {
        if (finished || !isCurrent(request) || serial !== readSerial || closePending)
            return;
        results[action] = parseResult(result, action === "open" ? page : status);
        if (!results[action].ok) {
            finished = true;
            done(results[action]);
            return;
        }
        if (results["open"] && results["status-view"]) {
            finished = true;
            // Status has its own truncation (including its smaller open-loop summary);
            // only the dedicated /open response determines todo-list completeness.
            var projection = {
                ok: true,
                status: results["status-view"].value,
                todos: results["open"].value.todos,
                truncated: results["open"].value.truncated,
                todosTruncated: results["open"].value.truncated
            };
            currentProjection = projection;
            currentProjection.generation = request;
            reconcileMarks(projection.todos);
            done(projection);
        }
    }
    // Reads only; never dispatch a close during load.
    dispatch("status-view", argv("status-view"), function (r) {
        receive("status-view", r);
    });
    if (!finished)
        dispatch("open", argv("open"), function (r) {
            receive("open", r);
        });
}
function reconcileMarks(todos) {
    Object.keys(marks).forEach(function (id) {
        var present = todos.some(function (todo) {
            return todo.id === id;
        });
        if (present) {
            // A fresh open row wins over even a formerly validated closed entry.
            marks[id].outcome = marks[id].evidence.validated ? "unknown" : "still-open";
        } else if (marks[id].outcome === "still-open") {
            // Absence on a later (possibly truncated) page is not close evidence.
            marks[id].outcome = "unknown";
        }
    });
}
function closeMarks() {
    // Integer-like keys enumerate numerically, so order by close sequence instead.
    return Object.keys(marks).map(function (id) {
        return marks[id];
    }).sort(function (a, b) {
        return a.sequence - b.sequence;
    });
}
function queueVisibleRead(dispatch, done) {
    if (!closePending) {
        load(dispatch, done);
        return false;
    }
    queuedRead = {
        generation: generation,
        dispatch: dispatch,
        done: done
    };
    return true;
}
function finishTransaction(tx, result) {
    if (transaction !== tx || tx.finished)
        return;
    tx.finished = true;
    transaction = null;
    closePending = false;
    // Confirmed closes are settled; keep only outcomes that still need attention.
    Object.keys(marks).forEach(function (id) {
        if (marks[id].outcome === "confirmed")
            delete marks[id];
    });
    marks[tx.id] = {
        id: tx.id,
        text: tx.text.slice(0, 80),
        outcome: result.outcome,
        evidence: tx.evidence,
        refreshFailed: result.refreshFailed === true,
        sequence: ++markSerial
    };
    if (isCurrent(tx.generation))
        tx.done({
            ok: true,
            mark: marks[tx.id],
            projection: result.projection || null
        });
    var queued = queuedRead;
    queuedRead = null;
    if (queued && queued.generation === generation)
        load(queued.dispatch, queued.done);
}
// Called after the Process host has terminated/reaped a timed-out child.
function timeoutClose() {
    if (!transaction)
        return;
    var tx = transaction;
    tx.evidence.error = "timeout";
    finishTransaction(tx, {
        outcome: tx.evidence.validated ? "confirmed-refresh-failed" : "unknown",
        refreshFailed: true
    });
}
function closeTodo(id, dispatch, done) {
    if (closePending)
        return error("busy");
    var canonical = canonicalId(id);
    if (canonical === null)
        return error("invalid-id");
    if (!guardVerified)
        return error("helper HTTPS guard not verified");
    if (!currentProjection || !isCurrent(currentProjection.generation || generation))
        return error("no-fresh-list");
    var todo = currentProjection.todos.filter(function (row) {
        return row.id === canonical && row.type === "todo";
    })[0];
    if (!todo)
        return error("not-open-todo");
    if (typeof dispatch !== "function" || typeof done !== "function")
        return error("invalid-action");
    closePending = true;
    ++readSerial; // Discard earlier read payloads, without suppressing terminal cleanup.
    var tx = {
        id: canonical,
        text: todo.text,
        generation: generation,
        done: done,
        finished: false,
        evidence: {
            command: "close",
            target: canonical,
            httpStatus: "unavailable (helper does not emit HTTP status)",
            timestamp: new Date().toISOString(),
            validated: false
        }
    };
    transaction = tx;
    // One write only. Every response, including a failed one, goes through reconciliation.
    dispatch("close", argv("close", id), function (response) {
        if (tx.finished)
            return;
        var parsed = parseResult(response, function (value) {
            if (!object(value) || !object(value.entry))
                throw new Error("close shape");
            var row = entry(value.entry, "closed");
            if (row.type !== "todo" || row.id !== canonical)
                throw new Error("close mismatch");
            return row;
        });
        tx.evidence.validated = parsed.ok;
        if (!parsed.ok)
            tx.evidence.error = parsed.category;
        var results = {};
        var complete = false;
        function receive(action, value) {
            if (tx.finished || complete)
                return;
            results[action] = parseResult(value, action === "open" ? page : status);
            if (results["open"] && results["status-view"]) {
                complete = true;
                var fresh = results["open"].ok && results["status-view"].ok;
                var present = fresh && results["open"].value.todos.some(function (row) {
                    return row.id === canonical;
                });
                var outcome = !fresh ? (parsed.ok ? "confirmed-refresh-failed" : "unknown") : parsed.ok ? (present ? "unknown" : "confirmed") : (present ? "still-open" : "unknown");
                var projection = fresh ? {
                    ok: true,
                    status: results["status-view"].value,
                    todos: results["open"].value.todos,
                    truncated: results["open"].value.truncated,
                    todosTruncated: results["open"].value.truncated
                } : null;
                if (projection) {
                    if (isCurrent(tx.generation)) {
                        currentProjection = projection;
                        currentProjection.generation = generation;
                    }
                    if (isCurrent(tx.generation))
                        reconcileMarks(projection.todos);
                } else if (isCurrent(tx.generation))
                    currentProjection = null;
                finishTransaction(tx, {
                    outcome: outcome,
                    projection: projection,
                    refreshFailed: !fresh
                });
            }
        }
        dispatch("status-view", argv("status-view"), function (r) {
            receive("status-view", r);
        });
        if (!tx.finished)
            dispatch("open", argv("open"), function (r) {
                receive("open", r);
            });
    });
    return {
        ok: true,
        pending: true
    };
}
// Notes for one project group from the current list. Unassigned notes have no
// server-side filter, so fetch all recent notes and keep the ones without a project.
function loadNotes(key, dispatch, done) {
    var request = generation;
    var serial = ++notesSerial;
    if (!guardVerified) {
        done(error("helper HTTPS guard not verified"));
        return;
    }
    if (closePending) {
        done(error("busy"));
        return;
    }
    if (!currentProjection || !isCurrent(currentProjection.generation || generation)) {
        done(error("no-fresh-list"));
        return;
    }
    var project = null;
    if (key !== "unassigned") {
        var match = currentProjection.todos.filter(function (todo) {
            return todo.project && "project:" + todo.project === key;
        })[0];
        if (!match) {
            done(error("unknown-project"));
            return;
        }
        project = match.project;
    }
    if (notesCache[key]) {
        done(notesCache[key]);
        return;
    }
    var args = argv("notes", project);
    if (!args) {
        done(error("unknown-project"));
        return;
    }
    dispatch("notes", args, function (result) {
        // Drop late answers for an older summon or a project the cursor already left.
        if (!isCurrent(request) || serial !== notesSerial)
            return;
        var parsed = parseResult(result, notesPage);
        if (!parsed.ok) {
            done(parsed);
            return;
        }
        var notes = parsed.value.notes.filter(function (note) {
            return project === null ? !note.project : note.project === project;
        });
        notesCache[key] = {
            ok: true,
            key: key,
            project: project,
            notes: notes,
            truncated: parsed.value.truncated
        };
        done(notesCache[key]);
    });
}
