# ext-repos: troubleshooting playbook

## "already checked out at <path>" (exit 3)

The wanted branch of the external repo lives in another worktree.

- **Path exists** → a real workspace owns it. Options: work on the external
  repo there; `ext link <dir> --branch <other-name>`; `ext link <dir>
  --detach` (read-only). Do not force.
- **Path does NOT exist** → stale registration (workspace deleted without
  teardown). `ext doctor --fix` prunes it; `ext link` also self-heals by
  running `worktree prune --expire=now` first, so simply re-running the link
  usually works.

## Linking the store's own default branch (usually `main`) is refused

A checkout-less canonical store's primary worktree still *holds* the branch
its HEAD points at (usually `main`), so a writable mount of that branch is
impossible by git's one-checkout-per-branch rule. `ext` prints a specialized
message. Use `ext link <dir> --detach` (read-only at the tip — the normal
want for base/release branches), or work on a feature branch. Stores that
`ext` clones itself (on first link) are created with a detached HEAD and
don't have this limitation.

## Superset deleted a workspace without running teardown

Symptoms: `ext link` of the same branch name refused, or `git branch -d`
refused in the store. Fix: `ext doctor --fix` (prunes stale registrations,
then deletes orphaned matching branches that have no upstream and no commits
beyond their base).

## Mount directory was deleted manually (`rm -rf external/x`)

Same as above — the store still has the registration. `ext link` self-heals;
`ext doctor --fix` cleans up explicitly.

## Mount moved or `.git` file broken

`ext doctor --fix` runs `git worktree repair` against the store.

## Canonical store missing (new machine, or a lazy repo's first use)

`ext link <dir>` clones it from the manifest `url` with
`git clone --no-checkout` into `<reposRoot>/<name>` (checkout-less, detached
HEAD) as part of linking — a not-yet-cloned repo materializes in one step.
`ext link --all` does this for every declared repo. `ext status` reports such
a repo as "not cloned yet"; `ext doctor` reports it too but does **not** clone
(materialization belongs to `link`, not the repair tool). A missing store with
no `url` in the manifest is the one real error — there's nothing to clone from.

## `.lock` errors during concurrent links

Two `ext link` runs raced on one store. `ext` retries once automatically;
if it still fails, just re-run — git's own locking guarantees consistency,
the loser only errors.

## Mount on the wrong branch after a host `git switch`

Mounts don't auto-follow. `ext status` flags the mismatch; `ext relink`
unlinks (refusing if dirty) and relinks at the new host branch.

## Legacy submodule checkout in the way

`ext link` refuses dirs whose `.git` file points into `modules/` (old
submodule layout). `ext doctor --migrate` verifies the checkout is clean with
nothing unpushed, removes the working dir and its module storage, then links
the replacement mount. If it reports local changes, deal with them first
(push from inside the old checkout — it's a normal repo).

## Uncommitted work lost with `unlink --force` / teardown?

Uncommitted changes in a force-removed mount are gone (same as deleting any
worktree). *Committed* work is never lost: branch GC only deletes branches
that are ancestors of `origin/<base>`; anything with real commits survives in
the canonical store and relinks on the next `ext link` from any workspace on
that branch.

## Detached mount

Created by `--detach` (read-only snapshot). It never pushes and `ext push`
skips it. To make it editable: `ext unlink <dir> && ext link <dir>` (or
`--branch <name>`).
