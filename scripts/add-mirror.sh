#!/usr/bin/env bash
#
# Register a new project to mirror, end to end: create the target repo, mint a
# deploy key scoped to it, store the private half as an Actions secret here, and
# append the entry to mirrors.yml.
#
#   scripts/add-mirror.sh <upstream-url> [target-repo-name]
#
# e.g. scripts/add-mirror.sh https://github.com/rust-lang/rust rust-squashed
#
# Run it from a clone of this repo, with gh authenticated. Commit the mirrors.yml
# change it makes and the next scheduled run picks the mirror up.

set -euo pipefail

UPSTREAM="${1:-}"
if [ -z "$UPSTREAM" ]; then
  sed -n '3,13p' "$0" | sed 's/^# \?//'
  exit 1
fi

cd "$(dirname "$0")/.."
command -v gh >/dev/null || { echo "gh is required"; exit 1; }
command -v yq >/dev/null || { echo "yq is required (brew install yq)"; exit 1; }

CONTROLLER="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
OWNER="${CONTROLLER%%/*}"

SLUG="${UPSTREAM##*/}"
NAME="$(printf '%s' "${SLUG%.git}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')"
NAME="${NAME%-}"
TARGET_NAME="${2:-$NAME}"
TARGET="$OWNER/$TARGET_NAME"
SECRET="DEPLOY_KEY_$(printf '%s' "$NAME" | tr '[:lower:]-' '[:upper:]_')"

# Ask the remote itself, so this works for upstreams that are not on GitHub.
REF="$(git ls-remote --symref "$UPSTREAM" HEAD | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2; exit}')"
[ -n "$REF" ] || { echo "could not resolve the default branch of $UPSTREAM"; exit 1; }

if yq -e ".mirrors[] | select(.name == \"$NAME\")" mirrors.yml >/dev/null 2>&1; then
  echo "mirrors.yml already has a mirror named '$NAME'"
  exit 1
fi

echo "upstream:   $UPSTREAM ($REF)"
echo "target:     $TARGET"
echo "secret:     $SECRET -> $CONTROLLER"
read -r -p "proceed? [y/N] " reply
[ "$reply" = "y" ] || [ "$reply" = "Y" ] || exit 1

if ! gh repo view "$TARGET" >/dev/null 2>&1; then
  echo "==> creating $TARGET"
  gh repo create "$TARGET" --public \
    --description "Squashed daily snapshots of $UPSTREAM -- one commit per day of upstream change"
fi

echo "==> provisioning deploy key"
KEYDIR="$(mktemp -d)"
trap 'rm -rf "$KEYDIR"' EXIT
ssh-keygen -q -t ed25519 -N '' -C "$CONTROLLER ($NAME)" -f "$KEYDIR/key"
gh repo deploy-key add "$KEYDIR/key.pub" --repo "$TARGET" --allow-write --title "$CONTROLLER ($NAME)"
gh secret set "$SECRET" --repo "$CONTROLLER" <"$KEYDIR/key"

echo "==> appending to mirrors.yml"
NAME="$NAME" UPSTREAM="$UPSTREAM" REF="$REF" TARGET="$TARGET" SECRET="$SECRET" \
  yq -i '.mirrors += [{
    "name": strenv(NAME),
    "upstream": strenv(UPSTREAM),
    "upstream_ref": strenv(REF),
    "target": strenv(TARGET),
    "target_branch": strenv(REF),
    "deploy_key_secret": strenv(SECRET),
    "strip": [".github/workflows"]
  }]' mirrors.yml

echo
echo "done. commit mirrors.yml, then seed it now with:"
echo "  gh workflow run mirror.yml -f only=$NAME"
