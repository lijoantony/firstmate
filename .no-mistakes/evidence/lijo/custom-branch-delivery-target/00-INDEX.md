# Live validation: the per-task delivery target branch (`--base`)

Every transcript here comes from driving the real firstmate scripts against real
git repositories built for the run. The headline transcript also uses a real
tmux server on a private socket and a real `treehouse` worktree pool.

Substituted only where the dependency is external to the change:
`gh-axi` (the fixture's origin is a local bare repo with no forge) and, in the
matrix runs, `treehouse`/`tmux` (the landed-work gate under test runs before
either is reached). `FM_GATE_REFUSE_BYPASS=1` is the repository's own documented
test-harness escape hatch for running `fm-spawn`/`fm-teardown` from a gate
worktree.

| File | What it shows |
| --- | --- |
| `01-lifecycle-end-to-end.txt` | One ship task stacked on `feat/stack`, start to finish: brief -> live spawn (real tmux window, real treehouse worktree) -> the worker running the brief's own branch step -> review diff -> guarded landing -> teardown -> the durable backlog record and the operator's fleet view. |
| `02-spawn-brief-agreement-guard.txt` | The brief/spawn delivery agreement refusing in both directions, `--relaunch` and scout refusing `--base`, and intake refusing every branch name the durable close marker would reject later. |
| `03-merge-local-matrix.txt` | The guarded local landing: lands on the recorded branch, still lands on the default branch without one, and refuses a dirty tree, the wrong checkout, a diverged branch, a missing branch, and a non-`local-only` task. Includes the same-named-tag case. |
| `04-teardown-landed-work-matrix.txt` | The landed-work gate. The headline contrast is first: the identical completed task is refused as unlanded WITHOUT the recorded base and tears down WITH it. Then unlanded work, an unresolvable base, an unreachable origin, and the squash content fallback. |
| `05-close-marker-replay.txt` | An interrupted cleanup leaves a pending-close record; the next session start replays it and a branch containing `%` survives untouched. Four tampered records are refused rather than replayed. |
| `06-review-round-regressions.txt` | Both earlier review-round fixes reproduced against the pre-fix source and passing against this branch. |
| `07-brief-default-branch-parity.txt` | Omitting `--base` renders the pre-change brief byte for byte in all three modes, with the hashes; then the diff `--base` actually makes. |
| `08-review-diff-base-resolution.txt` | The review diff's base: the local branch, the refreshed remote copy, the default branch when no base is recorded, and refusals for an unreachable origin and an unresolvable branch. |
| `09-fleet-completion-note.txt` | The completion note the snapshot reads and the fleet view renders, including the title traps that must NOT be read as notes. |
| `10-brief-branch-step.txt` | The brief's own step-1 command sequence run verbatim in a real worktree across all three shapes a base can have: local only, local ahead of origin, remote only. |
