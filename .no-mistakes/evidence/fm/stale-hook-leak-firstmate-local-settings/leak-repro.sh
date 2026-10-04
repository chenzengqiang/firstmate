#!/usr/bin/env bash
# End-to-end reproduction of the 2026-09-29 firstmate hook-leak root cause.
#
# Scenario (mirrors the leak): a ship task for an ordinary project is spawned
# while the pane read transiently reports firstmate's own running checkout as
# the task worktree. On WSL that read was a brand-new window's stale cwd; here
# the fake tmux stub reports it directly. FM_ROOT_OVERRIDE names a linked
# worktree of the project that plays "firstmate's own checkout".
#
# Usage: leak-repro.sh <label> <fm-spawn.sh path> <scenario-root>
# Prints the spawn transcript plus the resulting state of the own checkout's
# .claude/settings.local.json - the exact file the leaked claude-hook quartet
# was written into on 2026-09-29.
set -u
label=$1
spawn_bin=$(readlink -f "$2")
scenario=$3

REPO_ROOT=/home/lance/.no-mistakes/worktrees/d9409d389edc/01M43KMJ9PF6KGBJXQBX2Q9C5V
. "$REPO_ROOT/tests/fixtures.sh"

home="$scenario/home"
proj="$scenario/proj"
ownroot="$scenario/own-checkout"
fakebin="$scenario/fakebin"
config="$scenario/claude-config"

mkdir -p "$home/data" "$home/user-home" "$config"

# An ordinary project repository on main.
export GIT_AUTHOR_NAME=e2e GIT_AUTHOR_EMAIL=e2e@example.invalid
export GIT_COMMITTER_NAME=e2e GIT_COMMITTER_EMAIL=e2e@example.invalid
git init -q -b main "$proj"
git -C "$proj" commit -q --allow-empty -m init

# "Firstmate's own checkout": a linked worktree of that same project, detached
# on the default branch - the shape firstmate itself runs from.
git -C "$proj" worktree add -q --detach "$ownroot" >/dev/null 2>&1
ln -s "$REPO_ROOT/bin" "$ownroot/bin"
excl=$(git -C "$ownroot" rev-parse --git-path info/exclude)
mkdir -p "$(dirname "$excl")"
printf 'bin\n.claude/\n' >> "$excl"

# Spawn fakebin: tmux reports the own checkout as the pane's current path (the
# stale read), treehouse/claude/sleep are no-ops.
mkdir -p "$fakebin"
fm_test_fake_tmux_spawn "$fakebin"
fm_fake_exit0 "$fakebin" treehouse claude
fm_test_fake_sleep_noop "$fakebin"

# Task brief for id leak-e2e-q7.
mkdir -p "$home/data/leak-e2e-q7"
cat > "$home/data/leak-e2e-q7/brief.md" <<'EOF'
# Task
## Captain's intent
Demonstrate the 2026-09-29 hook-leak shape end to end.

## Firstmate spec
The spawn must resolve an isolated worktree before any task wiring.
EOF

echo "==================================================================="
echo "[$label] fm-spawn under test: $spawn_bin"
echo "scenario: pane reports firstmate's own checkout ($ownroot)"
echo "==================================================================="
out=$(FM_ROOT_OVERRIDE="$ownroot" FM_HOME="$home" HOME="$home/user-home" \
  CLAUDE_CONFIG_DIR="$config" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$ownroot" TMUX="fake,1,0" \
  PATH="$fakebin:$PATH" \
  "$spawn_bin" leak-e2e-q7 "$proj" claude --mode no-mistakes --yolo off 2>&1)
status=$?
printf '%s\n' "$out"
echo "-------------------------------------------------------------------"
echo "[$label] spawn exit code: $status"

settings="$ownroot/.claude/settings.local.json"
if [ -e "$settings" ]; then
  echo "[$label] LEAK CHECK: $settings EXISTS - contents:"
  cat "$settings"
  if grep -q UserPromptSubmit "$settings"; then
    echo "[$label] RESULT: claude-hook quartet LEAKED into firstmate's own checkout (the 2026-09-29 bug)"
  else
    echo "[$label] RESULT: settings file exists but carries no claude hooks"
  fi
else
  echo "[$label] LEAK CHECK: $settings does not exist - no task wiring written"
  echo "[$label] RESULT: own checkout left untouched"
fi
echo
