---
name: ext-repos
description: >-
  Link external sibling repos into the current repo as git worktrees checked
  out on a branch matching the host repo's branch — bring a related repo's
  code into the working tree, branch-aligned, for cross-repo features. Use
  when asked to "link <repo>", "bring in <repo>", "work across repos",
  "unlink"; when a task needs files under a directory declared in repos.json
  (e.g. external/backend) that is missing or on the wrong branch; to check
  status of, pull, push, or merge linked repos; to repair worktree problems
  ("already checked out", stale worktrees after a deleted Superset
  workspace); or to onboard a repo into this model ("set up ext-repos here"
  -> ext init). Triggers: external repos, linked repos, multi-repo, matching
  branch, repos.json, ext link, ext init, ext doctor, worktree conflict.
---

# ext-repos

The model in one paragraph: `repos.json` at the host repo root declares
linkable external repos; canonical stores live in `~/dev/repos/<name>`;
`ext link` mounts each declared dir as a **git worktree** of its store,
checked out at the host's current branch (created from `origin/<base>` —
normally `dev` — when missing, and never pushed until asked). Mount dirs are
gitignored in the host. Superset runs `link --auto` / `unlink --all` in its
workspace setup/teardown hooks, so eager (`autolink: true`) repos are just
there; lazy ones are linked on demand.

Use `~/.claude/skills/ext-repos/scripts/ext.sh` as the ONLY interface (the
`ext` command on PATH is the same script; the committed `.superset/ext.sh` in
each repo is a passthrough shim). Do not read `scripts/` or `references/`
unless a command fails unexpectedly or you were asked to change the skill
itself.

## When to act unprompted

- A task touches files under a dir listed in the host's `repos.json`, but the
  dir is missing or `ext status` shows it on a branch different from the
  host's → run `ext link <dir-basename>` first, then proceed. Tell the user
  you linked it.
- Never unlink, prune, push, or pass `--force` unprompted. Linking is the
  only self-serve action.

## Commands

    ext status                     # host + each mount: branch, dirty, ahead/behind base
    ext list                       # manifest entries and link state
    ext link [<dir>|--all|--auto] [--branch X] [--detach] [--no-fetch]
    ext unlink [<dir>|--all] [--force] [--keep-branch]
    ext fetch                      # host + all canonical stores, in parallel
    ext pull [--merge]             # fetch + rebase host and mounts onto upstream/origin/<base>
    ext push [--dry-run]           # publish mounts with real commits (sets -u), then host
    ext merge-to <target> [--dry-run]   # rebase onto origin/<target> + push HEAD:<target>
    ext each -- <cmd…>             # run a command in host root + every linked mount
    ext relink                     # realign mounts after a host branch switch
    ext doctor [--fix] [--migrate] # repair stale/broken state; --migrate converts
                                   # git-submodule checkouts into links
    ext init                       # scaffold repos.json + .superset hooks + .gitignore + CLAUDE.md note (idempotent)

Exit codes: 0 ok, 1 error, 2 usage, 3 branch-checkout conflict, 4 refused
(dirty or unpushed work — never override with --force on your own).

## Onboarding a repo (user asks to "set this repo up for ext-repos")

1. Run `ext init` (safe on repos with existing files — it never overwrites).
   It also appends a short "External repos (ext-repos)" note to `CLAUDE.md`
   (creating it if absent) so agents reading the repo know the model.
2. Edit `repos.json`: add each linkable repo as
   `{ "name": "<store dir in ~/dev/repos>", "mount": "external/<dir>", "url": "git@github.com:<org>/<repo>.git" }`
   (ask the user which repos if unclear; `autolink: false` for lazy ones).
3. If a declared path is currently a git-submodule checkout, convert it with
   `ext doctor --migrate` — confirm with the user first.
4. `ext link --all` to verify, then commit `repos.json`, `.superset/`,
   `.gitignore`, and the `CLAUDE.md` note.

## Reading conflicts (exit code 3)

"already checked out at <path>" → that branch of the external repo is owned
by another live worktree (usually a Superset workspace of that repo). Relay
the owning path to the user and offer the three options `ext` prints: work in
that checkout, `--branch <other-name>`, or `--detach` (read-only). NEVER
--force, never delete the other worktree.

## Safety rules

- Never run destructive operations (`unlink` on dirty mounts, `doctor --fix`,
  `doctor --migrate`, branch deletion) without showing what will happen and
  getting explicit confirmation.
- Never push an external repo unless the user asked for that push
  (`ext push` touches every linked mount with commits — say which).
- Never run raw `git worktree`/`git branch` commands against the canonical
  stores in `~/dev/repos` — always go through `ext`.
- Linked dirs are separate repos: `git commit`/`git push` inside them applies
  to THAT repo, not the host. `cd` into the mount (or `git -C`) to operate on
  it deliberately.

## References (load only when needed)

- `references/git-mechanics.md` — worktree layout, branch matching rules,
  store discovery order, what the manifest fields mean.
- `references/troubleshooting.md` — doctor playbook: Superset deleted a
  workspace without teardown; ".lock" races; missing store on a new machine;
  detached or mismatched mounts; submodule migration.
