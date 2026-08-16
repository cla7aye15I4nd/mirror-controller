#!/usr/bin/env bash
#
# Publish one squashed snapshot of an upstream repository.
#
# The upstream tip tree replaces the target working tree wholesale, so the
# target gains exactly one commit per sync no matter how many commits landed
# upstream in between. Upstream history is never downloaded -- a depth-1 clone
# is all a snapshot needs, which is what keeps a 6 GB repository like the Linux
# kernel down to a ~250 MB fetch.
#
# Where the previous sync stopped is read back from the Upstream-Commit trailer
# on the target's tip commit, so no state file has to live inside the mirrored
# tree.
#
# Required env:
#   NAME UPSTREAM UPSTREAM_REF TARGET TARGET_BRANCH DEPLOY_KEY
# Optional env:
#   STRIP_JSON  JSON array of paths to drop from every snapshot (default [])
#   REINIT      1 = discard target history and force-push a fresh single commit
#   TARGET_URL  push URL, defaults to git@github.com:$TARGET.git

set -euo pipefail

for var in NAME UPSTREAM UPSTREAM_REF TARGET TARGET_BRANCH DEPLOY_KEY; do
  [ -n "${!var:-}" ] || { echo "::error::$var is empty"; exit 1; }
done
STRIP_JSON="${STRIP_JSON:-[]}"
REINIT="${REINIT:-0}"
TARGET_URL="${TARGET_URL:-git@github.com:$TARGET.git}"

# GitHub rejects any blob over 100 MB. Leaving headroom and skipping the file
# beats letting one oversized blob fail the whole push every single day.
MAX_BLOB=$((95 * 1024 * 1024))

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

case "$UPSTREAM" in
  https://github.com/*)
    UPSTREAM_SLUG="${UPSTREAM#https://github.com/}"
    UPSTREAM_SLUG="${UPSTREAM_SLUG%.git}"
    UPSTREAM_HOME="https://github.com/$UPSTREAM_SLUG"
    ;;
  *)
    UPSTREAM_SLUG="${UPSTREAM##*/}"
    UPSTREAM_SLUG="${UPSTREAM_SLUG%.git}"
    UPSTREAM_HOME="$UPSTREAM"
    ;;
esac

note() { echo "==> $*"; }
summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
  return 0
}

# --- authentication ---------------------------------------------------------
# A deploy key writes to exactly one repository, so a leak here cannot reach the
# rest of the account the way a personal access token would.

key="$DEPLOY_KEY"
while [ -n "$key" ] && [ "${key: -1}" = $'\n' ]; do key="${key%$'\n'}"; done
umask 077
printf '%s\n' "$key" | tr -d '\r' >"$WORK/key"
unset key
ssh-keyscan -t rsa,ecdsa,ed25519 github.com >"$WORK/known_hosts" 2>/dev/null
export GIT_SSH_COMMAND="ssh -i $WORK/key -o IdentitiesOnly=yes -o UserKnownHostsFile=$WORK/known_hosts -o StrictHostKeyChecking=yes"

# --- has upstream actually moved? -------------------------------------------

UPSTREAM_SHA="$(git ls-remote "$UPSTREAM" "refs/heads/$UPSTREAM_REF" | awk 'NR==1 {print $1}')"
[ -n "$UPSTREAM_SHA" ] || { echo "::error::$UPSTREAM has no branch '$UPSTREAM_REF'"; exit 1; }
note "upstream $UPSTREAM@$UPSTREAM_REF is at $UPSTREAM_SHA"

TG="$WORK/target"
PREV_SHA=""

init_empty_target() {
  rm -rf "$TG"
  git init -q "$TG"
  git -C "$TG" symbolic-ref HEAD "refs/heads/$TARGET_BRANCH"
  git -C "$TG" remote add origin "$TARGET_URL"
}

if [ "$REINIT" = "1" ]; then
  note "reinit requested -- target history will be replaced"
  init_empty_target
else
  # An empty target repo makes this clone fail or land on an unborn HEAD;
  # either way the fallback gives us a repo pointed at the right branch.
  if git clone -q --depth 1 --branch "$TARGET_BRANCH" "$TARGET_URL" "$TG" 2>/dev/null &&
     git -C "$TG" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    PREV_SHA="$(git -C "$TG" log -1 --format=%B | sed -n 's/^Upstream-Commit: *//p' | head -1)"
    note "target tip mirrors upstream ${PREV_SHA:-<unknown>}"
  else
    note "target $TARGET has no $TARGET_BRANCH yet -- seeding it"
    init_empty_target
  fi
fi

if [ -n "$PREV_SHA" ] && [ "$PREV_SHA" = "$UPSTREAM_SHA" ]; then
  note "already at $UPSTREAM_SHA, nothing to sync"
  summary "### $NAME"
  summary ""
  summary "Already current at [\`${UPSTREAM_SHA:0:12}\`]($UPSTREAM_HOME/commit/$UPSTREAM_SHA) -- no commit made."
  exit 0
fi

# --- fetch the upstream tip tree --------------------------------------------

UP="$WORK/upstream"
note "cloning $UPSTREAM at depth 1"
git clone -q --depth 1 --single-branch --branch "$UPSTREAM_REF" "$UPSTREAM" "$UP"

# Authoritative values, in case upstream moved between ls-remote and clone.
UPSTREAM_SHA="$(git -C "$UP" rev-parse HEAD)"
UPSTREAM_DATE="$(git -C "$UP" log -1 --format=%cI)"
UPSTREAM_SUBJECT="$(git -C "$UP" log -1 --format=%s)"
rm -rf "$UP/.git"

while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    /*|*..*) echo "::error::refusing to strip suspicious path '$path'"; exit 1 ;;
  esac
  if [ -e "$UP/$path" ]; then
    note "stripping $path"
    rm -rf "${UP:?}/$path"
  fi
done < <(printf '%s' "$STRIP_JSON" | jq -r '.[]?')

SKIPPED=0
while IFS= read -r big; do
  [ -n "$big" ] || continue
  rel="${big#"$UP/"}"
  echo "::warning::skipping $rel -- larger than $((MAX_BLOB / 1024 / 1024)) MB, GitHub would reject the push"
  rm -f "$big"
  SKIPPED=$((SKIPPED + 1))
done < <(find "$UP" -type f -size +"${MAX_BLOB}"c -print | sort)

# --- collapse into a single commit ------------------------------------------

note "replacing target tree with the upstream snapshot"
rsync -a --delete --exclude '/.git/' "$UP/" "$TG/"
rm -rf "$UP"

cd "$TG"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git config gc.auto 0

# --force so that files upstream tracks despite its own .gitignore (build
# artifacts checked in deliberately, generated headers, and so on) still make it
# into the snapshot.
git add --all --force

if git rev-parse -q --verify HEAD >/dev/null 2>&1 && git diff --cached --quiet; then
  note "tree is byte-identical to the last snapshot, nothing to commit"
  summary "### $NAME"
  summary ""
  summary "Upstream moved to \`${UPSTREAM_SHA:0:12}\` but the tree is unchanged -- no commit made."
  exit 0
fi

CHANGED="$(git diff --cached --numstat | wc -l | tr -d ' ')"
SYNC_DATE="${UPSTREAM_DATE%%T*}"

{
  if [ -z "$PREV_SHA" ]; then
    echo "Import $UPSTREAM_SLUG @ ${UPSTREAM_SHA:0:12} ($SYNC_DATE)"
    echo
    echo "Initial squashed snapshot of $UPSTREAM_SLUG at '$UPSTREAM_REF'."
    echo "The entire upstream history is collapsed into this one commit;"
    echo "each later commit on this branch is one day's worth of changes."
  else
    echo "Sync $UPSTREAM_SLUG @ ${UPSTREAM_SHA:0:12} ($SYNC_DATE)"
    echo
    echo "Squashed snapshot of $UPSTREAM_SLUG at '$UPSTREAM_REF'."
    echo "Everything upstream committed since ${PREV_SHA:0:12}, as one commit."
  fi
  echo
  echo "Upstream tip: $UPSTREAM_SUBJECT"
  echo "Files changed: $CHANGED"
  [ "$SKIPPED" -gt 0 ] && echo "Files skipped for exceeding GitHub's blob limit: $SKIPPED"
  echo
  echo "Upstream: $UPSTREAM_HOME"
  echo "Upstream-Ref: $UPSTREAM_REF"
  echo "Upstream-Commit: $UPSTREAM_SHA"
  echo "Upstream-Date: $UPSTREAM_DATE"
  [ -n "$PREV_SHA" ] && echo "Previous-Upstream-Commit: $PREV_SHA"
} >"$WORK/msg"

# Author date tracks upstream so the branch reads chronologically against the
# project it mirrors; commit date stays real.
GIT_AUTHOR_DATE="$UPSTREAM_DATE" git commit -q --file="$WORK/msg"

note "pushing to $TARGET:$TARGET_BRANCH"
if [ "$REINIT" = "1" ]; then
  git push --force --quiet origin "HEAD:refs/heads/$TARGET_BRANCH"
else
  git push --quiet origin "HEAD:refs/heads/$TARGET_BRANCH"
fi

NEW_SHA="$(git rev-parse HEAD)"
note "done -- $TARGET is now at $NEW_SHA ($CHANGED files changed)"

summary "### $NAME"
summary ""
summary "| | |"
summary "|---|---|"
summary "| Upstream | [\`${UPSTREAM_SHA:0:12}\`]($UPSTREAM_HOME/commit/$UPSTREAM_SHA) ($SYNC_DATE) |"
summary "| Mirror commit | [\`${NEW_SHA:0:12}\`](https://github.com/$TARGET/commit/$NEW_SHA) |"
summary "| Files changed | $CHANGED |"
[ "$SKIPPED" -gt 0 ] && summary "| Files skipped (>95 MB) | $SKIPPED |"
summary ""
