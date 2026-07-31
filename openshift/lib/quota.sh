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
  local project quota_json quota_count

  project=$(extract_project "$ns")

  # Only "get -o json" -- "describe quota" was a second oc round-trip per
  # namespace for the same data in a prettier format; the JSON already
  # covers everything the summary/extended sections need.
  quota_json=$(oc --kubeconfig="$kubeconfig" get quota -n "$ns" -o json 2>/dev/null || echo '{"items":[]}')
  {
    echo "--- Namespace: $ns (project: ${project:-none}) ---"
    echo "$quota_json"
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
  done < <(echo "$quota_json" | jq -r '.items[] | [(.spec.hard["limits.cpu"] // "0"), (.status.used["limits.cpu"] // "0"), (.spec.hard["limits.memory"] // "0"), (.status.used["limits.memory"] // "0")] | @tsv')

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

# Runs the entire per-cluster quota workflow (login, resolve namespaces,
# fetch quota per namespace, cluster totals) for one cluster. Meant to be
# backgrounded (`quota_process_cluster ... &`) so many clusters run in
# parallel -- everything it needs to hand back to the caller is written to
# files under $out_prefix, since a background subshell's variables don't
# propagate back to the parent process.
#
# Writes:
#   $out_prefix.log       login/no-namespace-match messages (if any)
#   $out_prefix.summary   per-namespace summary rows + cluster totals line
#   $out_prefix.extended  raw quota JSON per namespace
#   $out_prefix.totals    "cpu_alloc cpu_used mem_alloc mem_used ns_count logged_in short"
quota_process_cluster() {
  local entry="$1" out_prefix="$2"
  split_cluster_entry "$entry"
  local env="$CL_ENV" short="$CL_SHORT" server="$CL_SERVER"

  log_activity LOGIN "Logging into $short ($env)..."
  log_cmd "oc login --server $server --username <user> --password ***"
  if ! login_cluster_or_reuse "$server" "$env" "$short" "$INSECURE"; then
    echo "[$short] login failed" >> "$out_prefix.log"
    log_activity ERROR "Login failed for $short"
    echo "0.000 0.000 0 0 0 0 $short" > "$out_prefix.totals"
    return
  fi
  log_activity LOGIN "Logged into $short"
  local kubeconfig="$LOGIN_KUBECONFIG"

  resolve_namespaces "$kubeconfig"
  if [[ ${#RESOLVED_NAMESPACES[@]} -eq 0 ]]; then
    echo "[$short] no matching namespaces" >> "$out_prefix.log"
    rm -f "$kubeconfig"
    echo "0.000 0.000 0 0 0 1 $short" > "$out_prefix.totals"
    return
  fi

  echo "===== Cluster: $short ($env) -- $server =====" >> "$out_prefix.extended"

  local cluster_cpu_alloc=0 cluster_cpu_used=0 cluster_mem_alloc=0 cluster_mem_used=0
  local ns
  for ns in "${RESOLVED_NAMESPACES[@]}"; do
    log_cmd "oc get quota -n $ns -o json"
    quota_collect_namespace "$kubeconfig" "$env" "$short" "$ns" "$out_prefix.extended" "$out_prefix.summary"
    log_activity QUOTA "Got quota for $short/$ns"
    read -r cluster_cpu_alloc cluster_cpu_used cluster_mem_alloc cluster_mem_used <<< "$(quota_sum_totals \
      "$cluster_cpu_alloc" "$cluster_cpu_used" "$cluster_mem_alloc" "$cluster_mem_used" \
      "$QUOTA_NS_CPU_ALLOC" "$QUOTA_NS_CPU_USED" "$QUOTA_NS_MEM_ALLOC" "$QUOTA_NS_MEM_USED")"
  done
  quota_write_cluster_totals "$out_prefix.summary" "$short" "$cluster_cpu_alloc" "$cluster_cpu_used" "$cluster_mem_alloc" "$cluster_mem_used"
  rm -f "$kubeconfig"

  echo "$cluster_cpu_alloc $cluster_cpu_used $cluster_mem_alloc $cluster_mem_used ${#RESOLVED_NAMESPACES[@]} 1 $short" > "$out_prefix.totals"
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
