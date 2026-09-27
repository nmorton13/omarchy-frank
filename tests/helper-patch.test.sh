#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture=tests/fixtures/frank-cloud-post.sh
checksum=08f19cea38fccab5a7e7cc2da72e7c1c2c9e4c2eed421c840bd0e5bb1c5b8151
compatible() { [[ "$(sha256sum "$1" | cut -d' ' -f1)" == "$checksum" ]]; }
compatible "$fixture" || { echo 'fixture checksum mismatch' >&2; exit 1; }
# Fail loudly on drift in both quoted dispatch and response envelope contracts.
for spec in 'api_get "/open"' 'api_get "/status"' '"${BASE}/v1/workspaces/${WS}/entries/${ID}/close"' 'FRANK_CLOUD_BASE' 'FRANK_CLOUD_WS' 'FRANK_CLOUD_TOKEN'; do
  grep -Fq "$spec" "$fixture" && grep -Fq "$spec" docs/helper-contract.md || { echo "contract mismatch: $spec" >&2; exit 1; }
done
for spec in 'entries' 'truncated' 'activeRightNow' 'activeProjects' 'recent'; do
  grep -Fq "$spec" docs/helper-contract.md || { echo "contract mismatch: $spec" >&2; exit 1; }
done
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/config/frank/test" "$tmp/bin"
cp "$fixture" "$tmp/frank-cloud-post.sh"
compatible "$tmp/frank-cloud-post.sh" || { echo 'unsupported helper revision' >&2; exit 1; }
patch --silent --directory="$tmp" --forward -p1 < patches/frank-cloud-post-https.patch
# Unsupported revisions fail the same pre-install compatibility check.
cp "$fixture" "$tmp/unsupported.sh"
printf '\n# drift\n' >> "$tmp/unsupported.sh"
if compatible "$tmp/unsupported.sh"; then echo 'unsupported revision accepted' >&2; exit 1; fi
cp "$fixture" "$tmp/unpatched.sh"
# Fake client records requests, never reaches a real network.
printf '#!/usr/bin/env bash\nprintf called >> "$HOME/calls"\nprintf "{}"\n' > "$tmp/bin/curl"; chmod +x "$tmp/bin/curl"
run() {
  env -i HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" FRANK_PROFILE=test \
    PATH="$tmp/bin:/usr/bin:/bin" FRANK_CLOUD_BASE="$1" \
    FRANK_CLOUD_WS=synthetic FRANK_CLOUD_TOKEN=synthetic \
    "$2" status-view > "$tmp/out" 2> "$tmp/err"
}
: > "$tmp/home/calls"
if run 'http://127.0.0.1:9/' "$tmp/frank-cloud-post.sh"; then echo 'HTTP accepted' >&2; exit 1; fi
[[ ! -s "$tmp/home/calls" ]] || { echo 'HTTP reached curl' >&2; exit 1; }
# Unpatched fixture demonstrates probe failure: fake curl IS invoked.
run 'http://127.0.0.1:9/' "$tmp/unpatched.sh"
[[ -s "$tmp/home/calls" ]] || { echo 'unpatched probe not detected' >&2; exit 1; }
: > "$tmp/home/calls"
run 'https://synthetic.invalid' "$tmp/frank-cloud-post.sh"
[[ -s "$tmp/home/calls" ]] || { echo 'HTTPS did not reach fake curl' >&2; exit 1; }
: > "$tmp/home/calls"
# Production-shaped parent environment must not leak into synthetic children;
# only the explicitly selected temporary profile may be sourced.
printf 'export FRANK_CLOUD_BASE=http://127.0.0.1:9/\nexport FRANK_CLOUD_WS=synthetic\nexport FRANK_CLOUD_TOKEN=synthetic\n' > "$tmp/config/frank/test/frankrc"
if env -i HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" FRANK_PROFILE=test \
  PATH="$tmp/bin:/usr/bin:/bin" "$tmp/frank-cloud-post.sh" open >"$tmp/out" 2>"$tmp/err"; then exit 1; fi
[[ ! -s "$tmp/home/calls" ]] || { echo 'profile HTTP reached curl' >&2; exit 1; }
[[ "$(grep -c 'synthetic' "$tmp/err" || :)" == 0 ]] || { echo 'credential leaked' >&2; exit 1; }
rm "$tmp/config/frank/test/frankrc"
: > "$tmp/home/calls"
if run '' "$tmp/frank-cloud-post.sh"; then exit 1; fi
[[ ! -s "$tmp/home/calls" ]] || exit 1
# Probe itself uses a synthetic HOME and fake client; no real config or curl.
PATH="$tmp:$tmp/bin:/usr/bin:/bin" bash FrankGuardProbe.sh >/dev/null
mkdir -p "$tmp/old"; cp "$tmp/unpatched.sh" "$tmp/old/frank-cloud-post.sh"
if PATH="$tmp/old:$tmp/bin:/usr/bin:/bin" bash FrankGuardProbe.sh >/dev/null 2>&1; then
  echo 'unpatched probe accepted' >&2; exit 1
fi
printf 'helper patch/contract/guard: PASS\n'
