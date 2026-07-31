#!/usr/bin/env bash
# Cluster discovery: turns a plain list of cluster identifiers into config.sh's
# CLUSTERS array. Source config.sh + common.sh first, then this file.
#
# Identifier shape: "<anything><3 letters><digits><1 letter>", e.g.
# clusterabc12345u -> three_letters=abc digits=12345 last_letter=u (env=uat).
# short name = three_letters + digits + last_letter ("abc12345u").
# last_letter -> env: d=dev, u=uat, p=prod, s=sit (dismissed, not added),
# anything else is unrecognized and also skipped.
#
# Server URL: https://api.<full-identifier>.$DISCOVERY_DOMAIN (config.sh)

# Sets DISCOVER_ENV / DISCOVER_SHORT and returns:
#   0 = recognized (dev/uat/prod)
#   1 = malformed -- doesn't fit <letters><digits><letter> at all
#   2 = shape fits but last letter is s -- sit, dismissed silently by design
#   3 = shape fits but last letter is something else unrecognized -- warn
discover_parse_identifier() {
  local id="$1"
  DISCOVER_ENV=""; DISCOVER_SHORT=""
  if [[ ! "$id" =~ ^(.*)([A-Za-z]{3})([0-9]+)([A-Za-z])$ ]]; then
    return 1
  fi
  local letters="${BASH_REMATCH[2]}" digits="${BASH_REMATCH[3]}" last="${BASH_REMATCH[4]}"
  DISCOVER_SHORT="${letters}${digits}${last}"
  case "$last" in
    [dD]) DISCOVER_ENV="dev"; return 0 ;;
    [uU]) DISCOVER_ENV="uat"; return 0 ;;
    [pP]) DISCOVER_ENV="prod"; return 0 ;;
    [sS]) return 2 ;;
    *) return 3 ;;
  esac
}

run_action_discover() {
  if [[ -z "$DISCOVER_FILE" ]]; then
    echo "ERROR: discover action requires -f/--file <cluster-id-list>" >&2
    exit 1
  fi
  if [[ ! -f "$DISCOVER_FILE" ]]; then
    echo "ERROR: file not found: $DISCOVER_FILE" >&2
    exit 1
  fi
  if [[ -z "${DISCOVERY_DOMAIN:-}" ]]; then
    echo "ERROR: DISCOVERY_DOMAIN is not set in config.sh" >&2
    exit 1
  fi

  local ids=() line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(echo "$line" | tr -d '[:space:]')"
    [[ -n "$line" ]] && ids+=("$line")
  done < "$DISCOVER_FILE"

  if [[ ${#ids[@]} -eq 0 ]]; then
    echo "ERROR: no cluster identifiers found in $DISCOVER_FILE" >&2
    exit 1
  fi

  # Live progress log (same mechanism as quota/search): -l quiet suppresses
  # it, otherwise a real terminal gets a live scrolling view via `tail -f`,
  # piped/redirected runs just get plain lines. Set up before the parsing
  # loop below so even parse-time skips (malformed/unrecognized) show up
  # live, not just the login phase.
  local work_dir
  work_dir=$(mktemp -d)
  trap "rm -rf '$work_dir'" EXIT
  ACTIVITY_LOG="$work_dir/activity.log"
  : > "$ACTIVITY_LOG"
  ui_start_live_tail "$ACTIVITY_LOG"

  local id rc skipped_malformed=() skipped_unknown=() skipped_login=()
  local accepted_key seen_accepted=""
  RESOLVED_CLUSTERS=()
  local -a acc_env=() acc_short=() acc_server=()

  for id in "${ids[@]}"; do
    rc=0
    discover_parse_identifier "$id" || rc=$?
    case $rc in
      0) ;;
      1) skipped_malformed+=("$id"); log_activity ERROR "Skipping '$id': doesn't match the identifier shape"; continue ;;
      2) continue ;;                        # sit, dismissed silently
      3) skipped_unknown+=("$id"); log_activity ERROR "Skipping '$id': unrecognized env suffix"; continue ;;
    esac
    local server="https://api.${id}.${DISCOVERY_DOMAIN}"
    accepted_key="$DISCOVER_ENV:$DISCOVER_SHORT:$server"
    if [[ ",$seen_accepted," == *",$accepted_key,"* ]]; then
      continue
    fi
    seen_accepted="${seen_accepted:+$seen_accepted,}$accepted_key"
    acc_env+=("$DISCOVER_ENV")
    acc_short+=("$DISCOVER_SHORT")
    acc_server+=("$server")
    RESOLVED_CLUSTERS+=("$accepted_key")
    log_activity DISCOVER "Recognized $id -> $DISCOVER_SHORT ($DISCOVER_ENV)"
  done

  if [[ ${#RESOLVED_CLUSTERS[@]} -eq 0 ]]; then
    echo "ERROR: no recognizable cluster identifiers in $DISCOVER_FILE" >&2
    exit 1
  fi

  prompt_passwords
  relocate_verified_kubeconfigs "$work_dir"

  local new_rows=() i env short server kubeconfig all_ns ns_count ns project
  for ((i = 0; i < ${#acc_env[@]}; i++)); do
    env="${acc_env[$i]}"; short="${acc_short[$i]}"; server="${acc_server[$i]}"
    log_activity LOGIN "Logging into $short ($env)..."
    log_cmd "oc login --server $server --username <user> --password ***"
    if ! login_cluster_or_reuse "$server" "$env" "$short" "$INSECURE"; then
      skipped_login+=("$short ($server)")
      log_activity ERROR "Login failed for $short"
      continue
    fi
    log_activity LOGIN "Logged into $short"
    kubeconfig="$LOGIN_KUBECONFIG"
    log_cmd "oc get projects -o jsonpath='{.items[*].metadata.name}'"
    all_ns=$(oc --kubeconfig="$kubeconfig" get projects -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    ns_count=0
    for ns in $all_ns; do
      project=$(extract_project "$ns")
      new_rows+=("${env}|${short}|${server}|${ns}|${project}")
      ns_count=$((ns_count + 1))
    done
    log_activity DISCOVER "Found $ns_count namespace(s) on $short"
    rm -f "$kubeconfig"
  done

  ui_stop_live_tail

  # Warn about any cluster (by short name) in the currently-loaded config
  # that this run didn't reproduce -- discovery always fully replaces
  # CLUSTERS, it doesn't merge, so anything not found here is about to
  # disappear from the file (whether it failed login, had zero namespaces,
  # or was simply left out of this run's identifier list).
  local old_shorts="" cfg_entry new_shorts="" row_short row_entry
  # bash 3.2: expanding an empty array under `set -u` throws "unbound
  # variable" -- a fresh/empty CLUSTERS (first-ever discover run) would
  # otherwise crash right here instead of just finding nothing to warn about.
  if [[ ${#CLUSTERS[@]} -gt 0 ]]; then
    for cfg_entry in "${CLUSTERS[@]}"; do
      split_config_entry "$cfg_entry"
      csv_contains "$old_shorts" "$CFG_SHORT" || old_shorts="${old_shorts:+$old_shorts,}$CFG_SHORT"
    done
  fi
  for row_entry in "${new_rows[@]}"; do
    IFS='|' read -r _ row_short _ _ _ <<< "$row_entry"
    csv_contains "$new_shorts" "$row_short" || new_shorts="${new_shorts:+$new_shorts,}$row_short"
  done
  local -a disappearing=()
  local check_short
  if [[ -n "$old_shorts" ]]; then
    local IFS=','
    for check_short in $old_shorts; do
      csv_contains "$new_shorts" "$check_short" || disappearing+=("$check_short")
    done
  fi
  if [[ ${#disappearing[@]} -gt 0 ]]; then
    echo "WARNING: these clusters are in the current config but weren't reproduced by this run and will be dropped: ${disappearing[*]}" >&2
  fi

  if [[ ${#new_rows[@]} -eq 0 ]]; then
    echo "ERROR: logged into 0 clusters successfully; config.sh left untouched" >&2
    [[ ${#skipped_login[@]} -gt 0 ]] && printf '  login failed: %s\n' "${skipped_login[@]}" >&2
    exit 1
  fi

  local target="${OUTPUT_FILE:-$SCRIPT_DIR/config.sh}"
  if [[ -f "$target" ]]; then
    # Second-granularity timestamp collides if discover runs twice within
    # the same second (rare for a human, plausible for automation) -- an
    # incrementing suffix guarantees a fresh backup path either way, so an
    # earlier backup is never silently overwritten.
    local backup="${target}.bak.$(date +%Y%m%d_%H%M%S)" backup_n=2
    while [[ -f "$backup" ]]; do
      backup="${target}.bak.$(date +%Y%m%d_%H%M%S).$backup_n"
      backup_n=$((backup_n + 1))
    done
    cp "$target" "$backup"
    echo "Backed up existing config to $backup"
  fi

  local sorted_rows
  sorted_rows=$(printf '%s\n' "${new_rows[@]}" | sort)

  {
    echo "#!/usr/bin/env bash"
    echo "# Shared OpenShift configuration: clusters and usernames."
    echo "# Regenerated by: oo.sh -a discover -f $DISCOVER_FILE"
    echo "# Generated: $(date)"
    echo "# Never put passwords here -- they're always prompted at runtime."
    echo "#"
    echo "# Each entry: \"env|shortname|server|namespace|project\""
    echo "CLUSTERS=("
    while IFS= read -r row; do
      [[ -n "$row" ]] && printf '  "%s"\n' "$row"
    done <<< "$sorted_rows"
    echo ")"
    echo
    echo "USER_DEFAULT=\"$USER_DEFAULT\""
    echo "USER_PROD=\"$USER_PROD\""
    echo "DISCOVERY_DOMAIN=\"$DISCOVERY_DOMAIN\""
  } > "$target"

  echo "Wrote $target: ${#new_rows[@]} namespace rows across ${#acc_env[@]} cluster(s) attempted."
  if [[ ${#skipped_malformed[@]} -gt 0 ]]; then
    echo "Skipped (couldn't parse): ${skipped_malformed[*]}"
  fi
  if [[ ${#skipped_unknown[@]} -gt 0 ]]; then
    echo "Skipped (unrecognized env suffix): ${skipped_unknown[*]}"
  fi
  if [[ ${#skipped_login[@]} -gt 0 ]]; then
    echo "Skipped (login failed): ${skipped_login[*]}"
  fi
}
