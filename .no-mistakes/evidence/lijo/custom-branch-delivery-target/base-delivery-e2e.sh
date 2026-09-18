#!/usr/bin/env bash
# End-to-end drive of the per-task delivery target branch (--base), against the
# real Firstmate scripts and real git repositories.
#
# Story: project "stacker" delivers onto the long-lived local branch feat/stack.
# origin carries main only - feat/stack is never pushed, because a local-only
# task's own Rule 1 forbids pushing it. Before this change all three measuring
# points (cleanup, the guarded landing, the review diff) looked at main.
#
# Only the terminal multiplexer (tmux), the worktree pool tool (treehouse) and
# the GitHub CLI are stubbed; every fm-*.sh under test runs for real.
set -u

ROOT=/Users/lijo/.no-mistakes/worktrees/1a9267ea2c57/01M2TDQSZR9AZMN0NSVGNMDR87
BIN="$ROOT/bin"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-base-e2e.XXXXXX")
TMP=$(cd -P "$TMP" && pwd -P)
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid
export GIT_CONFIG_NOSYSTEM=1 HOME="$TMP/fakehome"
mkdir -p "$TMP/fakehome"

FAILED=0
hdr() { printf '\n========================================================\n%s\n========================================================\n' "$*"; }
step() { printf '\n--- %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; eval "$@"; }
check() { # <description> <condition-result>
  if [ "$2" -eq 0 ]; then printf 'PASS: %s\n' "$1"; else printf 'FAIL: %s\n' "$1"; FAILED=1; fi
}

# ---------------------------------------------------------------- fixture ---
mkdir -p "$TMP/home/data" "$TMP/home/state" "$TMP/home/config" "$TMP/fakebin"
PROJ="$TMP/stacker"
git init -q -b main "$PROJ"
printf 'baseline\n' > "$PROJ/README.md"
git -C "$PROJ" add -A && git -C "$PROJ" commit -qm "main baseline"
git init --bare -q "$TMP/origin.git"
git -C "$PROJ" remote add origin "$TMP/origin.git"
git -C "$PROJ" push -q -u origin main
git -C "$TMP/origin.git" symbolic-ref HEAD refs/heads/main
git -C "$PROJ" remote set-head origin main >/dev/null 2>&1
# The long-lived delivery branch, two commits past main, LOCAL ONLY.
git -C "$PROJ" checkout -q -b feat/stack
printf 'stage one\n' > "$PROJ/stage-one.txt"
git -C "$PROJ" add -A && git -C "$PROJ" commit -qm "feat/stack: groundwork"
printf 'stage two\n' > "$PROJ/stage-two.txt"
git -C "$PROJ" add -A && git -C "$PROJ" commit -qm "feat/stack: more groundwork"

# Stubs for the external tools a spawn/teardown touches.
cat > "$TMP/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; list-windows) exit 0 ;; esac
exit 0
SH
printf '#!/bin/sh\nexit 0\n' > "$TMP/fakebin/treehouse"
cat > "$TMP/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
cp "$TMP/fakebin/gh-axi" "$TMP/fakebin/gh"
chmod +x "$TMP"/fakebin/*

export FM_GATE_REFUSE_BYPASS=1   # documented test-harness hatch (bin/fm-gate-refuse-lib.sh)
FM_ENV=(
  FM_ROOT_OVERRIDE="$ROOT"
  FM_HOME="$TMP/home"
  FM_STATE_OVERRIDE="$TMP/home/state"
  FM_DATA_OVERRIDE="$TMP/home/data"
  FM_CONFIG_OVERRIDE="$TMP/home/config"
  FM_PROJECTS_OVERRIDE="$TMP/projects-unused"
  FM_SPAWN_NO_GUARD=1
)
fm() { env "${FM_ENV[@]}" PATH="$TMP/fakebin:$PATH" "$@"; }
touch "$TMP/home/state/.last-watcher-beat"

hdr "FIXTURE: project 'stacker' delivers onto the long-lived branch feat/stack"
run "git -C '$PROJ' log --oneline --all --decorate"
run "git -C '$PROJ' ls-remote --heads origin"
echo "(origin carries main only: feat/stack was never pushed)"

# ------------------------------------------------- 1. brief with --base -----
hdr "SCENARIO 1 - the ship brief names the delivery target branch"
step "firstmate scaffolds the brief for task stack-1"
run "fm '$BIN/fm-brief.sh' stack-1 stacker --mode local-only --base feat/stack"
BRIEF="$TMP/home/data/stack-1/brief.md"
step "the generated brief's contract line, branch step, Rule 1 and definition of done"
grep -n "Delivery contract:" "$BRIEF"
grep -n "First action:" "$BRIEF"
grep -n "^1\. Never push to any remote" "$BRIEF"
grep -n "fast-forward onto" "$BRIEF"
grep -n "merges it into local" "$BRIEF"
grep -q 'Delivery contract: mode=local-only base=feat/stack' "$BRIEF"; check "contract line records mode and base" $?
grep -q 'git checkout -b fm/stack-1 refs/heads/feat/stack' "$BRIEF"; check "branch step starts from the LOCAL refs/heads/feat/stack" $?
! grep -q 'origin/feat/stack`' "$BRIEF" || grep -q 'Never branch from `origin/feat/stack`' "$BRIEF"; check "the brief forbids branching from origin/feat/stack" $?
n=$(grep -c 'merge into local `feat/stack`\|merges it into local `feat/stack`' "$BRIEF"); [ "$n" -ge 1 ]; check "Rule 1 and the DoD name one landing target (feat/stack)" $?
! grep -q 'into local `main`' "$BRIEF"; check "no sentence in the brief still says it lands on main" $?

step "the worker's own branch step, executed verbatim in a fresh worktree"
git -C "$PROJ" worktree add -q --detach "$TMP/wt-probe" HEAD
( cd "$TMP/wt-probe" \
  && if git rev-parse --verify --quiet refs/heads/feat/stack >/dev/null; then
       git checkout -q -b fm/probe refs/heads/feat/stack
     else
       git fetch -q origin feat/stack && git checkout -q -b fm/probe FETCH_HEAD
     fi \
  && printf 'probe branched at: %s\n' "$(git log --oneline -1)" )
[ "$(git -C "$TMP/wt-probe" rev-parse HEAD)" = "$(git -C "$PROJ" rev-parse refs/heads/feat/stack)" ]
check "running the brief's branch step puts the worker on the local feat/stack tip" $?
git -C "$PROJ" worktree remove --force "$TMP/wt-probe"
git -C "$PROJ" branch -q -D fm/probe

# ------------------------------- 2. omitting --base is byte-for-byte old ----
hdr "SCENARIO 2 - omitting --base renders the pre-change brief byte for byte"
mkdir -p "$TMP/pre-change"
git -C "$ROOT" archive 9bc051ff43c6e4d23c163ee8f1d87551a11050c0 | tar -x -C "$TMP/pre-change"
# Same FM_HOME for both renders: the brief embeds its own status-file path, so a
# different home would differ for a reason that is not this change.
mkdir -p "$TMP/cmp/data"
for m in no-mistakes direct-PR local-only; do
  rm -rf "$TMP/cmp/data/cmp-$m"
  FM_HOME="$TMP/cmp" "$TMP/pre-change/bin/fm-brief.sh" "cmp-$m" stacker --mode "$m" >/dev/null
  cp -f "$TMP/cmp/data/cmp-$m/brief.md" "$TMP/cmp/before-$m.md"
  rm -rf "$TMP/cmp/data/cmp-$m"
  FM_HOME="$TMP/cmp" "$BIN/fm-brief.sh" "cmp-$m" stacker --mode "$m" >/dev/null
  cp -f "$TMP/cmp/data/cmp-$m/brief.md" "$TMP/cmp/after-$m.md"
  # The brief embeds its own FM_ROOT path (helper-script references); the two
  # trees live at different paths, so that one token is normalized away and
  # everything else must match byte for byte.
  sed "s|$TMP/pre-change|<FM_ROOT>|g" "$TMP/cmp/before-$m.md" > "$TMP/cmp/before-$m.norm"
  sed "s|$ROOT|<FM_ROOT>|g" "$TMP/cmp/after-$m.md" > "$TMP/cmp/after-$m.norm"
  cmp -s "$TMP/cmp/before-$m.norm" "$TMP/cmp/after-$m.norm"
  check "mode=$m without --base is byte-identical to the pre-change brief" $?
done
echo "$ diff <pre-change brief> <post-change brief>   (local-only, no --base)"
diff "$TMP/cmp/before-local-only.norm" "$TMP/cmp/after-local-only.norm" && echo "(no differences)"
echo "$ sed -n '/Delivery contract/,/guarded fast-forward/p' <post-change local-only brief without --base>"
sed -n '/Delivery contract/,/guarded fast-forward path/p' "$TMP/cmp/after-local-only.md"

# ---------------------------------------- 3. spawn records / refuses --------
hdr "SCENARIO 3 - the spawn carries the base into the durable task record"
python3 - "$BRIEF" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
t = t.replace("{TASK}", "Stack the next slice onto the feature branch.")
t = t.replace("{FIRSTMATE_SPEC}", "Add stage three to the stacked work.")
p.write_text(t)
PY
git -C "$PROJ" worktree add -q --detach "$TMP/wt" refs/heads/main
step "spawn the crewmate with the matching --base"
run "fm FM_BACKEND=tmux TMUX='fake,1,0' FM_FAKE_PANE_PATH='$TMP/wt' '$BIN/fm-spawn.sh' stack-1 '$PROJ' claude --mode local-only --yolo off --base feat/stack"
step "the durable task record"
run "cat '$TMP/home/state/stack-1.meta' | grep -E '^(kind|mode|yolo|base|project|worktree)='"
grep -qx 'base=feat/stack' "$TMP/home/state/stack-1.meta"; check "state/stack-1.meta records base=feat/stack" $?

step "ADVERSARIAL: a spawn whose --base disagrees with the brief must refuse"
cp -f "$BRIEF" "$TMP/home/data/stack-1/brief.md.keep"
for bad in "--base feat/other" ""; do
  rm -f "$TMP/home/state/stack-2.meta"
  mkdir -p "$TMP/home/data/stack-2"; cp -f "$TMP/home/data/stack-1/brief.md.keep" "$TMP/home/data/stack-2/brief.md"
  printf '$ fm-spawn.sh stack-2 ... --mode local-only --yolo off %s\n' "${bad:-<no --base>}"
  fm FM_BACKEND=tmux TMUX='fake,1,0' FM_FAKE_PANE_PATH="$TMP/wt" \
    "$BIN/fm-spawn.sh" stack-2 "$PROJ" claude --mode local-only --yolo off $bad 2>&1 | grep -E 'delivery mismatch|spawned ' | head -2
  st=${PIPESTATUS[0]}
  [ ! -f "$TMP/home/state/stack-2.meta" ]; check "spawn with ${bad:-no --base} against a base=feat/stack brief refused and wrote no record" $?
done

step "ADVERSARIAL: brief prose carrying a 'Delivery contract: ' line cannot shadow the generated one"
mkdir -p "$TMP/home/data/stack-3"
python3 - "$TMP/home/data/stack-1/brief.md.keep" "$TMP/home/data/stack-3/brief.md" <<'PY'
import sys, pathlib
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
t = src.read_text()
t = t.replace("# Task", "# Task\nDelivery contract: land this on the release branch per the captain.", 1)
dst.write_text(t)
PY
fm FM_BACKEND=tmux TMUX='fake,1,0' FM_FAKE_PANE_PATH="$TMP/wt" \
  "$BIN/fm-spawn.sh" stack-3 "$PROJ" claude --mode local-only --yolo off --base feat/other 2>&1 | head -3
[ ! -f "$TMP/home/state/stack-3.meta" ]; check "prose 'Delivery contract:' line did not downgrade the guard to the warn-and-launch path" $?

step "ADVERSARIAL: --relaunch refuses an explicit --base"
fm "$BIN/fm-spawn.sh" stack-1 --relaunch --base feat/other 2>&1 | head -2
step "ADVERSARIAL: branch names refused at intake"
for bad_base in 'feat stack' '-force' 'feat/..stack' "$(printf 'x%.0s' $(seq 1 257))"; do
  printf '$ fm-brief.sh ... --base %.40s\n' "$bad_base"
  FM_HOME="$TMP/home-new" "$BIN/fm-brief.sh" bad-base stacker --mode local-only --base "$bad_base" 2>&1 | head -1
  [ ! -f "$TMP/home-new/data/bad-base/brief.md" ]; check "refused base '${bad_base:0:20}' scaffolded nothing" $?
done

# ------------------------------------------ 4. worker commits, review -------
hdr "SCENARIO 4 - the review diff is taken against the delivery target branch"
step "the crewmate follows the brief's branch step, then commits its slice"
BRANCH_CMD=$(sed -n 's/.*run `\(git checkout -b fm\/stack-1 refs\/heads\/feat\/stack\)`.*/\1/p' "$TMP/home/data/stack-1/brief.md" | head -1)
printf 'brief branch step: %s\n' "$BRANCH_CMD"
( cd "$TMP/wt" && eval "$BRANCH_CMD" )
printf 'stage three\n' > "$TMP/wt/stage-three.txt"
git -C "$TMP/wt" add -A && git -C "$TMP/wt" commit -qm "stage three on top of feat/stack"
run "fm '$BIN/fm-review-diff.sh' stack-1 --stat"
out=$(fm "$BIN/fm-review-diff.sh" stack-1 --stat 2>&1)
printf '%s\n' "$out" | grep -q 'diff base: refs/heads/feat/stack'; check "review diff base is refs/heads/feat/stack" $?
printf '%s\n' "$out" | grep -q 'stage-three.txt'; check "the diff shows this task's file" $?
! printf '%s\n' "$out" | grep -q 'stage-one.txt\|stage-two.txt'; check "the diff does NOT drag in the feature branch's own commits" $?
printf '%s\n' "$out" | grep -q 'warning: origin has no feat/stack'; check "a reachable origin without the branch says so and uses the local ref" $?

step "ADVERSARIAL: an UNREACHABLE origin must refuse, never fall back to a possibly-stale local base"
git -C "$PROJ" remote set-url origin "$TMP/nope-does-not-exist.git"
fm "$BIN/fm-review-diff.sh" stack-1 --stat 2>&1 | grep -E 'cannot reach origin|diff base:' | head -3
fm "$BIN/fm-review-diff.sh" stack-1 --stat >/dev/null 2>&1; [ $? -ne 0 ]; check "unreachable origin refuses the review rather than guessing a base" $?
git -C "$PROJ" remote set-url origin "$TMP/origin.git"

# -------------------------------------- 5. teardown before landing ----------
hdr "SCENARIO 5 - cleanup refuses work that has not landed on feat/stack"
fm "$BIN/fm-teardown.sh" stack-1 2>&1 | head -8
fm "$BIN/fm-teardown.sh" stack-1 >/dev/null 2>&1; [ $? -ne 0 ]; check "teardown refuses genuinely unlanded work" $?
[ -d "$TMP/wt" ]; check "the worktree holding unlanded work still exists" $?

# -------------------------------------- 6. the guarded local landing --------
hdr "SCENARIO 6 - the guarded fast-forward lands onto feat/stack, not main"
main_before=$(git -C "$PROJ" rev-parse --short main)
run "fm '$BIN/fm-merge-local.sh' stack-1"
st=$?
check "bin/fm-merge-local.sh landed the task" $st
[ "$(git -C "$PROJ" rev-parse feat/stack)" = "$(git -C "$TMP/wt" rev-parse HEAD)" ]; check "feat/stack fast-forwarded to the task branch" $?
[ "$(git -C "$PROJ" rev-parse --short main)" = "$main_before" ]; check "main was NOT moved by this landing" $?
run "git -C '$PROJ' log --oneline --decorate -3 feat/stack"

# -------------------------------------- 7. teardown after landing -----------
hdr "SCENARIO 7 - cleanup accepts the landed work and records the real branch"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$TMP/home/data/backlog.md"
tasks-axi add stack-1 "stacked slice" --kind ship --file "$TMP/home/data/backlog.md" >/dev/null
tasks-axi start stack-1 --file "$TMP/home/data/backlog.md" >/dev/null
run "fm '$BIN/fm-teardown.sh' stack-1"
st=$?
check "teardown of landed work succeeds without --force" $st
step "the permanent backlog record"
run "sed -n '/## Done/,\$p' '$TMP/home/data/backlog.md'"
grep -q 'local feat/stack' "$TMP/home/data/backlog.md"; check "the completion note names the branch it actually landed on" $?

# ------------------------------- 7b. a tag shadowing the base branch --------
hdr "SCENARIO 7b - ADVERSARIAL: a TAG named feat/stack must not decide anything"
git -C "$PROJ" tag feat/stack main
echo "(the project now holds BOTH refs/heads/feat/stack and refs/tags/feat/stack)"
printf '$ git rev-parse --short refs/heads/feat/stack -> %s\n' "$(git -C "$PROJ" rev-parse --short refs/heads/feat/stack)"
printf '$ git rev-parse --short refs/tags/feat/stack  -> %s\n' "$(git -C "$PROJ" rev-parse --short refs/tags/feat/stack)"
printf '$ git rev-parse --short feat/stack        # a BARE name resolves to the tag\n'
git -C "$PROJ" rev-parse --short feat/stack 2>/dev/null
printf '$ git -C <project> symbolic-ref --short HEAD   # reports heads/... once shadowed\n'
git -C "$PROJ" symbolic-ref --short HEAD

step "a second stacked task, briefed and spawned with the same --base"
FM_HOME="$TMP/home" "$BIN/fm-brief.sh" stack-4 stacker --mode local-only --base feat/stack >/dev/null
python3 - "$TMP/home/data/stack-4/brief.md" <<'PY2'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
p.write_text(t.replace("{TASK}", "Stack a fourth slice.").replace("{FIRSTMATE_SPEC}", "Add stage four."))
PY2
git -C "$PROJ" worktree add -q --detach "$TMP/wt4" refs/heads/main
tasks-axi add stack-4 "fourth stacked slice" --kind ship --file "$TMP/home/data/backlog.md" >/dev/null
fm FM_BACKEND=tmux TMUX='fake,1,0' FM_FAKE_PANE_PATH="$TMP/wt4" \
  "$BIN/fm-spawn.sh" stack-4 "$PROJ" claude --mode local-only --yolo off --base feat/stack 2>&1 | tail -3
( cd "$TMP/wt4" && git checkout -q -b fm/stack-4 refs/heads/feat/stack \
  && printf 'stage four\n' > stage-four.txt && git add -A && git commit -qm "stage four" )
tag_before=$(git -C "$PROJ" rev-parse refs/tags/feat/stack)
main_before=$(git -C "$PROJ" rev-parse main)
run "fm '$BIN/fm-merge-local.sh' stack-4"
check "the landing succeeds while a same-named tag exists" $?
[ "$(git -C "$PROJ" rev-parse refs/heads/feat/stack)" = "$(git -C "$TMP/wt4" rev-parse HEAD)" ]
check "the BRANCH refs/heads/feat/stack is what fast-forwarded" $?
[ "$(git -C "$PROJ" rev-parse refs/tags/feat/stack)" = "$tag_before" ]; check "the tag was not moved" $?
[ "$(git -C "$PROJ" rev-parse main)" = "$main_before" ]; check "main was not moved" $?
step "and cleanup measures the branch, not the tag"
fm "$BIN/fm-teardown.sh" stack-4 > "$TMP/teardown-4.out" 2>&1; st=$?
head -2 "$TMP/teardown-4.out"
check "teardown accepts work landed on the shadowed branch" "$st"

# ----------------------- 8. the same fixture under the PRE-CHANGE scripts ---
hdr "SCENARIO 8 - REGRESSION PROOF: the pre-change scripts refuse this same landed task"
PROJ2="$TMP/stacker2"
git init -q -b main "$PROJ2"
printf 'baseline\n' > "$PROJ2/README.md"; git -C "$PROJ2" add -A; git -C "$PROJ2" commit -qm "main baseline"
git -C "$PROJ2" checkout -q -b feat/stack
printf 'one\n' > "$PROJ2/one.txt"; git -C "$PROJ2" add -A; git -C "$PROJ2" commit -qm "feat/stack groundwork"
git -C "$PROJ2" worktree add -q -b fm/stack-9 "$TMP/wt9" refs/heads/feat/stack
printf 'nine\n' > "$TMP/wt9/nine.txt"; git -C "$TMP/wt9" add -A; git -C "$TMP/wt9" commit -qm "task work"
git -C "$PROJ2" update-ref refs/heads/feat/stack "$(git -C "$TMP/wt9" rev-parse HEAD)"
mkdir -p "$TMP/home2/state" "$TMP/home2/data" "$TMP/home2/config"
{ printf 'window=firstmate:fm-stack-9\nendpoint_task_id=stack-9\n'
  printf 'worktree=%s\nproject=%s\nkind=ship\nmode=local-only\nspawn_gen=e2e\nbase=feat/stack\n' "$TMP/wt9" "$PROJ2"; } \
  > "$TMP/home2/state/stack-9.meta"
touch "$TMP/home2/state/.last-watcher-beat"
step "PRE-CHANGE bin/fm-teardown.sh (base commit 9bc051f) on work landed on feat/stack"
env FM_ROOT_OVERRIDE="$TMP/pre-change" FM_HOME="$TMP/home2" FM_STATE_OVERRIDE="$TMP/home2/state" \
    FM_DATA_OVERRIDE="$TMP/home2/data" FM_CONFIG_OVERRIDE="$TMP/home2/config" \
    FM_GATE_REFUSE_BYPASS=1 PATH="$TMP/fakebin:$PATH" "$TMP/pre-change/bin/fm-teardown.sh" stack-9 2>&1 | head -6
env FM_ROOT_OVERRIDE="$TMP/pre-change" FM_HOME="$TMP/home2" FM_STATE_OVERRIDE="$TMP/home2/state" \
    FM_DATA_OVERRIDE="$TMP/home2/data" FM_CONFIG_OVERRIDE="$TMP/home2/config" \
    FM_GATE_REFUSE_BYPASS=1 PATH="$TMP/fakebin:$PATH" "$TMP/pre-change/bin/fm-teardown.sh" stack-9 >/dev/null 2>&1
[ $? -ne 0 ]; check "the OLD teardown refuses this landed task (the defect this change fixes)" $?
step "POST-CHANGE bin/fm-teardown.sh on the identical fixture"
env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$TMP/home2" FM_STATE_OVERRIDE="$TMP/home2/state" \
    FM_DATA_OVERRIDE="$TMP/home2/data" FM_CONFIG_OVERRIDE="$TMP/home2/config" \
    FM_GATE_REFUSE_BYPASS=1 PATH="$TMP/fakebin:$PATH" "$ROOT/bin/fm-teardown.sh" stack-9 \
    > "$TMP/teardown-9-new.out" 2>&1
st=$?
head -6 "$TMP/teardown-9-new.out"
check "the NEW teardown accepts the identical landed task without --force" "$st"

# --------------------- 9. a recorded base that resolves nowhere -------------
hdr "SCENARIO 9 - ADVERSARIAL: a recorded base naming a branch nobody created"
PROJ3="$TMP/stacker3"
git init -q -b main "$PROJ3"
printf 'baseline\n' > "$PROJ3/README.md"; git -C "$PROJ3" add -A; git -C "$PROJ3" commit -qm "main baseline"
git -C "$PROJ3" worktree add -q -b fm/stack-8 "$TMP/wt8" refs/heads/main
printf 'eight\n' > "$TMP/wt8/eight.txt"; git -C "$TMP/wt8" add -A; git -C "$TMP/wt8" commit -qm "task work"
mkdir -p "$TMP/home3/state" "$TMP/home3/data" "$TMP/home3/config"
{ printf 'window=firstmate:fm-stack-8\nendpoint_task_id=stack-8\n'
  printf 'worktree=%s\nproject=%s\nkind=ship\nmode=local-only\nspawn_gen=e2e\nbase=feat/never-created\n' "$TMP/wt8" "$PROJ3"; } \
  > "$TMP/home3/state/stack-8.meta"
touch "$TMP/home3/state/.last-watcher-beat"
env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$TMP/home3" FM_STATE_OVERRIDE="$TMP/home3/state" \
    FM_DATA_OVERRIDE="$TMP/home3/data" FM_CONFIG_OVERRIDE="$TMP/home3/config" \
    FM_GATE_REFUSE_BYPASS=1 PATH="$TMP/fakebin:$PATH" "$ROOT/bin/fm-teardown.sh" stack-8 2>&1 | head -6
env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$TMP/home3" FM_STATE_OVERRIDE="$TMP/home3/state" \
    FM_DATA_OVERRIDE="$TMP/home3/data" FM_CONFIG_OVERRIDE="$TMP/home3/config" \
    FM_GATE_REFUSE_BYPASS=1 PATH="$TMP/fakebin:$PATH" "$ROOT/bin/fm-teardown.sh" stack-8 >/dev/null 2>&1
[ $? -ne 0 ]; check "an unresolvable delivery target branch refuses with its real cause" $?
[ -d "$TMP/wt8" ]; check "the worktree was not discarded by that refusal" $?

# ------- 10. a remote mirror/<base> must not be mistaken for the base --------
hdr "SCENARIO 10 - ADVERSARIAL: origin carries mirror/feat/stack but not feat/stack"
PROJ4="$TMP/stacker4"
git init --bare -q "$TMP/origin4.git"
git init -q -b main "$PROJ4"
printf 'baseline\n' > "$PROJ4/README.md"; git -C "$PROJ4" add -A; git -C "$PROJ4" commit -qm "main baseline"
git -C "$PROJ4" remote add origin "$TMP/origin4.git"
git -C "$PROJ4" push -q -u origin main
git -C "$TMP/origin4.git" symbolic-ref HEAD refs/heads/main
# origin holds a same-suffix decoy branch, and NOT the delivery target branch.
git -C "$PROJ4" push -q origin "refs/heads/main:refs/heads/mirror/feat/stack"
git -C "$PROJ4" checkout -q -b feat/stack
printf 'groundwork\n' > "$PROJ4/groundwork.txt"; git -C "$PROJ4" add -A; git -C "$PROJ4" commit -qm "feat/stack groundwork"
run "git -C '$PROJ4' ls-remote --heads origin"
printf '$ git ls-remote --exit-code --heads origin feat/stack              -> '
git -C "$PROJ4" ls-remote --exit-code --heads origin 'feat/stack' >/dev/null 2>&1 && echo "exit 0 (a BARE name matches the decoy)" || echo "exit $?"
printf '$ git ls-remote --exit-code --heads origin refs/heads/feat/stack   -> '
git -C "$PROJ4" ls-remote --exit-code --heads origin 'refs/heads/feat/stack' >/dev/null 2>&1 && echo "exit 0" || echo "exit $? (absent, which is the truth)"

git -C "$PROJ4" worktree add -q -b fm/stack-7 "$TMP/wt7" refs/heads/feat/stack
printf 'seven\n' > "$TMP/wt7/seven.txt"; git -C "$TMP/wt7" add -A; git -C "$TMP/wt7" commit -qm "task work"
# The work IS landed on the local delivery target branch, and nowhere on origin.
git -C "$PROJ4" update-ref refs/heads/feat/stack "$(git -C "$TMP/wt7" rev-parse HEAD)"
mkdir -p "$TMP/home4/state" "$TMP/home4/data" "$TMP/home4/config"
{ printf 'window=firstmate:fm-stack-7\nendpoint_task_id=stack-7\n'
  printf 'worktree=%s\nproject=%s\nkind=ship\nmode=no-mistakes\nspawn_gen=e2e\nbase=feat/stack\n' "$TMP/wt7" "$PROJ4"; } \
  > "$TMP/home4/state/stack-7.meta"
touch "$TMP/home4/state/.last-watcher-beat"
env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$TMP/home4" FM_STATE_OVERRIDE="$TMP/home4/state" \
    FM_DATA_OVERRIDE="$TMP/home4/data" FM_CONFIG_OVERRIDE="$TMP/home4/config" \
    FM_GATE_REFUSE_BYPASS=1 PATH="$TMP/fakebin:$PATH" "$ROOT/bin/fm-teardown.sh" stack-7 \
    > "$TMP/teardown-7.out" 2>&1
st=$?
head -4 "$TMP/teardown-7.out"
check "teardown measured the LOCAL feat/stack, not the remote decoy, and accepted the landed work" "$st"

# ---------------- 11. the captain's fleet view names the real branch --------
hdr "SCENARIO 11 - the fleet view publishes the branch each task landed on"
step "bin/fm-fleet-view.sh, rendered from this home's real backlog"
env FM_HOME="$TMP/home" FM_DATA_OVERRIDE="$TMP/home/data" FM_STATE_OVERRIDE="$TMP/home/state" \
    FM_CONFIG_OVERRIDE="$TMP/home/config" FM_PROJECTS_OVERRIDE="$TMP/projects-unused" \
    PATH="$TMP/fakebin:$PATH" "$BIN/fm-fleet-view.sh" > "$TMP/fleet-view.txt" 2>&1
cat "$TMP/fleet-view.txt"
grep -q '| local feat/stack |' "$TMP/fleet-view.txt"
check "the landed-artifact column names feat/stack, not main" $?
! grep -q '| local main |' "$TMP/fleet-view.txt"
check "no landed task is published as having landed on main" $?

hdr "RESULT"
if [ "$FAILED" -eq 0 ]; then echo "ALL E2E CHECKS PASSED"; else echo "SOME E2E CHECKS FAILED"; fi
echo "fixture root: $TMP"
exit "$FAILED"
