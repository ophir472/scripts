#!/usr/bin/env bash
set -euo pipefail

# Resolve the real script location even when invoked through a symlink (e.g.
# ~/bin/oo -> .../openshift/oo.sh), so config.sh/lib/ are still found relative
# to the actual file, not the symlink's directory.
oo_source="${BASH_SOURCE[0]}"
while [[ -h "$oo_source" ]]; do
  oo_dir="$(cd -P "$(dirname "$oo_source")" && pwd)"
  oo_source="$(readlink "$oo_source")"
  [[ "$oo_source" != /* ]] && oo_source="$oo_dir/$oo_source"
done
SCRIPT_DIR="$(cd -P "$(dirname "$oo_source")" && pwd)"
unset oo_source oo_dir
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/quota.sh
source "$SCRIPT_DIR/lib/quota.sh"
# shellcheck source=lib/search.sh
source "$SCRIPT_DIR/lib/search.sh"
# shellcheck source=lib/discover.sh
source "$SCRIPT_DIR/lib/discover.sh"
# shellcheck source=lib/menu.sh
source "$SCRIPT_DIR/lib/menu.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [-a <action> [-e env|all] [-c cluster] [-n namespace] [-p project] [--insecure] [options]]

Run with no arguments at all for an interactive menu (pick action / env / project / clusters).

Actions:
  -a quota      report namespace quota (CPU/memory allocated vs. used)
  -a search <string>
                search base64-decoded secret values for <string>
  -a discover -f <file>
                log into clusters listed in <file> (one identifier per line, e.g.
                clusterabc12345u) and regenerate config.sh's CLUSTERS array

Selection (combine as needed; default is -e all -> every cluster, every namespace).
-e/-c/-n/-p all accept comma-separated lists (e.g. -e dev,uat or -c t1,t2):
  -e env        dev | uat | prod | all
  -c cluster    target cluster(s) by short name (overrides -e)
  -n namespace  target exact namespace name(s); without -c this searches every
                selected cluster and reports it wherever it's found
  -p project    only namespaces whose derived project matches (namespaces follow
                word-word-PROJECT-123456, exactly 6 trailing digits; project can
                contain hyphens)
  --insecure    use --insecure-skip-tls-verify when logging in
  -j N          how many clusters to process concurrently (default 8; quota
                and search actions only -- each cluster logs in once, reused
                for all its namespaces, never re-logged-in per namespace)

quota-only options:
  -o file       output file (default ./output-<timestamp>.txt)

discover-only options:
  -f file       cluster identifier list (required)
  -o file       write config here instead of config.sh (existing file is backed up first)

Examples:
  $(basename "$0")                                # interactive menu
  $(basename "$0") -a quota
  $(basename "$0") -a quota -e uat
  $(basename "$0") -a quota -c pr1 -n checkout-prod-482913
  $(basename "$0") -a quota -p checkout          # this project, across ALL envs
  $(basename "$0") -a quota -j 15                # up to 15 clusters at once
  $(basename "$0") -a search -e uat "my-secret-value"
  $(basename "$0") -a search -c pr1 -n checkout-prod-482913 "api-key"
  $(basename "$0") -a discover -f cluster-ids.txt
EOF
  exit "${1:-1}"
}

run_action_quota() {
  need_command jq
  need_command awk

  resolve_clusters
  prompt_passwords

  if [[ -z "$OUTPUT_FILE" ]]; then
    OUTPUT_FILE="./quota-report-$(date +%Y%m%d_%H%M%S).txt"
  fi

  local work_dir
  work_dir=$(mktemp -d)
  trap "rm -rf '$work_dir'" EXIT

  ACTIVITY_LOG="$work_dir/activity.log"
  : > "$ACTIVITY_LOG"
  local tail_pid
  tail_pid=$(ui_start_live_tail "$ACTIVITY_LOG")

  # Clusters are independent (different servers/kubeconfigs), so they're
  # processed concurrently (batches of $PARALLEL_JOBS, default 8, override
  # with -j) instead of one at a time -- the previous behavior was fully
  # sequential, which was slow with dozens of clusters.
  run_clusters_parallel quota_process_cluster "$work_dir"

  ui_stop_live_tail "$tail_pid"

  local summary_tmp="$work_dir/merged.summary" extended_tmp="$work_dir/merged.extended"
  : > "$extended_tmp"
  quota_write_summary_header "$summary_tmp"

  local grand_cpu_alloc=0 grand_cpu_used=0 grand_mem_alloc=0 grand_mem_used=0
  local clusters_processed=0 namespaces_processed=0
  local total=${#RESOLVED_CLUSTERS[@]}
  local i cpu_a cpu_u mem_a mem_u ns_count ok short
  for ((i = 0; i < total; i++)); do
    [[ -f "$work_dir/$i.log" ]] && cat "$work_dir/$i.log" >&2
    [[ -f "$work_dir/$i.summary" ]] && cat "$work_dir/$i.summary" >> "$summary_tmp"
    [[ -f "$work_dir/$i.extended" ]] && cat "$work_dir/$i.extended" >> "$extended_tmp"
    if [[ -f "$work_dir/$i.totals" ]]; then
      read -r cpu_a cpu_u mem_a mem_u ns_count ok short < "$work_dir/$i.totals"
      if [[ "$ok" == "1" ]]; then
        clusters_processed=$((clusters_processed + 1))
        namespaces_processed=$((namespaces_processed + ns_count))
        read -r grand_cpu_alloc grand_cpu_used grand_mem_alloc grand_mem_used <<< "$(quota_sum_totals \
          "$grand_cpu_alloc" "$grand_cpu_used" "$grand_mem_alloc" "$grand_mem_used" \
          "$cpu_a" "$cpu_u" "$mem_a" "$mem_u")"
      fi
    fi
  done

  quota_write_grand_totals "$summary_tmp" "$clusters_processed" "$namespaces_processed" \
    "$grand_cpu_alloc" "$grand_cpu_used" "$grand_mem_alloc" "$grand_mem_used"

  {
    echo "===== SUMMARY ====="
    echo "Generated: $(date)"
    echo "Selection: env=${ENV_FILTER:-<none>} cluster=${CLUSTER_FILTER:-<none>} namespace=${NAMESPACE_FILTER:-<none>} project=${PROJECT_FILTER:-<none>}"
    echo
    cat "$summary_tmp"
    echo
    echo "===== EXTENDED (raw quota data) ====="
    cat "$extended_tmp"
  } > "$OUTPUT_FILE"

  echo "Report written to $OUTPUT_FILE"
}

run_action_search() {
  need_command jq

  if [[ ${#REMAINING_ARGS[@]} -eq 0 ]]; then
    echo "ERROR: search action requires a search string, e.g. -a search -e uat \"my-value\"" >&2
    usage
  fi
  local search_string="${REMAINING_ARGS[0]}"

  resolve_clusters
  prompt_passwords

  local work_dir
  work_dir=$(mktemp -d)
  trap "rm -rf '$work_dir'" EXIT

  ACTIVITY_LOG="$work_dir/activity.log"
  : > "$ACTIVITY_LOG"
  local tail_pid
  tail_pid=$(ui_start_live_tail "$ACTIVITY_LOG")

  # Clusters are independent, so processed concurrently (batches of
  # $PARALLEL_JOBS, default 8, override with -j) instead of one at a time.
  run_clusters_parallel search_process_cluster "$work_dir" "$search_string"

  ui_stop_live_tail "$tail_pid"

  local total=${#RESOLVED_CLUSTERS[@]}
  local i
  for ((i = 0; i < total; i++)); do
    [[ -f "$work_dir/$i.log" ]] && cat "$work_dir/$i.log" >&2
    [[ -f "$work_dir/$i.found" ]] && cat "$work_dir/$i.found"
  done
}

need_command oc

if [[ $# -eq 0 ]]; then
  interactive_run
  exit 0
fi

parse_common_args "$@"
[[ "$COMMON_HELP" -eq 1 ]] && usage 0

case "$ACTION" in
  quota) run_action_quota ;;
  search) run_action_search ;;
  discover) run_action_discover ;;
  "") echo "ERROR: -a/--action is required (quota|search|discover)" >&2; usage ;;
  *) echo "ERROR: unknown action '$ACTION' (expected quota|search|discover)" >&2; usage ;;
esac
