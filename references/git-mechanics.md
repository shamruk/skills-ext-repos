# ext-repos: git mechanics

## Layout

- **Canonical store**: `<reposRoot>/<name>` (default `~/dev/repos/<name>`).
  Non-bare but checkout-less (only `.git` on disk; Superset's layout). It owns
  the object store, all refs, and the `worktrees/` registry for every mount.
- **Mount**: `<host>/<mount>` (e.g. `external/backend`) created by
  `git -C <store> worktree add …`. Its `.git` is a *file* containing
  `gitdir: <store>/.git/worktrees/<id>`. All worktrees of one store share
  objects and refs: a fetch anywhere updates everyone; `gc` runs once.
- Store discovery order: `$EXT_REPOS_STORE` → manifest `reposRoot` →
  `dirname $SUPERSET_ROOT_PATH` (set inside Superset hooks). First candidate
  where `<dir>/<name>` is a git repo wins.

## Branch resolution (link)

Host on branch `B`, manifest base `<base>` (default `dev`):

0. **Store missing?** If `<reposRoot>/<name>` isn't cloned yet, clone it from
   the manifest `url` with `git clone --no-checkout`, then detach its HEAD so
   the checkout-less primary worktree owns no branch. This makes the first
   `ext link` of a lazy repo a one-step materialize-and-link; no `url` and no
   store → hard error (nothing to clone). Freshly cloned stores skip the fetch
   in step 2 (their refs are already current).
1. `git worktree prune --expire=now` in the store (self-heals registrations
   left by workspaces deleted without teardown).
2. Fetch `origin --prune` (unless `fetch: false` or `--no-fetch`); offline is
   a warning, not an error.
3. Local `B` exists → `worktree add <mount> B`.
4. Only `origin/B` → `branch --track B origin/B`, then add. (Covers work
   pushed from another machine.)
5. Neither → `worktree add --no-track -b B <mount> origin/<base>` and record
   `branch.B.base = <base>` in the store. `--no-track` matters: with tracking
   set to `origin/<base>`, a bare `git push` inside the mount would target
   the base branch. The new branch is invisible to GitHub until `ext push`.

Always fork from `origin/<base>`, never `refs/heads/<base>` — stores may have
no local base branch, and stale local bases would bite.

## Collisions

Git allows a branch in exactly one worktree per repo. Matching branch names
mean: within one host repo's workspaces, collisions are impossible (Superset
gives each branch one worktree). A collision therefore means another
*project's* workspace (e.g. a dedicated cms workspace) or the store's own
primary slot (holds `main`) owns the branch. `ext` errors with the owning
path and three options; it never detaches, renames, or force-moves anything
on its own. `--detach` mounts a read-only snapshot at the branch tip (or
`origin/<base>` if the branch doesn't exist).

## Unlink + branch GC

`unlink` refuses when the mount is dirty or has commits on no remote
(`--force` overrides; committed work still survives on the branch in the
store — git never loses commits on branch deletion refusal). After
`worktree remove`, the matching branch is deleted **only if** it has no
upstream AND is an ancestor of `origin/<base>` (i.e. it never got real
commits, or they were fully merged). Base/main/master branches are never
GC'd. `--keep-branch` skips GC.

## Superset lifecycle

- Workspace create → setup hook `sh .superset/ext.sh link --auto` → eager
  repos mounted.
- Workspace delete via UI → teardown `unlink --all --force` → registrations
  removed, empty matching branches pruned.
- Workspace deleted *without* teardown (crash, manual rm) → stale
  registration in the store pins the branch as "checked out". Self-heals at
  the next `ext link` (prune step) or `ext doctor --fix`.

## Manifest fields

| Field | Meaning | Default |
|---|---|---|
| `reposRoot` | where canonical stores live | `~/dev/repos` |
| `defaults.base` | branch new matching branches fork from | `dev` |
| `defaults.autolink` | linked by `link --auto` (Superset setup) | `true` |
| `defaults.fetch` | fetch store before resolving branches | `true` |
| `repos[].name` | store dir name + GitHub repo name | required |
| `repos[].mount` | host-relative mount path | required |
| `repos[].url` | clone URL — `ext link` clones the store from it on first link | optional (required to auto-clone a lazy store) |
| `repos[].base/autolink/fetch` | per-repo overrides | inherit |
