#!/usr/bin/env bash
# Exercises oo.sh (both the quota and search actions) against a mock `oc`
# (tests/mock-oc) -- no real cluster needed. Also runs lib/common.sh's
# extract_project as a plain unit test.
#
# Run: ./run-tests.sh
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENSHIFT_DIR="$(cd "$TESTS_DIR/.." && pwd)"

WORKDIR=$(mktemp -d)
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

cp "$OPENSHIFT_DIR/oo.sh" "$WORKDIR/"
cp -r "$OPENSHIFT_DIR/lib" "$WORKDIR/lib"
cp "$TESTS_DIR/fixtures/config.sh" "$WORKDIR/config.sh"
cp "$TESTS_DIR/mock-oc" "$WORKDIR/oc"
chmod +x "$WORKDIR"/*.sh "$WORKDIR/oc"

PASS=0
FAIL=0

assert_eq() {
  local actual="$1" expected="$2" desc="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc"
    echo "  expected: [$expected]"
    echo "  actual:   [$actual]"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" desc="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc"
    echo "  expected output to contain: $needle"
    echo "  --- actual output ---"
    echo "$haystack" | sed 's/^/  /'
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" desc="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc"
    echo "  expected output NOT to contain: $needle"
  fi
}

# run_quota <stdin-passwords> <oo.sh args after -a quota...> -- sets QUOTA_OUT/QUOTA_ERR/QUOTA_EXIT
run_quota() {
  local stdin="$1"; shift
  printf '%s' "$stdin" | /bin/bash "$WORKDIR/oo.sh" -a quota "$@" -o "$WORKDIR/out.txt" 2>"$WORKDIR/err.txt"
  QUOTA_EXIT=$?
  QUOTA_OUT=$(cat "$WORKDIR/out.txt" 2>/dev/null)
  QUOTA_ERR=$(cat "$WORKDIR/err.txt" 2>/dev/null)
}

# run_search <stdin-passwords> <oo.sh args after -a search...> -- sets SEARCH_OUT/SEARCH_ERR/SEARCH_EXIT
run_search() {
  local stdin="$1"; shift
  printf '%s' "$stdin" | /bin/bash "$WORKDIR/oo.sh" -a search "$@" >"$WORKDIR/sout.txt" 2>"$WORKDIR/serr.txt"
  SEARCH_EXIT=$?
  SEARCH_OUT=$(cat "$WORKDIR/sout.txt" 2>/dev/null)
  SEARCH_ERR=$(cat "$WORKDIR/serr.txt" 2>/dev/null)
}

# run_discover <stdin-passwords> <oo.sh args after -a discover...> -- sets DISCOVER_OUT/DISCOVER_ERR/DISCOVER_EXIT
run_discover() {
  local stdin="$1"; shift
  printf '%s' "$stdin" | /bin/bash "$WORKDIR/oo.sh" -a discover "$@" >"$WORKDIR/dout.txt" 2>"$WORKDIR/derr.txt"
  DISCOVER_EXIT=$?
  DISCOVER_OUT=$(cat "$WORKDIR/dout.txt" 2>/dev/null)
  DISCOVER_ERR=$(cat "$WORKDIR/derr.txt" 2>/dev/null)
}

echo "=== unit: extract_project ==="
source "$WORKDIR/lib/common.sh"
assert_eq "$(extract_project qwe-rty-abd-def-123456)" "abd-def" "project with internal hyphen"
assert_eq "$(extract_project sm-controlplane-123456)" "" "known exception namespace has no project"
assert_eq "$(extract_project aaa-bbb-my-project-2-999999)" "my-project-2" "project containing a digit segment"
assert_eq "$(extract_project checkout-123456)" "" "too few segments -> no project"
assert_eq "$(extract_project aaa-bbb-project-12345)" "" "5-digit suffix (not exactly 6) -> no project"
assert_eq "$(extract_project aaa-bbb-project-1234567)" "" "7-digit suffix (not exactly 6) -> no project"

echo "=== unit: discover_parse_identifier ==="
source "$WORKDIR/lib/discover.sh"
discover_parse_identifier "clusterabc12345u"
assert_eq "$?:$DISCOVER_ENV:$DISCOVER_SHORT" "0:uat:abc12345u" "uat identifier parsed"
discover_parse_identifier "clusterxyz67890d"
assert_eq "$?:$DISCOVER_ENV:$DISCOVER_SHORT" "0:dev:xyz67890d" "dev identifier with 5-digit run parsed"
discover_parse_identifier "clusterfoo11111s"
assert_eq "$?" "2" "sit suffix dismissed silently"
discover_parse_identifier "clusterbar22222q"
assert_eq "$?" "3" "unrecognized suffix flagged"
discover_parse_identifier "short"
assert_eq "$?" "1" "too-short identifier flagged as malformed"

echo "=== unit: menu_choose_one / menu_choose_many ==="
source "$WORKDIR/lib/menu.sh"
assert_eq "$(printf '2\n' | menu_choose_one 'pick' opt-a opt-b opt-c 2>/dev/null)" "opt-b" "single choice by number"
assert_eq "$(printf '1,3\n' | menu_choose_many 'pick' opt-a opt-b opt-c opt-d 2>/dev/null)" "$(printf 'opt-a\nopt-c')" "multi choice by comma list"
assert_eq "$(printf 'all\n' | menu_choose_many 'pick' opt-a opt-b 2>/dev/null)" "all" "multi choice \"all\" shortcut"

echo "=== unit: live tail start/stop doesn't abort under set -e (regression) ==="
# This whole path is gated on ui_stderr_is_tty, which is always false under
# piped test input -- stubbing it lets this regression get covered even
# without a real terminal. Two real bugs shipped here before: (1) stopping a
# tail that was never started called `wait ''` (invalid, aborts under set
# -e), (2) `wait "$pid"` on a killed tail naturally returns its exit status
# (143), which under set -e silently aborts the whole script one line before
# `return 0` -- the `2>/dev/null` on that wait only hid the message, not the
# exit code.
UI_TAIL_TEST_LOG=$(mktemp)
UI_TAIL_REGRESSION_OUT=$(
  set -e
  source "$WORKDIR/lib/ui.sh"
  ui_stderr_is_tty() { return 0; }
  LOG_LEVEL=normal
  echo "pre-existing line" > "$UI_TAIL_TEST_LOG"
  ui_stop_live_tail   # never started -- must not try to wait on an empty PID
  echo "SURVIVED_NEVER_STARTED"
  ui_start_live_tail "$UI_TAIL_TEST_LOG"
  sleep 0.2
  ui_stop_live_tail   # kill+wait a real tail -- must not abort on its exit status
  echo "SURVIVED_START_STOP"
)
UI_TAIL_REGRESSION_EXIT=$?
rm -f "$UI_TAIL_TEST_LOG"
assert_eq "$UI_TAIL_REGRESSION_EXIT" "0" "does not abort under set -e"
assert_contains "$UI_TAIL_REGRESSION_OUT" "SURVIVED_NEVER_STARTED" "stopping a never-started tail is a no-op"
assert_contains "$UI_TAIL_REGRESSION_OUT" "SURVIVED_START_STOP" "starting then stopping a real tail completes normally"

export PATH="$WORKDIR:$PATH"

echo "=== quota: default (-e all) covers every cluster/namespace ==="
run_quota $'testpass\nprodpass\n' -e all
assert_eq "$QUOTA_EXIT" "0" "exits cleanly"
assert_contains "$QUOTA_OUT" "Grand totals across 2 cluster(s), 4 namespace(s):" "processes both clusters, both namespaces each"
assert_contains "$QUOTA_OUT" "checkout" "project column populated"

echo "=== quota: -p filters to one project, across all envs ==="
run_quota $'testpass\nprodpass\n' -e all -p checkout
assert_contains "$QUOTA_OUT" "Grand totals across 2 cluster(s), 2 namespace(s):" "only checkout namespaces counted"
assert_not_contains "$QUOTA_OUT" "sm-controlplane" "non-matching namespace excluded"

echo "=== quota: -n with no match anywhere (regression: used to abort under set -e) ==="
run_quota $'testpass\nprodpass\n' -e all -n does-not-exist
assert_eq "$QUOTA_EXIT" "0" "does not abort when a filter matches nothing"
assert_contains "$QUOTA_ERR" "no matching namespaces" "reports the miss per cluster instead of crashing"

echo "=== quota: -c + -n targets exactly one namespace on one cluster ==="
run_quota $'testpass\n' -c t1 -n sm-controlplane-222222
assert_contains "$QUOTA_OUT" "Grand totals across 1 cluster(s), 1 namespace(s):" "exactly one namespace processed"
assert_contains "$QUOTA_OUT" "none" "namespace without a derivable project is tagged none, not dropped"

echo "=== quota: -e prod only touches the prod cluster ==="
run_quota $'prodpass\n' -e prod
assert_contains "$QUOTA_OUT" " p1 " "prod cluster present"
assert_not_contains "$QUOTA_OUT" " t1 " "dev cluster excluded"

echo "=== quota: -e accepts a comma-separated list of envs ==="
run_quota $'testpass\nprodpass\n' -e "dev, prod"
assert_contains "$QUOTA_OUT" "Grand totals across 2 cluster(s), 4 namespace(s):" "both envs matched despite the stray space after the comma"

echo "=== interactive menu: full quota flow end to end (no CLI flags at all) ==="
(cd "$WORKDIR" && printf '1\nall\nall\nn\ny\ntestpass\nprodpass\n' | /bin/bash "$WORKDIR/oo.sh" 2>"$WORKDIR/ierr.txt")
INTER_EXIT=$?
assert_eq "$INTER_EXIT" "0" "interactive quota run exits cleanly"
assert_contains "$(cat "$WORKDIR/ierr.txt")" "About to run, for each of the 2 cluster(s) below:" "shows the real oc commands, not the oo.sh invocation"
assert_contains "$(cat "$WORKDIR/ierr.txt")" "oc login --server" "shows the real oc login command"
assert_contains "$(cat "$WORKDIR/ierr.txt")" "--password ***" "password is masked, never shown in the clear"
assert_contains "$(cat "$WORKDIR/ierr.txt")" "oc get quota -n <namespace> -o json" "shows the per-namespace command as a template"
REPORT_FILE=$(ls "$WORKDIR"/quota-report-*.txt 2>/dev/null | head -1)
assert_contains "$([[ -n "$REPORT_FILE" ]] && cat "$REPORT_FILE")" "Grand totals across 2 cluster(s), 4 namespace(s):" "interactive run produced the same report a flag-driven run would"
rm -f "$WORKDIR"/quota-report-*.txt

echo "=== interactive menu: cancelling at the final confirm runs nothing ==="
(cd "$WORKDIR" && printf '1\nall\nall\nn\nn\n' | /bin/bash "$WORKDIR/oo.sh" >"$WORKDIR/cout.txt" 2>"$WORKDIR/cerr.txt")
CANCEL_EXIT=$?
assert_eq "$CANCEL_EXIT" "0" "cancelling exits cleanly, not an error"
assert_contains "$(cat "$WORKDIR/cerr.txt")" "Cancelled" "confirms the cancellation"
CANCEL_REPORTS=$(ls "$WORKDIR"/quota-report-*.txt 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$CANCEL_REPORTS" "0" "no report written, no login attempted, when cancelled"

echo "=== quota: login failure on one cluster doesn't stop the run ==="
# t1's server always fails login here, so the default-user's password
# VERIFICATION step (which happens to pick t1 as its test cluster) also
# exhausts its 3 attempts and warns -- that's expected; it should still not
# block the real run, which then correctly skips t1 and processes p1.
MOCK_LOGIN_FAIL_SERVERS="fake-dev" run_quota $'testpass1\ntestpass2\ntestpass3\nprodpass\n' -e all
assert_eq "$QUOTA_EXIT" "0" "exits cleanly despite one login failure"
assert_contains "$QUOTA_ERR" "Proceeding anyway" "verification warns but doesn't block the run"
assert_contains "$QUOTA_ERR" "[t1] login failed" "failed cluster reported in the real run"
assert_contains "$QUOTA_OUT" "Grand totals across 1 cluster(s)" "the other cluster still gets processed"

echo "=== password verification: retries on a mistyped password, succeeds on the 3rd try ==="
MOCK_EXPECTED_PASSWORD="rightpass" run_quota $'wrongpass1\nwrongpass2\nrightpass\n' -c t1
assert_eq "$QUOTA_EXIT" "0" "eventually succeeds"
assert_contains "$QUOTA_ERR" "Login failed for testuser against t1" "reports the failed attempt(s)"
assert_contains "$QUOTA_OUT" "Grand totals across 1 cluster(s)" "run proceeds once the right password is entered"

echo "=== password verification: after 3 wrong attempts, warns and proceeds (doesn't hard-block) ==="
# Deliberately doesn't hard-exit here: the test cluster could just be down
# for unrelated reasons, and the real per-cluster loop below already reports
# a login failure on its own -- so the run continues, and simply shows 0
# clusters processed once the real attempt also fails with the same password.
MOCK_EXPECTED_PASSWORD="rightpass" run_quota $'wrong1\nwrong2\nwrong3\n' -c t1
assert_eq "$QUOTA_EXIT" "0" "does not hard-exit on repeated bad password"
assert_contains "$QUOTA_ERR" "Login still failing for testuser against t1 after 3 attempts" "clear final warning"
assert_contains "$QUOTA_ERR" "Proceeding anyway" "explains it's continuing rather than blocking"
assert_contains "$QUOTA_ERR" "[t1] login failed" "the real run's own login attempt fails too, reported as usual"
assert_contains "$QUOTA_OUT" "Grand totals across 0 cluster(s)" "no cluster actually got processed, but the run still completes and reports that clearly"

echo "=== password verification: prod password is tested against a prod cluster ==="
MOCK_EXPECTED_PASSWORD="testpass" run_quota $'testpass\nprodwrong\ntestpass\n' -e all
assert_eq "$QUOTA_EXIT" "0" "eventually succeeds"
assert_contains "$QUOTA_ERR" "Login failed for produser (prod) against p1" "prod password tested against the prod cluster specifically"
assert_contains "$QUOTA_OUT" "Grand totals across 2 cluster(s)" "both clusters end up processed once both passwords are right"

echo "=== password verification: the verification cluster's login is reused, not repeated ==="
# t1 (dev) and p1 (prod) are exactly the clusters prompt_passwords picks to
# test-log into for -e all -- the real run should reuse those sessions
# instead of logging into either one a second time.
LOGIN_LOG="$WORKDIR/login-attempts.log"
rm -f "$LOGIN_LOG"
MOCK_LOGIN_LOG="$LOGIN_LOG" run_quota $'testpass\nprodpass\n' -e all
DEV_LOGIN_COUNT=$(grep -c "fake-dev.example.com" "$LOGIN_LOG" 2>/dev/null || echo 0)
PROD_LOGIN_COUNT=$(grep -c "fake-prod.example.com" "$LOGIN_LOG" 2>/dev/null || echo 0)
assert_eq "$DEV_LOGIN_COUNT" "1" "t1 logged into exactly once (verification + real run reuse it), not twice"
assert_eq "$PROD_LOGIN_COUNT" "1" "p1 logged into exactly once, not twice"
assert_contains "$QUOTA_ERR" "Reusing verified login for t1" "explicitly reports reusing t1's verified session"
assert_contains "$QUOTA_ERR" "Reusing verified login for p1" "explicitly reports reusing p1's verified session"
assert_contains "$QUOTA_OUT" "Grand totals across 2 cluster(s), 4 namespace(s):" "the run still completes normally using the reused sessions"
rm -f "$LOGIN_LOG"

echo "=== search-string: finds a match ==="
MOCK_SECRET_VALUE="super-secret-value" run_search $'testpass\nprodpass\n' -e all "super-secret-value"
assert_contains "$SEARCH_OUT" "FOUND in" "match reported"
assert_eq "$SEARCH_EXIT" "0" "exits cleanly"

echo "=== search-string: string absent -> no false positives ==="
MOCK_SECRET_VALUE="super-secret-value" run_search $'testpass\nprodpass\n' -e all "not-present-xyz"
assert_not_contains "$SEARCH_OUT" "FOUND in" "no match reported"
assert_eq "$SEARCH_EXIT" "0" "exits cleanly even with zero matches"

echo "=== quota: -c accepts a comma-separated list of clusters ==="
run_quota $'testpass\nprodpass\n' -c t1,p1
assert_contains "$QUOTA_OUT" "Grand totals across 2 cluster(s), 4 namespace(s):" "both clusters processed via -c t1,p1"

echo "=== discover: parses identifiers, logs in, writes CLUSTERS, skips the rest ==="
run_discover $'testpass\nprodpass\n' -f "$TESTS_DIR/fixtures/cluster-ids.txt" -o "$WORKDIR/discovered-config.sh"
assert_eq "$DISCOVER_EXIT" "0" "discover exits cleanly"
assert_contains "$DISCOVER_OUT" "Wrote $WORKDIR/discovered-config.sh" "reports where it wrote"
assert_contains "$DISCOVER_OUT" "4 namespace rows across 2 cluster(s)" "2 accepted clusters x 2 mock namespaces each"
assert_contains "$DISCOVER_OUT" "Skipped (couldn't parse): short" "malformed identifier reported"
assert_contains "$DISCOVER_OUT" "Skipped (unrecognized env suffix): clusterbar22222q" "unrecognized suffix reported"
assert_not_contains "$DISCOVER_OUT" "clusterfoo11111s" "sit identifier dismissed with no mention at all"

echo "=== discover: shows live progress logging, not silent ==="
assert_contains "$DISCOVER_ERR" "[DISCOVER] Recognized clusterabc12345u -> abc12345u (uat)" "logs each recognized identifier as it's parsed"
assert_contains "$DISCOVER_ERR" "[ERROR] Skipping 'short': doesn't match the identifier shape" "logs parse-time skips live too, not just in the final summary"
assert_contains "$DISCOVER_ERR" "[LOGIN] Logging into abc12345u (uat)..." "logs each login attempt"
assert_contains "$DISCOVER_ERR" "[LOGIN] Logged into abc12345u" "logs successful logins"
assert_contains "$DISCOVER_ERR" "[DISCOVER] Found 2 namespace(s) on abc12345u" "logs how many namespaces were found per cluster"

DISCOVERED_CLUSTERS_DUMP=""
if [[ -f "$WORKDIR/discovered-config.sh" ]]; then
  DISCOVERED_CLUSTERS_DUMP=$(source "$WORKDIR/discovered-config.sh"; printf '%s\n' "${CLUSTERS[@]}")
fi
assert_contains "$DISCOVERED_CLUSTERS_DUMP" "uat|abc12345u|https://api.clusterabc12345u.example.com|" "uat cluster row written with correct URL"
assert_contains "$DISCOVERED_CLUSTERS_DUMP" "dev|xyz67890d|https://api.clusterxyz67890d.example.com|" "dev cluster row written with correct URL"
assert_contains "$DISCOVERED_CLUSTERS_DUMP" "|checkout" "project column populated from a real namespace"

echo "=== discover: warns when a currently-configured cluster isn't reproduced ==="
# The fixture config.sh has t1/p1; this run's identifier file finds
# abc12345u/xyz67890d instead -- neither t1 nor p1 is reproduced, so both
# should be flagged as about to be dropped.
assert_contains "$DISCOVER_ERR" "WARNING: these clusters are in the current config but weren't reproduced" "warns about the drop"
assert_contains "$DISCOVER_ERR" "t1" "t1 specifically named as disappearing"
assert_contains "$DISCOVER_ERR" "p1" "p1 specifically named as disappearing"

echo "=== discover: no warning when the rediscovered set fully covers the current config ==="
cat > "$WORKDIR/config.sh" <<'EOF'
CLUSTERS=(
  "uat|abc12345u|https://api.clusterabc12345u.example.com|old-namespace-000000|"
)
USER_DEFAULT="testuser"
USER_PROD="produser"
DISCOVERY_DOMAIN="example.com"
EOF
run_discover $'testpass\nprodpass\n' -f "$TESTS_DIR/fixtures/cluster-ids.txt" -o "$WORKDIR/discovered-config.sh"
assert_not_contains "$DISCOVER_ERR" "WARNING" "no warning when every existing cluster is reproduced"
cp "$TESTS_DIR/fixtures/config.sh" "$WORKDIR/config.sh"

echo "=== discover: backs up an existing target file instead of clobbering it ==="
# discovered-config.sh was already written by earlier tests above, so clear
# any backups they triggered first -- otherwise this assertion is a coin
# flip: an earlier backup and this one only collide into a single file
# (same per-second timestamp) if they happen to land in the same wall-clock
# second, so "exactly one" would fail whenever a test run straddles a
# second boundary between those two run_discover calls.
rm -f "$WORKDIR"/discovered-config.sh.bak.*
echo "# pre-existing config" > "$WORKDIR/discovered-config.sh"
run_discover $'testpass\nprodpass\n' -f "$TESTS_DIR/fixtures/cluster-ids.txt" -o "$WORKDIR/discovered-config.sh"
assert_contains "$DISCOVER_OUT" "Backed up existing config" "announces the backup"
BACKUP_COUNT=$(ls "$WORKDIR"/discovered-config.sh.bak.* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$BACKUP_COUNT" "1" "exactly one backup file created"

echo "=== discover: two rapid backups never clobber each other, even with colliding timestamps ==="
# The backup filename is second-granularity, so two runs in the same wall
# clock second would generate an identical name -- verifies the
# collision-avoidance suffix (.2, .3, ...) kicks in instead of silently
# overwriting an earlier backup, regardless of whether this particular test
# run happens to straddle a second boundary or not.
rm -f "$WORKDIR"/discovered-config.sh.bak.*
echo "# first version" > "$WORKDIR/discovered-config.sh"
run_discover $'testpass\nprodpass\n' -f "$TESTS_DIR/fixtures/cluster-ids.txt" -o "$WORKDIR/discovered-config.sh"
echo "# second version" > "$WORKDIR/discovered-config.sh"
run_discover $'testpass\nprodpass\n' -f "$TESTS_DIR/fixtures/cluster-ids.txt" -o "$WORKDIR/discovered-config.sh"
TWO_BACKUP_COUNT=$(ls "$WORKDIR"/discovered-config.sh.bak.* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$TWO_BACKUP_COUNT" "2" "two distinct backups exist, not one overwriting the other"
FIRST_VERSION_SURVIVED=$(grep -l "first version" "$WORKDIR"/discovered-config.sh.bak.* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$FIRST_VERSION_SURVIVED" "1" "the first backup's content survives even if the second run's timestamp collides with it"
rm -f "$WORKDIR"/discovered-config.sh.bak.*

echo "=== oo.sh: missing -a errors out instead of silently doing nothing ==="
printf '' | /bin/bash "$WORKDIR/oo.sh" -e all >"$WORKDIR/nact.out" 2>"$WORKDIR/nact.err"
NOACTION_EXIT=$?
assert_eq "$NOACTION_EXIT" "1" "exits non-zero when -a is missing"
assert_contains "$(cat "$WORKDIR/nact.err")" "action is required" "explains what's missing"

echo "=== oo.sh: unknown action rejected ==="
printf '' | /bin/bash "$WORKDIR/oo.sh" -a bogus -e all >"$WORKDIR/bad.out" 2>"$WORKDIR/bad.err"
BADACTION_EXIT=$?
assert_eq "$BADACTION_EXIT" "1" "exits non-zero for an unrecognized action"
assert_contains "$(cat "$WORKDIR/bad.err")" "unknown action" "explains what's wrong"

echo "=== oo.sh: works when invoked through a symlink from another directory ==="
mkdir -p "$WORKDIR/elsewhere-bin"
ln -sf "$WORKDIR/oo.sh" "$WORKDIR/elsewhere-bin/oo"
"$WORKDIR/elsewhere-bin/oo" -a quota -c t1 -o "$WORKDIR/symlink-out.txt" <<< $'testpass\n' 2>"$WORKDIR/symlink-err.txt"
SYMLINK_EXIT=$?
assert_eq "$SYMLINK_EXIT" "0" "symlinked invocation still finds config.sh/lib and runs cleanly"
assert_contains "$(cat "$WORKDIR/symlink-out.txt" 2>/dev/null)" "Grand totals across 1 cluster(s)" "symlinked run produces a real report, not a sourcing error"

echo "=== oo.sh: -h exits 0 (not treated as an error) ==="
printf '' | /bin/bash "$WORKDIR/oo.sh" -h >"$WORKDIR/help.out" 2>"$WORKDIR/help.err"
HELP_EXIT=$?
assert_eq "$HELP_EXIT" "0" "-h exits cleanly, unlike a real usage error"
assert_contains "$(cat "$WORKDIR/help.out")" "Usage:" "help text printed"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
