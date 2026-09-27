#!/usr/bin/env bash
# Checks the pinned Frank helper (tests/fixtures/frank-cloud-post.sh) and the
# overlay's startup guard probe. Uses a fake curl and throwaway HOME/config;
# never touches the installed helper, real credentials, or the network.
set -euo pipefail
cd "$(dirname "$0")/.."
fixture=tests/fixtures/frank-cloud-post.sh
checksum=0421e7b16755d4027104f640221c1ff80a63908bd0a1b207613509f424437d6a
min_version=2.3.3
fail() { echo "helper guard check: $*" >&2; exit 1; }

[[ "$(sha256sum "$fixture" | cut -d' ' -f1)" == "$checksum" ]] ||
  fail "pinned helper checksum mismatch (see docs/helper-contract.md to re-pin)"

# The guard must be present: require_secure_url and SKILL_VERSION >= 2.3.3.
grep -q '^require_secure_url() {' "$fixture" ||
  fail "helper has no require_secure_url; update it with: frank-cloud-post.sh skill-update"
version="$(sed -n 's/^SKILL_VERSION="\([0-9.]*\)"$/\1/p' "$fixture")"
[[ -n "$version" && "$(printf '%s\n%s\n' "$min_version" "$version" | sort -V | head -1)" == "$min_version" ]] ||
  fail "helper is ${version:-unversioned}, need $min_version or newer; update it with: frank-cloud-post.sh skill-update"

# The commands and response envelopes the overlay relies on.
for spec in 'api_get "/open"' 'api_get "/status"' 'api_get "/entries${QUERY}"' \
  '"${BASE}/v1/workspaces/${WS}/entries/${ID}/close"' 'FRANK_CLOUD_BASE' 'FRANK_CLOUD_WS' 'FRANK_CLOUD_TOKEN'; do
  grep -Fq "$spec" "$fixture" && grep -Fq "$spec" docs/helper-contract.md || fail "contract mismatch: $spec"
done
for spec in 'entries' 'truncated' 'activeRightNow' 'activeProjects' 'recent'; do
  grep -Fq "$spec" docs/helper-contract.md || fail "contract mismatch: $spec"
done

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/config/frank/test" "$tmp/bin" "$tmp/guarded" "$tmp/unguarded"
printf '#!/usr/bin/env bash\nprintf called >> "$HOME/calls"\nprintf "{}"\n' > "$tmp/bin/curl"
chmod +x "$tmp/bin/curl"
cp "$fixture" "$tmp/guarded/frank-cloud-post.sh"
# The same helper with its base check removed stands in for an old, unguarded helper.
sed '/^require_secure_url "\$FRANK_CLOUD_BASE"/d' "$fixture" > "$tmp/unguarded/frank-cloud-post.sh"
chmod +x "$tmp/guarded/frank-cloud-post.sh" "$tmp/unguarded/frank-cloud-post.sh"

run() {
  : > "$tmp/home/calls"
  env -i HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" FRANK_PROFILE=test \
    PATH="$tmp/bin:/usr/bin:/bin" FRANK_CLOUD_BASE="$1" \
    FRANK_CLOUD_WS=synthetic FRANK_CLOUD_TOKEN=synthetic \
    "$2" status-view > "$tmp/out" 2> "$tmp/err"
}
reached_curl() { [[ -s "$tmp/home/calls" ]]; }

# Plain http to a real host is refused before curl; https and loopback http reach it.
if run 'http://frank.invalid/' "$tmp/guarded/frank-cloud-post.sh" || reached_curl; then fail "http base reached curl"; fi
grep -q 'must use https://' "$tmp/err" || fail "http refusal did not explain itself"
run 'https://synthetic.invalid' "$tmp/guarded/frank-cloud-post.sh"; reached_curl || fail "https base did not reach curl"
# Loopback http is allowed by design, which is why the probe must not use it.
run 'http://127.0.0.1:9/' "$tmp/guarded/frank-cloud-post.sh"; reached_curl || fail "loopback http did not reach curl"
if run '' "$tmp/guarded/frank-cloud-post.sh" || reached_curl; then fail "empty base reached curl"; fi

# A profile's frankrc with an http base is refused too, without echoing credentials.
printf 'export FRANK_CLOUD_BASE=http://frank.invalid/\nexport FRANK_CLOUD_WS=synthetic\nexport FRANK_CLOUD_TOKEN=synthetic\n' \
  > "$tmp/config/frank/test/frankrc"
: > "$tmp/home/calls"
if env -i HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" FRANK_PROFILE=test \
  PATH="$tmp/bin:/usr/bin:/bin" "$tmp/guarded/frank-cloud-post.sh" open > "$tmp/out" 2> "$tmp/err"; then
  fail "profile http base accepted"
fi
reached_curl && fail "profile http base reached curl"
[[ "$(grep -c synthetic "$tmp/err" || :)" == 0 ]] || fail "credential leaked to stderr"
rm "$tmp/config/frank/test/frankrc"

# The overlay's probe accepts the guarded helper and rejects the unguarded one or none.
PATH="$tmp/guarded:$tmp/bin:/usr/bin:/bin" bash FrankGuardProbe.sh > /dev/null ||
  fail "probe rejected a guarded helper"
if PATH="$tmp/unguarded:$tmp/bin:/usr/bin:/bin" bash FrankGuardProbe.sh > /dev/null 2>&1; then
  fail "probe accepted an unguarded helper"
fi
if PATH="$tmp/bin:/usr/bin:/bin" bash FrankGuardProbe.sh > /dev/null 2>&1; then
  fail "probe accepted a missing helper"
fi

printf 'helper guard check: PASS (Frank helper %s)\n' "$version"
