# mirror-controller

Daily squashed mirrors of large upstream projects.

A normal fork of the Linux kernel drags along 1.3 million commits and 6 GB of
history. These mirrors keep the *content* and throw away the *history*: the first
commit is the entire source tree, and every commit after it is one day of
upstream change collapsed into a single commit.

| mirror | upstream | target |
|---|---|---|
| `linux` | [torvalds/linux](https://github.com/torvalds/linux) `master` | [cla7aye15I4nd/linux-squashed](https://github.com/cla7aye15I4nd/linux-squashed) `master` |
| `v8` | [v8/v8](https://github.com/v8/v8) `main` | [cla7aye15I4nd/v8-squashed](https://github.com/cla7aye15I4nd/v8-squashed) `main` |

Every target is named `<project>-squashed`, so none of them can be mistaken for
an ordinary fork that still carries upstream history.

```
commit 3  Sync torvalds/linux @ a1b2c3d4e5f6 (2026-08-18)   47 files changed
commit 2  Sync torvalds/linux @ 9f8e7d6c5b4a (2026-08-17)   213 files changed
commit 1  Import torvalds/linux @ 4d5c6b7a8f90 (2026-08-16) the whole tree
```

## How it works

`.github/workflows/mirror.yml` runs at 03:17 UTC daily, fans out over the entries
in [`mirrors.yml`](mirrors.yml), and runs [`scripts/mirror.sh`](scripts/mirror.sh)
for each one. Per mirror:

1. `git ls-remote` reads the upstream tip. If the target's last commit already
   points at it, the run stops — no empty commits on quiet days.
2. `git clone --depth 1` fetches the upstream tip **tree only**. No history is
   ever downloaded, which is why a 6 GB repository costs a ~250 MB fetch.
3. `rsync -a --delete` replaces the target's working tree with that snapshot.
4. `git add --all --force && git commit` turns the whole difference into one
   commit, which is pushed to the target repo.

Where the last sync stopped is recorded in the commit message rather than in a
state file, so nothing foreign appears in the mirrored tree:

```
Upstream-Commit: 4d5c6b7a8f90...
Upstream-Ref: master
Upstream-Date: 2026-08-16T09:14:22+02:00
Previous-Upstream-Commit: 9f8e7d6c5b4a...
```

`git add` runs with `--force` on purpose: some projects track files their own
`.gitignore` would exclude, and those belong in the snapshot too.

## Design notes

**Deploy keys, not a PAT.** The workflow pushes into other repositories, which
the built-in `GITHUB_TOKEN` cannot do. Rather than an account-wide personal
access token, each target repo has its own write-scoped deploy key, with the
private half stored here as `DEPLOY_KEY_<NAME>`. A leaked key reaches exactly one
mirror.

**Upstream workflows are stripped.** Committing another project's
`.github/workflows/` into this account would turn their CI definitions into live
workflows here. The `strip` list in `mirrors.yml` drops that directory from every
snapshot; add more paths there if a project carries something else you don't
want.

**Oversized files are skipped, not fatal.** GitHub rejects any blob over 100 MB.
Files above 95 MB are dropped from the snapshot with a warning, so one huge file
cannot break the sync every day.

**The schedule keeps itself alive.** GitHub disables a cron workflow after 60
days of repository inactivity, and workflow runs don't count — the commits from
this project land in the mirror repos, not here. A `keepalive` job commits a
timestamp whenever this repo has been quiet for 45 days, so the daily run cannot
switch itself off.

## Operating it

```sh
# sync everything now
gh workflow run mirror.yml

# sync one mirror
gh workflow run mirror.yml -f only=linux

# throw away a target's history and re-seed it from a single commit
gh workflow run mirror.yml -f only=linux -f reinit=true
```

Add a project — creates the repo, the deploy key and the secret, then writes the
`mirrors.yml` entry. The target defaults to `<project>-squashed`; pass a second
argument only to override it:

```sh
scripts/add-mirror.sh https://github.com/rust-lang/rust   # -> cla7aye15I4nd/rust-squashed
git commit -am 'mirror rust' && git push
gh workflow run mirror.yml -f only=rust
```

Remove one by deleting its block from `mirrors.yml`. The deploy key and the
target repo stay until you delete them yourself.

## Limits worth knowing

- A mirror's repo grows by roughly one day of changed files per commit, so it
  stays far below a full clone — but GitHub still wants repositories under 5 GB.
- The initial import of a large project takes 10–30 minutes; later syncs are a
  few minutes.
- Only the tracked source tree is mirrored. Projects that pull dependencies at
  build time (V8's `gclient`/`DEPS`, for instance) are mirrored without those
  dependencies, exactly as upstream stores them.
- Public repositories get free Actions minutes, so the daily run costs nothing.
