#!/usr/bin/env bash
# Install (or uninstall) the ext-repos skill for the human terminal:
# adds a marked PATH block to ~/.zshrc pointing at the skill's bin/ dir.
# Claude sessions and Superset shims reach scripts/ext.sh directly and do
# not need this.
set -euo pipefail

SKILL_HOME="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
RC="$HOME/.zshrc"
MARK_BEGIN='# >>> ext-repos >>>'
MARK_END='# <<< ext-repos <<<'

if [[ "${1:-}" == "--uninstall" ]]; then
  if [[ -f "$RC" ]] && grep -qF "$MARK_BEGIN" "$RC"; then
    sed -i '' "/^${MARK_BEGIN//>/\\>}\$/,/^${MARK_END//</\\<}\$/d" "$RC" 2>/dev/null \
      || sed -i '' "/ext-repos >>>/,/ext-repos <<</d" "$RC"
    echo "removed ext-repos PATH block from $RC"
  else
    echo "no ext-repos PATH block in $RC"
  fi
  exit 0
fi

command -v git >/dev/null || { echo "missing dependency: git"; exit 1; }
command -v jq  >/dev/null || { echo "missing dependency: jq (brew install jq)"; exit 1; }
gv="$(git version | awk '{print $3}')"
IFS=. read -r gmaj gmin _ <<<"$gv"
if ((gmaj < 2 || (gmaj == 2 && gmin < 31))); then
  echo "git >= 2.31 required (found $gv)"
  exit 1
fi

chmod +x "$SKILL_HOME/bin/ext" "$SKILL_HOME/scripts/ext.sh"

if [[ "$SKILL_HOME" != "$HOME/.claude/skills/ext-repos" ]]; then
  echo "note: skill is not at ~/.claude/skills/ext-repos — Superset shims and Claude"
  echo "      expect that path; symlink it: ln -s '$SKILL_HOME' ~/.claude/skills/ext-repos"
fi

if grep -qF "$MARK_BEGIN" "$RC" 2>/dev/null; then
  echo "PATH block already present in $RC"
else
  {
    echo ""
    echo "$MARK_BEGIN"
    echo 'export PATH="$HOME/.claude/skills/ext-repos/bin:$PATH"'
    echo "$MARK_END"
  } >>"$RC"
  echo "added PATH block to $RC"
fi

echo "ext-repos $(cat "$SKILL_HOME/VERSION" 2>/dev/null || echo dev) ready."
echo "open a new shell, or run: export PATH=\"\$HOME/.claude/skills/ext-repos/bin:\$PATH\""
