#!/usr/bin/env bash
# Live driver: run bin/fm-spawn.sh for a claude crewmate against a REAL tmux
# server on a private socket. A stand-in `claude` on PATH records the argv it
# was started with, which proves whether the pane shell ran the full launch.
# Usage: live-spawn-tmux.sh <repo-root-to-run> <label>
set -u
RUN_ROOT=$1 LABEL=$2
WT_ROOT=/Users/lijo/.no-mistakes/worktrees/2524c5f7b1fc/01M455Z9MH2RQ5MSVADGC9562F
. "$WT_ROOT/tests/fixtures.sh"
ROOT=$RUN_ROOT
TMP_ROOT=$(fm_test_tmproot "fm-live-launch-$LABEL")
REAL_TMUX=$(command -v tmux)
SOCKET="fm-live-launch-$LABEL-$$"
id=live-claude-launch-$LABEL
case_dir=$TMP_ROOT/case; home=$case_dir/home; proj=$case_dir/project; wt=$case_dir/wt
fm_test_spawn_home "$home" claude
fm_git_worktree "$proj" "$wt" "wt-$LABEL" >/dev/null
fm_test_spawn_brief "$home" "$id"
fakebin=$(fm_fakebin "$case_dir/fake")
# Stand-in treehouse: `treehouse get` adds a detached worktree and enters a
# fresh interactive subshell there, as the real one does. The subshell starts
# after a short delay, like a shell loading its rc files, so text typed into
# the pane meanwhile waits in the tty under the canonical line discipline.
cat > "$fakebin/treehouse" <<SH
#!/bin/sh
[ "\${1:-}" = get ] || exit 0
git worktree add -q -d "$case_dir/pool/1/wt" >/dev/null 2>&1
cd "$case_dir/pool/1/wt" || exit 1
sleep 2
exec /bin/bash --noprofile --norc \${LIVE_BASH_FLAGS:-} -i
SH
chmod +x "$fakebin/treehouse"
cat > "$fakebin/pane-shell" <<SH
#!/bin/sh
exec /bin/bash --noprofile --norc \${LIVE_BASH_FLAGS:-} -i
SH
chmod +x "$fakebin/pane-shell"
ARGV_LOG=$case_dir/claude-argv.log
cat > "$fakebin/claude" <<SH
#!/bin/sh
: > "$ARGV_LOG"
for a in "\$@"; do printf '<%s>\n' "\$a" >> "$ARGV_LOG"; done
printf 'FAKE-CLAUDE-STARTED argc=%s\n' "\$#"
exec sleep 600
SH
chmod +x "$fakebin/claude"
cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = send-keys ]; then printf '%s\n' "\$*" >> "$case_dir/send-keys.log"; fi
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$fakebin/tmux"
cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1; }
trap cleanup EXIT
PANE_SHELL=$fakebin/pane-shell
SHELL=$PANE_SHELL PATH="$fakebin:$PATH" "$REAL_TMUX" -L "$SOCKET" -f /dev/null new-session -d -s firstmate -x 200 -y 50 -c "$wt"
"$REAL_TMUX" -L "$SOCKET" set -g default-shell "$PANE_SHELL"
"$REAL_TMUX" -L "$SOCKET" set-environment -g PATH "$fakebin:$PATH"
"$REAL_TMUX" -L "$SOCKET" set-environment -g LIVE_BASH_FLAGS "${LIVE_BASH_FLAGS:-}"
echo "== treehouse subshell: bash ${LIVE_BASH_FLAGS:-(readline)}"
mkdir -p "$home/user-home"
sock_path=$("$REAL_TMUX" -L "$SOCKET" display-message -p '#{socket_path}')
echo "== run root: $RUN_ROOT ($(git -C "$RUN_ROOT" rev-parse --short HEAD 2>/dev/null || echo snapshot)) pane shell: $PANE_SHELL"
out=$(TMUX="$sock_path,1,0" FM_HOME="$home" FM_ROOT_OVERRIDE='' HOME="$home/user-home" CLAUDE_CONFIG_DIR='' \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
  FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 PATH="$fakebin:$PATH" \
  timeout 120 "$RUN_ROOT/bin/fm-spawn.sh" "$id" "$proj" --mode no-mistakes --yolo off 2>&1); rc=$?
echo "== fm-spawn exit: $rc"; printf '%s\n' "$out" | tail -5
sleep 3
echo "== typed send-keys -l payload(s), byte length:"
grep -- ' -l ' "$case_dir/send-keys.log" | while IFS= read -r l; do printf '  %s bytes: %.160s\n' "${#l}" "$l"; done
lf="$home/state/$id.launch"
if [ -f "$lf" ]; then echo "== launch file: $lf mode=$(stat -f %Lp "$lf") bytes=$(wc -c < "$lf" | tr -d ' ')"; else echo "== launch file: none"; fi
echo "== stand-in claude argv log:"
if [ -s "$ARGV_LOG" ]; then echo "  argc=$(wc -l < "$ARGV_LOG" | tr -d ' ')"; grep -c -- '<--append-system-prompt>' "$ARGV_LOG" | sed 's/^/  --append-system-prompt present: /'; tail -c 300 "$ARGV_LOG" | sed 's/^/  /'; else echo "  EMPTY: claude never started"; fi
echo "== pane capture (tail):"
"$REAL_TMUX" -L "$SOCKET" capture-pane -p -J -t "firstmate:fm-$id" -S -40 2>&1 | grep -v '^$' | tail -12 | cut -c1-200 | sed 's/^/  | /'
rm -rf "$TMP_ROOT"
