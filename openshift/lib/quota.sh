#!/usr/bin/env bash
# Quota-checking domain logic. Source config.sh + common.sh first, then this file.

quota_write_summary_header() {
  local summary_file="$1"
  {
    printf '%-6s %-8s %-30s %-20s %-12s %-12s %-14s %-14s\n' "ENV" "CLUSTER" "NAMESPACE" "PROJECT" "CPU_ALLOC" "CPU_USED" "MEM_ALLOC" "MEM_USED"
    printf '%-6s %-8s %-30s %-20s %-12s %-12s %-14s %-14s\n' "---" "-------" "---------" "-------" "---------" "--------" "---------" "--------"
  } >> "$summary_file"
}

# Fetches quota for one namespace, appends the raw data to $extended_file and a
# summary row to $summary_file. Leaves this namespace's totals in
# QUOTA_NS_CPU_ALLOC / QUOTA_NS_CPU_USED / QUOTA_NS_MEM_ALLOC / QUOTA_NS_MEM_USED
# (bytes for memory) for the caller to accumulate into cluster/grand totals.
quota_collect_namespace() {
  local kubeconfig="$1" env="$2" short="$3" ns="$4" extended_file="$5" summary_file="$6"
  local project quota_json describe_out quota_count

  project=$(extract_project "$ns")

  quota_json=$(oc --kubeconfig="$kubeconfig" get quota -n "$ns" -o json 2>/dev/null || echo '{"items":[]}')
  describe_out=$(oc --kubeconfig="$kubeconfig" describe quota -n "$ns" 2>/dev/null || true)
  {
    echo "--- Namespace: $ns (project: ${project:-none}) ---"
    echo "$quota_json"
    echo
    echo "$describe_out"
    echo
  } >> "$extended_file"

  QUOTA_NS_CPU_ALLOC=0; QUOTA_NS_CPU_USED=0; QUOTA_NS_MEM_ALLOC=0; QUOTA_NS_MEM_USED=0

  quota_count=$(echo "$quota_json" | jq -r '.items | length' 2>/dev/null || echo 0)
  if [[ "$quota_count" -eq 0 ]]; then
    printf '%-6s %-8s %-30s %-20s %-12s %-12s %-14s %-14s\n' "$env" "$short" "$ns" "${project:-none}" "-" "-" "-" "-" >> "$summary_file"
    return
  fi

  # Process substitution (not a pipe) so this while loop runs in the current
  # shell and QUOTA_NS_* updates survive past the loop, even on bash 3.2
  # (macOS default) which has no mapfile/readarray.
  local cpu_alloc cpu_used mem_alloc mem_used
  while IFS=$'\t' read -r cpu_alloc cpu_used mem_alloc mem_used; do
    QUOTA_NS_CPU_ALLOC=$(awk -v a="$QUOTA_NS_CPU_ALLOC" -v b="$(parse_cpu "$cpu_alloc")" 'BEGIN{printf "%.3f", a+b}')
    QUOTA_NS_CPU_USED=$(awk -v a="$QUOTA_NS_CPU_USED" -v b="$(parse_cpu "$cpu_used")" 'BEGIN{printf "%.3f", a+b}')
    QUOTA_NS_MEM_ALLOC=$(awk -v a="$QUOTA_NS_MEM_ALLOC" -v b="$(parse_memory_to_bytes "$mem_alloc")" 'BEGIN{printf "%.0f", a+b}')
    QUOTA_NS_MEM_USED=$(awk -v a="$QUOTA_NS_MEM_USED" -v b="$(parse_memory_to_bytes "$mem_used")" 'BEGIN{printf "%.0f", a+b}')
  done < <(echo "$quota_json" | jq -r '.items[] | [(.spec.hard["requests.cpu"] // "0"), (.status.used["requests.cpu"] // "0"), (.spec.hard["requests.memory"] // "0"), (.status.used["requests.memory"] // "0")] | @tsv')

  printf '%-6s %-8s %-30s %-20s %-12s %-12s %-14s %-14s\n' "$env" "$short" "$ns" "${project:-none}" \
    "$QUOTA_NS_CPU_ALLOC" "$QUOTA_NS_CPU_USED" "$(human_bytes "$QUOTA_NS_MEM_ALLOC")" "$(human_bytes "$QUOTA_NS_MEM_USED")" >> "$summary_file"
}

# Adds two (cpu_alloc cpu_used mem_alloc mem_used) tuples. No namerefs (bash 3.2,
# macOS's default, doesn't support "local -n") — prints the 4 sums space-separated;
# caller does: read a b c d <<< "$(quota_sum_totals ...)"
quota_sum_totals() {
  local cpu_alloc_a="$1" cpu_used_a="$2" mem_alloc_a="$3" mem_used_a="$4"
  local cpu_alloc_b="$5" cpu_used_b="$6" mem_alloc_b="$7" mem_used_b="$8"
  awk -v ca="$cpu_alloc_a" -v cb="$cpu_alloc_b" -v ua="$cpu_used_a" -v ub="$cpu_used_b" \
      -v ma="$mem_alloc_a" -v mb="$mem_alloc_b" -v va="$mem_used_a" -v vb="$mem_used_b" \
    'BEGIN{printf "%.3f %.3f %.0f %.0f", ca+cb, ua+ub, ma+mb, va+vb}'
}

quota_write_cluster_totals() {
  local summary_file="$1" short="$2" cpu_alloc="$3" cpu_used="$4" mem_alloc="$5" mem_used="$6"
  {
    printf 'Cluster %s totals: CPU alloc=%s used=%s | Mem alloc=%s used=%s\n' \
      "$short" "$cpu_alloc" "$cpu_used" "$(human_bytes "$mem_alloc")" "$(human_bytes "$mem_used")"
    echo
  } >> "$summary_file"
}

quota_write_grand_totals() {
  local summary_file="$1" clusters_processed="$2" namespaces_processed="$3"
  local cpu_alloc="$4" cpu_used="$5" mem_alloc="$6" mem_used="$7"
  {
    echo "Grand totals across $clusters_processed cluster(s), $namespaces_processed namespace(s):"
    printf '  CPU allocated:    %s cores\n' "$cpu_alloc"
    printf '  CPU used:         %s cores\n' "$cpu_used"
    printf '  Memory allocated: %s\n' "$(human_bytes "$mem_alloc")"
    printf '  Memory used:      %s\n' "$(human_bytes "$mem_used")"
  } >> "$summary_file"
}
