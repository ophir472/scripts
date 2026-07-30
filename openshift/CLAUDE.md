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

## Known unresolved gap: discovery fully replaces, never merges

`oo.sh -a discover` regenerates the entire `CLUSTERS` array from only what
it successfully logs into *this run*. A mistyped password (dropping an
entire env) or running with a partial identifier list silently drops
clusters that aren't in this run's successful set — the old file is backed
up first, but nothing merges automatically. This was flagged to the user as
a design gap with a proposed fix (merge mode: keep existing rows for any
cluster that fails login or isn't in this run's input, default to merge
rather than replace) but not yet implemented — check with the user before
assuming which behavior is wanted if this comes up again.

## Before considering any change to lib/*.sh or oo.sh done

Run `/bin/bash tests/run-tests.sh` (72 assertions as of this writing, mock
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
