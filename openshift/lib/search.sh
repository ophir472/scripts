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
