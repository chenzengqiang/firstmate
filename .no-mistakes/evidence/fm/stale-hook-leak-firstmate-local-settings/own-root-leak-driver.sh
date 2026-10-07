#!/usr/bin/env bash
# Evidence driver: reproduce the 2026-09-29 own-checkout hook-leak shape against
# whichever bin/fm-spawn.sh is currently checked out in the worktree, then print
# the end-user-visible outcome (the running checkout's .claude/settings.local.json,
# its git HEAD, its file tree). Mirrors the fixture staged by
# tests/fm-tangle-guard.test.sh:test_spawn_own_root_identity_abort.
set -u
WTREE=/home/lance/.no-mistakes/worktrees/d9409d389edc/01M4BJ3HA8KRBGVX7AS8R9K18H
. "$WTREE/tests/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot ownroot-leak-evidence)
fm_git_identity fmtest fmtest@example.invalid

make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  fm_git_add_origin "$dir" "$dir.origin.git"
  printf '%s\n' "$dir"
}

checkout_fingerprint() { # <dir>
  (cd "$1" && find . -name .git -prune -o -type f -exec cksum {} + | LC_ALL=C sort)
}

home="$TMP_ROOT/ownroot-home"
mkdir -p "$home/data" "$home/user-home"
proj=$(make_repo "$TMP_ROOT/ownroot-proj")
ownroot="$TMP_ROOT/ownroot-fm"
git -C "$proj" worktree add -q --detach "$ownroot" >/dev/null 2>&1
ln -s "$WTREE/bin" "$ownroot/bin"
settings="$ownroot/.claude/settings.local.json"
mkdir -p "$ownroot/.claude"
printf '{\n  "permissions": {\n    "allow": [\n      "Bash(git diff:*)"\n    ]\n  }\n}\n' > "$settings"
excl=$(git -C "$ownroot" rev-parse --git-path info/exclude)
mkdir -p "$(dirname "$excl")"
printf 'bin\n.claude/\n' >> "$excl"
git -C "$proj" commit -q --allow-empty -m advance-origin-default
git -C "$proj" push -q origin main
fetch_head=$(git -C "$ownroot" rev-parse --git-path FETCH_HEAD)
fakebin=$(make_spawn_fakebin "$TMP_ROOT/ownroot-fake" claude)
fm_test_fake_sleep_noop "$fakebin"
config="$TMP_ROOT/ownroot-claude"
mkdir -p "$config"
fm_test_spawn_brief "$home" ownroot-ii9

head_before=$(git -C "$ownroot" rev-parse HEAD)
tree_before=$(checkout_fingerprint "$ownroot")
excl_before=$(cksum <"$excl")

echo "=== fixture ==="
echo "firstmate running checkout (FM_ROOT): $ownroot"
echo "spawning project:                     $proj"
echo "checkout HEAD before spawn:           $head_before"
echo "origin/main (advanced past HEAD):     $(git -C "$ownroot" rev-parse origin/main)"

out=$(FM_ROOT_OVERRIDE="$ownroot" FM_HOME="$home" HOME="$home/user-home" \
  CLAUDE_CONFIG_DIR="$config" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$ownroot" TMUX="fake,1,0" \
  PATH="$fakebin:$PATH" \
  "$WTREE/bin/fm-spawn.sh" ownroot-ii9 "$proj" claude --mode no-mistakes --yolo off 2>&1)
status=$?

echo "=== spawn exit: $status ==="
echo "=== spawn output (tail) ==="
printf '%s\n' "$out" | tail -6

echo "=== firstmate's own checkout AFTER the spawn ==="
echo "HEAD before: $head_before"
echo "HEAD after:  $(git -C "$ownroot" rev-parse HEAD)"
[ "$head_before" = "$(git -C "$ownroot" rev-parse HEAD)" ] \
  && echo "HEAD: unchanged" || echo "HEAD: MOVED by base refresh"
if [ -e "$fetch_head" ]; then echo "FETCH_HEAD: created (a fetch ran in this checkout)"; else echo "FETCH_HEAD: absent"; fi
[ "$excl_before" = "$(cksum <"$excl")" ] \
  && echo "shared info/exclude: unchanged" || echo "shared info/exclude: MODIFIED"
[ "$tree_before" = "$(checkout_fingerprint "$ownroot")" ] \
  && echo "file tree: byte-identical" || echo "file tree: CHANGED"

echo "=== the running checkout's .claude/settings.local.json after the spawn ==="
cat "$settings"
echo
if grep -q UserPromptSubmit "$settings"; then
  echo "VERDICT: LEAK - a dead task's claude-hook quartet landed in firstmate's own checkout"
else
  echo "VERDICT: CLEAN - no task hooks in firstmate's own checkout"
fi
