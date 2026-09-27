# Frank helper contract (pinned)

Source: Frank's published helper at <https://frankagent.dev/skills/frank-cloud/frank-cloud-post.sh>. Its current bytes match the pinned `nmorton13/frank` commit `dc2a09ef32a3931ebc4b54612878f8e02347b8e8`, formerly `skills/frank-cloud/scripts/frank-cloud-post.sh` and now `public/skills/frank-cloud/frank-cloud-post.sh`; SHA-256 `08f19cea38fccab5a7e7cc2da72e7c1c2c9e4c2eed421c840bd0e5bb1c5b8151`. The verbatim credential-free copy is `tests/fixtures/frank-cloud-post.sh`. The checksum pins the supported bytes; the hosted URL may change.

Pinned source quotations (original line numbers):

```bash
# 21–31: config resolution (the helper, not the adapter, sources frankrc)
_FRANK_DIR="${XDG_CONFIG_HOME:-${HOME:-}/.config}/frank"
_FRANK_RC="${_FRANK_DIR}/frankrc"
if [[ -n "${FRANK_PROFILE:-}" ]]; then
  _FRANK_RC="${_FRANK_DIR}/${FRANK_PROFILE}/frankrc"
fi
if [[ -f "$_FRANK_RC" ]]; then
  # shellcheck disable=SC1090
  . "$_FRANK_RC"
fi

# 142–145: required configuration
if [[ -z "${FRANK_CLOUD_BASE:-}" || -z "${FRANK_CLOUD_WS:-}" || -z "${FRANK_CLOUD_TOKEN:-}" ]]; then
  echo "FRANK_CLOUD_BASE, FRANK_CLOUD_WS, and FRANK_CLOUD_TOKEN must all be set" >&2
  exit 1
fi

# 334–340: dispatch
if [[ "$TYPE" == "open" ]]; then
  api_get "/open"; printf '\n'; exit 0
fi
if [[ "$TYPE" == "status-view" ]]; then
  api_get "/status"; printf '\n'; exit 0
fi

# 392–403: close dispatch (ID raw in URL; adapter must canonicalize)
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

`list --type note [--project <name>] --limit 50` (pinned lines 316–332, below) is the notes pane's only read. The adapter passes the project name as its own argv element, taken from a validated `/open` read (the helper URL-encodes it); unassigned notes have no server filter, so the adapter lists all notes and keeps those with a null project. The response is `GET /v1/workspaces/{ws}/entries?type=note…`: `{entries: Entry[], truncated: boolean}`, and every entry must be `type: note`. Notes are read-only in the overlay.

```bash
# 316–332: list dispatch (read-only; filters URL-encoded)
if [[ "$TYPE" == "list" ]]; then
  ...
      --type|--project|--status|--limit)
        FILTERS+=("${1#--}=$(urlencode "$2")")
  ...
  api_get "/entries${QUERY}"
```

`status-view` returns `GET /v1/workspaces/{ws}/status`: `{active: Entry|null, activeRightNow: Entry[], activeProjects: {name:string,count:number,lastType:EntryType,lastText:string,updatedAt:string}[], recent: Entry[], openLoops?: Entry[], truncated?: boolean}`. `open` returns `GET /v1/workspaces/{ws}/open`: `{entries: Entry[], truncated: boolean}` (up to 100 rows). The pinned server source at the same commit (`src/cloud/workspace.ts`, `WorkspaceEntry`) defines `Entry`: positive integer `id`; `type` one of `note,status,active,todo,blocker,done,decision,session`; `text`, `source`, `actorType`, `actorId`, `createdAt`, `updatedAt` strings; `tags` string array; `structuredJson` object; nullable `title`, `project`, `projectRaw`, `sessionId`, `closedAt`, `closeNote`; `status` open or closed. Status projection recent rows can be closed. The adapter projects only displayed fields and never returns raw credentials, actors, or the helper's stderr.

`close <id>` returns the response body on stdout (expected `{entry: Entry}` with matching ID, `type: todo`, `status: closed` for validated closure). Its `curl -fsS` invocation does **not** print a numeric HTTP status; a zero exit alone is insufficient evidence of closure. The UI therefore reports `HTTP status unavailable (helper does not emit HTTP status)` alongside the close command, canonical ID, and attempt timestamp, and never fabricates a status code. Adding an exact numeric status requires a separately reviewed helper-contract change; the adapter does not make a second authenticated request for one.

The pinned helper has **no HTTPS guard**. The versioned local patch adds rejection before authenticated network traffic. The installed helper must be the patched pinned copy; the adapter probes this behavior under synthetic credentials before permitting reads. See `patches/README.md` for source verification, installation, rollback, and re-pinning.
