# Local HTTPS helper guard

The supported helper is the Frank Cloud helper published at <https://frankagent.dev/skills/frank-cloud/frank-cloud-post.sh>. The currently published bytes have SHA-256 `08f19cea38fccab5a7e7cc2da72e7c1c2c9e4c2eed421c840bd0e5bb1c5b8151`, matching `tests/fixtures/frank-cloud-post.sh` byte-for-byte. The same bytes are pinned to `nmorton13/frank` commit `dc2a09ef32a3931ebc4b54612878f8e02347b8e8`, formerly at `skills/frank-cloud/scripts/frank-cloud-post.sh` (now served from `public/skills/frank-cloud/frank-cloud-post.sh`). The checksum, not the moving URL, defines the supported version.

The local patch adds an HTTPS-only guard before authenticated requests. No patch is installed automatically. **Block live use until the installed helper matches the supported source and the patched checksum has been verified.**

## User-controlled installation

This procedure replaces the installed helper with the exact pinned official source plus the local HTTPS guard. It does not modify Frank credentials or data. Do not proceed unless you intend to replace the installed helper; retain a rollback copy.

From the repository root:

```sh
helper="$HOME/.local/share/frank-cloud/scripts/frank-cloud-post.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

curl -fsSL --max-time 20 \
  https://frankagent.dev/skills/frank-cloud/frank-cloud-post.sh \
  -o "$work/frank-cloud-post.sh"
printf '%s  %s\n' \
  08f19cea38fccab5a7e7cc2da72e7c1c2c9e4c2eed421c840bd0e5bb1c5b8151 \
  "$work/frank-cloud-post.sh" | sha256sum --check -

patch --directory="$work" -p1 < "$PWD/patches/frank-cloud-post-https.patch"
printf '%s  %s\n' \
  ddeb14111e5d2d91f7c938340c38deb0006ee71112c03e3e74af3666b9bb2f8c \
  "$work/frank-cloud-post.sh" | sha256sum --check -

# Only after reviewing both checksums and deciding to replace the helper:
backup="$helper.before-https.$(date +%Y%m%d%H%M%S)"
cp -p -- "$helper" "$backup"
printf 'Rollback copy: %s\n' "$backup"
install -m 700 "$work/frank-cloud-post.sh" "$helper"
sha256sum "$helper"  # must match the patched SHA above
```

First inspect the installed helper if unsure:

```sh
sha256sum "$HOME/.local/share/frank-cloud/scripts/frank-cloud-post.sh"
```

A mismatch with the supported unmodified checksum means **do not patch that installed file**. Fetch and verify the official source in the temporary directory as above instead. If the fetched source checksum differs, stop and review the new upstream revision; do not apply this patch blindly. For rollback:

```sh
cp -p -- "$backup" "$helper"
sha256sum "$helper"
```

Verify the patch with `tests/helper-patch.test.sh`; its fake client and temporary config never touch the installed helper or use the network. The overlay's isolated startup probe must succeed before a live read. After installation, `frank-cloud-post.sh status-view` and `frank-cloud-post.sh open` are read-only smoke gates; never automate a live write. Do not use the helper's `self-test` as a smoke check because it writes an entry.

Unset/empty `FRANK_CLOUD_BASE` is rejected by the helper's required-variable check; nonempty bases that do not start with `https://` are rejected by the guard before any authenticated curl. The adapter does not independently inspect schemes.

## Re-pinning after an upstream update

Fetch the hosted helper to a temporary file and inspect the full diff against the pinned fixture. Verify the close path, credential handling, response envelopes, and all network calls. Do not update the fixture from the moving URL until a new source identity is established. Update `tests/fixtures/frank-cloud-post.sh`, this document, `docs/helper-contract.md`, the patch, and both checksums; extend the fake-curl compatibility test for changed behavior. Rerun `tests/helper-patch.test.sh` and the QML tests. Only then consider replacing the installed helper, with an explicit user decision, rollback copy, and verified hashes. Never let tests touch the installed copy or Frank Cloud.
