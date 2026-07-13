# ext-repos

External sibling repos as **matching-branch git worktrees**. One canonical
store per repo (e.g. `~/dev/repos/acme-backend`, checkout-less); every host
worktree that needs it gets a lightweight `git worktree` mount that shares
the store's objects and refs. Sub-second setup with no network, one fetch
serves every checkout, and each mount is branch-aligned with its host — a
feature branch in the app repo gets the same-named branch in every linked
repo.

## How it works

- A host repo commits `repos.json` declaring linkable repos:

  ```json
  {
    "version": 1,
    "reposRoot": "~/dev/repos",
    "defaults": { "base": "dev", "autolink": true, "fetch": true },
    "repos": [
      { "name": "acme-backend", "mount": "external/backend",
        "url": "git@github.com:acme/acme-backend.git" }
    ]
  }
  ```

  Per-repo overrides: `base`, `autolink` (eager vs lazy), `fetch`.

- `ext link` mounts each repo as a worktree of its canonical store, on a branch
  **named after the host's current branch**: existing local branch → used;
  `origin/<branch>` → tracked; neither → created from `origin/<base>` with
  `--no-track` (stays local until `ext push`). The store is located under
  `reposRoot` by the repo's **git name** (from `url`) — falling back to
  `owner/repo`, `owner-repo`, then the manifest `name` — and confirmed by
  matching its `origin` remote, so a store you already cloned (under its git
  name) is reused rather than re-cloned under `name`.
- Mount dirs are **gitignored** in the host (`/external/`).
- Superset integration: each repo commits `.superset/config.json` whose
  `setup` runs `sh .superset/ext.sh link --auto` and whose `teardown` runs
  `sh .superset/ext.sh unlink --all --force`. `.superset/ext.sh` is a
  logic-free shim that calls this skill's `scripts/ext.sh`.
- A branch can be checked out in only one worktree per repo (git rule).
  Matching branch names make collisions impossible across workspaces of one
  host repo; cross-project collisions produce a structured error with options
  (work there / `--branch` / `--detach`) — never auto-resolved.
- Unlinking garbage-collects the matching branch only when it has no
  upstream and no commits beyond the base — published or diverged work
  always survives in the canonical store.

## Install (new machine)

```sh
git clone git@github.com:shamruk/skills-ext-repos.git ~/.claude/skills/ext-repos
~/.claude/skills/ext-repos/scripts/install.sh   # PATH block in ~/.zshrc + prereq checks
```

Update: `git -C ~/.claude/skills/ext-repos pull` — every consumer references
the scripts in place; nothing propagates or drifts.
Uninstall: `scripts/install.sh --uninstall && rm -rf ~/.claude/skills/ext-repos`.
Already-linked worktrees keep working as plain git worktrees without the skill.

## Command cheatsheet

| Command | Does |
|---|---|
| `ext status` / `ext s` | Host + mounts: branch, dirty, ahead/behind base (terminal colors preserve Git's status palette and show `+ahead` green / `-behind` red; set `NO_COLOR=1` to disable) |
| `ext list` | Manifest entries and link state |
| `ext link [dir\|--all\|--auto] [--branch X] [--detach] [--no-fetch]` | mount worktree(s) at the matching branch |
| `ext unlink [dir\|--all] [--force] [--keep-branch]` | remove mount(s); prunes branches with no real commits |
| `ext fetch` | fetch host + all stores in parallel (one fetch serves every worktree) |
| `ext pull [--merge]` | fetch + rebase(/merge) host and mounts onto upstream or `origin/<base>` |
| `ext push [--dry-run]` | publish mounts with commits beyond base (`push -u origin HEAD`), then host |
| `ext merge-to <target> [--dry-run]` | rebase onto `origin/<target>`, push `HEAD:<target>` — no checkout of target |
| `ext each -- <cmd>` | run cmd in host + every mount |
| `ext relink` | realign mounts after a host branch switch |
| `ext doctor [--fix] [--migrate]` | repair stale registrations, orphaned branches, broken links; convert submodule checkouts |
| `ext init` | scaffold the per-repo footprint (repos.json skeleton, `.superset/` hooks, `.gitignore`) — idempotent |

## Per-repo footprint (committed)

- `repos.json` — the manifest (repos with no external deps can omit it; the
  shim + hooks then no-op).
- `.superset/ext.sh` — 10-line passthrough shim (identical in every repo).
- `.superset/config.json` — `{ setup: link --auto, teardown: unlink --all --force }`.
- `.gitignore` — `/external/` and `.superset/config.local.json`.

`ext init` creates all of it.

## Exit codes

`0` ok · `1` error · `2` usage · `3` branch-checkout conflict · `4` refused
(dirty / unpushed work).
