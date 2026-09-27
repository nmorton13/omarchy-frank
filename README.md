# Frank for Omarchy

A hotkey overlay for [Omarchy](https://omarchy.org) that shows your [Frank](https://frankagent.dev) workspace: current status, open todos grouped by project, and each project's notes. Check off a todo without leaving what you're doing.

<!-- Screenshot: docs/screenshot.png -->

- **Native look.** Built on the Omarchy shell's own UI kit and theme tokens, so it restyles with `omarchy theme set` like the clipboard and emoji pickers.
- **Keyboard and mouse.** One shared cursor: hover a row or arrow to it, then act.
- **Todos by project.** Collapsible project groups, with a count per project.
- **Notes on demand.** Press → and the card widens to show the selected project's notes.
- **Careful writes.** Closing a todo always asks first, and the result is checked against a fresh read from Frank before it is shown as done.

## Requirements

- Omarchy with the Quickshell-based `omarchy-shell` (plugin schema v1).
- A Frank Cloud workspace and an agent credential in `~/.config/frank/frankrc`, as set up by Frank's `frank-cloud-post.sh redeem` or `bootstrap`.
- Frank's `frank-cloud-post.sh` helper on your `PATH`, **with the HTTPS guard patch from this repository applied** (see below).

## Install

### 1. Patch the Frank helper

The overlay only talks to Frank through `frank-cloud-post.sh`, and it refuses to read anything until the helper rejects non-HTTPS endpoints. Follow [`patches/README.md`](patches/README.md): it fetches the published helper, verifies its checksum, applies [`patches/frank-cloud-post-https.patch`](patches/frank-cloud-post-https.patch), verifies the result, and keeps a rollback copy.

### 2. Install the plugin

Copy the four runtime files into your plugins folder (Omarchy rejects symlinks there):

```sh
dest=~/.config/omarchy/plugins/nmorton.frank
mkdir -p "$dest"
cp manifest.json Frank.qml FrankAdapter.js FrankGuardProbe.sh "$dest"/
omarchy plugin validate "$dest"
omarchy plugin enable nmorton.frank
```

The overlay stays loaded between uses, so after updating the files run `omarchy restart shell` to pick up the new version.

### 3. Add a hotkey

Add a binding to `~/.config/hypr/bindings.lua`. Pick a free key; `SUPER + CTRL + F` is taken by Omarchy's "Tiled full screen", for example.

```lua
o.bind("SUPER + CTRL + SHIFT + F", "Frank overlay", "omarchy-shell shell toggle nmorton.frank")
```

Run `hyprctl reload`. You can also toggle it from a terminal with `omarchy-shell shell toggle nmorton.frank`.

## Using it

| Key | Action |
|-----|--------|
| ↑/↓, `k`/`j`, Shift-Tab/Tab | Move the cursor |
| PgUp/PgDn, Home/End | Jump six rows, or to the first/last row |
| Enter/Space, or click | Fold a project heading, or close the todo (after confirmation) |
| → / `l`, or **notes ›** on a heading | Show that project's notes |
| ← / `h` | Hide the notes |
| Shift+↑/↓, `K`/`J` | Scroll the notes (the mouse wheel works too) |
| `z` | Fold or unfold the project under the cursor |
| `r` / F5, or **Refresh** | Reload from Frank |
| Esc, **Dismiss**, or click outside | Hide the notes if open, otherwise dismiss |

While the notes are open they follow the project under the cursor. Notes are read-only in the overlay.

## How it talks to Frank

Frank stays the source of truth: the overlay keeps no local copy of your data and adds no Frank API changes. Everything goes through a short, fixed list of helper commands, run directly (never through a shell):

| Command | When |
|---------|------|
| `status-view`, `open` | Opening the overlay and refreshing (read-only) |
| `list --type note --project <name> --limit 50` | Opening notes for a project (read-only, cached until dismissed) |
| `close <id>` | Only after you confirm closing a todo |

- **HTTPS guard check.** At startup the overlay runs the helper against a fake `http://` endpoint in a throwaway home directory with a stub `curl`. If the helper doesn't refuse before calling `curl`, the overlay won't read or write. **Refresh** re-runs the check, so patching the helper takes effect without restarting the shell.
- **Validated responses.** Every response is checked against the expected shape before anything is shown, and only displayed fields are kept. Raw helper errors and credentials never reach the UI.
- **Honest close results.** A close shows as confirmed only when Frank returns the matching closed entry *and* a fresh list no longer contains it. Otherwise it reports "outcome unknown" and points you to Frank's dashboard. Writes are never retried automatically.
- **Timeouts.** Each helper call has a deadline, and stuck processes are terminated.
- **Truncation.** Frank may return a partial list. The overlay says so, and never treats a missing row as proof that a todo is closed.

Things to know:

- Closing a todo is recorded in Frank under the **agent credential** the helper uses, not as a browser action by you.
- The overlay limits what the UI can do, not what the credential can do. Like any Omarchy plugin, it runs unsandboxed as your user inside the shell.

## Development

```sh
omarchy plugin validate "$PWD"
/usr/lib/qt6/bin/qmlformat -i Frank.qml
/usr/lib/qt6/bin/qmllint Frank.qml
QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/
tests/helper-patch.test.sh
```

- `qmltestrunner` needs `-input tests/`: a bare `tests/` argument is treated as a test-function filter.
- `QML_XHR_ALLOW_FILE_READ=1` lets the source-inspection tests read this repository's files.
- The tests use synthetic responses and fake helpers only; they never touch your helper, credentials or Frank Cloud. Quickshell's `Process` can't be loaded outside the shell, so the overlay's process wiring is checked by inspecting the source, and the adapter's logic is tested directly.
- `tests/helper-patch.test.sh` verifies the pinned helper copy in `tests/fixtures/` (from [nmorton13/frank](https://github.com/nmorton13/frank), MIT) and the HTTPS patch, using a fake `curl`.
- `qmllint` warns that `qs.*` modules and `PanelWindow` can't be resolved outside the shell; that's expected.
- CI runs the QML tests and the helper check on every push and pull request.

See [`docs/helper-contract.md`](docs/helper-contract.md) for the exact helper commands and response shapes the overlay relies on, and [`patches/README.md`](patches/README.md) for re-pinning after an upstream helper update.

## License

[MIT](LICENSE)
