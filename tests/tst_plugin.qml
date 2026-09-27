import QtQuick
import QtTest
import "../FrankAdapter.js" as FrankAdapter

TestCase {
    name: "FrankOverlayShell"
    when: true

    function projectFile(name) {
        var xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../" + name), false);
        xhr.send();
        compare(xhr.status, 200);
        return xhr.responseText;
    }

    function test_manifest() {
        var manifest = JSON.parse(projectFile("manifest.json"));
        compare(manifest.schemaVersion, 1);
        compare(manifest.id, "nmorton.frank");
        compare(manifest.keepLoaded, true);
        compare(manifest.kinds.length, 1);
        compare(manifest.kinds[0], "overlay");
        compare(manifest.entryPoints.overlay, "Frank.qml");
        verify(projectFile(manifest.entryPoints.overlay).length > 0);
        compare(manifest.hotkeys, undefined);
    }

    function test_entryPointsAndNativeTheme() {
        var source = projectFile("Frank.qml");
        verify(/function open\(payloadJson\)/.test(source));
        verify(/function close\(\)/.test(source));
        verify(/function toggle\(\)/.test(source));
        verify(/PanelWindow\s*\{/.test(source));
        verify(/visible:\s*root.opened/.test(source));
        verify(/keyCatcher.forceActiveFocus\(\)/.test(source));
        verify(/keyCatcher.focus = false/.test(source));
        verify(/WlrKeyboardFocus.Exclusive/.test(source));
        verify(/import qs\.Ui/.test(source));
        verify(/property color background: Color\.menu\.background/.test(source));
        verify(/property color foreground: Color\.menu\.text/.test(source));
        verify(/property color scrim: Color\.menu\.scrim/.test(source));
        verify(/Border\.surfaceSpec\("menu", "border"/.test(source));
        verify(/readonly property int cornerRadius: Style\.cornerRadius/.test(source));
        verify(/BorderSurface\s*\{/.test(source));
        verify(/Style\.font\.menuFamily/.test(source));
        // Theme-owned sizes only: no hard-coded rounding or pixel fonts.
        verify(!/radius:\s*Style\.space\(/.test(source));
        verify(!/font\.pixelSize:\s*Style\.space\(/.test(source));
    }

    function test_truncationBelongsToOpenTodoPage() {
        FrankAdapter.resetGuard();
        FrankAdapter.summon();
        FrankAdapter.setGuardProbeResult(0);
        function entry(id, project) {
            return {
                id: id,
                type: "todo",
                status: "open",
                text: "todo " + id,
                tags: [],
                title: null,
                project: project,
                projectRaw: null,
                sessionId: null,
                closedAt: null,
                closeNote: null,
                source: "test",
                actorType: "agent",
                actorId: "test",
                createdAt: "2026-01-01",
                updatedAt: "2026-01-01",
                structuredJson: {}
            };
        }
        var result;
        FrankAdapter.load(function (action, argv, callback) {
            callback(action === "status-view" ? {
                exitCode: 0,
                stdout: JSON.stringify({
                    active: null,
                    activeRightNow: [],
                    activeProjects: [],
                    recent: [],
                    truncated: true
                })
            } : {
                exitCode: 0,
                stdout: JSON.stringify({
                    entries: [entry(1, "Alpha"), entry(2, null)],
                    truncated: false
                })
            });
        }, function (value) {
            result = value;
        });
        verify(result.ok);
        compare(result.status.truncated, true);
        compare(result.todosTruncated, false);
        compare(result.todos.length, 2);
    }

    function test_groupTodosByProject() {
        var groups = FrankAdapter.groupTodosByProject([
            {
                id: "1",
                project: "Alpha"
            },
            {
                id: "2",
                project: null
            },
            {
                id: "3",
                project: "Alpha"
            },
            {
                id: "4",
                project: "Beta"
            }
        ]);
        compare(groups.length, 3);
        compare(groups[0].project, "Alpha");
        compare(groups[0].todos.map(function (todo) {
            return todo.id;
        }).join(","), "1,3");
        compare(groups[1].project, "Unassigned");
        compare(groups[2].project, "Beta");
    }

    function test_layoutAndGrouping() {
        var source = projectFile("Frank.qml");
        var card = source.indexOf("id: card");
        var list = source.indexOf("id: todoList");
        var footer = source.indexOf("id: fixedFooter");
        var dismiss = source.indexOf("id: dismissButton");
        verify(card >= 0 && list > card && footer > list && dismiss > footer);
        verify(/clip:\s*true/.test(source));
        verify(/FrankAdapter\.groupTodosByProject/.test(source));
        verify(/function groupedTodoRows\(\)/.test(source));
        verify(/modelData\.collapsed \? "▸" : "▾"/.test(source));
        verify(/function toggleProject\(key\)/.test(source));
        verify(/root\.projection\.todosTruncated/.test(source));
        verify(/onClicked:\s*root\.close\(\)/.test(source));
    }

    function test_keyboardAndPointerShareOneCursor() {
        var source = projectFile("Frank.qml");
        verify(/PointerMoveGate\s*\{/.test(source));
        verify(/root\.selectFromPointer\(row\.index, row, mouse\)/.test(source));
        verify(/color: hasCursor \? root\.selectedBackground : "transparent"/.test(source));
        verify(/row\.hasCursor \? root\.selectedText/.test(source));
        var keys = ["Up", "Down", "K", "J", "Tab", "Backtab", "PageUp", "PageDown", "Home", "End", "Left", "Right", "H", "L", "Z", "Return", "Enter", "Space", "Escape", "R", "F5"];
        for (var i = 0; i < keys.length; i++)
            verify(source.indexOf("Qt.Key_" + keys[i]) >= 0, keys[i]);
        verify(/todoList\.positionViewAtIndex\(root\.selectedIndex, ListView\.Contain\)/.test(source));
    }

    function test_closeIsConfirmedAndFailuresAreVisible() {
        var source = projectFile("Frank.qml");
        verify(/ConfirmDialog\s*\{/.test(source));
        verify(/closeConfirm\.handleKey\(event\)/.test(source));
        verify(/onConfirmed: root\.confirmClose\(\)/.test(source));
        verify(/root\.checkTodo\(todo\.id\)/.test(source));
        verify(/FrankAdapter\.closeTodo\(Number\(id\), root\.dispatch/.test(source));
        // Pointer and keyboard both route through the confirmation, never straight to a write.
        verify(!/onClicked:[^}]*checkTodo/.test(source));
        verify(/root\.notice = root\.describe\(start\.category\)/.test(source));
        verify(/function describe\(category\)/.test(source));
        verify(/root\.closingId === modelData\.todo\.id/.test(source));
    }

    function test_notesPaneExpandsCard() {
        var source = projectFile("Frank.qml");
        verify(/property int cardWidth: root\.notesOpen \? root\.notesCardWidth : root\.listCardWidth/.test(source));
        verify(/Behavior on width \{/.test(source));
        verify(/id: notesArea/.test(source));
        verify(/FrankAdapter\.loadNotes\(key, root\.dispatch/.test(source));
        // The todo column keeps its width while the card grows.
        verify(/width: Math\.min\(parent\.width, root\.listCardWidth - card\.contentLeftInset - card\.contentRightInset\)/.test(source));
        // Esc hides notes before dismissing; notes errors never replace the list state.
        verify(/if \(root\.notesOpen\)\s*root\.hideNotes\(\);\s*else\s*root\.close\(\);/.test(source));
        verify(/action !== "notes" && !FrankAdapter\.isClosePending\(\)/.test(source));
        verify(/onSelectedIndexChanged: if \(root\.notesOpen\)/.test(source));
        verify(/root\.scrollNotes\(/.test(source));
    }

    function test_guardProbeRetriesOnRefresh() {
        var source = projectFile("Frank.qml");
        verify(/Component\.onCompleted: root\.startProbe\(\)/.test(source));
        verify(/!FrankAdapter\.isGuardVerified\(\) && !root\.probing/.test(source));
        // A probe completion loads directly, so a failed probe cannot re-probe in a loop.
        verify(/root\.wantsRead\)\s*root\.loadNow\(\)/.test(source));
    }

    function test_processDeclarations() {
        var source = projectFile("Frank.qml");
        var actions = ["status-view", "open", "close"];
        // One read-only notes list plus the signal sender for bounded termination.
        compare((source.match(/Process\s*\{/g) || []).length, actions.length + 2);
        compare((source.match(/stdout:\s*StdioCollector\s*\{\s*waitForEnd:\s*true\s*\}/g) || []).length, actions.length + 1);
        verify(source.indexOf('command: ["frank-cloud-post.sh", "list"]') >= 0);
        for (var i = 0; i < actions.length; i++)
            verify(source.indexOf('command: ["frank-cloud-post.sh", "' + actions[i] + '"]') >= 0);
        verify(!/(?:statusProc|openProc|closeProc)\.running\s*=\s*true/.test(source));
        verify(!/execDetached\(/.test(source));
        verify(!/\.exec\(/.test(source));
        verify(/closeProc\.running = Boolean\(args\.length\)/.test(source) === false); // fixed-action dispatch, never string commands
        verify(/proc\.running = Boolean\(args\.length\)/.test(source));
        verify(/root\.signalChild\(proc, "-TERM"\)/.test(source));
        verify(/root\.signalChild\(proc, "-KILL"\)/.test(source));
    }
    function test_explicitActionAndDisclosure() {
        var source = projectFile("Frank.qml");
        verify(source.indexOf("Closed in Frank — recorded under the agent credential.") >= 0);
        verify(/root\.requestClose\(row\.todo\)/.test(source));
        verify(/root\.readState !== "ready"/.test(source));
        verify(/FrankAdapter\.queueVisibleRead/.test(source));
        verify(/text: "Refresh"/.test(source));
        verify(/model: root\.displayRows/.test(source)); // pending row remains until reconcile
        verify(/function checkTodo\(id\)/.test(source));
        verify(!/function (?:open|refresh|close|toggle)\([^)]*\)\s*\{[^}]*checkTodo/.test(source));
        verify(/dashboard\/agent view/.test(source));
        verify(/root\.closeMark\.evidence\.httpStatus/.test(source));
        verify(/root\.closeMark\.evidence\.timestamp/.test(source));
        verify(/function onError\(action, category\)/.test(source));
        verify(/root\.onError\(action, response\.category \|\| "helper"\)/.test(source));
    }

    // qmltestrunner cannot load Quickshell.Io on this installation: its QML
    // module is registered by the Quickshell executable, not a loadable plugin.
    // Inspect process declarations without starting a helper or accessing config.
}
