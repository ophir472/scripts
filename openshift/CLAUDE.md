# Notes for Claude working in openshift/

For usage docs see `README.md`. This file is implementation-level guidance —
things that bit us during development and shouldn't be repeated.

## Runtime target: bash 3.2, not modern bash

The user's Mac ships bash 3.2 (no Homebrew bash on PATH), and that's what
`#!/usr/bin/env bash` resolves to. This rules out:
- `mapfile`/`readarray` (bash 4+) — use a `while read` loop with **process
  substitution** (`< <(cmd)`, not a pipe) if the loop body needs to set
  variables that must survive past the loop.
- `local -n` namerefs (bash 4.3+) — a function can't return multiple values
  by reference. The pattern used throughout: a helper that needs to "return"
  several values either sets predictable globals (e.g. `QUOTA_NS_CPU_ALLOC`,
  `CFG_ENV`/`CFG_SHORT`/...) or prints space-separated values for the caller
  to `read a b c d <<< "$(fn ...)"`.
- `declare -A` associative arrays — not used; dedup/lookups are done with a
  comma-joined "seen" string and `csv_contains`/substring matching instead.

**Always verify changes with `/bin/bash -n <file>` and run the real test
suite** (`/bin/bash tests/run-tests.sh`) — don't just eyeball syntax. A
change that looks fine and even runs under the invoking shell can still be
wrong if that shell isn't actually bash 3.2 (e.g. testing under zsh silently
gives different `BASH_REMATCH`/regex behavior than the bash 3.2 the scripts
actually run under).

## `set -e` gotchas specific to this codebase

Every `lib/*.sh` helper that loops and conditionally appends to an array
(`resolve_namespaces`, `resolve_clusters`, `config_list_envs`, etc.) ends
with an **explicit `return 0`**. This is required, not decorative: if the
loop's last iteration takes a "no match" branch, the last executed command
is a false `[[ ]] && ...` test, which becomes the function's return status.
When that function is later called as a bare statement (not inside `if`),
`set -e` aborts the whole script immediately — silently, with no error
message. This exact bug shipped once already (`resolve_namespaces`) and was
only caught because a `-p` filter happened to exercise the "last item
doesn't match" path in a test. If you add a new `resolve_*`/`config_*`-style
helper, give it the same trailing `return 0`.

Similarly, if a function is designed to return meaningful non-zero codes
(like `discover_parse_identifier`, which returns 0/1/2/3 for different
classifications), never call it as a bare statement — use
`cmd "$arg" || rc=$?` (with `rc=0` set beforehand), not `cmd; rc=$?`. The
bare form aborts the script under `set -e` before `rc=$?` ever runs.

## bash 3.2: expanding an empty array under `set -u` throws "unbound variable"

Fixed only in bash 4.4+. `${#arr[@]}` (length) is always safe even when
`arr=()`, but `"${arr[@]}"` (direct expansion) throws under `set -u` when the
array has zero elements. `run_clusters_parallel` in `lib/common.sh` hit this
(the "extra args" passed to a worker function are empty for quota, non-empty
for search) — fixed by checking `${#arr[@]} -gt 0` first and only expanding
`"${arr[@]}"` in that branch, never expanding an array that might be empty
unconditionally. Don't reach for `"${arr[@]:-}"` instead — that silently
turns "zero args" into "one empty-string arg", which is a different, subtler
bug if the callee ever inspects `$#` or positional args by number.

## `trap ... EXIT` inside a function must not reference a `local` var by name

Single-quoting a trap body (`trap 'rm -rf "$work_dir"' EXIT`) defers
expansion of `$work_dir` until the trap actually *fires* — which, for an
`EXIT` trap, is after the whole script (not just the function) finishes. If
`work_dir` is `local` to the function that set the trap, it's long out of
scope by then, and the trap dies with "unbound variable" instead of cleaning
up. This shipped once already in `run_action_quota`/`run_action_search`
(both moved `summary_tmp`/`extended_tmp`-style temp state into a `local
work_dir` when parallelization was added). Fix: double-quote the *outer*
trap string so the current value is captured immediately, while still in
scope: `trap "rm -rf '$work_dir'" EXIT`. If a variable used in a trap is a
real global (like `RESOLVED_CLUSTERS`), single-quoting is fine — this only
bites `local` variables.

## CLUSTERS format is pipe-delimited on purpose

`env|short|server|namespace|project` — pipe, not colon. The `server` field
is a URL and contains colons (`https://...`), so colon-delimiting 5 fields is
ambiguous. Don't "clean this up" to colons. If you add a 6th field, pipe is
still safe as long as no field itself can contain a literal `|` (true for
env/short/namespace/project by k8s naming rules, and true for URLs).

`RESOLVED_CLUSTERS` (the internal, deduped, one-row-per-cluster list built by
`resolve_clusters()`) is a *separate*, still colon-delimited
`env:short:server` format — 3 fields, server last, no ambiguity. Don't
confuse the two formats; `split_config_entry` parses the config's 5-field
pipe format, `split_cluster_entry` parses the internal 3-field colon format.

## Never commit real org data

`config.sh`'s example `CLUSTERS` rows and `tests/fixtures/*` must only use
generic placeholders (`clusterabc12345u`, `example.com`, etc.), never the
user's real cluster identifiers or internal domain. This was explicitly
requested and scrubbed once already — don't reintroduce real-looking
examples when adding new docs/tests, even if a real value would make a more
"realistic" example.

`DISCOVERY_DOMAIN` ships **blank** in `config.sh` on purpose — `discover.sh`
already refuses to run while it's empty (`ERROR: DISCOVERY_DOMAIN is not set`).
Don't "fix" this by giving it a default value; blank-by-default plus a hard
guard is the intended safety net so a fresh clone can't silently hit the
wrong domain.

## Every `oc` call in this codebase is read-only — keep it that way

Only `login` and `get` are used anywhere (`lib/common.sh`, `lib/quota.sh`,
`lib/search.sh`, `lib/discover.sh`) — `describe` was dropped as a redundant
second call per namespace (see the quota_process_cluster note above). No
`create`, `delete`, `patch`, `apply`, `replace`, `scale`, `exec`, etc. This is
a deliberate property of the tool (it's a reporting/inspection tool, not a
management one) — if a future feature needs a mutating `oc` verb, that's a significant
change in kind and should be confirmed explicitly with the user first, not
folded in quietly.

Related: `oc login` always writes to an **isolated temp kubeconfig**
(`mktemp`, removed right after that cluster is processed), never the user's
real `~/.kube/config`. Passwords are always prompted fresh (`read -rsp`),
never written to disk anywhere. Don't change either of these without being
asked — they were explicit requirements from the start of this project.

## `oo.sh` must resolve symlinks for `SCRIPT_DIR`

The README tells users to symlink `oo.sh` into `~/bin`. That only works
because `SCRIPT_DIR` is computed by following `${BASH_SOURCE[0]}` through
symlinks (a loop with `readlink`), not a naive
`dirname "${BASH_SOURCE[0]}"`. Reverting to the naive version breaks the
documented install path silently (it'll look for `config.sh`/`lib/` next to
the symlink instead of the real file). Covered by a regression test in
`tests/run-tests.sh` ("works when invoked through a symlink").

## Project-name derivation is regex-based, always live

`extract_project()` in `lib/common.sh` matches
`^[A-Za-z0-9]+-[A-Za-z0-9]+-(.+)-[0-9]{6}$` — namespaces are
`word-word-PROJECT-123456`, **exactly 6** trailing digits (not "any digits").
This is always computed live against the actual namespace name at runtime,
during `resolve_namespaces()`. The `project` column stored in `config.sh`'s
`CLUSTERS` rows is only a discovery-time snapshot, used solely to power the
interactive menu's project list and default cluster selection *before*
login — never trust it as the source of truth for actual `-p` filtering
logic; that always re-derives from a live `oc get projects` call.

## quota/search process clusters in parallel batches

`run_clusters_parallel` (`lib/common.sh`) backgrounds `quota_process_cluster`
/ `search_process_cluster` (`lib/quota.sh` / `lib/search.sh`) in batches of
`$PARALLEL_JOBS` (`-j`, default 8) clusters at a time, `wait`-ing for the
whole batch before starting the next. Not a sliding-window semaphore —
bash 3.2 has no `wait -n` (4.3+ only), so it can't replace a finished job
mid-batch; it waits for the slowest job in each batch. Fine in practice for
a handful of batches (e.g. 35 clusters / 8 = 5 batches).

Each worker runs in `(...) &`, a real subshell — it can't hand results back
via global variables, so it writes everything to files at
`$work_dir/<cluster-index>.{log,summary,extended,totals}` (quota) or
`.{log,found}` (search), and the caller reads those back in cluster-index
order after `run_clusters_parallel` returns. This also means output is
always in a **deterministic order** (by original `RESOLVED_CLUSTERS` index),
regardless of which cluster's background job actually finished first.

If you add a new parallel-cluster action, follow this same
worker-writes-files-not-variables shape rather than trying to thread results
back through globals — a background subshell's variable changes never
propagate to the parent process.

Login still happens exactly once per cluster no matter how many namespaces
it has (unaffected by parallelization — `-j` only controls how many
*clusters* run concurrently). `quota_collect_namespace` also only makes one
`oc` call per namespace now (`get -o json`) — the separate `oc describe
quota` call was dropped as a redundant second round-trip for the same data
in a prettier format; don't add it back for "nicer output" without checking
whether the JSON already covers what's needed (it does, currently).

## Quota field names: `limits.cpu`/`limits.memory`, not `requests.*`

`quota_collect_namespace` (`lib/quota.sh`) reads
`.spec.hard["limits.cpu"]`/`["limits.memory"]` and the matching
`.status.used` keys. This was originally `requests.cpu`/`requests.memory` (a
guess from the very first draft), which silently produced all-zero
allocated/used values against this user's real clusters — their
`ResourceQuota` objects track `limits.*`, not `requests.*`. Kubernetes
`ResourceQuota` supports tracking either one depending on how the quota
object itself was defined; if quota numbers ever look wrong again (e.g. a
different org's clusters track `requests.*` instead), check which key
`oc get quota -o json` actually returns before assuming the code is broken —
this is a per-cluster-policy field name, not a fixed API constant.

## Password re-entry is a soft check, never a hard gate

`prompt_and_verify_password` (`lib/common.sh`) test-logs into one
representative cluster right after each password is typed (dev/uat password
against the first non-prod cluster, prod password against the first prod
cluster), retrying up to 3 times. Deliberately **never exits** even after 3
failures — it warns and lets the real run proceed. This is intentional, not
a missed case: the single test cluster could just be unreachable for reasons
unrelated to the password, and hard-failing there would block every other
cluster over what might be one flaky target. The real per-cluster loop
already reports login failures gracefully on its own, so a genuinely wrong
password still surfaces normally once the actual run starts — verification
only exists to catch the common case (a typo) early, not to gate the run.

**The verification login is reused, not thrown away.** `prompt_and_verify_password`
now records the tested cluster's short name and its already-authenticated
kubeconfig (`VERIFIED_DEFAULT_SHORT`/`VERIFIED_DEFAULT_KUBECONFIG`, and the
`_PROD_` equivalents) instead of `rm -f`-ing it. `login_cluster_or_reuse`
(`lib/common.sh`) is a drop-in replacement for `login_cluster` used by every
call site (`quota_process_cluster`, `search_process_cluster`,
`run_action_discover`'s login loop) — same signature plus `$short`, same
`LOGIN_KUBECONFIG`/return-code contract — that checks whether `$short`
matches a verified slot first; if so it copies that kubeconfig (a fresh copy
each time, so the caller can freely `rm` it) instead of hitting the network
again. This matters most for `-e all`-style runs where the verification
cluster is very likely also one of the clusters actually being processed —
without this, that one cluster silently logged in twice.

Since `prompt_passwords` runs *before* any `work_dir` exists (quota/search/
discover all create theirs afterward), the verified kubeconfig starts as a
bare `mktemp` file with no owner to clean it up. `relocate_verified_kubeconfigs`
(`lib/common.sh`) moves it into the work_dir right after that's created,
updating `VERIFIED_*_KUBECONFIG` to the new path -- so the existing
`trap "rm -rf '$work_dir'" EXIT` cleans it up automatically. Call this once,
right after creating `work_dir`, in any new action that calls
`prompt_passwords`.

## Activity log / live tail (`lib/ui.sh`): shared file, not shared screen

`-l quiet|normal|verbose` and the live progress display are built around one
idea: **workers never touch the terminal directly**. Every worker
(`quota_process_cluster`, `search_process_cluster`, run sequentially or in
parallel batches) appends short lines to one shared `$ACTIVITY_LOG` file via
`log_activity KIND message` (`lib/ui.sh`) — a single small `>>` write per
call, which is atomic enough on a normal filesystem that concurrent parallel
workers can't corrupt each other's lines without any locking. Only the
*main* process ever renders anything: `ui_start_live_tail` runs a plain
`tail -n 15 -f` on that file, once, only when stderr is a real terminal and
`LOG_LEVEL != quiet`. This is why it's safe under parallelization — there's
no hand-rolled cursor-redraw code to fight over screen position between
concurrent processes; `tail -f` already handles "show last N then follow"
correctly on its own.

**`ui_stop_live_tail` dumps the log if it was never live-displayed.** If
`UI_TAIL_PID` was never set (not a real terminal -- piped, redirected,
automation, or any non-interactive invocation), `ui_stop_live_tail` `cat`s
the whole `$ACTIVITY_LOG` to stderr once the action finishes, instead of
just letting it vanish when `work_dir` gets cleaned up. This was added
because discovery originally had *zero* `log_activity` calls and the user
had no visibility into whether it was doing anything; once logging was
added, it turned out the live-tail-only design meant a non-tty invocation
(also common for quota/search) would still see nothing extra beyond the
final result. Don't remove this fallback thinking the tty-only path is
sufficient — it isn't, for exactly this reason.

`run_action_discover` (`lib/discover.sh`) sets up its own `ACTIVITY_LOG` +
`work_dir` + `ui_start_live_tail`/`ui_stop_live_tail`, same pattern as
`run_action_quota`/`run_action_search` in `oo.sh` -- but discovery isn't
parallelized (a plain sequential loop), so there's no multi-worker file
-writer concern there, just the same "make progress visible" motivation.
Logging starts *before* the identifier-parsing loop (not just the login
phase), so parse-time skips (malformed/unrecognized-suffix) show up live
too, not only in the final summary.

`log_activity`'s `KIND` controls color (LOGIN=green, ERROR=red, CMD=dim,
everything else=yellow) but only the `[KIND]` tag is colored, not the whole
line — deliberate, per explicit user preference for something calmer than a
wall of colored text. `log_cmd` (echoes the literal `oc` command about to
run, password always masked as `***`) only fires at `verbose`.

**This whole path is invisible to the piped test suite by construction** --
`ui_stderr_is_tty`/`ui_stdin_is_tty` are false under piped input, so
`tail -f` and the arrow-key reader never actually run in CI. Three real bugs
shipped here before being caught, all only reproducible against a genuine
pty (verified with Python's `pty.fork()`, not `script`/`expect` -- `script`'s
own stdin handling didn't compose cleanly with piping further input through
it):

1. `ui_stop_live_tail` called `wait "$pid"` unconditionally even when `$pid`
   was empty (no tty, no tail started) -- `wait ''` is invalid and aborts
   under `set -e` as a bare statement.
2. `ui_start_live_tail`/`ui_read_key` were originally called via command
   substitution (`pid=$(ui_start_live_tail ...)`, `key=$(ui_read_key)`).
   Command substitution always forks a subshell -- so `tail ... &` /
   the blocking `read` ran in a *subshell*, not the caller's own shell. For
   `tail`, that subshell exits immediately after echoing `$!`, orphaning the
   backgrounded `tail` before the caller ever gets a PID it can actually
   `wait` on as a real child. For key-reading, it meant a `trap ... INT` set
   by `ui_menu_setup_tty` and the blocked `read` lived in *different*
   processes, which is fragile depending on how a terminal/multiplexer
   propagates signals. Fix in both cases: don't echo-and-capture, set a
   global directly (`UI_TAIL_PID`, `UI_KEY`) so the relevant work happens in
   the exact process that holds the state/trap it needs.
3. **The subtle one**: even after (2), `ui_stop_live_tail`'s
   `wait "$UI_TAIL_PID" 2>/dev/null` still silently aborted the script under
   `set -e` -- `wait` naturally returns the killed process's own exit status
   (143, SIGTERM), and `2>/dev/null` only suppresses the *message*, not the
   *exit code*. Since this is an unguarded bare statement, `set -e` triggers
   immediately, one line before `return 0`. Symptom: `run_action_quota`
   would log in, fetch quota for every namespace successfully, then just...
   stop, with zero indication why -- no error message, no "Report written
   to", `ps` shows nothing running because the process already exited. This
   took the longest to isolate because every simplified reproduction
   (`tail` + parallel workers, without `set -e`) worked fine; the bug only
   exists in scripts that actually run under `set -e`, which `oo.sh` does.
   Fix: `wait "$UI_TAIL_PID" 2>/dev/null || true`.

If you touch `ui_start_live_tail`/`ui_stop_live_tail`/`ui_read_key` again,
verify against a real pty (`python3 -c` with the `pty` module), not just the
piped test suite -- the suite provides regression coverage by stubbing
`ui_stderr_is_tty` to force the path open (see "live tail start/stop doesn't
abort under set -e" in `tests/run-tests.sh`), but a *new* bug in this area
could easily slip past that same stub if it doesn't also exercise whatever's
different this time.

The interactive menu's pre-run confirmation (`lib/menu.sh`) shows the actual
`oc login`/`oc get projects`/`oc get quota`|`get secrets` commands (password
masked) instead of an `oo.sh -a ...` invocation — using the *first* matched
cluster as a representative example, since the exact per-namespace command
list isn't knowable before login. Don't try to enumerate every cluster's
exact commands here; the cluster list itself is already shown separately
right below it.

## Arrow-key menu (`lib/menu.sh` + `lib/ui.sh`): dispatch on `ui_stdin_is_tty`

`menu_choose_one`/`menu_choose_many` are thin dispatchers: arrow-key picker
(`*_arrow`) when stdin is a real terminal, numbered picker (`*_numbered`,
the original implementation) otherwise. This is why the whole automated test
suite (piped input throughout) never needed to change to get the modern menu
-- it always takes the numbered path, unchanged. Only a human at a real
keyboard ever reaches the arrow-key code.

Implementation notes if you touch the arrow-key pickers:
- Raw mode (`stty -icanon -echo`) is required to read one keypress at a time
  without waiting for Enter -- `ui_menu_setup_tty`/`ui_menu_restore_tty`
  save/restore it. **Always** pair setup with restore on every exit path
  (Enter, cancel, and `trap ... INT` for Ctrl-C) -- leaving the terminal in
  raw mode breaks the user's shell until they run `stty sane`.
- An arrow key is an escape sequence (`Esc [ A/B/C/D`), not one byte, so
  `ui_read_key` does a follow-up `read -rsn2 -t 1 rest` after seeing `Esc`.
  bash 3.2's `read -t` **only accepts integer seconds** -- `-t 0.01` errors
  with "invalid timeout specification" and silently breaks arrow-key
  detection entirely (every arrow key falls through to the `QUIT` case).
  `-t 1` is the fix; the cost is a bare lone `Esc` press taking up to 1s to
  resolve as cancel, acceptable since `q` is also available.
- `_menu_draw_one`/`_menu_draw_many` and the arrow-key pickers communicate
  via predictable globals (`_MENU_OPTIONS`, `_MENU_SELECTED`, `_MENU_CHECKED`
  ), not namerefs or return values -- same reason as everywhere else in this
  codebase (bash 3.2).
- Cursor hide/show (`\033[?25l` / `\033[?25h`) happens in
  `ui_menu_setup_tty`/`ui_menu_restore_tty` too, so it's automatically
  covered by the same setup/restore discipline.

## Discovery fully replaces, never merges -- by decision, not oversight

`oo.sh -a discover` regenerates the entire `CLUSTERS` array from only what it
successfully logs into *this run*; a mistyped password or a partial
identifier list drops clusters that aren't in this run's successful set. This
was flagged as a design gap with a proposed merge-mode fix; the user's
decision was explicitly **keep full-replace, don't merge, but warn** — so
`run_action_discover` (`lib/discover.sh`) compares the currently-loaded
`CLUSTERS` (already in memory from `config.sh` at startup, not re-read from
disk) against the short names that actually end up in `new_rows`, and prints
`WARNING: ... will be dropped: <shorts>` (stderr) for anything about to
disappear -- whether that cluster failed login, had zero namespaces, or was
simply left out of the input file, since all three cases result in it being
absent from the written file either way. Don't build a merge mode without
checking first — this was a deliberate choice, not something waiting to be
finished.

## Before considering any change to lib/*.sh or oo.sh done

Run `/bin/bash tests/run-tests.sh` (91 assertions as of this writing, mock
`oc`, no real cluster/credentials needed) and confirm it's still green. It
covers CLI targeting/comma-lists, project-name extraction edge cases,
discovery parsing (including the sit-dismissed and unknown-suffix paths),
the `set -e` regression case above, the interactive menu end to end
(including cancel), password-retry behavior (including the "test cluster
happens to be down" edge case), and `mock-oc`'s `MOCK_EXPECTED_PASSWORD` /
`MOCK_LOGIN_FAIL_SERVERS` knobs for simulating both.

For anything touching parallel execution or `sleep`-based timing, remember
`mock-oc` has zero artificial latency by default — a real speedup
demonstration needs a throwaway copy with an injected `sleep` (see git
history around the parallelization change for the exact recipe), not the
committed `tests/mock-oc`.
