import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "FrankAdapter.js" as FrankAdapter
import "NoteFormat.js" as NoteFormat

Item {
    id: root

    // Shares the [menu] surface tokens, like Omarchy's clipboard overlay, so
    // themes that style the menu also style this overlay.
    property color background: Color.menu.background
    property color foreground: Color.menu.text
    property color muted: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.62)
    property color accent: Color.accent
    property color outline: Color.menu.border
    property var borderSpec: Border.surfaceSpec("menu", "border", outline, Math.max(1, Style.space(2)))
    property color scrim: Color.menu.scrim
    property color selectedBackground: Color.menu.selectedBackground
    property color selectedText: Color.menu.selectedText
    readonly property int cornerRadius: Style.cornerRadius
    property string fontFamily: Style.font.menuFamily
    property int contentMargin: Style.spacing.panelPadding
    property int contentSpacing: Style.spacing.md
    property int listCardWidth: Math.max(1, Math.min(Style.space(760), panel.width - Style.gapsOut * 2))
    // Opening notes grows the card on both sides; the todo column keeps its width.
    property int notesCardWidth: Math.max(root.listCardWidth, Math.min(Style.space(1240), panel.width - Style.gapsOut * 2))
    property int cardWidth: root.notesOpen ? root.notesCardWidth : root.listCardWidth
    property int cardHeight: Math.max(1, Math.min(Style.space(600), panel.height - Style.gapsOut * 2))
    property int rowHeight: Math.max(Style.space(38), Style.font.title + Style.spacing.rowPaddingX * 2)

    property bool budgetExpired: false
    property var closeMark: null
    property string closingId: ""
    property var collapsedProjects: ({})
    property bool confirmOpen: false
    property var confirmTodo: null
    property bool cursorActive: false
    property var displayRows: root.groupedTodoRows()
    property string errorCategory: ""
    property string notice: ""
    property bool notesOpen: false
    property string notesKey: ""
    property string notesProject: ""
    property var notesResult: null
    property string notesState: ""
    property bool opened: false
    property var pendingCallbacks: ({})
    property var pendingLaunches: ({})
    property bool probing: false
    property var projection: null
    // Reads start only after the isolated HTTPS-guard probe succeeds.
    property string readState: "loading"
    property int selectedIndex: 0
    onSelectedIndexChanged: if (root.notesOpen)
        Qt.callLater(root.syncNotes)
    property var signalsToSend: []
    property var timedOut: ({})
    property var unknownMarks: []
    property bool wantsRead: false

    function describe(category) {
        var messages = {
            "helper HTTPS guard not verified": "The Frank helper's HTTPS guard isn't verified. Install the patched helper (patches/README.md), then refresh.",
            "busy": "A close is already in progress.",
            "no-fresh-list": "The list is out of date. Refresh before closing a todo.",
            "not-open-todo": "That todo is no longer open in the latest read.",
            "invalid-id": "That todo has an invalid ID.",
            "invalid-action": "The overlay tried an unsupported action.",
            "timeout": "Frank didn't respond in time.",
            "helper": "The Frank helper failed. Check your connection and credentials.",
            "malformed-response": "Frank sent a response the overlay couldn't read.",
            "oversized-output": "Frank's response was too large to show.",
            "refresh-failed": "The close finished, but the list couldn't be refreshed.",
            "unknown-project": "That project isn't in the current list. Refresh and try again."
        };
        return messages[category] || category;
    }
    function rowKey(row) {
        return !row ? "" : row.kind === "project" ? "project:" + row.key : "todo:" + row.todo.id;
    }
    function setProjection(value) {
        // Keep the cursor on the same row across reloads when it still exists.
        var key = root.rowKey(root.displayRows[root.selectedIndex]);
        root.projection = value;
        var rows = root.displayRows;
        var index = 0;
        for (var i = 0; i < rows.length; i++) {
            if (root.rowKey(rows[i]) === key) {
                index = i;
                break;
            }
        }
        root.selectedIndex = Math.min(index, Math.max(0, rows.length - 1));
    }
    function requestClose(todo) {
        if (!todo || !root.opened || root.readState !== "ready" || FrankAdapter.isClosePending())
            return;
        root.notice = "";
        root.confirmTodo = todo;
        closeConfirm.selectedIndex = 1;
        root.confirmOpen = true;
    }
    function cancelClose() {
        root.confirmOpen = false;
        root.confirmTodo = null;
        pointerGate.reset();
        Qt.callLater(function () {
            if (root.opened)
                keyCatcher.forceActiveFocus();
        });
    }
    function confirmClose() {
        var todo = root.confirmTodo;
        root.cancelClose();
        if (todo)
            root.checkTodo(todo.id);
    }
    function checkTodo(id) {
        if (!root.opened || root.readState !== "ready" || FrankAdapter.isClosePending())
            return;
        // Rows store validated IDs as strings; the adapter only accepts the integer.
        var start = FrankAdapter.closeTodo(Number(id), root.dispatch, function (result) {
            closeBudget.stop();
            root.closingId = "";
            if (!root.opened)
                return;
            root.showMarks();
            root.setProjection(result.projection);
            root.readState = result.projection ? (result.projection.todos.length ? "ready" : "empty") : "refresh-failed";
        });
        if (!start.ok) {
            // The list is still valid; report why nothing happened instead of locking it.
            root.notice = root.describe(start.category);
            return;
        }
        root.closingId = String(id);
        root.readState = "closing";
        closeBudget.restart();
    }
    function close() {
        root.hideNotes();
        root.cancelClose();
        FrankAdapter.hide();
        root.opened = false;
        root.wantsRead = false;
        keyCatcher.focus = false;
    }
    function helper(action) {
        return action === "open" ? {
            proc: openProc,
            deadline: openDeadline,
            grace: openGrace
        } : action === "close" ? {
            proc: closeProc,
            deadline: closeDeadline,
            grace: closeGrace
        } : action === "notes" ? {
            proc: notesProc,
            deadline: notesDeadline,
            grace: notesGrace
        } : {
            proc: statusProc,
            deadline: statusDeadline,
            grace: statusGrace
        };
    }
    function completed(action, code, proc, timer) {
        timer.stop();
        root.helper(action).grace.stop();
        var callback = root.pendingCallbacks[action];
        delete root.pendingCallbacks[action];
        if (callback && !root.budgetExpired) {
            var response = root.timedOut[action] ? {
                category: "timeout"
            } : {
                exitCode: code,
                stdout: String(proc.stdout.text || "")
            };
            if (response.category || code !== 0)
                root.onError(action, response.category || "helper");
            callback(response);
        }
        root.timedOut[action] = false;
        if (!FrankAdapter.isClosePending())
            closeBudget.stop();
        root.launchPending(action);
    }
    function dispatch(action, args, done) {
        if (action !== "status-view" && action !== "open" && action !== "close" && action !== "notes") {
            done({
                category: "invalid-action"
            });
            return;
        }
        var proc = root.helper(action).proc;
        if (root.pendingCallbacks[action] || proc.running) {
            if (action === "close") {
                done({
                    category: "busy"
                });
            } else {
                // One latest read after reaping an older summon; never queue a write.
                root.pendingLaunches[action] = {
                    args: args,
                    done: done
                };
            }
            return;
        }
        root.pendingCallbacks[action] = done;
        proc.command = args;
        proc.running = Boolean(args.length);
        root.helper(action).deadline.restart();
    }
    function expireBudget() {
        root.budgetExpired = true;
        if (closeProc.running)
            root.stopChild("close", closeProc, closeGrace);
        if (statusProc.running)
            root.stopChild("status-view", statusProc, statusGrace);
        if (openProc.running)
            root.stopChild("open", openProc, openGrace);
        if (notesProc.running)
            root.stopChild("notes", notesProc, notesGrace);
        budgetGrace.restart();
    }
    function finishBudget() {
        closeBudget.stop();
        budgetGrace.stop();
        root.budgetExpired = false;
        FrankAdapter.timeoutClose();
        if (!FrankAdapter.isClosePending())
            root.closingId = "";
        if (root.opened && !FrankAdapter.isClosePending())
            root.showMarks();
    }
    function launchPending(action) {
        var proc = root.helper(action).proc;
        if (proc.running || root.pendingCallbacks[action])
            return;
        var next = root.pendingLaunches[action];
        delete root.pendingLaunches[action];
        if (next)
            Qt.callLater(function () {
                root.dispatch(action, next.args, next.done);
            });
    }
    function onError(action, category) {
        // The only transport-error path: no raw stderr, tokens, or entry text.
        root.errorCategory = action + ": " + category;
        // Notes failures stay in the notes pane; the todo list is still valid.
        if (action !== "notes" && !FrankAdapter.isClosePending() && root.opened)
            root.readState = category;
    }
    function open(payloadJson) {
        FrankAdapter.summon();
        root.collapsedProjects = ({});
        root.hideNotes();
        root.notice = "";
        root.cursorActive = true;
        root.selectedIndex = 0;
        pointerGate.reset();
        root.opened = true;
        if (FrankAdapter.isClosePending()) {
            root.projection = null;
            root.readState = "waiting-for-close";
            FrankAdapter.queueVisibleRead(root.dispatch, function (result) {
                if (!root.opened)
                    return;
                root.setProjection(result.ok ? result : null);
                root.readState = result.ok ? (result.todos.length ? "ready" : "empty") : result.category;
                root.showMarks();
            });
        } else
            root.refresh();
        Qt.callLater(function () {
            if (root.opened)
                keyCatcher.forceActiveFocus();
        });
    }
    function reapChild(action, proc, grace, deadline) {
        grace.stop();
        if (proc.running) {
            root.signalChild(proc, "-KILL");
            proc.running = false;
        }
        // A killed child may have no exit notification; discard its late payload.
        root.completed(action, -1, proc, deadline);
    }
    function groupedTodoRows() {
        if (!root.projection)
            return [];
        var rows = [];
        FrankAdapter.groupTodosByProject(root.projection.todos).forEach(function (group) {
            var collapsed = root.collapsedProjects[group.key] === true;
            rows.push({
                kind: "project",
                key: group.key,
                project: group.project,
                count: group.todos.length,
                collapsed: collapsed
            });
            if (collapsed)
                return;
            group.todos.forEach(function (todo) {
                rows.push({
                    kind: "todo",
                    key: group.key,
                    todo: todo
                });
            });
        });
        return rows;
    }
    function setCollapsed(key, collapsed) {
        var next = {};
        Object.keys(root.collapsedProjects).forEach(function (existing) {
            next[existing] = root.collapsedProjects[existing];
        });
        next[key] = collapsed;
        // Collapsing hides the cursor's todo, so move the cursor to its heading.
        var current = root.displayRows[root.selectedIndex];
        root.collapsedProjects = next;
        if (current && current.key === key) {
            for (var i = 0; i < root.displayRows.length; i++) {
                if (root.displayRows[i].kind === "project" && root.displayRows[i].key === key) {
                    root.selectedIndex = i;
                    break;
                }
            }
        }
    }
    function toggleProject(key) {
        root.setCollapsed(key, root.collapsedProjects[key] !== true);
    }
    function select(delta) {
        var count = root.displayRows.length;
        if (!count)
            return;
        pointerGate.reset();
        if (!root.cursorActive) {
            root.cursorActive = true;
            root.selectedIndex = delta < 0 ? count - 1 : 0;
        } else if (Math.abs(delta) === 1)
            root.selectedIndex = (root.selectedIndex + delta + count) % count;
        else
            root.selectedIndex = Math.max(0, Math.min(count - 1, root.selectedIndex + delta));
        todoList.positionViewAtIndex(root.selectedIndex, ListView.Contain);
    }
    function selectAbsolute(index) {
        var count = root.displayRows.length;
        if (!count)
            return;
        pointerGate.reset();
        root.cursorActive = true;
        root.selectedIndex = Math.max(0, Math.min(index, count - 1));
        todoList.positionViewAtIndex(root.selectedIndex, ListView.Contain);
    }
    function selectFromPointer(index, item, mouse) {
        if (!pointerGate.moved(item, mouse))
            return;
        root.cursorActive = true;
        root.selectedIndex = index;
    }
    function activateRow(index) {
        var row = root.displayRows[index];
        if (!row)
            return;
        if (row.kind === "project")
            root.toggleProject(row.key);
        else
            root.requestClose(row.todo);
    }
    function foldSelected() {
        var row = root.cursorActive ? root.displayRows[root.selectedIndex] : null;
        if (!row)
            return;
        root.setCollapsed(row.key, row.kind === "project" ? !row.collapsed : true);
        todoList.positionViewAtIndex(root.selectedIndex, ListView.Contain);
    }
    function refresh() {
        if (FrankAdapter.isClosePending())
            return;
        root.notice = "";
        // A failed guard probe is retried here, so installing the patched helper
        // takes effect without restarting the shell.
        if (!FrankAdapter.isGuardVerified() && !root.probing) {
            if (!root.startProbe())
                return;
        }
        if (root.probing) {
            root.projection = null;
            root.readState = "loading";
            root.wantsRead = true;
            return;
        }
        root.loadNow();
    }
    function loadNow() {
        root.wantsRead = false;
        root.notesResult = null;
        root.notesState = root.notesOpen ? "loading" : "";
        root.projection = null;
        root.readState = "loading";
        FrankAdapter.load(root.dispatch, function (result) {
            if (!root.opened)
                return;
            if (!result.ok) {
                root.projection = null;
                root.readState = result.category;
            } else {
                root.setProjection(result);
                root.readState = result.todos.length ? "ready" : "empty";
            }
            root.showMarks();
            if (root.notesOpen)
                root.syncNotes();
        });
    }
    function startProbe() {
        if (statusProc.running || root.pendingCallbacks["status-view"])
            return false;
        // The probe script creates a temporary HOME/XDG tree, clears inherited
        // Frank variables and inserts a fake curl ahead of all real clients.
        FrankAdapter.resetGuard();
        root.probing = true;
        statusProc.command = [Qt.resolvedUrl("FrankGuardProbe.sh").toString().replace(/^file:\/\//, "")];
        statusProc.running = Boolean(statusProc.command.length);
        statusDeadline.restart();
        return true;
    }
    function cursorProjectKey() {
        var row = root.displayRows[root.selectedIndex];
        return row ? row.key : "";
    }
    function showNotes(key) {
        if (!key || root.readState !== "ready" && root.readState !== "empty")
            return;
        root.notesOpen = true;
        root.loadNotesFor(key);
    }
    function scrollNotes(direction) {
        var step = notesScroll.height * 0.8;
        var limit = Math.max(0, notesScroll.contentHeight - notesScroll.height);
        notesScroll.contentY = Math.max(0, Math.min(limit, notesScroll.contentY + direction * step));
    }
    function hideNotes() {
        root.notesOpen = false;
        root.notesKey = "";
        root.notesProject = "";
        root.notesResult = null;
        root.notesState = "";
    }
    function syncNotes() {
        // With the pane open, the notes follow the project under the cursor.
        var key = root.cursorProjectKey();
        if (root.notesOpen && key && (key !== root.notesKey || !root.notesResult))
            root.loadNotesFor(key);
    }
    function loadNotesFor(key) {
        var group = root.displayRows.filter(function (row) {
            return row.kind === "project" && row.key === key;
        })[0];
        root.notesKey = key;
        root.notesProject = group ? group.project : "";
        root.notesResult = null;
        root.notesState = "loading";
        notesScroll.contentY = 0;
        FrankAdapter.loadNotes(key, root.dispatch, function (result) {
            if (!root.opened || !root.notesOpen || root.notesKey !== key)
                return;
            root.notesResult = result.ok ? result : null;
            root.notesState = result.ok ? "ready" : result.category;
        });
    }
    function ago(iso) {
        var then = Date.parse(iso);
        if (isNaN(then))
            return "";
        var minutes = Math.max(0, Math.round((Date.now() - then) / 60000));
        if (minutes < 1)
            return "just now";
        if (minutes < 60)
            return minutes + "m ago";
        if (minutes < 60 * 24)
            return Math.round(minutes / 60) + "h ago";
        if (minutes < 60 * 24 * 2)
            return "yesterday";
        if (minutes < 60 * 24 * 30)
            return Math.round(minutes / 1440) + "d ago";
        return new Date(then).toLocaleDateString(Qt.locale(), Locale.ShortFormat);
    }
    function sendNextSignal() {
        if (signalProc.running || !root.signalsToSend.length)
            return;
        signalProc.command = root.signalsToSend.shift();
        signalProc.running = true;
    }
    function showMarks() {
        var all = FrankAdapter.closeMarks();
        root.closeMark = all.length ? all[all.length - 1] : null;
        root.unknownMarks = all.filter(function (mark) {
            return mark.outcome === "unknown" && mark !== root.closeMark;
        });
    }
    function signalChild(proc, signalName) {
        if (!proc.running || !proc.processId)
            return;
        root.signalsToSend.push(["kill", signalName, String(proc.processId)]);
        root.sendNextSignal();
    }
    function stopChild(action, proc, grace) {
        root.timedOut[action] = true;
        root.signalChild(proc, "-TERM");
        grace.restart();
    }
    function toggle() {
        if (root.opened)
            root.close();
        else
            root.open("{}");
    }

    Component.onCompleted: root.startProbe()

    PointerMoveGate {
        id: pointerGate

        referenceItem: card
    }

    // Keeping helper processes children of the overlay runs them inside the
    // existing shell.
    // Only fixed argv actions are declared; no shell command strings or token I/O.
    Process {
        id: statusProc

        command: ["frank-cloud-post.sh", "status-view"]
        running: false

        stdout: StdioCollector {
            waitForEnd: true
        }

        onExited: function (exitCode) {
            if (root.probing) {
                statusDeadline.stop();
                root.probing = false;
                FrankAdapter.setGuardProbeResult(exitCode);
                if (root.opened && root.wantsRead)
                    root.loadNow();
                Qt.callLater(function () {
                    root.launchPending("status-view");
                });
            } else
                root.completed("status-view", exitCode, statusProc, statusDeadline);
        }
        onRunningChanged: if (!running && !root.probing)
            root.launchPending("status-view")
    }
    Process {
        id: openProc

        command: ["frank-cloud-post.sh", "open"]
        running: false

        stdout: StdioCollector {
            waitForEnd: true
        }

        onExited: function (exitCode) {
            root.completed("open", exitCode, openProc, openDeadline);
        }
        onRunningChanged: if (!running)
            root.launchPending("open")
    }
    Process {
        id: closeProc

        // Adapter supplies a validated, canonical ID before this is started.
        command: ["frank-cloud-post.sh", "close"]
        running: false

        stdout: StdioCollector {
            waitForEnd: true
        }

        onExited: function (exitCode) {
            root.completed("close", exitCode, closeProc, closeDeadline);
        }
    }
    Process {
        id: notesProc

        // Read-only note list; the adapter supplies the validated project filter.
        command: ["frank-cloud-post.sh", "list"]
        running: false

        stdout: StdioCollector {
            waitForEnd: true
        }

        onExited: function (exitCode) {
            root.completed("notes", exitCode, notesProc, notesDeadline);
        }
        onRunningChanged: if (!running)
            root.launchPending("notes")
    }
    Timer {
        id: notesDeadline

        interval: 15000

        onTriggered: root.stopChild("notes", notesProc, notesGrace)
    }
    Timer {
        id: notesGrace

        interval: 2000

        onTriggered: root.reapChild("notes", notesProc, notesGrace, notesDeadline)
    }
    Timer {
        id: statusDeadline

        interval: 15000

        onTriggered: {
            if (root.probing) {
                statusProc.running = false;
                root.probing = false;
                FrankAdapter.setGuardProbeResult(-1);
                root.onError("guard", "helper HTTPS guard not verified");
                if (root.opened && root.wantsRead)
                    root.loadNow();
            } else
                root.stopChild("status-view", statusProc, statusGrace);
        }
    }
    Timer {
        id: openDeadline

        interval: 15000

        onTriggered: {
            root.stopChild("open", openProc, openGrace);
        }
    }
    Process {
        id: signalProc

        running: false

        onExited: root.sendNextSignal()
    }
    Timer {
        id: statusGrace

        interval: 2000

        onTriggered: root.reapChild("status-view", statusProc, statusGrace, statusDeadline)
    }
    Timer {
        id: openGrace

        interval: 2000

        onTriggered: root.reapChild("open", openProc, openGrace, openDeadline)
    }
    Timer {
        id: closeGrace

        interval: 2000

        onTriggered: root.reapChild("close", closeProc, closeGrace, closeDeadline)
    }
    Timer {
        id: closeDeadline

        interval: 15000

        onTriggered: root.stopChild("close", closeProc, closeGrace)
    }
    Timer {
        id: closeBudget

        // Reserve 2 s for SIGTERM grace and reaping within the 45 s budget.
        interval: 43000

        onTriggered: root.expireBudget()
    }
    Timer {
        id: budgetGrace

        interval: 2000

        onTriggered: root.finishBudget()
    }
    PanelWindow {
        id: panel

        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "nmorton-frank"
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        visible: root.opened

        anchors {
            bottom: true
            left: true
            right: true
            top: true
        }
        Rectangle {
            anchors.fill: parent
            color: root.scrim
        }
        MouseArea {
            anchors.fill: parent

            onClicked: root.close()
        }
        BorderSurface {
            id: card

            anchors.centerIn: parent
            borderSpec: root.borderSpec
            color: root.background
            height: root.cardHeight
            padding: root.contentMargin
            radius: root.cornerRadius
            width: root.cardWidth

            Behavior on width {
                enabled: root.opened

                NumberAnimation {
                    duration: 160
                    easing.type: Easing.OutCubic
                }
            }

            MouseArea {
                anchors.fill: parent

                onClicked: {}
            }
            Item {
                id: keyCatcher

                Keys.priority: Keys.BeforeItem
                anchors.fill: parent
                focus: true
                z: root.confirmOpen ? 20 : 0

                Keys.onPressed: function (event) {
                    if (root.confirmOpen) {
                        if (closeConfirm.handleKey(event))
                            event.accepted = true;
                        return;
                    }
                    var ready = root.readState === "ready";
                    var shifted = (event.modifiers & Qt.ShiftModifier) !== 0;
                    if (root.notesOpen && shifted && (event.key === Qt.Key_Up || event.key === Qt.Key_K || event.key === Qt.Key_Down || event.key === Qt.Key_J)) {
                        root.scrollNotes(event.key === Qt.Key_Up || event.key === Qt.Key_K ? -1 : 1);
                    } else if (event.key === Qt.Key_Escape) {
                        // Esc steps back: hide the notes pane first, then dismiss.
                        if (root.notesOpen)
                            root.hideNotes();
                        else
                            root.close();
                    } else if (event.key === Qt.Key_R || event.key === Qt.Key_F5) {
                        root.refresh();
                    } else if (!ready) {
                        return;
                    } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K || event.key === Qt.Key_Backtab) {
                        root.select(-1);
                    } else if (event.key === Qt.Key_Down || event.key === Qt.Key_J || event.key === Qt.Key_Tab) {
                        root.select(1);
                    } else if (event.key === Qt.Key_PageUp) {
                        root.select(-6);
                    } else if (event.key === Qt.Key_PageDown) {
                        root.select(6);
                    } else if (event.key === Qt.Key_Home) {
                        root.selectAbsolute(0);
                    } else if (event.key === Qt.Key_End) {
                        root.selectAbsolute(root.displayRows.length - 1);
                    } else if (event.key === Qt.Key_Right || event.key === Qt.Key_L) {
                        root.showNotes(root.cursorProjectKey());
                    } else if (event.key === Qt.Key_Left || event.key === Qt.Key_H) {
                        root.hideNotes();
                    } else if (event.key === Qt.Key_Z) {
                        root.foldSelected();
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                        if (root.cursorActive)
                            root.activateRow(root.selectedIndex);
                        else
                            root.select(1);
                    } else {
                        return;
                    }
                    event.accepted = true;
                }

                ConfirmDialog {
                    id: closeConfirm

                    anchors.fill: parent
                    background: root.background
                    cancelText: "Keep"
                    confirmText: "Close"
                    cornerRadius: root.cornerRadius
                    fontFamily: root.fontFamily
                    foreground: root.foreground
                    message: root.confirmTodo ? "Close “" + root.confirmTodo.text + "” in Frank? It is recorded under the agent credential." : ""
                    opened: root.confirmOpen
                    scrim: root.scrim
                    selectedBackground: root.selectedBackground
                    selectedText: root.selectedText
                    z: 10

                    onCanceled: root.cancelClose()
                    onConfirmed: root.confirmClose()
                }
            }
            Item {
                anchors.bottomMargin: card.contentBottomInset
                anchors.fill: parent
                anchors.leftMargin: card.contentLeftInset
                anchors.rightMargin: card.contentRightInset
                anchors.topMargin: card.contentTopInset

                Column {
                    id: headerBlock

                    spacing: Style.spacing.sm
                    width: parent.width

                    Item {
                        height: Math.max(titleText.implicitHeight, countText.implicitHeight)
                        width: parent.width

                        Text {
                            id: titleText

                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.display
                            font.weight: Font.Bold
                            text: "Frank"
                            textFormat: Text.PlainText
                        }
                        Text {
                            id: countText

                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            color: root.muted
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            text: root.projection ? root.projection.todos.length + (root.projection.todosTruncated ? "+ open" : " open") : ""
                            textFormat: Text.PlainText
                        }
                    }
                    Text {
                        color: root.foreground
                        elide: Text.ElideRight
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.title
                        maximumLineCount: 2
                        text: root.projection && root.projection.status.active ? (root.projection.status.active.title ? root.projection.status.active.title + ": " : "") + root.projection.status.active.text : "No status set"
                        textFormat: Text.PlainText
                        visible: root.projection !== null
                        width: parent.width
                        wrapMode: Text.WordWrap
                    }
                    Text {
                        color: root.muted
                        elide: Text.ElideRight
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        text: root.projection && root.projection.status.activeRightNow.length ? "Active now · " + root.projection.status.activeRightNow.map(function (item) {
                            return item.text;
                        }).join(" · ") : ""
                        textFormat: Text.PlainText
                        visible: text.length > 0
                        width: parent.width
                    }
                }
                Rectangle {
                    id: headerRule

                    anchors.top: headerBlock.bottom
                    anchors.topMargin: root.contentSpacing * 2
                    color: Util.alpha(root.outline, 0.28)
                    height: Style.normalBorderWidth
                    width: parent.width
                }
                Item {
                    id: listArea

                    anchors.bottom: footerRule.top
                    anchors.bottomMargin: root.contentSpacing * 2
                    anchors.left: parent.left
                    anchors.top: headerRule.bottom
                    width: Math.min(parent.width, root.listCardWidth - card.contentLeftInset - card.contentRightInset)
                    anchors.topMargin: root.contentSpacing * 2

                    ListView {
                        id: todoList

                        anchors.fill: parent
                        boundsBehavior: Flickable.StopAtBounds
                        clip: true
                        model: root.displayRows
                        spacing: Style.space(2)

                        delegate: Rectangle {
                            id: row

                            required property int index
                            required property var modelData
                            readonly property bool hasCursor: root.cursorActive && root.selectedIndex === index
                            readonly property bool isProject: modelData.kind === "project"
                            readonly property bool isClosing: !isProject && root.closingId === modelData.todo.id

                            color: hasCursor ? root.selectedBackground : "transparent"
                            height: isProject ? root.rowHeight + (index > 0 ? Style.spacing.lg : 0) : Math.max(root.rowHeight, todoLabel.implicitHeight + Style.spacing.lg * 2)
                            radius: root.cornerRadius
                            width: ListView.view.width

                            Row {
                                anchors.fill: parent
                                anchors.leftMargin: Style.spacing.rowPaddingX
                                anchors.rightMargin: Style.spacing.rowPaddingX + notesLink.width + Style.spacing.xl
                                anchors.topMargin: row.index > 0 ? Style.spacing.lg : 0
                                spacing: Style.spacing.xl
                                visible: row.isProject

                                Text {
                                    id: projectArrow

                                    anchors.verticalCenter: parent.verticalCenter
                                    color: row.hasCursor ? root.selectedText : root.accent
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.heading
                                    text: row.isProject ? (modelData.collapsed ? "▸" : "▾") : ""
                                    textFormat: Text.PlainText
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: row.hasCursor ? root.selectedText : root.accent
                                    elide: Text.ElideRight
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.heading
                                    font.weight: Font.Bold
                                    text: row.isProject ? modelData.project : ""
                                    textFormat: Text.PlainText
                                    width: parent.width - projectArrow.implicitWidth - projectCount.implicitWidth - parent.spacing * 2
                                }
                                Text {
                                    id: projectCount

                                    anchors.verticalCenter: parent.verticalCenter
                                    color: row.hasCursor ? root.selectedText : root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.bodySmall
                                    text: row.isProject ? modelData.count + (modelData.count === 1 ? " todo" : " todos") : ""
                                    textFormat: Text.PlainText
                                }
                            }
                            Row {
                                anchors.fill: parent
                                anchors.leftMargin: Style.spacing.rowPaddingX
                                anchors.rightMargin: Style.spacing.rowPaddingX
                                opacity: row.isClosing ? 0.55 : 1
                                spacing: Style.spacing.xl
                                visible: !row.isProject

                                Text {
                                    id: todoBox

                                    anchors.verticalCenter: parent.verticalCenter
                                    color: row.hasCursor ? root.selectedText : root.foreground
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.heading
                                    text: row.isClosing ? "󰔟" : "󰄱"
                                    textFormat: Text.PlainText
                                }
                                Text {
                                    id: todoLabel

                                    anchors.verticalCenter: parent.verticalCenter
                                    color: row.hasCursor ? root.selectedText : root.foreground
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.title
                                    text: row.isProject ? "" : modelData.todo.text
                                    textFormat: Text.PlainText
                                    width: parent.width - todoBox.implicitWidth - parent.spacing
                                    wrapMode: Text.WordWrap
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                enabled: root.readState === "ready"
                                hoverEnabled: true

                                onClicked: {
                                    root.cursorActive = true;
                                    root.selectedIndex = row.index;
                                    root.activateRow(row.index);
                                }
                                onPositionChanged: function (mouse) {
                                    root.selectFromPointer(row.index, row, mouse);
                                }
                            }
                            Text {
                                id: notesLink

                                readonly property bool showing: root.notesOpen && root.notesKey === (row.isProject ? modelData.key : "")

                                anchors.right: parent.right
                                anchors.rightMargin: Style.spacing.rowPaddingX
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.verticalCenterOffset: row.index > 0 ? Style.spacing.lg / 2 : 0
                                color: row.hasCursor ? root.selectedText : notesLinkArea.containsMouse || showing ? root.accent : root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                text: showing ? "notes ‹" : "notes ›"
                                textFormat: Text.PlainText
                                visible: row.isProject

                                MouseArea {
                                    id: notesLinkArea

                                    anchors.fill: parent
                                    anchors.margins: -Style.spacing.sm
                                    cursorShape: Qt.PointingHandCursor
                                    hoverEnabled: true

                                    onClicked: {
                                        root.cursorActive = true;
                                        root.selectedIndex = row.index;
                                        if (notesLink.showing)
                                            root.hideNotes();
                                        else
                                            root.showNotes(modelData.key);
                                    }
                                }
                            }
                        }
                    }
                    Column {
                        anchors.centerIn: parent
                        spacing: Style.space(8)
                        visible: root.displayRows.length === 0
                        width: parent.width

                        Text {
                            color: root.selectedText
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.displayLarge
                            horizontalAlignment: Text.AlignHCenter
                            opacity: 0.8
                            text: root.readState === "empty" ? "󰗡" : root.readState === "loading" || root.readState === "waiting-for-close" || root.readState === "closing" ? "󰔟" : "󰗖"
                            textFormat: Text.PlainText
                            width: parent.width
                        }
                        Text {
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.title
                            horizontalAlignment: Text.AlignHCenter
                            opacity: 0.7
                            text: root.readState === "empty" ? "No open todos" : root.readState === "loading" ? "Loading Frank…" : root.readState === "waiting-for-close" ? "Waiting for the pending close to finish…" : root.readState === "closing" ? "Closing todo…" : root.describe(root.readState)
                            textFormat: Text.PlainText
                            width: parent.width
                            wrapMode: Text.WordWrap
                        }
                    }
                }
                Item {
                    id: notesArea

                    anchors.bottom: listArea.bottom
                    anchors.left: listArea.right
                    anchors.right: parent.right
                    anchors.top: listArea.top
                    clip: true
                    opacity: root.notesOpen ? 1 : 0
                    visible: width > 1 && opacity > 0

                    Behavior on opacity {
                        NumberAnimation {
                            duration: 160
                            easing.type: Easing.OutCubic
                        }
                    }

                    Rectangle {
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.leftMargin: root.contentMargin / 2
                        anchors.top: parent.top
                        color: Util.alpha(root.outline, 0.28)
                        width: Style.normalBorderWidth
                    }
                    Item {
                        anchors.fill: parent
                        anchors.leftMargin: root.contentMargin
                        anchors.rightMargin: Style.spacing.rowPaddingX

                        Item {
                            id: notesHeader

                            height: Math.max(notesTitle.implicitHeight, notesCount.implicitHeight)
                            width: parent.width

                            Text {
                                id: notesTitle

                                anchors.left: parent.left
                                anchors.right: notesCount.left
                                anchors.rightMargin: Style.spacing.xl
                                anchors.verticalCenter: parent.verticalCenter
                                color: root.accent
                                elide: Text.ElideRight
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.heading
                                font.weight: Font.Bold
                                text: (root.notesProject || "Unassigned") + " notes"
                                textFormat: Text.PlainText
                            }
                            Text {
                                id: notesCount

                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                text: root.notesResult ? root.notesResult.notes.length + (root.notesResult.truncated ? "+" : "") + (root.notesResult.notes.length === 1 ? " note" : " notes") : ""
                                textFormat: Text.PlainText
                            }
                        }
                        Flickable {
                            id: notesScroll

                            anchors.bottom: parent.bottom
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: notesHeader.bottom
                            anchors.topMargin: root.contentSpacing * 2
                            boundsBehavior: Flickable.StopAtBounds
                            clip: true
                            contentHeight: notesColumn.implicitHeight
                            visible: root.notesState === "ready" && root.notesResult && root.notesResult.notes.length > 0

                            Column {
                                id: notesColumn

                                spacing: Style.spacing.xxl
                                width: notesScroll.width

                                Repeater {
                                    model: root.notesResult ? root.notesResult.notes : []

                                    delegate: Column {
                                        required property var modelData

                                        spacing: Style.spacing.xs
                                        width: notesColumn.width

                                        Text {
                                            color: root.foreground
                                            font.family: root.fontFamily
                                            font.pixelSize: Style.font.title
                                            font.weight: Font.DemiBold
                                            text: modelData.title || ""
                                            textFormat: Text.PlainText
                                            visible: text.length > 0
                                            width: parent.width
                                            wrapMode: Text.WordWrap
                                        }
                                        Column {
                                            spacing: Style.spacing.sm
                                            width: parent.width

                                            Repeater {
                                                // Escaped note text plus formatter tags only; see NoteFormat.js.
                                                model: NoteFormat.format(modelData.text, root.accent.toString())

                                                delegate: Item {
                                                    required property var modelData
                                                    readonly property bool listItem: modelData.kind === "bullet" || modelData.kind === "numbered"
                                                    // Fixed marker column so "1." and "10." items line up.
                                                    readonly property real markerWidth: listItem ? Style.space(modelData.kind === "numbered" ? 26 : 16) : 0
                                                    readonly property real indent: modelData.level * Style.spacing.xxxl

                                                    height: blockText.implicitHeight
                                                    width: parent.width

                                                    Text {
                                                        color: modelData.kind === "bullet" ? root.accent : root.muted
                                                        font.family: root.fontFamily
                                                        font.pixelSize: Style.font.body
                                                        text: modelData.marker
                                                        textFormat: Text.PlainText
                                                        visible: parent.listItem
                                                        x: parent.indent
                                                    }
                                                    Text {
                                                        id: blockText

                                                        color: modelData.kind === "heading" ? root.accent : root.foreground
                                                        font.family: root.fontFamily
                                                        font.pixelSize: modelData.kind === "heading" ? Style.font.title : Style.font.body
                                                        font.weight: modelData.kind === "heading" ? Font.Bold : Font.Normal
                                                        lineHeight: 1.15
                                                        text: modelData.html
                                                        textFormat: Text.StyledText
                                                        width: parent.width - x
                                                        wrapMode: Text.WordWrap
                                                        x: parent.indent + parent.markerWidth
                                                    }
                                                }
                                            }
                                        }
                                        Text {
                                            color: root.muted
                                            font.family: root.fontFamily
                                            font.pixelSize: Style.font.caption
                                            text: [root.ago(modelData.createdAt)].concat(modelData.tags.map(function (tag) {
                                                return "#" + tag;
                                            })).filter(function (part) {
                                                return part.length > 0;
                                            }).join(" · ")
                                            textFormat: Text.PlainText
                                            width: parent.width
                                            wrapMode: Text.WordWrap
                                        }
                                        Rectangle {
                                            color: Util.alpha(root.outline, 0.18)
                                            height: Style.normalBorderWidth
                                            width: parent.width
                                        }
                                    }
                                }
                            }
                        }
                        Rectangle {
                            // Scroll position, shown only when the notes overflow.
                            color: Util.alpha(root.foreground, 0.35)
                            height: Math.max(Style.space(24), notesScroll.height * notesScroll.visibleArea.heightRatio)
                            radius: width / 2
                            visible: notesScroll.visible && notesScroll.contentHeight > notesScroll.height
                            width: Style.space(3)
                            x: notesScroll.x + notesScroll.width + Style.spacing.sm
                            y: notesScroll.y + notesScroll.visibleArea.yPosition * notesScroll.height
                        }
                        Column {
                            anchors.centerIn: notesScroll
                            spacing: Style.space(8)
                            visible: !notesScroll.visible
                            width: notesScroll.width

                            Text {
                                color: root.selectedText
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.display
                                horizontalAlignment: Text.AlignHCenter
                                opacity: 0.8
                                text: root.notesState === "loading" ? "󰔟" : root.notesState === "ready" ? "󰎛" : "󰗖"
                                textFormat: Text.PlainText
                                width: parent.width
                            }
                            Text {
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.title
                                horizontalAlignment: Text.AlignHCenter
                                opacity: 0.7
                                text: root.notesState === "loading" ? "Loading notes…" : root.notesState === "ready" ? "No notes for " + (root.notesProject || "unassigned todos") + " yet" : root.describe(root.notesState)
                                textFormat: Text.PlainText
                                width: parent.width
                                wrapMode: Text.WordWrap
                            }
                        }
                    }
                }
                Rectangle {
                    id: footerRule

                    anchors.bottom: fixedFooter.top
                    anchors.bottomMargin: root.contentSpacing * 2
                    color: Util.alpha(root.outline, 0.28)
                    height: Style.normalBorderWidth
                    width: parent.width
                }
                Column {
                    id: fixedFooter

                    anchors.bottom: parent.bottom
                    spacing: Style.spacing.md
                    width: parent.width

                    Text {
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        text: root.notice
                        textFormat: Text.PlainText
                        visible: root.notice.length > 0
                        width: parent.width
                        wrapMode: Text.WordWrap
                    }
                    Text {
                        color: root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        text: root.projection && root.projection.todosTruncated ? "Frank's page is truncated. Showing the first " + root.projection.todos.length + " open todos." : ""
                        textFormat: Text.PlainText
                        visible: text.length > 0
                        width: parent.width
                        wrapMode: Text.WordWrap
                    }
                    Text {
                        color: root.closeMark && root.closeMark.outcome !== "confirmed" ? root.foreground : root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        text: root.closeMark ? "Todo #" + root.closeMark.id + " — " + (root.closeMark.outcome === "confirmed" ? "Confirmed closed" : root.closeMark.outcome === "confirmed-refresh-failed" ? "Close confirmed; refresh failed" : root.closeMark.outcome === "still-open" ? "Still open in latest read" : "Outcome unknown; check Frank's dashboard/agent view") + ". " + root.closeMark.evidence.command + " #" + root.closeMark.evidence.target + ", HTTP status " + root.closeMark.evidence.httpStatus + ", " + root.closeMark.evidence.timestamp : ""
                        textFormat: Text.PlainText
                        visible: root.closeMark !== null
                        width: parent.width
                        wrapMode: Text.WordWrap
                    }
                    Text {
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        text: root.unknownMarks.map(function (mark) {
                            return "Outcome unknown for todo #" + mark.id + "; recheck in Frank's dashboard/agent view. Evidence: " + mark.evidence.command + " #" + mark.evidence.target + ", HTTP status " + mark.evidence.httpStatus + ", " + mark.evidence.timestamp;
                        }).join("\n")
                        textFormat: Text.PlainText
                        visible: root.unknownMarks.length > 0
                        width: parent.width
                        wrapMode: Text.WordWrap
                    }
                    Item {
                        height: Math.max(dismissButton.implicitHeight, hintText.implicitHeight)
                        width: parent.width

                        Column {
                            anchors.left: parent.left
                            anchors.right: buttons.left
                            anchors.rightMargin: Style.spacing.xl
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Style.spacing.xxs

                            Text {
                                id: hintText

                                color: root.muted
                                elide: Text.ElideRight
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                text: root.readState === "closing" ? "Closing todo; reconciling with Frank…" : root.readState === "waiting-for-close" ? "Close pending; waiting for a fresh Frank read…" : "↑↓ select · ↵ close todo · " + (root.notesOpen ? "⇧↑↓ scroll notes · ← hide notes" : "→ notes") + " · z fold · r refresh · esc " + (root.notesOpen ? "back" : "dismiss")
                                textFormat: Text.PlainText
                                width: parent.width
                            }
                            Text {
                                color: root.muted
                                elide: Text.ElideRight
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                text: "Closed in Frank — recorded under the agent credential."
                                textFormat: Text.PlainText
                                width: parent.width
                            }
                        }
                        Row {
                            id: buttons

                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Style.spacing.controlGap

                            Button {
                                id: refreshButton

                                bordered: true
                                fontFamily: root.fontFamily
                                fontSize: Style.font.caption
                                foreground: root.foreground
                                opacity: root.readState === "closing" || root.readState === "waiting-for-close" ? 0.5 : 1
                                text: "Refresh"

                                onClicked: root.refresh()
                            }
                            Button {
                                id: dismissButton

                                bordered: true
                                fontFamily: root.fontFamily
                                fontSize: Style.font.caption
                                foreground: root.foreground
                                text: "Dismiss"

                                onClicked: root.close()
                            }
                        }
                    }
                }
            }
        }
    }
}
