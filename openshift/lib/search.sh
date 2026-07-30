#!/usr/bin/env bash
# Secret-search domain logic. Source config.sh + common.sh first, then this file.

# Searches base64-decoded secret values in one namespace for $5 (search string).
# Prints "FOUND in [short/env]: ns/secretname" to stdout for each match.
search_collect_namespace() {
  local kubeconfig="$1" env="$2" short="$3" ns="$4" search_string="$5"
  oc --kubeconfig="$kubeconfig" get secrets -n "$ns" -o json 2>/dev/null | \
    jq -r '.items[] | .metadata.namespace + "/" + .metadata.name as $id | (.data // {}) | to_entries[] | [$id, .value] | @tsv' | \
    while IFS=$'\t' read -r id val; do
      if printf '%s' "$val" | base64 -d 2>/dev/null | grep -qF "$search_string"; then
        echo "FOUND in [$short/$env]: $id"
      fi
    done
}

# Runs the entire per-cluster search workflow (login, resolve namespaces,
# search secrets) for one cluster. Meant to be backgrounded
# (`search_process_cluster ... &`) so many clusters run in parallel -- writes
# results to files under $out_prefix rather than returning via variables,
# since a background subshell's variables don't propagate back to the parent.
#
# Writes:
#   $out_prefix.log    login/no-namespace-match messages (if any)
#   $out_prefix.found  "FOUND in [...]" lines, if any
search_process_cluster() {
  local entry="$1" out_prefix="$2" search_string="$3"
  split_cluster_entry "$entry"
  local env="$CL_ENV" short="$CL_SHORT" server="$CL_SERVER"

  log_activity LOGIN "Logging into $short ($env)..."
  log_cmd "oc login --server $server --username <user> --password ***"
  if ! login_cluster "$server" "$env" "$INSECURE"; then
    echo "[$short] login failed" >> "$out_prefix.log"
    log_activity ERROR "Login failed for $short"
    return
  fi
  log_activity LOGIN "Logged into $short"
  local kubeconfig="$LOGIN_KUBECONFIG"

  resolve_namespaces "$kubeconfig"
  if [[ ${#RESOLVED_NAMESPACES[@]} -eq 0 ]]; then
    echo "[$short] no matching namespaces" >> "$out_prefix.log"
    rm -f "$kubeconfig"
    return
  fi

  local ns
  for ns in "${RESOLVED_NAMESPACES[@]}"; do
    log_cmd "oc get secrets -n $ns -o json"
    search_collect_namespace "$kubeconfig" "$env" "$short" "$ns" "$search_string" >> "$out_prefix.found"
    log_activity SEARCH "Searched $short/$ns"
  done
  rm -f "$kubeconfig"
}
