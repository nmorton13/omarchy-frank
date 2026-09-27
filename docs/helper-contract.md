# Frank helper contract (pinned)

Source: Frank's published helper at <https://frankagent.dev/skills/frank-cloud/frank-cloud-post.sh>, version **2.3.4** (HTTPS guard from [nmorton13/frank#19](https://github.com/nmorton13/frank/pull/19), `skill-update` symlink fix from [#20](https://github.com/nmorton13/frank/pull/20); identical on `main` at `755fd37efdf8d682dffe8d4dd3a6e0e8c855583c`, as `skills/frank-cloud/scripts/frank-cloud-post.sh` and `public/skills/frank-cloud/frank-cloud-post.sh`). SHA-256 `8118e0f77d3c77000692a8bbe5bafcbdc3f327b7f6354a09a00051f4de14f319`. The verbatim credential-free copy is `tests/fixtures/frank-cloud-post.sh`. The checksum pins the supported bytes; the hosted URL may change.

The overlay needs helper **2.3.4 or newer**. 2.3.3 is the first version that refuses to send credentials over plain `http://`; 2.3.4 also makes `skill-update` follow the `~/.local/bin` symlink, so it updates the real helper instead of writing into `~/.local/bin`.

Pinned source quotations (line numbers in the pinned file):

```bash
# 21–29: config resolution (the helper, not the adapter, sources frankrc)
_FRANK_DIR="${XDG_CONFIG_HOME:-${HOME:-}/.config}/frank"
_FRANK_RC="${_FRANK_DIR}/frankrc"
if [[ -n "${FRANK_PROFILE:-}" ]]; then
  _FRANK_RC="${_FRANK_DIR}/${FRANK_PROFILE}/frankrc"
fi
if [[ -f "$_FRANK_RC" ]]; then
  # shellcheck disable=SC1090
  . "$_FRANK_RC"
fi

# 65–74: HTTPS guard
require_secure_url() {
  local url="$1" what="$2"
  local loopback='^http://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?(/[^@]*)?$'
  if [[ "$url" != *[[:space:][:cntrl:]\\]* ]]; then
    [[ "$url" =~ ^https://. ]] && return 0
    [[ "$url" =~ $loopback ]] && return 0
  fi
  echo "frank-cloud: ${what} must use https:// (plain http is only allowed for localhost)" >&2
  exit 1
}

# 183–189: required configuration, then the guard for every remaining command
if [[ -z "${FRANK_CLOUD_BASE:-}" || -z "${FRANK_CLOUD_WS:-}" || -z "${FRANK_CLOUD_TOKEN:-}" ]]; then
  echo "FRANK_CLOUD_BASE, FRANK_CLOUD_WS, and FRANK_CLOUD_TOKEN must all be set" >&2
  exit 1
fi
require_secure_url "$FRANK_CLOUD_BASE" "FRANK_CLOUD_BASE"

# 385–391: dispatch
if [[ "$TYPE" == "open" ]]; then
  api_get "/open"; printf '\n'; exit 0
fi
if [[ "$TYPE" == "status-view" ]]; then
  api_get "/status"; printf '\n'; exit 0
fi

# 443–454: close dispatch (ID raw in URL; adapter must canonicalize)
if [[ "$TYPE" == "close" ]]; then
  ID="${1:-}"
  [[ -n "$ID" ]] || { usage; exit 2; }
  curl -fsS -X PATCH \
    -H "Authorization: Bearer ${TOKEN}" \
    -H 'Accept: application/json' \
    "${BASE}/v1/workspaces/${WS}/entries/${ID}/close"
  printf '\n'
  exit 0
fi
```

`list --type note [--project <name>] --limit 50` (pinned lines 367–383, below) is the notes pane's only read. The adapter passes the project name as its own argv element, taken from a validated `/open` read (the helper URL-encodes it); unassigned notes have no server filter, so the adapter lists all notes and keeps those with a null project. The response is `GET /v1/workspaces/{ws}/entries?type=note…`: `{entries: Entry[], truncated: boolean}`, and every entry must be `type: note`. Notes are read-only in the overlay.

```bash
# 367–383: list dispatch (read-only; filters URL-encoded)
if [[ "$TYPE" == "list" ]]; then
  ...
      --type|--project|--status|--limit)
        FILTERS+=("${1#--}=$(urlencode "$2")")
  ...
  api_get "/entries${QUERY}"
```

`status-view` returns `GET /v1/workspaces/{ws}/status`: `{active: Entry|null, activeRightNow: Entry[], activeProjects: {name:string,count:number,lastType:EntryType,lastText:string,updatedAt:string}[], recent: Entry[], openLoops?: Entry[], truncated?: boolean}`. `open` returns `GET /v1/workspaces/{ws}/open`: `{entries: Entry[], truncated: boolean}` (up to 100 rows). The pinned server source at the same commit (`src/cloud/workspace.ts`, `WorkspaceEntry`) defines `Entry`: positive integer `id`; `type` one of `note,status,active,todo,blocker,done,decision,session`; `text`, `source`, `actorType`, `actorId`, `createdAt`, `updatedAt` strings; `tags` string array; `structuredJson` object; nullable `title`, `project`, `projectRaw`, `sessionId`, `closedAt`, `closeNote`; `status` open or closed. Status projection recent rows can be closed. The adapter projects only displayed fields and never returns raw credentials, actors, or the helper's stderr.

`close <id>` returns the response body on stdout (expected `{entry: Entry}` with matching ID, `type: todo`, `status: closed` for validated closure). Its `curl -fsS` invocation does **not** print a numeric HTTP status; a zero exit alone is insufficient evidence of closure. The UI therefore reports `HTTP status unavailable (helper does not emit HTTP status)` alongside the close command, canonical ID, and attempt timestamp, and never fabricates a status code. Adding an exact numeric status requires a separately reviewed helper-contract change; the adapter does not make a second authenticated request for one.

## HTTPS guard and the startup probe

From 2.3.3 the helper refuses any base that is not `https://`, before any request, for every command. Plain `http://` is allowed only for loopback (`localhost`, `127.0.0.1`, `[::1]`, optional numeric port) so a local Worker can be used in development. `redeem` also requires the setup link to be on `FRANK_CLOUD_BASE`, and only writes a `frankrc` with `wsp_…` workspace IDs, `frank_agent_…` tokens and `[a-z0-9_-]` labels. The overlay never runs `redeem` or `bootstrap`.

The overlay does not trust the version number. At startup (and on Refresh after a failure), `FrankGuardProbe.sh` runs the installed helper's `status-view` in a throwaway `HOME` with synthetic credentials, a fake `curl`, and `FRANK_CLOUD_BASE=http://frank.invalid/`. The probe passes only if the helper exits non-zero without calling `curl`. It must use a non-loopback host, since loopback `http://` is allowed by design. `tests/helper-guard.test.sh` checks this against the pinned copy and against the same helper with its guard removed.

## Re-pinning after a helper release

1. Fetch the hosted helper to a temporary file and review the full diff against `tests/fixtures/frank-cloud-post.sh`: the commands above, credential handling, response envelopes, and every network call.
2. Replace the fixture, then update the checksum in `tests/helper-guard.test.sh` and the version, commit, checksum and line numbers in this document.
3. Run `tests/helper-guard.test.sh` and the QML tests. Tests never touch the installed helper or Frank Cloud.
