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
# isn't quiet, backgrounding it directly in the CALLER's shell and setting
# UI_TAIL_PID (empty if not started; global, not echoed -- calling this via
# `pid=$(ui_start_live_tail ...)` would background `tail` inside the command
# -substitution subshell instead of the caller's shell, making it that
# subshell's child. The subshell exits immediately after, orphaning `tail`
# before the caller ever gets a PID it can actually `wait` on -- this shipped
# once already and hung real interactive/tty runs, though it never showed up
# in piped test runs since ui_stderr_is_tty is false there and this whole
# path never even ran).
ui_start_live_tail() {
  UI_TAIL_PID=""
  local logfile="$1"
  if [[ "${LOG_LEVEL:-normal}" != "quiet" ]] && ui_stderr_is_tty; then
    tail -n 15 -f "$logfile" >&2 2>/dev/null &
    UI_TAIL_PID="$!"
  fi
}

# Stops whatever ui_start_live_tail started (reads UI_TAIL_PID; no-op if empty).
ui_stop_live_tail() {
  if [[ -n "${UI_TAIL_PID:-}" ]]; then
    kill "$UI_TAIL_PID" 2>/dev/null
    # `wait` naturally returns the killed process's exit status (typically
    # 143, SIGTERM) -- under set -e that's an unguarded bare statement that
    # silently aborts the whole script right here, before ever reaching
    # `return 0` below. The 2>/dev/null above only hides the message, not
    # the exit code; `|| true` is what actually neutralizes it.
    wait "$UI_TAIL_PID" 2>/dev/null || true
  fi
  return 0
}

# --- Arrow-key menu primitives (lib/menu.sh builds the actual pickers on
# top of these). Only used when stdin is a real terminal -- piped/redirected
# input (tests, automation) never reaches this code at all; see
# menu_choose_one/menu_choose_many in lib/menu.sh for the dispatch.

ui_stdin_is_tty() { [[ -t 0 ]]; }

# Puts the terminal into raw mode (read one keypress at a time, no local
# echo) and hides the cursor. Also traps INT so Ctrl-C during a menu still
# restores the terminal instead of leaving it broken for the rest of the
# user's shell session.
ui_menu_setup_tty() {
  UI_SAVED_STTY="$(stty -g 2>/dev/null)" || UI_SAVED_STTY=""
  stty -icanon -echo min 1 time 0 2>/dev/null
  printf '\033[?25l' >&2
  trap 'ui_menu_restore_tty; exit 130' INT
}

# Undoes ui_menu_setup_tty. Always call this before returning/exiting from
# any arrow-key picker -- never leave the terminal in raw mode.
ui_menu_restore_tty() {
  [[ -n "${UI_SAVED_STTY:-}" ]] && stty "$UI_SAVED_STTY" 2>/dev/null
  printf '\033[?25h' >&2
  trap - INT
}

# Reads one logical key from the terminal (already in raw mode) and sets
# UI_KEY to one of: UP DOWN SPACE ENTER QUIT OTHER:<char>. Sets UI_KEY
# directly (a global) rather than echoing for command substitution -- a
# `$(...)` capture would fork a subshell to run the blocking read in,
# separate from the process that holds the `trap ... INT` set by
# ui_menu_setup_tty, which is exactly the process a real terminal's Ctrl-C
# needs to interrupt.
#
# An arrow key arrives as an escape sequence (Esc [ A/B/C/D), not a single
# character, hence the follow-up read when the first byte is Esc. bash 3.2's
# `read -t` only accepts integer seconds (no 0.01-style fractional timeout),
# so a bare lone Esc press takes up to 1s to resolve as cancel -- acceptable
# since `q` is also available as an instant cancel key.
ui_read_key() {
  local key rest
  IFS= read -rsn1 key
  if [[ "$key" == $'\x1b' ]]; then
    IFS= read -rsn2 -t 1 rest
    case "$rest" in
      '[A') UI_KEY="UP" ;;
      '[B') UI_KEY="DOWN" ;;
      *) UI_KEY="QUIT" ;;
    esac
  elif [[ -z "$key" ]]; then
    UI_KEY="ENTER"
  elif [[ "$key" == " " ]]; then
    UI_KEY="SPACE"
  elif [[ "$key" == "q" || "$key" == "Q" ]]; then
    UI_KEY="QUIT"
  else
    UI_KEY="OTHER:$key"
  fi
}
