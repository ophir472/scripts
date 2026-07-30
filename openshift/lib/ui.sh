#!/usr/bin/env bash
# Terminal presentation: colors and the shared "activity log" used to show
# progress (logins, per-namespace fetches, errors) while quota/search run,
# including across parallel cluster workers. Source config.sh + common.sh
# first, then this file.
#
# Design: every worker (even ones running concurrently in the background)
# appends short lines to ONE shared file via a single redirect -- safe
# without locking, since a small single `>>` write is atomic on a normal
# filesystem. A single `tail -f` on that file (started once by the main
# process, only on a real terminal) is what shows it live; workers never
# touch the screen directly, so there's no risk of concurrent processes
# fighting over cursor position. Piped/non-interactive runs (tests, log
# redirection) just get the plain file -- no live-display machinery at all.

ui_stderr_is_tty() { [[ -t 2 ]]; }

if ui_stderr_is_tty; then
  UI_RESET=$'\033[0m'
  UI_RED=$'\033[31m'
  UI_GREEN=$'\033[32m'
  UI_YELLOW=$'\033[33m'
  UI_CYAN=$'\033[36m'
  UI_DIM=$'\033[2m'
else
  UI_RESET=""; UI_RED=""; UI_GREEN=""; UI_YELLOW=""; UI_CYAN=""; UI_DIM=""
fi

# Appends one line to $ACTIVITY_LOG (set by the caller before dispatching
# work): "[KIND] message", with only the "[KIND]" tag colored -- not the
# whole line, so a busy log stays readable rather than a wall of color.
# Suppressed entirely at LOG_LEVEL=quiet. KIND: LOGIN (green), ERROR (red),
# QUOTA/SEARCH (yellow), CMD (dim -- verbose only, see log_cmd).
log_activity() {
  [[ "${LOG_LEVEL:-normal}" == "quiet" ]] && return 0
  [[ -z "${ACTIVITY_LOG:-}" ]] && return 0
  local kind="$1" message="$2" color
  case "$kind" in
    LOGIN) color="$UI_GREEN" ;;
    ERROR) color="$UI_RED" ;;
    CMD) color="$UI_DIM" ;;
    *) color="$UI_YELLOW" ;;
  esac
  printf '%s[%s]%s %s\n' "$color" "$kind" "$UI_RESET" "$message" >> "$ACTIVITY_LOG"
}

# Logs the exact oc command about to run, but only at LOG_LEVEL=verbose.
log_cmd() {
  [[ "${LOG_LEVEL:-normal}" == "verbose" ]] || return 0
  log_activity "CMD" "+ $1"
}

# Starts `tail -n 15 -f` on $1 if stderr is a real terminal and LOG_LEVEL
# isn't quiet; echoes its PID (empty if not started). Caller must eventually
# call ui_stop_live_tail with whatever this echoed.
ui_start_live_tail() {
  local logfile="$1"
  if [[ "${LOG_LEVEL:-normal}" != "quiet" ]] && ui_stderr_is_tty; then
    tail -n 15 -f "$logfile" >&2 2>/dev/null &
    echo "$!"
  fi
}

# $1 = PID from ui_start_live_tail (may be empty -- no-op then).
ui_stop_live_tail() {
  local pid="$1"
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  fi
  return 0
}
