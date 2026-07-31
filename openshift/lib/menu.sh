#!/usr/bin/env bash
# Interactive menu shown when oo.sh is run with no arguments. Source config.sh
# + common.sh + lib/ui.sh + quota.sh + search.sh first, then this file.

# Numbered single-choice prompt (fallback for non-tty stdin -- see
# menu_choose_one). $1 = prompt text, remaining args = options. Echoes the
# chosen option text (not its number).
menu_choose_one_numbered() {
  local prompt="$1"; shift
  local -a options=("$@")
  local i choice
  echo "$prompt" >&2
  for ((i = 0; i < ${#options[@]}; i++)); do
    printf '  %d) %s\n' "$((i + 1))" "${options[$i]}" >&2
  done
  while true; do
    read -rp "> " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      echo "${options[$((choice - 1))]}"
      return 0
    fi
    echo "Enter a number between 1 and ${#options[@]}." >&2
  done
}

# Numbered multi-choice prompt (fallback -- see menu_choose_many) with an
# "All" shortcut. $1 = prompt text, remaining args = options. User types
# comma-separated numbers (e.g. "1,3") or "all". Echoes the chosen options
# newline-separated, or the single line "all".
menu_choose_many_numbered() {
  local prompt="$1"; shift
  local -a options=("$@")
  local i choice num out
  echo "$prompt (comma-separated numbers, or \"all\")" >&2
  for ((i = 0; i < ${#options[@]}; i++)); do
    printf '  %d) %s\n' "$((i + 1))" "${options[$i]}" >&2
  done
  while true; do
    read -rp "> " choice
    choice="$(echo "$choice" | tr -d '[:space:]')"
    if [[ "$choice" == "all" || "$choice" == "All" || -z "$choice" ]]; then
      echo "all"
      return 0
    fi
    if [[ "$choice" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
      out=""
      local IFS=','
      local valid=1
      for num in $choice; do
        if (( num < 1 || num > ${#options[@]} )); then
          valid=0
          break
        fi
        out="${out:+$out
}${options[$((num - 1))]}"
      done
      if [[ $valid -eq 1 ]]; then
        printf '%s\n' "$out"
        return 0
      fi
    fi
    echo "Enter comma-separated numbers between 1 and ${#options[@]}, or \"all\"." >&2
  done
}

# Redraws the single-choice list in place, reading _MENU_OPTIONS /
# _MENU_SELECTED (globals, not locals -- bash 3.2 has no namerefs, and this
# keeps the draw logic shared between the initial paint and every redraw
# without a nested function).
_menu_draw_one() {
  local i
  for ((i = 0; i < ${#_MENU_OPTIONS[@]}; i++)); do
    printf '\033[2K\r' >&2
    if [[ $i -eq $_MENU_SELECTED ]]; then
      printf '%s> %s%s\n' "$UI_CYAN" "${_MENU_OPTIONS[$i]}" "$UI_RESET" >&2
    else
      printf '  %s\n' "${_MENU_OPTIONS[$i]}" >&2
    fi
  done
}

# Arrow-key single-choice picker. Same signature/output as
# menu_choose_one_numbered. Only called when stdin is a real terminal.
menu_choose_one_arrow() {
  local prompt="$1"; shift
  _MENU_OPTIONS=("$@")
  _MENU_SELECTED=0
  local n=${#_MENU_OPTIONS[@]} key

  echo "$prompt" >&2
  echo "(↑/↓ to move, enter to select, q to cancel)" >&2
  ui_menu_setup_tty
  _menu_draw_one

  while true; do
    ui_read_key; key="$UI_KEY"
    case "$key" in
      UP) _MENU_SELECTED=$(( (_MENU_SELECTED - 1 + n) % n )) ;;
      DOWN) _MENU_SELECTED=$(( (_MENU_SELECTED + 1) % n )) ;;
      ENTER)
        ui_menu_restore_tty
        echo "${_MENU_OPTIONS[$_MENU_SELECTED]}"
        return 0
        ;;
      QUIT)
        ui_menu_restore_tty
        echo "Cancelled." >&2
        exit 0
        ;;
    esac
    printf '\033[%dA' "$n" >&2
    _menu_draw_one
  done
}

# Redraws the multi-choice list in place, reading _MENU_OPTIONS /
# _MENU_SELECTED / _MENU_CHECKED globals (see _menu_draw_one for why globals).
_menu_draw_many() {
  local i mark
  for ((i = 0; i < ${#_MENU_OPTIONS[@]}; i++)); do
    mark="[ ]"
    [[ "${_MENU_CHECKED[$i]}" == "1" ]] && mark="[x]"
    printf '\033[2K\r' >&2
    if [[ $i -eq $_MENU_SELECTED ]]; then
      printf '%s> %s %s%s\n' "$UI_CYAN" "$mark" "${_MENU_OPTIONS[$i]}" "$UI_RESET" >&2
    else
      printf '  %s %s\n' "$mark" "${_MENU_OPTIONS[$i]}" >&2
    fi
  done
}

# Arrow-key multi-choice picker. Same signature/output as
# menu_choose_many_numbered (newline-separated picks, or the single line
# "all" if nothing was checked when confirmed). Only called when stdin is a
# real terminal.
menu_choose_many_arrow() {
  local prompt="$1"; shift
  _MENU_OPTIONS=("$@")
  _MENU_SELECTED=0
  local n=${#_MENU_OPTIONS[@]} key i any

  _MENU_CHECKED=()
  for ((i = 0; i < n; i++)); do _MENU_CHECKED[$i]=0; done

  echo "$prompt" >&2
  echo "(↑/↓ move, space toggle, a select-all, enter confirm, q cancel)" >&2
  ui_menu_setup_tty
  _menu_draw_many

  while true; do
    ui_read_key; key="$UI_KEY"
    case "$key" in
      UP) _MENU_SELECTED=$(( (_MENU_SELECTED - 1 + n) % n )) ;;
      DOWN) _MENU_SELECTED=$(( (_MENU_SELECTED + 1) % n )) ;;
      SPACE)
        if [[ "${_MENU_CHECKED[$_MENU_SELECTED]}" == "1" ]]; then
          _MENU_CHECKED[$_MENU_SELECTED]=0
        else
          _MENU_CHECKED[$_MENU_SELECTED]=1
        fi
        ;;
      OTHER:a|OTHER:A)
        any=0
        for ((i = 0; i < n; i++)); do [[ "${_MENU_CHECKED[$i]}" == "0" ]] && any=1; done
        for ((i = 0; i < n; i++)); do _MENU_CHECKED[$i]=$any; done
        ;;
      ENTER)
        ui_menu_restore_tty
        any=0
        for ((i = 0; i < n; i++)); do [[ "${_MENU_CHECKED[$i]}" == "1" ]] && any=1; done
        if [[ $any -eq 0 ]]; then
          echo "all"
        else
          for ((i = 0; i < n; i++)); do
            [[ "${_MENU_CHECKED[$i]}" == "1" ]] && printf '%s\n' "${_MENU_OPTIONS[$i]}"
          done
        fi
        return 0
        ;;
      QUIT)
        ui_menu_restore_tty
        echo "Cancelled." >&2
        exit 0
        ;;
    esac
    printf '\033[%dA' "$n" >&2
    _menu_draw_many
  done
}

# Single-choice prompt: arrow keys on a real terminal, numbered input
# otherwise (piped/redirected stdin -- tests, automation). Same
# signature/output either way, so callers never need to care which one ran.
menu_choose_one() {
  if ui_stdin_is_tty; then
    menu_choose_one_arrow "$@"
  else
    menu_choose_one_numbered "$@"
  fi
}

# Multi-choice prompt: arrow keys on a real terminal, numbered input
# otherwise. Same signature/output either way.
menu_choose_many() {
  if ui_stdin_is_tty; then
    menu_choose_many_arrow "$@"
  else
    menu_choose_many_numbered "$@"
  fi
}

# $1 = prompt text. Returns 0 for yes, 1 for no. Defaults to no on empty input.
menu_confirm() {
  local prompt="$1" answer
  read -rp "$prompt [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

# Joins a newline-separated list (as produced by menu_choose_many) into a
# comma-separated string suitable for CLUSTER_FILTER/ENV_FILTER/PROJECT_FILTER.
menu_lines_to_csv() {
  local input="$1" IFS_OLD="$IFS"
  local line out=""
  while IFS= read -r line; do
    [[ -n "$line" ]] && out="${out:+$out,}$line"
  done <<< "$input"
  echo "$out"
}

interactive_run() {
  local -a all_actions=("quota" "search")
  local chosen_action entry env short server
  chosen_action=$(menu_choose_one "What do you want to do?" "${all_actions[@]}")

  config_list_envs
  if [[ ${#CONFIG_ENVS[@]} -eq 0 ]]; then
    echo "ERROR: config.sh has no clusters. Run 'oo.sh -a discover -f <file>' first." >&2
    exit 1
  fi
  local envs_raw envs_csv
  envs_raw=$(menu_choose_many "Which environment(s)?" "${CONFIG_ENVS[@]}")
  if [[ "$envs_raw" == "all" ]]; then
    envs_csv="all"
  else
    envs_csv=$(menu_lines_to_csv "$envs_raw")
  fi

  config_list_projects
  local projects_raw projects_csv
  if [[ ${#CONFIG_PROJECTS[@]} -eq 0 ]]; then
    projects_csv="all"
  else
    projects_raw=$(menu_choose_many "Which project(s)?" "${CONFIG_PROJECTS[@]}")
    if [[ "$projects_raw" == "all" ]]; then
      projects_csv="all"
    else
      projects_csv=$(menu_lines_to_csv "$projects_raw")
    fi
  fi

  config_match_clusters "$envs_csv" "$projects_csv"
  if [[ ${#MENU_CLUSTERS[@]} -eq 0 ]]; then
    echo "ERROR: no clusters in config.sh match that env/project combination." >&2
    exit 1
  fi

  echo "Matching clusters (default: all of these):" >&2
  for entry in "${MENU_CLUSTERS[@]}"; do
    IFS='|' read -r env short server <<< "$entry"
    printf '  %s (%s) - %s\n' "$short" "$env" "$server" >&2
  done

  local final_shorts_csv
  if menu_confirm "Narrow down which of these clusters to use?"; then
    local -a short_options=()
    for entry in "${MENU_CLUSTERS[@]}"; do
      IFS='|' read -r env short server <<< "$entry"
      short_options+=("$short ($env) - $server")
    done
    local picked_raw picked_csv
    picked_raw=$(menu_choose_many "Which cluster(s)?" "${short_options[@]}")
    if [[ "$picked_raw" == "all" ]]; then
      final_shorts_csv=""
      for entry in "${MENU_CLUSTERS[@]}"; do
        IFS='|' read -r env short server <<< "$entry"
        final_shorts_csv="${final_shorts_csv:+$final_shorts_csv,}$short"
      done
    else
      local line short_only
      final_shorts_csv=""
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        short_only="${line%% *}"
        final_shorts_csv="${final_shorts_csv:+$final_shorts_csv,}$short_only"
      done <<< "$picked_raw"
    fi
  else
    final_shorts_csv=""
    for entry in "${MENU_CLUSTERS[@]}"; do
      IFS='|' read -r env short server <<< "$entry"
      final_shorts_csv="${final_shorts_csv:+$final_shorts_csv,}$short"
    done
  fi

  local search_string=""
  if [[ "$chosen_action" == "search" ]]; then
    read -rp "Search string: " search_string
    if [[ -z "$search_string" ]]; then
      echo "ERROR: search string cannot be empty" >&2
      exit 1
    fi
  fi

  CLUSTER_FILTER="$final_shorts_csv"
  ENV_FILTER="all"
  PROJECT_FILTER=""
  [[ "$projects_csv" != "all" ]] && PROJECT_FILTER="$projects_csv"
  NAMESPACE_FILTER=""
  OUTPUT_FILE=""
  INSECURE=0
  PARALLEL_JOBS="${PARALLEL_JOBS:-8}"
  LOG_LEVEL="${LOG_LEVEL:-normal}"

  resolve_clusters

  # Show the actual oc commands that will run, not the oo.sh invocation --
  # a representative example (using the first matched cluster), since the
  # exact namespace list per cluster isn't known until after login.
  local example_entry="${RESOLVED_CLUSTERS[0]}" example_user
  split_cluster_entry "$example_entry"
  example_user="$USER_DEFAULT"
  [[ "$CL_ENV" == "prod" ]] && example_user="$USER_PROD"

  echo >&2
  echo "About to run, for each of the ${#RESOLVED_CLUSTERS[@]} cluster(s) below:" >&2
  printf '  oc login --server %s --username %s --password ***\n' "$CL_SERVER" "$example_user" >&2
  echo "  oc get projects -o jsonpath='{.items[*].metadata.name}'" >&2
  if [[ "$chosen_action" == "quota" ]]; then
    echo "  oc get quota -n <namespace> -o json    # once per matching namespace" >&2
  else
    echo "  oc get secrets -n <namespace> -o json  # once per matching namespace" >&2
    echo "  Searching for: \"$search_string\"" >&2
  fi
  echo "On these clusters:" >&2
  for entry in "${RESOLVED_CLUSTERS[@]}"; do
    split_cluster_entry "$entry"
    printf '  %s (%s) - %s\n' "$CL_SHORT" "$CL_ENV" "$CL_SERVER" >&2
  done
  echo >&2

  if ! menu_confirm "Proceed?"; then
    echo "Cancelled." >&2
    exit 0
  fi

  REMAINING_ARGS=()
  [[ -n "$search_string" ]] && REMAINING_ARGS=("$search_string")

  case "$chosen_action" in
    quota) run_action_quota ;;
    search) run_action_search ;;
  esac
}
