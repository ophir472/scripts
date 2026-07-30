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
assert_contains "$(cat "$WORKDIR/ierr.txt")" "About to run:" "shows the equivalent command before executing"
assert_contains "$(cat "$WORKDIR/ierr.txt")" "oo.sh -a quota -c t1,p1" "equivalent command reflects both clusters"
REPORT_FILE=$(ls "$WORKDIR"/output-*.txt 2>/dev/null | head -1)
assert_contains "$([[ -n "$REPORT_FILE" ]] && cat "$REPORT_FILE")" "Grand totals across 2 cluster(s), 4 namespace(s):" "interactive run produced the same report a flag-driven run would"
rm -f "$WORKDIR"/output-*.txt

echo "=== interactive menu: cancelling at the final confirm runs nothing ==="
(cd "$WORKDIR" && printf '1\nall\nall\nn\nn\n' | /bin/bash "$WORKDIR/oo.sh" >"$WORKDIR/cout.txt" 2>"$WORKDIR/cerr.txt")
CANCEL_EXIT=$?
assert_eq "$CANCEL_EXIT" "0" "cancelling exits cleanly, not an error"
assert_contains "$(cat "$WORKDIR/cerr.txt")" "Cancelled" "confirms the cancellation"
CANCEL_REPORTS=$(ls "$WORKDIR"/output-*.txt 2>/dev/null | wc -l | tr -d ' ')
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

DISCOVERED_CLUSTERS_DUMP=""
if [[ -f "$WORKDIR/discovered-config.sh" ]]; then
  DISCOVERED_CLUSTERS_DUMP=$(source "$WORKDIR/discovered-config.sh"; printf '%s\n' "${CLUSTERS[@]}")
fi
assert_contains "$DISCOVERED_CLUSTERS_DUMP" "uat|abc12345u|https://api.clusterabc12345u.example.com|" "uat cluster row written with correct URL"
assert_contains "$DISCOVERED_CLUSTERS_DUMP" "dev|xyz67890d|https://api.clusterxyz67890d.example.com|" "dev cluster row written with correct URL"
assert_contains "$DISCOVERED_CLUSTERS_DUMP" "|checkout" "project column populated from a real namespace"

echo "=== discover: backs up an existing target file instead of clobbering it ==="
echo "# pre-existing config" > "$WORKDIR/discovered-config.sh"
run_discover $'testpass\nprodpass\n' -f "$TESTS_DIR/fixtures/cluster-ids.txt" -o "$WORKDIR/discovered-config.sh"
assert_contains "$DISCOVER_OUT" "Backed up existing config" "announces the backup"
BACKUP_COUNT=$(ls "$WORKDIR"/discovered-config.sh.bak.* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$BACKUP_COUNT" "1" "exactly one backup file created"

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
