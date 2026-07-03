#!/usr/bin/env bash
# ext — link external sibling repos into the current repo as git worktrees
# checked out on a branch matching the host repo's branch. Canonical stores
# live in ~/dev/repos; every link shares a store's objects/refs, and nothing
# about a link is committed into the host repo beyond the manifest.
#
# Part of the ext-repos skill (github.com/shamruk/skills-ext-repos).
# Manifest: repos.json at the host repo root. Dependencies: git >= 2.31, jq.
# Compatible with macOS /bin/bash 3.2.
#
# Exit codes:
#   0 ok · 1 error · 2 usage · 3 branch-checkout conflict · 4 refused (dirty/unpushed)

set -euo pipefail

EXT_HOME="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
EXT_VERSION="$(cat "$EXT_HOME/VERSION" 2>/dev/null || echo dev)"

say()  { printf '%s\n' "$*"; }
note() { printf 'ext: %s\n' "$*"; }
warn() { printf 'ext: warning: %s\n' "$*" >&2; }
err()  { printf 'ext: error: %s\n' "$*" >&2; }
die()  { err "$1"; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
ext — external repos as matching-branch git worktrees (manifest: repos.json)

usage: ext <command> [args]

  link [mount…|--all|--auto] [--branch X] [--detach] [--no-fetch]
        Mount external repo(s) as worktrees at the host's current branch
        (created from origin/<base> when missing; never auto-pushed).
        --auto links only repos with autolink=true (used by Superset setup).
  unlink [mount…|--all] [--force] [--keep-branch]
        Remove mount(s). Refuses dirty/unpushed unless --force. Deletes the
        matching branch in the store when it has no commits beyond the base.
  status            Host + each mount: branch, dirty, ahead/behind base.
  list              Manifest entries and their link state.
  fetch             Fetch host + all canonical stores (parallel).
  pull [--merge]    Fetch, then rebase (or merge) host + mounts onto
                    upstream or origin/<base>.
  push [--dry-run]  Push mounts that have commits beyond origin/<base>
                    (publishes matching branch with -u), then the host.
  merge-to <target> [--dry-run]
        Per repo with commits beyond origin/<target>: rebase onto it, then
        push HEAD:<target> — merges without checking <target> out anywhere.
  each -- <cmd…>    Run a command in the host root and every linked mount.
  relink            Realign mounts after a host branch switch.
  init              Scaffold the per-repo footprint in the current repo:
                    repos.json skeleton, .superset/{ext.sh,config.json},
                    .gitignore entries, and a short ext-repos note in
                    CLAUDE.md. Idempotent; commit the result.
  doctor [--fix] [--migrate]
        Repair stale worktree registrations, orphaned matching branches,
        broken links, missing stores; --migrate converts legacy submodule
        checkouts into links.
  version | help

Repos are addressed by mount basename (e.g. `ext link backend`) or full
manifest name. Manifest lookup walks up from $PWD; no repos.json = no-op.
EOF
}

# ---------------------------------------------------------------- host + manifest

find_host_root() {
  local top parent
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  while :; do
    if [[ -f "$top/repos.json" ]]; then printf '%s' "$top"; return 0; fi
    parent="$(dirname "$top")"
    [[ "$parent" == "/" || "$parent" == "$HOME" ]] && return 1
    top="$(cd "$parent" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" || return 1
  done
}

load_manifest() {
  MANIFEST="$HOST_ROOT/repos.json"
  jq -e . "$MANIFEST" >/dev/null 2>&1 || die "invalid JSON in $MANIFEST"
  REPOS_ROOT="$(jq -r '.reposRoot // "~/dev/repos"' "$MANIFEST")"
  REPOS_ROOT="${REPOS_ROOT/#\~/$HOME}"
  DEF_BASE="$(jq -r '.defaults.base // "dev"' "$MANIFEST")"
  # NB: jq's // treats boolean false as empty — use has() for boolean defaults.
  DEF_AUTOLINK="$(jq -r '.defaults // {} | if has("autolink") then .autolink else true end' "$MANIFEST")"
  DEF_FETCH="$(jq -r '.defaults // {} | if has("fetch") then .fetch else true end' "$MANIFEST")"
  R_NAME=(); R_MOUNT=(); R_URL=(); R_BASE=(); R_AUTOLINK=(); R_FETCH=()
  local n i
  n="$(jq -r '.repos // [] | length' "$MANIFEST")"
  for ((i = 0; i < n; i++)); do
    R_NAME+=("$(jq -r ".repos[$i].name // empty" "$MANIFEST")")
    R_MOUNT+=("$(jq -r ".repos[$i].mount // empty" "$MANIFEST")")
    R_URL+=("$(jq -r ".repos[$i].url // empty" "$MANIFEST")")
    R_BASE+=("$(jq -r ".repos[$i].base // \"$DEF_BASE\"" "$MANIFEST")")
    R_AUTOLINK+=("$(jq -r --argjson d "$DEF_AUTOLINK" ".repos[$i] | if has(\"autolink\") then .autolink else \$d end" "$MANIFEST")")
    R_FETCH+=("$(jq -r --argjson d "$DEF_FETCH" ".repos[$i] | if has(\"fetch\") then .fetch else \$d end" "$MANIFEST")")
    [[ -n "${R_NAME[$i]}" && -n "${R_MOUNT[$i]}" ]] || die "repos[$i] in $MANIFEST needs both 'name' and 'mount'"
  done
  N_REPOS="$n"
}

repo_seq() { # 0..N_REPOS-1, safely (BSD seq counts DOWN when last < first)
  ((N_REPOS > 0)) || return 0
  seq 0 $((N_REPOS - 1))
}

repo_index() { # selector (mount basename | mount path | name) -> index on stdout
  local sel="${1%/}" i
  for i in $(repo_seq); do
    if [[ "$sel" == "${R_NAME[$i]}" || "$sel" == "${R_MOUNT[$i]}" || "$sel" == "$(basename "${R_MOUNT[$i]}")" ]]; then
      printf '%s' "$i"
      return 0
    fi
  done
  return 1
}

canon_dir() { # name -> canonical store path on stdout
  local name="$1" c
  for c in "${EXT_REPOS_STORE:-}" "$REPOS_ROOT" "${SUPERSET_ROOT_PATH:+$(dirname "$SUPERSET_ROOT_PATH")}"; do
    [[ -n "$c" && -d "$c/$name" ]] || continue
    if git -C "$c/$name" rev-parse --git-dir >/dev/null 2>&1; then
      printf '%s' "$c/$name"
      return 0
    fi
  done
  return 1
}

host_base() {
  git -C "$HOST_ROOT" config "branch.$HOST_BRANCH.base" 2>/dev/null || echo "$DEF_BASE"
}

# ------------------------------------------------------------------- mount state

mount_state() { # <abs mount> <canon> -> absent|empty-dir|linked|foreign-worktree|legacy-submodule|clone|occupied
  local m="$1" canon="$2" common
  [[ -e "$m" ]] || { echo absent; return; }
  if [[ -f "$m/.git" ]]; then
    # submodule gitdirs: .git/modules/<x> or .git/worktrees/<wt>/modules/<x>;
    # plain worktree gitdirs (.git/worktrees/<id>) must NOT match.
    if grep -Eq '\.git/(worktrees/[^/]+/)?modules/' "$m/.git" 2>/dev/null; then echo legacy-submodule; return; fi
    common="$(git -C "$m" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [[ -n "$common" && "$common" == "$(cd "$canon" && pwd -P)/.git" ]]; then
      echo linked
    else
      echo foreign-worktree
    fi
    return
  fi
  if [[ -d "$m/.git" ]]; then echo clone; return; fi
  if [[ -d "$m" && -z "$(ls -A "$m" 2>/dev/null)" ]]; then echo empty-dir; else echo occupied; fi
}

is_linked() { # idx
  local canon
  canon="$(canon_dir "${R_NAME[$1]}")" || return 1
  [[ "$(mount_state "$HOST_ROOT/${R_MOUNT[$1]}" "$canon")" == "linked" ]]
}

owner_of_branch() { # <canon> <branch> -> worktree path holding it (empty if none)
  git -C "$1" worktree list --porcelain | awk -v b="branch refs/heads/$2" '
    /^worktree /{wt=substr($0,10)} $0==b{print wt; exit}'
}

conflict_error() { # <mount_rel> <name> <branch> <owner-path>
  {
    echo "ext: cannot link $1 at branch '$3'"
    echo "  branch '$3' of $2 is already checked out at:"
    echo "    $4"
    echo "  options:"
    echo "    - work on $2 in that checkout"
    echo "    - ext link $(basename "$1") --branch <other-name>"
    echo "    - ext link $(basename "$1") --detach   # read-only snapshot"
  } >&2
}

store_holds_branch_error() { # <mount_rel> <name> <branch> <canon>
  {
    echo "ext: cannot link $1 at branch '$3'"
    echo "  the canonical store itself holds '$3' (its checkout-less primary worktree):"
    echo "    $4"
    echo "  options:"
    echo "    - ext link $(basename "$1") --detach           # read-only mount at '$3' tip (usual for base/release branches)"
    echo "    - ext link $(basename "$1") --branch <other>   # editable mount on another branch"
  } >&2
}

try_worktree_add() { # <canon> <worktree-add args…>
  local canon="$1" out
  shift
  if out="$(git -C "$canon" worktree add "$@" 2>&1)"; then
    [[ -n "$out" ]] && say "$out"
    return 0
  fi
  if printf '%s' "$out" | grep -qi '\.lock'; then # transient lock race — retry once
    sleep 1
    if out="$(git -C "$canon" worktree add "$@" 2>&1)"; then
      [[ -n "$out" ]] && say "$out"
      return 0
    fi
  fi
  err "$out"
  # git <2.36 says "already checked out"; newer says "already used by worktree"
  if printf '%s' "$out" | grep -Eq 'already (checked out|used by worktree)'; then return 3; fi
  return 1
}

# ------------------------------------------------------------------------- link

link_one() { # idx (uses LINK_BRANCH_OVERRIDE, LINK_DETACH, LINK_NO_FETCH)
  local i="$1"
  local name="${R_NAME[$i]}" mount_rel="${R_MOUNT[$i]}" base="${R_BASE[$i]}"
  local m="$HOST_ROOT/$mount_rel"
  local want="${LINK_BRANCH_OVERRIDE:-$HOST_BRANCH}"
  local canon cur owner
  if ! canon="$(canon_dir "$name")"; then
    err "$name: canonical store not found under $REPOS_ROOT"
    err "  fix: ext doctor --fix   (clones ${R_URL[$i]:-<no url in manifest>})"
    return 1
  fi
  case "$(mount_state "$m" "$canon")" in
    linked)
      cur="$(git -C "$m" symbolic-ref --short -q HEAD || echo '(detached)')"
      if [[ "$cur" == "$want" ]]; then
        note "$mount_rel: already linked ($name @ $cur)"
        return 0
      fi
      if [[ -n "$LINK_BRANCH_OVERRIDE" ]]; then
        err "$mount_rel: already linked on '$cur' — to move it: ext unlink $(basename "$mount_rel") && ext link $(basename "$mount_rel") --branch $want"
        return 1
      fi
      warn "$mount_rel: linked but on '$cur' while host wants '$want' — run 'ext relink'"
      return 0 ;;
    legacy-submodule)
      err "$mount_rel: legacy submodule checkout — run 'ext doctor --migrate'"
      return 1 ;;
    foreign-worktree)
      err "$mount_rel: is a worktree of a different repo — remove it manually, then re-run"
      return 1 ;;
    clone)
      err "$mount_rel: is a standalone clone — remove it manually, then re-run"
      return 1 ;;
    occupied)
      err "$mount_rel: directory exists and is not empty — remove it manually, then re-run"
      return 1 ;;
  esac
  git -C "$canon" worktree prune --expire=now 2>/dev/null || true # self-heal stale registrations
  if [[ "${R_FETCH[$i]}" == "true" && "$LINK_NO_FETCH" != "true" ]]; then
    git -C "$canon" fetch origin --prune --quiet 2>/dev/null \
      || warn "$name: fetch failed (offline?) — using local refs"
  fi
  mkdir -p "$(dirname "$m")"
  if [[ "$LINK_DETACH" == "true" ]]; then
    local ref="origin/$base"
    git -C "$canon" show-ref --verify -q "refs/heads/$want" && ref="$want"
    try_worktree_add "$canon" --detach "$m" "$ref" || return $?
    say "linked $mount_rel <- $name @ detached ($ref)"
    return 0
  fi
  owner="$(owner_of_branch "$canon" "$want")"
  if [[ -n "$owner" ]]; then
    if [[ "$owner" == "$(cd "$canon" && pwd -P)" || "$owner" == "$canon" ]]; then
      store_holds_branch_error "$mount_rel" "$name" "$want" "$canon"
    else
      conflict_error "$mount_rel" "$name" "$want" "$owner"
    fi
    return 3
  fi
  if git -C "$canon" show-ref --verify -q "refs/heads/$want"; then
    try_worktree_add "$canon" "$m" "$want" || return $?
    say "linked $mount_rel <- $name @ $want (existing branch)"
  elif git -C "$canon" show-ref --verify -q "refs/remotes/origin/$want"; then
    git -C "$canon" branch --track "$want" "origin/$want" >/dev/null
    try_worktree_add "$canon" "$m" "$want" || return $?
    say "linked $mount_rel <- $name @ $want (from origin/$want, tracking)"
  else
    if ! git -C "$canon" show-ref --verify -q "refs/remotes/origin/$base"; then
      err "$name: neither branch '$want' nor base 'origin/$base' exists in $canon"
      return 1
    fi
    # --no-track: a bare `git push` from the mount must never target the base branch.
    try_worktree_add "$canon" --no-track -b "$want" "$m" "origin/$base" || return $?
    git -C "$canon" config "branch.$want.base" "$base"
    say "linked $mount_rel <- $name @ $want (new, forked from origin/$base, local-only until 'ext push')"
  fi
}

cmd_link() {
  LINK_BRANCH_OVERRIDE=""
  LINK_DETACH=false
  LINK_NO_FETCH=false
  local sel=() auto=false s ix i rc=0
  while (($#)); do
    case "$1" in
      --all) ;;
      --auto) auto=true ;;
      --branch) [[ $# -ge 2 ]] || die "link: --branch needs a value" 2; LINK_BRANCH_OVERRIDE="$2"; shift ;;
      --detach) LINK_DETACH=true ;;
      --no-fetch) LINK_NO_FETCH=true ;;
      -*) die "link: unknown flag $1" 2 ;;
      *) sel+=("$1") ;;
    esac
    shift
  done
  if [[ -z "$HOST_BRANCH" && -z "$LINK_BRANCH_OVERRIDE" && "$LINK_DETACH" != "true" ]]; then
    die "host is on a detached HEAD — use --branch <name> or --detach"
  fi
  local idxs=()
  if ((${#sel[@]})); then
    for s in "${sel[@]}"; do
      ix="$(repo_index "$s")" || die "unknown repo: $s (see 'ext list')" 2
      idxs+=("$ix")
    done
  else
    for i in $(repo_seq); do
      if [[ "$auto" == "true" && "${R_AUTOLINK[$i]}" != "true" ]]; then continue; fi
      idxs+=("$i")
    done
  fi
  ((${#idxs[@]})) || { note "nothing to link"; return 0; }
  for i in ${idxs[@]+"${idxs[@]}"}; do
    link_one "$i" || rc=$?
  done
  return $rc
}

# ----------------------------------------------------------------------- unlink

unlink_one() { # idx force keep_branch
  local i="$1" force="$2" keep="$3"
  local name="${R_NAME[$i]}" mount_rel="${R_MOUNT[$i]}" base="${R_BASE[$i]}"
  local m="$HOST_ROOT/$mount_rel"
  local canon state br
  canon="$(canon_dir "$name")" || { warn "$mount_rel: canonical store missing; skipping"; return 0; }
  state="$(mount_state "$m" "$canon")"
  if [[ "$state" != "linked" ]]; then
    if [[ "$state" == "absent" ]]; then note "$mount_rel: not linked"; else warn "$mount_rel: not a linked worktree ($state); skipping"; fi
    return 0
  fi
  br="$(git -C "$m" symbolic-ref --short -q HEAD || echo '')"
  if [[ "$force" != "true" ]]; then
    if [[ -n "$(git -C "$m" status --porcelain)" ]]; then
      err "$mount_rel: has uncommitted changes — commit/stash them, or --force to discard"
      return 4
    fi
    if [[ -n "$(git -C "$m" log --oneline -1 HEAD --not --remotes 2>/dev/null)" ]]; then
      err "$mount_rel: has commits not on any remote — 'ext push' first, or --force (commits stay on branch '$br' in $canon)"
      return 4
    fi
  fi
  if [[ "$force" == "true" ]]; then
    git -C "$canon" worktree remove --force "$m" \
      || { err "$mount_rel: 'git worktree remove' failed (see above)"; return 1; }
  else
    git -C "$canon" worktree remove "$m" \
      || { err "$mount_rel: 'git worktree remove' failed (see above)"; return 1; }
  fi
  say "unlinked $mount_rel"
  if [[ "$keep" != "true" && -n "$br" && "$br" != "$base" && "$br" != "main" && "$br" != "master" ]]; then
    if git -C "$canon" rev-parse --verify -q --abbrev-ref "$br@{upstream}" >/dev/null 2>&1; then
      note "  kept branch '$br' in $name (has upstream)"
    elif git -C "$canon" merge-base --is-ancestor "$br" "origin/$base" 2>/dev/null; then
      if git -C "$canon" branch -D "$br" >/dev/null 2>&1; then
        git -C "$canon" config --unset "branch.$br.base" 2>/dev/null || true
        say "  pruned branch '$br' in $name (no commits beyond origin/$base)"
      else
        note "  kept branch '$br' in $name (delete failed)"
      fi
    else
      note "  kept branch '$br' in $name (has commits beyond origin/$base)"
    fi
  fi
}

cmd_unlink() {
  local sel=() force=false keep=false s ix i rc=0
  while (($#)); do
    case "$1" in
      --all) ;;
      --force) force=true ;;
      --keep-branch) keep=true ;;
      -*) die "unlink: unknown flag $1" 2 ;;
      *) sel+=("$1") ;;
    esac
    shift
  done
  local idxs=()
  if ((${#sel[@]})); then
    for s in "${sel[@]}"; do
      ix="$(repo_index "$s")" || die "unknown repo: $s (see 'ext list')" 2
      idxs+=("$ix")
    done
  else
    for i in $(repo_seq); do idxs+=("$i"); done
  fi
  ((${#idxs[@]})) || { note "nothing to unlink"; return 0; }
  for i in ${idxs[@]+"${idxs[@]}"}; do
    unlink_one "$i" "$force" "$keep" || rc=$?
  done
  return $rc
}

# ----------------------------------------------------------------- status / list

cmd_status() {
  say "== $HOST_NAME @ ${HOST_BRANCH:-(detached)}"
  git -C "$HOST_ROOT" status -sb | sed 's/^/  /'
  local i
  for i in $(repo_seq); do
    local name="${R_NAME[$i]}" mount_rel="${R_MOUNT[$i]}" base="${R_BASE[$i]}"
    local m="$HOST_ROOT/$mount_rel"
    local canon state
    if ! canon="$(canon_dir "$name")"; then
      say "== $mount_rel ($name): canonical store MISSING — ext doctor --fix"
      continue
    fi
    state="$(mount_state "$m" "$canon")"
    if [[ "$state" == "absent" ]]; then
      say "== $mount_rel ($name): not linked"
      continue
    elif [[ "$state" != "linked" ]]; then
      say "== $mount_rel ($name): $state (!) — see 'ext doctor'"
      continue
    fi
    local br dirty behind=0 ahead=0 up extra=""
    br="$(git -C "$m" symbolic-ref --short -q HEAD || echo '(detached)')"
    dirty="$(git -C "$m" status --porcelain | wc -l | tr -d ' ')"
    if git -C "$m" rev-parse --verify -q "origin/$base" >/dev/null 2>&1; then
      read -r behind ahead <<<"$(git -C "$m" rev-list --left-right --count "origin/$base...HEAD")"
      extra=" | +$ahead/-$behind vs origin/$base"
    fi
    up="$(git -C "$m" rev-parse --verify -q --abbrev-ref '@{upstream}' 2>/dev/null || true)"
    [[ -n "$up" ]] && extra="$extra | upstream $up"
    [[ "$dirty" != "0" ]] && extra="$extra | DIRTY($dirty)"
    [[ "$br" == "(detached)" ]] && extra="$extra | (!) detached"
    [[ -n "$HOST_BRANCH" && "$br" != "(detached)" && "$br" != "$HOST_BRANCH" ]] && extra="$extra | (!) differs from host branch — ext relink"
    say "== $mount_rel ($name) @ $br$extra"
    git -C "$m" status -s | awk 'NR<=20{print "  " $0}' # awk drains stdin: no SIGPIPE under pipefail
  done
}

cmd_list() {
  ((N_REPOS)) || { note "no repos declared in $MANIFEST"; return 0; }
  local i
  for i in $(repo_seq); do
    local state="not linked" br=""
    if is_linked "$i"; then
      state="linked"
      br=" @ $(git -C "$HOST_ROOT/${R_MOUNT[$i]}" symbolic-ref --short -q HEAD || echo detached)"
    fi
    say "${R_MOUNT[$i]}  <-  ${R_NAME[$i]}  (base ${R_BASE[$i]}, autolink ${R_AUTOLINK[$i]})  —  $state$br"
  done
}

# ------------------------------------------------------------ fetch / pull / push

cmd_fetch() {
  local pids=() labels=() seen=" " i k rc=0 canon
  git -C "$HOST_ROOT" fetch origin --prune &
  pids+=($!); labels+=("$HOST_NAME")
  for i in $(repo_seq); do
    canon="$(canon_dir "${R_NAME[$i]}")" || continue
    case "$seen" in *" $canon "*) continue ;; esac
    seen="$seen$canon "
    git -C "$canon" fetch origin --prune &
    pids+=($!); labels+=("${R_NAME[$i]}")
  done
  for k in ${pids[@]+"${!pids[@]}"}; do
    wait "${pids[$k]}" || { warn "fetch failed: ${labels[$k]}"; rc=1; }
  done
  return $rc
}

pull_dir() { # dir base mode label
  local d="$1" base="$2" mode="$3" label="$4" target
  if [[ -n "$(git -C "$d" status --porcelain)" ]]; then
    warn "$label: dirty — skipped"
    return 0
  fi
  if git -C "$d" rev-parse --verify -q --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    target='@{upstream}'
  elif git -C "$d" rev-parse --verify -q "origin/$base" >/dev/null 2>&1; then
    target="origin/$base"
  else
    warn "$label: no upstream and no origin/$base — skipped"
    return 0
  fi
  if [[ "$mode" == "merge" ]]; then
    git -C "$d" merge --no-edit "$target"
  else
    git -C "$d" rebase "$target"
  fi
}

cmd_pull() {
  local mode=rebase i a
  for a in "$@"; do
    case "$a" in
      --merge) mode=merge ;;
      *) die "pull: unknown argument $a" 2 ;;
    esac
  done
  cmd_fetch || true
  pull_dir "$HOST_ROOT" "$(host_base)" "$mode" "$HOST_NAME"
  for i in $(repo_seq); do
    is_linked "$i" || continue
    pull_dir "$HOST_ROOT/${R_MOUNT[$i]}" "${R_BASE[$i]}" "$mode" "${R_MOUNT[$i]}"
  done
}

cmd_push() {
  local dry=() i br ahead a
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=(--dry-run) ;;
      *) die "push: unknown argument $a" 2 ;;
    esac
  done
  for i in $(repo_seq); do
    is_linked "$i" || continue
    local m="$HOST_ROOT/${R_MOUNT[$i]}" base="${R_BASE[$i]}" label="${R_MOUNT[$i]}"
    br="$(git -C "$m" symbolic-ref --short -q HEAD || echo '')"
    [[ -z "$br" ]] && { warn "$label: detached — skipped"; continue; }
    ahead=0
    if git -C "$m" rev-parse --verify -q "origin/$base" >/dev/null 2>&1; then
      ahead="$(git -C "$m" rev-list --count "origin/$base..HEAD")"
    fi
    if [[ "$ahead" == "0" ]]; then
      note "$label: no commits beyond origin/$base — skipped"
      continue
    fi
    git -C "$m" push -u ${dry[@]+"${dry[@]}"} origin HEAD
  done
  if [[ -n "$HOST_BRANCH" ]]; then
    git -C "$HOST_ROOT" push -u ${dry[@]+"${dry[@]}"} origin HEAD
  else
    warn "$HOST_NAME: detached HEAD — host push skipped"
  fi
}

cmd_merge_to() {
  local target="" dry=false a
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=true ;;
      -*) die "merge-to: unknown flag $a" 2 ;;
      *) [[ -n "$target" ]] && die "merge-to: one target only" 2; target="$a" ;;
    esac
  done
  [[ -n "$target" ]] || die "merge-to: target branch required (e.g. ext merge-to dev)" 2
  local dirs=() labels=() i k
  for i in $(repo_seq); do
    is_linked "$i" || continue
    dirs+=("$HOST_ROOT/${R_MOUNT[$i]}"); labels+=("${R_MOUNT[$i]}")
  done
  dirs+=("$HOST_ROOT"); labels+=("$HOST_NAME")
  for k in ${dirs[@]+"${!dirs[@]}"}; do
    local d="${dirs[$k]}" label="${labels[$k]}" cnt
    git -C "$d" fetch origin --prune --quiet 2>/dev/null || warn "$label: fetch failed"
    if ! git -C "$d" rev-parse --verify -q "origin/$target" >/dev/null 2>&1; then
      warn "$label: no origin/$target — skipped"
      continue
    fi
    cnt="$(git -C "$d" rev-list --count "origin/$target..HEAD")"
    if [[ "$cnt" == "0" ]]; then
      note "$label: nothing to merge into $target"
      continue
    fi
    if [[ -n "$(git -C "$d" status --porcelain)" ]]; then
      err "$label: dirty — commit or stash first"
      return 4
    fi
    git -C "$d" rebase "origin/$target"
    if [[ "$dry" == "true" ]]; then
      say "== $label -> $target ($cnt commits, rebased, NOT pushed):"
      git -C "$d" log --oneline "origin/$target..HEAD" | sed 's/^/  /'
    else
      git -C "$d" push origin "HEAD:refs/heads/$target"
      say "$label: merged $cnt commits into $target"
    fi
  done
}

cmd_each() {
  [[ "${1:-}" == "--" ]] && shift
  (($#)) || die "each: command required (ext each -- git tag v1)" 2
  local rc=0 i
  say "== $HOST_NAME ($HOST_ROOT)"
  (cd "$HOST_ROOT" && "$@") || rc=1
  for i in $(repo_seq); do
    is_linked "$i" || continue
    say "== ${R_MOUNT[$i]}"
    (cd "$HOST_ROOT/${R_MOUNT[$i]}" && "$@") || rc=1
  done
  return $rc
}

cmd_relink() {
  (($#)) && die "relink: takes no arguments" 2
  [[ -n "$HOST_BRANCH" ]] || die "host is on a detached HEAD — nothing to align to"
  LINK_BRANCH_OVERRIDE=""; LINK_DETACH=false; LINK_NO_FETCH=false
  local i rc=0 br m canon owner
  for i in $(repo_seq); do
    if is_linked "$i"; then
      m="$HOST_ROOT/${R_MOUNT[$i]}"
      br="$(git -C "$m" symbolic-ref --short -q HEAD || echo '')"
      if [[ -z "$br" ]]; then
        note "${R_MOUNT[$i]}: detached (deliberate --detach) — left as is"
        continue
      fi
      [[ "$br" == "$HOST_BRANCH" ]] && continue
      canon="$(canon_dir "${R_NAME[$i]}")" || continue
      owner="$(owner_of_branch "$canon" "$HOST_BRANCH")"
      if [[ -n "$owner" ]]; then
        warn "${R_MOUNT[$i]}: '$HOST_BRANCH' is already checked out at $owner — left on '$br'"
        rc=3
        continue
      fi
      if ! unlink_one "$i" false false; then
        warn "${R_MOUNT[$i]}: kept on '$br' — resolve, or: ext unlink $(basename "${R_MOUNT[$i]}") --force && ext relink"
        rc=4
        continue
      fi
      link_one "$i" || rc=$?
    elif [[ "${R_AUTOLINK[$i]}" == "true" ]]; then
      link_one "$i" || rc=$?
    fi
  done
  return $rc
}

# ------------------------------------------------------------------------- init

cmd_init() { # scaffold the committed per-repo footprint (idempotent)
  (($#)) && die "init: takes no arguments" 2
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
  if [[ -f "$root/repos.json" ]]; then
    note "repos.json already exists — left untouched"
  else
    cat >"$root/repos.json" <<'EOF'
{
  "version": 1,
  "reposRoot": "~/dev/repos",
  "defaults": { "base": "dev", "autolink": true, "fetch": true },
  "repos": []
}
EOF
    say "created repos.json — declare linkable repos in .repos[]:"
    say '  { "name": "<store-dir>", "mount": "external/<dir>", "url": "git@github.com:<org>/<repo>.git" }'
  fi
  mkdir -p "$root/.superset"
  if [[ -f "$root/.superset/ext.sh" ]]; then
    note ".superset/ext.sh already exists — left untouched"
  else
    cat >"$root/.superset/ext.sh" <<'EOF'
#!/bin/sh
# ext-repos shim — logic-free by design; do NOT add logic here, update the skill instead.
# Identical in every participating repo. Skill: github.com/shamruk/skills-ext-repos
EXT="${EXT_REPOS_HOME:-$HOME/.claude/skills/ext-repos}/scripts/ext.sh"
[ -x "$EXT" ] && exec "$EXT" "$@"
echo "[ext-repos] skill not found at: $EXT" >&2
echo "[ext-repos] install:" >&2
echo "  git clone git@github.com:shamruk/skills-ext-repos.git ~/.claude/skills/ext-repos" >&2
echo "  ~/.claude/skills/ext-repos/scripts/install.sh" >&2
exit 1
EOF
    chmod +x "$root/.superset/ext.sh"
    say "created .superset/ext.sh (shim)"
  fi
  if [[ -f "$root/.superset/config.json" ]]; then
    note ".superset/config.json already exists — ensure setup runs 'sh .superset/ext.sh link --auto' and teardown 'sh .superset/ext.sh unlink --all --force || true'"
  else
    cat >"$root/.superset/config.json" <<'EOF'
{
  "setup": ["sh .superset/ext.sh link --auto"],
  "teardown": ["sh .superset/ext.sh unlink --all --force || true"],
  "run": [],
  "cwd": "."
}
EOF
    say "created .superset/config.json (Superset setup/teardown hooks)"
  fi
  if grep -qx '/external/' "$root/.gitignore" 2>/dev/null; then
    note ".gitignore already covers /external/"
  else
    {
      echo ""
      echo "# ext-repos: linked external worktrees (see repos.json) + machine-local Superset overlay"
      echo "/external/"
    } >>"$root/.gitignore"
    say "appended /external/ to .gitignore"
  fi
  if ! grep -qx '.superset/config.local.json' "$root/.gitignore" 2>/dev/null; then
    echo ".superset/config.local.json" >>"$root/.gitignore"
  fi
  # short ext-repos note in CLAUDE.md so agents reading it know the model
  local claude_md="$root/CLAUDE.md" claude_existed=0
  [[ -f "$claude_md" ]] && claude_existed=1
  if grep -qF '## External repos (ext-repos)' "$claude_md" 2>/dev/null; then
    note "CLAUDE.md already documents ext-repos — left untouched"
  else
    {
      ((claude_existed)) && [[ -s "$claude_md" ]] && echo ""
      cat <<'EOF'
## External repos (ext-repos)

This repo can link sibling repos as **branch-aligned git worktrees** under
`external/` (declared in `repos.json`). Linked dirs are gitignored and are
**separate repos** — `git commit`/`git push` inside one applies to THAT repo,
not this host. Link on demand with `ext link <name>` (or `ext link --all`);
`ext status` shows branch/dirty/link state. Managed by the ext-repos skill.
EOF
    } >>"$claude_md"
    ((claude_existed)) && say "documented ext-repos in CLAUDE.md" \
      || say "created CLAUDE.md with an ext-repos note"
  fi
  say "init done — edit repos.json, run 'ext link --all', then commit repos.json .superset/ .gitignore CLAUDE.md"
}

# ----------------------------------------------------------------------- doctor

cmd_doctor() {
  local fix=false migrate=false a
  for a in "$@"; do
    case "$a" in
      --fix) fix=true ;;
      --migrate) migrate=true ;;
      *) die "doctor: unknown flag $a" 2 ;;
    esac
  done
  local issues=0 fixed=0 i
  for i in $(repo_seq); do
    local name="${R_NAME[$i]}" mount_rel="${R_MOUNT[$i]}" url="${R_URL[$i]}"
    local m="$HOST_ROOT/$mount_rel"
    local canon
    if ! canon="$(canon_dir "$name")"; then
      issues=$((issues + 1))
      say "x $name: canonical store missing under $REPOS_ROOT"
      if [[ "$fix" == "true" && -n "$url" ]]; then
        if git clone --no-checkout "$url" "$REPOS_ROOT/$name"; then
          # detach the store's HEAD so its checkout-less primary worktree
          # never owns a branch (which would block linking that branch)
          git -C "$REPOS_ROOT/$name" update-ref --no-deref HEAD \
            "$(git -C "$REPOS_ROOT/$name" rev-parse HEAD)" 2>/dev/null || true
          say "  + cloned $url (store HEAD detached — checkout-less)"
          fixed=$((fixed + 1))
        fi
      else
        say "  fix: ext doctor --fix   (clones ${url:-<no url in manifest>})"
      fi
      continue
    fi
    # stale worktree registrations (Superset deleted a workspace without teardown)
    local stale="" still=""
    local p
    while IFS= read -r p; do
      [[ -n "$p" && ! -d "$p" ]] && stale="$stale$p"$'\n'
    done < <(git -C "$canon" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}')
    if [[ -n "$stale" ]]; then
      issues=$((issues + 1))
      say "x $name: stale worktree registrations (deleted without teardown):"
      printf '%s' "$stale" | sed 's/^/    /'
      if [[ "$fix" == "true" ]]; then
        git -C "$canon" worktree prune --expire=now
        while IFS= read -r p; do
          [[ -n "$p" && ! -d "$p" ]] && still="$still$p"$'\n'
        done < <(git -C "$canon" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}')
        if [[ -z "$still" ]]; then
          say "  + pruned"
          fixed=$((fixed + 1))
        else
          say "  ! still registered after prune (locked?):"
          printf '%s' "$still" | sed 's/^/    /'
          say "    unlock first: git -C $canon worktree unlock <path>, then re-run"
        fi
      else
        say "  fix: ext doctor --fix"
      fi
    fi
    # orphaned matching branches (worktree gone, never pushed, no commits beyond base)
    local b bb
    while IFS= read -r b; do
      [[ -n "$b" ]] || continue
      bb="$(git -C "$canon" config "branch.$b.base" 2>/dev/null || true)"
      [[ -n "$bb" ]] || continue
      [[ "$b" == "$bb" || "$b" == "main" || "$b" == "master" ]] && continue
      [[ -n "$(owner_of_branch "$canon" "$b")" ]] && continue
      git -C "$canon" rev-parse --abbrev-ref -q "$b@{upstream}" >/dev/null 2>&1 && continue
      git -C "$canon" merge-base --is-ancestor "$b" "origin/$bb" 2>/dev/null || continue
      issues=$((issues + 1))
      say "x $name: orphaned branch '$b' (worktree gone, no commits beyond origin/$bb)"
      if [[ "$fix" == "true" ]]; then
        git -C "$canon" branch -D "$b" >/dev/null
        git -C "$canon" config --unset "branch.$b.base" 2>/dev/null || true
        say "  + deleted"
        fixed=$((fixed + 1))
      else
        say "  fix: ext doctor --fix"
      fi
    done < <(git -C "$canon" for-each-ref --format='%(refname:short)' refs/heads)
    # mount health
    local state
    state="$(mount_state "$m" "$canon")"
    case "$state" in
      linked)
        if ! git -C "$m" status >/dev/null 2>&1; then
          issues=$((issues + 1))
          say "x $mount_rel: broken worktree link"
          if [[ "$fix" == "true" ]]; then
            git -C "$canon" worktree repair "$m" && { say "  + repaired"; fixed=$((fixed + 1)); }
          else
            say "  fix: ext doctor --fix"
          fi
        else
          local br
          br="$(git -C "$m" symbolic-ref --short -q HEAD || echo '(detached)')"
          if [[ -n "$HOST_BRANCH" && "$br" != "$HOST_BRANCH" ]]; then
            say "! $mount_rel: on '$br' while host is on '$HOST_BRANCH' — consider 'ext relink'"
          fi
        fi ;;
      absent|legacy-submodule) : ;; # absent is fine; legacy handled by the scan below
      *)
        issues=$((issues + 1))
        say "x $mount_rel: unexpected state: $state — remove it manually, then 'ext link'" ;;
    esac
    # gitignore coverage — an unignored mount can be re-committed as a gitlink by `git add -A`
    if ! git -C "$HOST_ROOT" check-ignore -q "$mount_rel" 2>/dev/null; then
      issues=$((issues + 1))
      say "x $mount_rel: NOT gitignored — add '/${mount_rel%%/*}/' to .gitignore (a bare 'git add -A' would commit it as a gitlink)"
    fi
  done
  # legacy submodule scan: any top-level or external/ dir whose .git file points into modules/
  local d rel gd ix blockers ref
  for d in "$HOST_ROOT"/*/ "$HOST_ROOT"/external/*/; do
    [[ -f "$d/.git" ]] || continue
    grep -Eq '\.git/(worktrees/[^/]+/)?modules/' "$d/.git" 2>/dev/null || continue
    rel="${d#"$HOST_ROOT"/}"
    rel="${rel%/}"
    issues=$((issues + 1))
    say "x $rel: legacy submodule checkout"
    if [[ "$migrate" != "true" ]]; then
      say "  fix: ext doctor --migrate"
      continue
    fi
    # destructive migration only for repos declared in the manifest
    if ! ix="$(repo_index "$(basename "$rel")")"; then
      say "  ! not declared in repos.json — migrate manually (push its work, then remove the dir)"
      continue
    fi
    # refuse if ANY local state could be lost: dirty tree, stashes, unpushed commits on any branch
    blockers=""
    [[ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]] && blockers="uncommitted changes"
    [[ -z "$blockers" && -n "$(git -C "$d" stash list 2>/dev/null)" ]] && blockers="stashed changes"
    if [[ -z "$blockers" ]]; then
      while IFS= read -r ref; do
        [[ -n "$ref" ]] || continue
        if [[ -n "$(git -C "$d" log --oneline -1 "$ref" --not --remotes 2>/dev/null)" ]]; then
          blockers="unpushed commits on '$ref'"
          break
        fi
      done < <(git -C "$d" for-each-ref --format='%(refname:short)' refs/heads)
    fi
    if [[ -n "$blockers" ]]; then
      say "  ! has $blockers — resolve manually, then re-run"
      continue
    fi
    gd="$(sed -n 's/^gitdir: //p' "$d/.git")"
    [[ "$gd" != /* ]] && gd="$d$gd"
    gd="$(cd "$gd" 2>/dev/null && pwd -P || true)"
    rm -rf "$d"
    [[ -n "$gd" && -d "$gd" ]] && rm -rf "$gd"
    # de-submodule the host: drop gitlink + .gitmodules/config sections if still present
    git -C "$HOST_ROOT" rm --cached -q "$rel" 2>/dev/null || true
    git -C "$HOST_ROOT" config -f "$HOST_ROOT/.gitmodules" --remove-section "submodule.$rel" 2>/dev/null || true
    git -C "$HOST_ROOT" config --remove-section "submodule.$rel" 2>/dev/null || true
    say "  + removed legacy checkout + module storage (commit the de-submodule change if git status shows one)"
    LINK_BRANCH_OVERRIDE=""
    LINK_DETACH=false
    LINK_NO_FETCH=false
    if link_one "$ix"; then
      fixed=$((fixed + 1))
    else
      say "  ! removed, but re-link failed — run 'ext link $(basename "$rel")' after resolving the error above"
    fi
  done
  # shim presence (informational)
  if [[ -f "$HOST_ROOT/.superset/ext.sh" && ! -x "$HOST_ROOT/.superset/ext.sh" ]]; then
    say "! .superset/ext.sh is not executable (Superset uses 'sh .superset/ext.sh', so this is cosmetic)"
  fi
  if ((issues == 0)); then
    say "doctor: all clean"
    return 0
  fi
  say "doctor: $issues issue(s), $fixed fixed"
  ((issues == fixed)) && return 0
  return 1
}

# ------------------------------------------------------------------------- main

main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    -h|--help|help) usage; exit 0 ;;
    -V|--version|version) say "ext $EXT_VERSION"; exit 0 ;;
    link|unlink|status|list|fetch|pull|push|merge-to|each|relink|doctor|init) ;;
    *) die "unknown command: $cmd (see 'ext help')" 2 ;;
  esac
  command -v git >/dev/null || die "git is required"
  command -v jq  >/dev/null || die "jq is required (brew install jq)"
  if [[ "$cmd" == "init" ]]; then # init runs before a manifest exists
    cmd_init "$@"
    exit $?
  fi
  if ! HOST_ROOT="$(find_host_root)"; then
    # No manifest: stay silent-success so .superset hooks can ship uniformly to
    # repos that declare no external links — unless the user named a repo.
    case "$cmd" in
      link|unlink)
        local a
        for a in "$@"; do
          case "$a" in -*) ;; *) die "no repos.json found from $PWD upward" 1 ;; esac
        done ;;
    esac
    note "no repos.json found from $PWD upward — nothing to do"
    exit 0
  fi
  HOST_BRANCH="$(git -C "$HOST_ROOT" symbolic-ref --short -q HEAD || echo '')"
  HOST_NAME="$(basename "$(dirname "$(git -C "$HOST_ROOT" rev-parse --path-format=absolute --git-common-dir)")")"
  load_manifest
  case "$cmd" in
    link)     cmd_link "$@" ;;
    unlink)   cmd_unlink "$@" ;;
    status)   cmd_status "$@" ;;
    list)     cmd_list "$@" ;;
    fetch)    cmd_fetch "$@" ;;
    pull)     cmd_pull "$@" ;;
    push)     cmd_push "$@" ;;
    merge-to) cmd_merge_to "$@" ;;
    each)     cmd_each "$@" ;;
    relink)   cmd_relink "$@" ;;
    doctor)   cmd_doctor "$@" ;;
  esac
}

main "$@"
