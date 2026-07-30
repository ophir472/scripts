#!/usr/bin/env bash
# Shared helpers for openshift/*.sh scripts. Source config.sh first, then this file.

need_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: $1 is required but not installed." >&2
    exit 1
  fi
}

sanitize_name() {
  local value="$1"
  value=${value//[^A-Za-z0-9._-]/-}
  echo "$value"
}

parse_cpu() {
  local value="$1"
  if [[ -z "$value" || "$value" == "-" ]]; then
    echo "0"
    return
  fi
  if [[ "$value" == *m ]]; then
    awk -v m="${value%m}" 'BEGIN {printf "%.3f", m/1000}'
  else
    awk -v v="$value" 'BEGIN {printf "%.3f", v}'
  fi
}

parse_memory_to_bytes() {
  local value="$1"
  if [[ -z "$value" || "$value" == "-" ]]; then
    echo "0"
    return
  fi
  local num unit
  value=$(echo "$value" | tr -d '[:space:]')
  case "$value" in
    *Ki) unit=1024; num=${value%Ki} ;;
    *Mi) unit=1048576; num=${value%Mi} ;;
    *Gi) unit=1073741824; num=${value%Gi} ;;
    *Ti) unit=1099511627776; num=${value%Ti} ;;
    *Pi) unit=1125899906842624; num=${value%Pi} ;;
    *Ei) unit=1152921504606846976; num=${value%Ei} ;;
    *K)  unit=1000; num=${value%K} ;;
    *M)  unit=1000000; num=${value%M} ;;
    *G)  unit=1000000000; num=${value%G} ;;
    *T)  unit=1000000000000; num=${value%T} ;;
    *P)  unit=1000000000000000; num=${value%P} ;;
    *E)  unit=1000000000000000000; num=${value%E} ;;
    *)   unit=1; num="$value" ;;
  esac
  awk -v n="$num" -v f="$unit" 'BEGIN {printf "%.0f", n * f}'
}

human_bytes() {
  local bytes="$1"
  awk -v b="$bytes" 'BEGIN {
    if (b < 1024) { printf "%dB", b }
    else if (b < 1048576) { printf "%.1fKi", b/1024 }
    else if (b < 1073741824) { printf "%.1fMi", b/1048576 }
    else if (b < 1099511627776) { printf "%.1fGi", b/1073741824 }
    else { printf "%.1fTi", b/1099511627776 }
  }'
}

# Namespaces follow "word-word-<project-name>-<6 digits>" -- project-name is
# everything between the first two words and the trailing 6-digit number, and
# may itself be multiple words/hyphens (it's usually 2). The digit suffix must
# be exactly 6 digits, not "any digits" -- a 5- or 7-digit tail doesn't match.
# Namespaces that don't fit this shape (e.g. sm-controlplane-123456, or any
# non-conforming digit count) have no project — echoes "".
extract_project() {
  local ns="$1"
  if [[ "$ns" =~ ^[A-Za-z0-9]+-[A-Za-z0-9]+-(.+)-[0-9]{6}$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

# Parses -a/-e/-c/-n/-p/-o/--insecure/-h. Leftover args (e.g. a search string)
# land in REMAINING_ARGS for the caller to handle. Sets COMMON_HELP=1 on -h/--help.
parse_common_args() {
  ACTION=""
  ENV_FILTER=""
  CLUSTER_FILTER=""
  NAMESPACE_FILTER=""
  PROJECT_FILTER=""
  OUTPUT_FILE=""
  DISCOVER_FILE=""
  INSECURE=0
  COMMON_HELP=0
  REMAINING_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--action) ACTION="$2"; shift 2 ;;
      -e|--env) ENV_FILTER="$2"; shift 2 ;;
      -c|--cluster) CLUSTER_FILTER="$2"; shift 2 ;;
      -n|--namespace) NAMESPACE_FILTER="$2"; shift 2 ;;
      -p|--project) PROJECT_FILTER="$2"; shift 2 ;;
      -o|--output) OUTPUT_FILE="$2"; shift 2 ;;
      -f|--file) DISCOVER_FILE="$2"; shift 2 ;;
      --insecure) INSECURE=1; shift ;;
      -h|--help) COMMON_HELP=1; shift ;;
      *) REMAINING_ARGS+=("$1"); shift ;;
    esac
  done
  # No -e and no -c means "everything" (matches "-n alone searches everywhere").
  if [[ -z "$ENV_FILTER" && -z "$CLUSTER_FILTER" ]]; then
    ENV_FILTER="all"
  fi
}

# True if comma-separated $1 contains the exact element $2. Tolerates stray
# spaces around commas (e.g. "-e dev, uat" typed by hand).
csv_contains() {
  local csv="$1" value="$2" item
  local IFS=','
  for item in $csv; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ "$item" == "$value" ]] && return 0
  done
  return 1
}

# Splits one CLUSTERS row ("env|short|server|namespace|project") into
# CFG_ENV / CFG_SHORT / CFG_SERVER / CFG_NAMESPACE / CFG_PROJECT globals.
# Pipe-delimited (not colon) because server is a URL and contains colons.
split_config_entry() {
  IFS='|' read -r CFG_ENV CFG_SHORT CFG_SERVER CFG_NAMESPACE CFG_PROJECT <<< "$1"
}

# Populates RESOLVED_CLUSTERS (array of "env:shortname:server", one per
# distinct cluster) from CLUSTERS, applying ENV_FILTER / CLUSTER_FILTER.
# Both accept comma-separated lists (e.g. -e dev,uat or -c t1,t2); -c wins
# over -e if both are set. CLUSTERS has one row per namespace, so this dedupes
# down to one row per cluster before logging in.
resolve_clusters() {
  RESOLVED_CLUSTERS=()
  local entry key seen="" include
  for entry in "${CLUSTERS[@]}"; do
    split_config_entry "$entry"
    key="$CFG_ENV:$CFG_SHORT:$CFG_SERVER"
    if [[ ",$seen," == *",$key,"* ]]; then
      continue
    fi
    include=0
    if [[ -n "$CLUSTER_FILTER" ]]; then
      csv_contains "$CLUSTER_FILTER" "$CFG_SHORT" && include=1
    elif [[ "$ENV_FILTER" == "all" ]]; then
      include=1
    elif csv_contains "$ENV_FILTER" "$CFG_ENV"; then
      include=1
    fi
    if [[ $include -eq 1 ]]; then
      RESOLVED_CLUSTERS+=("$key")
      seen="${seen:+$seen,}$key"
    fi
  done

  if [[ ${#RESOLVED_CLUSTERS[@]} -eq 0 ]]; then
    echo "ERROR: no clusters matched selection (env=${ENV_FILTER:-<none>} cluster=${CLUSTER_FILTER:-<none>})" >&2
    exit 1
  fi
  return 0
}

# Distinct env values seen in CLUSTERS, into CONFIG_ENVS.
config_list_envs() {
  local entry seen=""
  CONFIG_ENVS=()
  for entry in "${CLUSTERS[@]}"; do
    split_config_entry "$entry"
    if [[ ",$seen," != *",$CFG_ENV,"* ]]; then
      CONFIG_ENVS+=("$CFG_ENV")
      seen="${seen:+$seen,}$CFG_ENV"
    fi
  done
  return 0
}

# Distinct non-empty project values seen in CLUSTERS, into CONFIG_PROJECTS.
config_list_projects() {
  local entry seen=""
  CONFIG_PROJECTS=()
  for entry in "${CLUSTERS[@]}"; do
    split_config_entry "$entry"
    if [[ -n "$CFG_PROJECT" && ",$seen," != *",$CFG_PROJECT,"* ]]; then
      CONFIG_PROJECTS+=("$CFG_PROJECT")
      seen="${seen:+$seen,}$CFG_PROJECT"
    fi
  done
  return 0
}

# Populates MENU_CLUSTERS with unique "env|short|server" combos from CLUSTERS
# whose env is in $1 (comma list, or "all") and whose project is in $2 (comma
# list, "all", or "" -- both meaning any project). Config-only, no live oc calls
# -- this is what lets the interactive menu show a cluster list before login.
config_match_clusters() {
  local envs_csv="$1" projects_csv="$2"
  local entry key seen=""
  MENU_CLUSTERS=()
  for entry in "${CLUSTERS[@]}"; do
    split_config_entry "$entry"
    if [[ "$envs_csv" != "all" ]] && ! csv_contains "$envs_csv" "$CFG_ENV"; then
      continue
    fi
    if [[ -n "$projects_csv" && "$projects_csv" != "all" ]] && ! csv_contains "$projects_csv" "$CFG_PROJECT"; then
      continue
    fi
    key="$CFG_ENV|$CFG_SHORT|$CFG_SERVER"
    if [[ ",$seen," != *",$key,"* ]]; then
      MENU_CLUSTERS+=("$key")
      seen="${seen:+$seen,}$key"
    fi
  done
  return 0
}

# Split a "env:shortname:server" entry into CL_ENV / CL_SHORT / CL_SERVER globals.
split_cluster_entry() {
  local entry="$1" rest
  CL_ENV="${entry%%:*}"
  rest="${entry#*:}"
  CL_SHORT="${rest%%:*}"
  CL_SERVER="${rest#*:}"
}

# Prompts for whichever usernames RESOLVED_CLUSTERS actually needs. Sets
# PASS_DEFAULT and/or PASS_PROD.
prompt_passwords() {
  local need_default=0 need_prod=0 entry
  for entry in "${RESOLVED_CLUSTERS[@]}"; do
    split_cluster_entry "$entry"
    if [[ "$CL_ENV" == "prod" ]]; then need_prod=1; else need_default=1; fi
  done
  if [[ $need_default -eq 1 ]]; then
    read -rsp "Password for $USER_DEFAULT: " PASS_DEFAULT; echo
  fi
  if [[ $need_prod -eq 1 ]]; then
    read -rsp "Password for $USER_PROD (prod): " PASS_PROD; echo
  fi
}

# Logs into one cluster with an isolated temp kubeconfig (never touches the
# user's real kubeconfig). On success sets LOGIN_KUBECONFIG and returns 0; on
# failure removes the temp file and returns 1.
login_cluster() {
  local server="$1" env="$2" insecure="$3"
  local username password
  if [[ "$env" == "prod" ]]; then
    username="$USER_PROD"; password="$PASS_PROD"
  else
    username="$USER_DEFAULT"; password="$PASS_DEFAULT"
  fi
  LOGIN_KUBECONFIG=$(mktemp)
  local login_args=(--kubeconfig "$LOGIN_KUBECONFIG" login --server "$server" --username "$username" --password "$password")
  [[ "$insecure" -eq 1 ]] && login_args+=(--insecure-skip-tls-verify)
  if ! oc "${login_args[@]}" >/dev/null 2>&1; then
    rm -f "$LOGIN_KUBECONFIG"
    LOGIN_KUBECONFIG=""
    return 1
  fi
  return 0
}

# Populates RESOLVED_NAMESPACES from the accessible namespaces on $1 (a
# kubeconfig path), applying NAMESPACE_FILTER (-n, exact match, comma list
# allowed) or PROJECT_FILTER (-p, matched against extract_project, comma list
# allowed). Neither set -> all. Always live (oc get projects), never read from
# CLUSTERS -- the config's namespace/project columns are discovery-time
# snapshots, used only to build menus/defaults, not to gate what actually runs.
resolve_namespaces() {
  local kubeconfig="$1"
  local all_ns ns proj
  all_ns=$(oc --kubeconfig="$kubeconfig" get projects -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
  RESOLVED_NAMESPACES=()
  for ns in $all_ns; do
    if [[ -n "$NAMESPACE_FILTER" ]]; then
      csv_contains "$NAMESPACE_FILTER" "$ns" && RESOLVED_NAMESPACES+=("$ns")
    elif [[ -n "$PROJECT_FILTER" ]]; then
      proj=$(extract_project "$ns")
      csv_contains "$PROJECT_FILTER" "$proj" && RESOLVED_NAMESPACES+=("$ns")
    else
      RESOLVED_NAMESPACES+=("$ns")
    fi
  done
  # Explicit: under set -e, if the loop's last iteration takes the "no match"
  # branch, the [[ ]] && ... test leaves a non-zero status as this function's
  # return value, which aborts the whole script at the call site.
  return 0
}
