#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
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
                namicgswd52u) and regenerate config.sh's CLUSTERS array

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

quota-only options:
  -o file       output file (default ./quota-report-<target>-<timestamp>.txt)

discover-only options:
  -f file       cluster identifier list (required)
  -o file       write config here instead of config.sh (existing file is backed up first)

Examples:
  $(basename "$0")                                # interactive menu
  $(basename "$0") -a quota
  $(basename "$0") -a quota -e uat
  $(basename "$0") -a quota -c pr1 -n checkout-prod-482913
  $(basename "$0") -a quota -p checkout          # this project, across ALL envs
  $(basename "$0") -a search -e uat "my-secret-value"
  $(basename "$0") -a search -c pr1 -n checkout-prod-482913 "api-key"
  $(basename "$0") -a discover -f cluster-ids.txt
EOF
  exit 1
}

run_action_quota() {
  need_command jq
  need_command awk

  resolve_clusters
  prompt_passwords

  if [[ -z "$OUTPUT_FILE" ]]; then
    target="${CLUSTER_FILTER:-$ENV_FILTER}"
    [[ -n "$PROJECT_FILTER" ]] && target="${target}-${PROJECT_FILTER}"
    [[ -n "$NAMESPACE_FILTER" ]] && target="${target}-${NAMESPACE_FILTER}"
    OUTPUT_FILE="./quota-report-$(sanitize_name "$target")-$(date +%Y%m%d_%H%M%S).txt"
  fi

  summary_tmp=$(mktemp)
  extended_tmp=$(mktemp)
  trap 'rm -f "$summary_tmp" "$extended_tmp"' EXIT

  quota_write_summary_header "$summary_tmp"

  grand_cpu_alloc=0; grand_cpu_used=0; grand_mem_alloc=0; grand_mem_used=0
  clusters_processed=0
  namespaces_processed=0

  for entry in "${RESOLVED_CLUSTERS[@]}"; do
    split_cluster_entry "$entry"
    env="$CL_ENV"; short="$CL_SHORT"; server="$CL_SERVER"

    if ! login_cluster "$server" "$env" "$INSECURE"; then
      echo "[$short] login failed" >&2
      continue
    fi
    kubeconfig="$LOGIN_KUBECONFIG"
    clusters_processed=$((clusters_processed + 1))

    resolve_namespaces "$kubeconfig"
    if [[ ${#RESOLVED_NAMESPACES[@]} -eq 0 ]]; then
      echo "[$short] no matching namespaces" >&2
      rm -f "$kubeconfig"
      continue
    fi

    echo "===== Cluster: $short ($env) -- $server =====" >> "$extended_tmp"

    cluster_cpu_alloc=0; cluster_cpu_used=0; cluster_mem_alloc=0; cluster_mem_used=0

    for ns in "${RESOLVED_NAMESPACES[@]}"; do
      namespaces_processed=$((namespaces_processed + 1))
      quota_collect_namespace "$kubeconfig" "$env" "$short" "$ns" "$extended_tmp" "$summary_tmp"
      read -r cluster_cpu_alloc cluster_cpu_used cluster_mem_alloc cluster_mem_used <<< "$(quota_sum_totals \
        "$cluster_cpu_alloc" "$cluster_cpu_used" "$cluster_mem_alloc" "$cluster_mem_used" \
        "$QUOTA_NS_CPU_ALLOC" "$QUOTA_NS_CPU_USED" "$QUOTA_NS_MEM_ALLOC" "$QUOTA_NS_MEM_USED")"
    done

    quota_write_cluster_totals "$summary_tmp" "$short" "$cluster_cpu_alloc" "$cluster_cpu_used" "$cluster_mem_alloc" "$cluster_mem_used"

    read -r grand_cpu_alloc grand_cpu_used grand_mem_alloc grand_mem_used <<< "$(quota_sum_totals \
      "$grand_cpu_alloc" "$grand_cpu_used" "$grand_mem_alloc" "$grand_mem_used" \
      "$cluster_cpu_alloc" "$cluster_cpu_used" "$cluster_mem_alloc" "$cluster_mem_used")"

    rm -f "$kubeconfig"
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

  for entry in "${RESOLVED_CLUSTERS[@]}"; do
    split_cluster_entry "$entry"
    env="$CL_ENV"; short="$CL_SHORT"; server="$CL_SERVER"

    if ! login_cluster "$server" "$env" "$INSECURE"; then
      echo "[$short] login failed" >&2
      continue
    fi
    kubeconfig="$LOGIN_KUBECONFIG"

    resolve_namespaces "$kubeconfig"
    if [[ ${#RESOLVED_NAMESPACES[@]} -eq 0 ]]; then
      echo "[$short] no matching namespaces" >&2
      rm -f "$kubeconfig"
      continue
    fi

    for ns in "${RESOLVED_NAMESPACES[@]}"; do
      search_collect_namespace "$kubeconfig" "$env" "$short" "$ns" "$search_string"
    done

    rm -f "$kubeconfig"
  done
}

need_command oc

if [[ $# -eq 0 ]]; then
  interactive_run
  exit 0
fi

parse_common_args "$@"
[[ "$COMMON_HELP" -eq 1 ]] && usage

case "$ACTION" in
  quota) run_action_quota ;;
  search) run_action_search ;;
  discover) run_action_discover ;;
  "") echo "ERROR: -a/--action is required (quota|search|discover)" >&2; usage ;;
  *) echo "ERROR: unknown action '$ACTION' (expected quota|search|discover)" >&2; usage ;;
esac
