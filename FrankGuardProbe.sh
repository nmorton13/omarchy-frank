#!/usr/bin/env bash
# Isolated synthetic probe: exit 0 iff the helper rejects plain HTTP before curl.
# Uses a non-loopback host: Frank's helper (2.3.3+) deliberately allows http://
# for localhost/127.0.0.1/[::1], and .invalid never resolves.
set -euo pipefail
helper="$(command -v frank-cloud-post.sh || :)"
[[ -n "$helper" ]] || exit 1
sandbox="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/home" "$sandbox/config" "$sandbox/bin"
printf '#!/usr/bin/env bash\nprintf invoked > "$HOME/curl-invoked"\nexit 77\n' > "$sandbox/bin/curl"
chmod 700 "$sandbox/bin/curl"
# env -i prevents a parent profile/credential from overriding the probe.
if env -i HOME="$sandbox/home" XDG_CONFIG_HOME="$sandbox/config" \
  PATH="$sandbox/bin:$PATH" FRANK_CLOUD_BASE='http://frank.invalid/' \
  FRANK_CLOUD_WS='synthetic-workspace' FRANK_CLOUD_TOKEN='synthetic-token' \
  "$helper" status-view > /dev/null 2>&1; then
  exit 1
fi
[[ ! -e "$sandbox/home/curl-invoked" ]] || exit 1
