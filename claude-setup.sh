#!/bin/bash
#
# Claude setup for Mac
#
# Installs the Claude app, Claude Code (the `claude` command), Apple's
# developer tools (which include Git), and the GitHub CLI (`gh`), signs in to
# Claude Code and GitHub, and shows each step in a window. If a step fails, it
# opens Claude with a message that describes what happened, so the person can
# troubleshoot with Claude.
#
# Run it as yourself (not with sudo) from Terminal, either straight from the
# latest GitHub release:
#   /bin/bash -c "$(curl -fsSL https://github.com/Excaliburke/set-up-claude/releases/latest/download/claude-setup.sh)"
# or after downloading the file:
#   bash ~/Downloads/claude-setup.sh
#
# The Origami app runs this same script; see README.md.
#
# Running it again is safe. Steps that already worked are skipped.
#
# Every setting below can also be set as an environment variable.

# ---- Team settings ---------------------------------------------------------

# Shown to people, as in "Sign in with your ... account".
ORG_LABEL="${CLAUDE_SETUP_ORG_LABEL:-Northeastern University}"
# After sign-in, the organization name must contain this text. "" turns the check off.
ORG_NAME_MATCH="${CLAUDE_SETUP_ORG_NAME_MATCH:-Northeastern University}"
# Exact organization ID to require (shown by `claude auth status`). "" turns the check off.
ORG_ID="${CLAUDE_SETUP_ORG_ID:-}"
# Plan the account must be on, as `claude auth status` reports it. "" turns the check off.
REQUIRED_PLAN="${CLAUDE_SETUP_REQUIRED_PLAN:-enterprise}"
# How to run this tool again, shown when setup doesn't finish and in the help
# message. Leave empty: when the tool runs from a file, it fills this in itself
# (for example "bash ~/Downloads/claude-setup.sh"). Set it only if you share the
# one-line web-address command instead.
RERUN_COMMAND="${CLAUDE_SETUP_RERUN_COMMAND:-}"
# 1 = force single sign-on when signing in to Claude Code.
USE_SSO="${CLAUDE_SETUP_SSO:-0}"
# 1 = show the setup window. 0 = show progress in Terminal only.
USE_WINDOW="${CLAUDE_SETUP_WINDOW:-1}"
# 1 = turn off ANTHROPIC_API_KEY lines in shell startup files. Those keys take
# priority over the Enterprise sign-in and cause confusing errors.
TURN_OFF_API_KEYS="${CLAUDE_SETUP_TURN_OFF_API_KEYS:-1}"

# ---- Set by the Origami app ------------------------------------------------

# "app" means the Origami app draws the window. This tool then reports
# progress as lines starting with "@@" and reads the person's choice ("help" or
# "close") on standard input.
UI_MODE="${CLAUDE_SETUP_UI:-}"
# How to run setup again, as a phrase such as "open the Origami app again
# and click Start setup". Takes priority over RERUN_COMMAND.
RERUN_TEXT="${CLAUDE_SETUP_RERUN_TEXT:-}"

# ---- Fixed values ----------------------------------------------------------

# Set by release.sh from the VERSION file.
SETUP_VERSION="1.0.0"
# The newest release's copy of this script, and its description of itself.
SCRIPT_URL="https://github.com/Excaliburke/set-up-claude/releases/latest/download/claude-setup.sh"
LATEST_RELEASE_URL="${CLAUDE_SETUP_LATEST_RELEASE_URL:-https://github.com/Excaliburke/set-up-claude/releases/latest/download/latest.json}"

ANTHROPIC_TEAM_ID="Q6L2SF6YDW"
CLI_INSTALL_URL="https://claude.ai/install.sh"
APP_DMG_URL="https://claude.ai/api/desktop/darwin/universal/dmg/latest/redirect"

# swiftDialog draws the setup window. It's open source, signed, and notarized:
# https://github.com/swiftDialog/swiftDialog. Version 3 needs macOS 15 or newer.
DIALOG_TEAM_ID="PWA5E9TQ59"
DIALOG_PKG_URL_MACOS15="https://github.com/swiftDialog/swiftDialog/releases/download/v3.1.0/dialog-3.1.0-4994.pkg"
DIALOG_PKG_URL_MACOS13="https://github.com/swiftDialog/swiftDialog/releases/download/v2.5.6/dialog-2.5.6-4805.pkg"

# The GitHub CLI (gh). Some Mac apps, Hangar for one, sign in to GitHub through
# it. When it's missing, this tool installs GitHub's own build for the Mac's
# chip, which must match GitHub's checksum and be signed by GitHub, Inc. (team
# confirmed on gh 2.102.0's own binary). Never Homebrew, and never the .pkg,
# which needs an admin password.
GH_TEAM_ID="VEKTX9H2N7"
GH_RELEASE_API_URL="https://api.github.com/repos/cli/cli/releases/latest"
GH_DOWNLOAD_URL="https://github.com/cli/cli/releases/download"
GH_DEVICE_URL="https://github.com/login/device"

# Use macOS's own tools first. Copies from Homebrew or Anaconda can behave
# differently: GNU sed breaks in-place edits, and some curl builds don't trust
# the certificates macOS trusts.
ORIGINAL_PATH=$PATH
PATH="${CLAUDE_SETUP_STUB_PATH:+$CLAUDE_SETUP_STUB_PATH:}/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

WORK_DIR="${CLAUDE_SETUP_WORK_DIR:-$HOME/Library/Application Support/ClaudeSetup}"
APPS_DIR="${CLAUDE_SETUP_APPS_DIR:-/Applications}"
CLAUDE_BIN="$HOME/.local/bin/claude"
GH_LOCAL_BIN="$HOME/.local/bin/gh"
# Where Homebrew may be (Apple silicon, then Intel), separated by spaces.
HOMEBREW_DIRS="${CLAUDE_SETUP_HOMEBREW_DIRS:-/opt/homebrew /usr/local}"
POLL_SECS="${CLAUDE_SETUP_POLL_SECS:-3}"
DEVTOOLS_TIMEOUT_SECS="${CLAUDE_SETUP_DEVTOOLS_TIMEOUT:-2700}"
DEVTOOLS_APPEAR_SECS="${CLAUDE_SETUP_DEVTOOLS_APPEAR:-90}"
SIGNIN_TIMEOUT_SECS="${CLAUDE_SETUP_SIGNIN_TIMEOUT:-900}"
# GitHub isn't needed for Claude, so people without an account wait less.
GITHUB_TIMEOUT_SECS="${CLAUDE_SETUP_GITHUB_TIMEOUT:-600}"
HELP_MAX_CHARS=12000

# ---- Steps -----------------------------------------------------------------

# Titles can't contain commas: swiftDialog splits list items on them.
STEP_TITLES=(
  "Check your Mac"
  "Install Git (Apple's developer tools)"
  "Install the Claude app"
  "Install Claude Code for Terminal"
  "Sign in to Claude Code"
  "Set up Git"
  "Set up GitHub"
  "Sign in to the Claude app"
  "Final check"
)
S_MAC=0; S_TOOLS=1; S_APP=2; S_CLI=3; S_SIGNIN=4; S_GIT=5; S_GITHUB=6; S_APPSIGNIN=7; S_FINAL=8
STEP_COUNT=${#STEP_TITLES[@]}

# States: wait, progress, pending (needs the person), success, warn, fail, skip.
STEP_STATE=(wait wait wait wait wait wait wait wait wait)
STEP_NOTE=("" "" "" "" "" "" "" "" "")
STEP_TRIED=("" "" "" "" "" "" "" "" "")

# ---- Run state -------------------------------------------------------------

# Where this file is, when it's run as a file ("bash ~/Downloads/claude-setup.sh").
# Empty when it came straight from a web address.
SCRIPT_PATH=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
fi

RUN_ID=$(date +%Y%m%d-%H%M%S)
RUN_DIR="$WORK_DIR/logs/$RUN_ID"
LOG_FILE=""
STEP_LOG=""
FATAL=0
OS_VERSION=""; OS_BUILD=""; OS_MAJOR=0
ARCH=""; ROSETTA=0; CHIP_LABEL=""
LOGIN_SHELL=""; LOGIN_PATH=""; IS_ADMIN=0; FREE_GB=""; FULL_NAME=""
NET_PROBLEM=""
OTHER_INSTALLS=""
CHANGES=""
CLEANUP_NOTES=""
BACKED_UP=" "
ENV_KEY_WAS_SET=0
RC_FILE=""
FRESH_SHELL_RESULT=""
CLI_VERSION=""
APP_PATH=""
GIT_BIN=""
GIT_VERSION=""
GH_BIN=""
GH_VERSION=""
GH_FRESH=""
GH_ACCOUNT=""
GH_SIGNED_IN=0
GH_PROBLEM=""
GH_LOGIN_PID=""
BREW_NOTE=""
TOOLS_NEW=0
TOOLS_SEEN=0
TOOLS_STARTED_AT=0
HELP_WHERE=""
NEWER_VERSION=""
AUTH_LOGGED_IN=false; AUTH_ORG_NAME=""; AUTH_ORG_ID=""; AUTH_PLAN=""; AUTH_EMAIL=""; AUTH_METHOD=""
SIGNIN_FAIL=""
LOGIN_PID=""
MOUNT_POINT=""
CAFFEINATE_PID=""
DIALOG_BIN="${CLAUDE_SETUP_DIALOG_BIN:-}"
DIALOG_PID=""
DIALOG_V3=0
SIGNIN_HINT=""
CMD_FILE=""
HELP_FILE=""

if [ -t 1 ]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_OFF=$'\033[0m'
else
  C_BOLD=""; C_DIM=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_BLUE=""; C_OFF=""
fi

# ---- Small helpers ---------------------------------------------------------

log() {
  [ -n "$LOG_FILE" ] && printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG_FILE"
  return 0
}

say() {
  printf '%s\n' "$*"
  log "$*"
}

tilde() {
  local t='~'
  printf '%s' "${1/#"$HOME"/$t}"
}

# swiftDialog splits list-item commands on commas and colons, so status text
# can't contain them.
no_commas() {
  local s=${1//, / · }
  s=${s//,/ }
  s=${s//: / — }
  s=${s//:/ }
  s=${s//$'\n'/ }
  printf '%s' "$s"
}

last_line() {
  # Last non-empty line of a file, without terminal color codes.
  [ -f "$1" ] || return 0
  sed -e $'s/\033\\[[0-9;]*[A-Za-z]//g' "$1" | awk 'NF { line = $0 } END { print line }' | cut -c1-300
}

json_get() {
  plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

can_use_tty() {
  { : < /dev/tty; } 2>/dev/null
}

# Runs a command, stopping it after a number of seconds. Returns 143 on timeout.
run_with_timeout() {
  local secs=$1
  shift
  "$@" &
  local pid=$!
  (
    sleep "$secs" &
    local sleeper=$!
    trap 'kill "$sleeper" 2>/dev/null; exit 0' TERM
    wait "$sleeper"
    kill -TERM "$pid" 2>/dev/null
  ) &
  local watcher=$!
  wait "$pid"
  local rc=$?
  kill -TERM "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  return $rc
}

begin_step() {
  STEP_LOG="$RUN_DIR/step-$1.log"
  printf '== %s ==\n' "${STEP_TITLES[$1]}" >> "$STEP_LOG"
}

any_failed() {
  local i
  for ((i = 0; i < STEP_COUNT; i++)); do
    [ "${STEP_STATE[$i]}" = fail ] && return 0
  done
  return 1
}

add_change() {
  CHANGES="${CHANGES:+$CHANGES; }$1"
  log "Changed: $1"
}

backup_once() {
  local f=$1 backup="$1.before-claude-setup-$RUN_ID"
  case "$BACKED_UP" in *" $f "*) return 0 ;; esac
  # Never overwrite a backup: it has to hold the file as it was before this run.
  if [ ! -e "$backup" ]; then
    cp -p "$f" "$backup" || return 1
    log "Backed up $f"
  fi
  BACKED_UP="$BACKED_UP$f "
}

# ---- Window (swiftDialog) and Terminal output ------------------------------

ui_alive() {
  [ -n "$DIALOG_PID" ] && kill -0 "$DIALOG_PID" 2>/dev/null
}

ui_cmd() {
  ui_alive || return 0
  printf '%s\n' "$1" >> "$CMD_FILE"
}

# swiftDialog's icons: "wait" is a spinner, "pending" is gray dots, "error" is
# a yellow "!". Version 3 also takes SF Symbol names.
ui_status_for() {
  case $1 in
    success) echo success ;;
    warn) echo error ;;
    fail) echo fail ;;
    progress) echo wait ;;
    pending) if [ "$DIALOG_V3" = 1 ]; then echo hand.raised.fill; else echo error; fi ;;
    skip) if [ "$DIALOG_V3" = 1 ]; then echo minus.circle; else echo pending; fi ;;
    *) echo pending ;;
  esac
}

ui_message() {
  local text=${1//$'\n'/\\n}
  ui_cmd "message: $text"
  app_event message "$1"
}

# Sends one event to the Origami app: "@@" and tab-separated fields, with
# newlines written as \n.
app_event() {
  [ "$UI_MODE" = app ] || return 0
  local out="" field tab=$'\t'
  for field in "$@"; do
    field=${field//$'\t'/ }
    field=${field//$'\n'/\\n}
    out="${out:+$out$tab}$field"
  done
  printf '@@%s\n' "$out"
}

ui_progress() {
  local done=0 i
  for ((i = 0; i < STEP_COUNT; i++)); do
    case ${STEP_STATE[$i]} in success|warn|fail|skip) done=$((done + 1)) ;; esac
  done
  ui_cmd "progress: $done"
}

print_step_line() {
  local i=$1 sym color label
  case ${STEP_STATE[$i]} in
    success|warn) sym="✓"; color=$C_GREEN ;;
    fail) sym="✗"; color=$C_RED ;;
    pending) sym="→"; color=$C_YELLOW ;;
    progress) sym="…"; color=$C_BLUE ;;
    skip) sym="–"; color=$C_DIM ;;
    *) sym=" "; color="" ;;
  esac
  label=${STEP_TITLES[$i]}
  printf '%s%s %s%s' "$color" "$sym" "$label" "$C_OFF"
  [ -n "${STEP_NOTE[$i]}" ] && printf ' %s— %s%s' "$C_DIM" "${STEP_NOTE[$i]}" "$C_OFF"
  printf '\n'
}

# set_step INDEX STATE NOTE [quiet]
# "quiet" updates the window without printing a new line in Terminal.
set_step() {
  local i=$1 state=$2 note=$3 quiet=${4:-}
  local prev_state=${STEP_STATE[$i]} prev_note=${STEP_NOTE[$i]}
  STEP_STATE[$i]=$state
  STEP_NOTE[$i]=$note
  if [ "$state" != "$prev_state" ] || [ "$note" != "$prev_note" ]; then
    log "step $i [$state] ${STEP_TITLES[$i]}: $note"
    [ -z "$quiet" ] && print_step_line "$i"
    app_event step "$i" "$state" "$note"
    ui_cmd "listitem: index: $i, status: $(ui_status_for "$state"), statustext: $(no_commas "$note")"
    case $state in
      progress) ui_cmd "progresstext: ${STEP_TITLES[$i]}" ;;
      pending) [ "$prev_state" = pending ] || ui_cmd "progresstext: Waiting for you: ${STEP_TITLES[$i]}" ;;
    esac
    ui_progress
  fi
}

intro_message() {
  printf '%s' "**Setting up Claude on your Mac.** This takes about 10 to 20 minutes, and most of it runs by itself.

A few steps need you when they come up: clicking **Install** in Apple's window, **signing in** with your $ORG_LABEL account in your browser, and **signing in to GitHub**.

Keep this window open. You can keep working while it runs."
  if [ -n "$NEWER_VERSION" ]; then
    printf '%s' "

**A newer version of this setup is available ($NEWER_VERSION).** This copy still works. Next time, use the newest one."
  fi
}

get_dialog() {
  [ "$USE_WINDOW" = 1 ] || return 1
  if [ -n "$DIALOG_BIN" ]; then
    [ -x "$DIALOG_BIN" ] && return 0
    return 1
  fi
  if [ -x /usr/local/bin/dialog ]; then
    DIALOG_BIN=/usr/local/bin/dialog
    return 0
  fi

  local app="$WORK_DIR/Dialog.app"
  if [ -d "$app" ] && dialog_app_ok "$app"; then
    DIALOG_BIN=$(dialog_exe_for "$app")
    [ -x "$DIALOG_BIN" ] && return 0
  fi

  say "Getting the setup window ready…"
  local url=$DIALOG_PKG_URL_MACOS13
  [ "$OS_MAJOR" -ge 15 ] && url=$DIALOG_PKG_URL_MACOS15
  local pkg="$RUN_DIR/dialog.pkg" expanded="$RUN_DIR/dialog-pkg" found sig
  curl -fsSL --max-time 300 -o "$pkg" "$url" >> "$LOG_FILE" 2>&1 || return 1
  sig=$(pkgutil --check-signature "$pkg" 2>&1)
  log "$sig"
  case $sig in *"($DIALOG_TEAM_ID)"*) ;; *) log "swiftDialog package isn't signed by $DIALOG_TEAM_ID"; return 1 ;; esac
  spctl --assess --type install "$pkg" >> "$LOG_FILE" 2>&1 || { log "Gatekeeper rejected the swiftDialog package"; return 1; }
  rm -rf "$expanded"
  pkgutil --expand-full "$pkg" "$expanded" >> "$LOG_FILE" 2>&1 || return 1
  found=$(find "$expanded" -maxdepth 8 -type d -name 'Dialog.app' 2>/dev/null | head -n 1)
  [ -n "$found" ] || return 1
  rm -rf "$app"
  mv "$found" "$app" || return 1
  rm -rf "$expanded" "$pkg"
  dialog_app_ok "$app" || return 1
  DIALOG_BIN=$(dialog_exe_for "$app")
  [ -x "$DIALOG_BIN" ]
}

# swiftDialog 3 is meant to be run through its bundled dialogcli; running the
# app's own binary directly mis-reads arguments. Version 2 has only the app binary.
dialog_exe_for() {
  local app=$1 exe
  if [ -x "$app/Contents/MacOS/dialogcli" ]; then
    printf '%s' "$app/Contents/MacOS/dialogcli"
    return 0
  fi
  exe=$(defaults read "$app/Contents/Info" CFBundleExecutable 2>/dev/null)
  printf '%s' "$app/Contents/MacOS/${exe:-Dialog}"
}

dialog_app_ok() {
  codesign --verify --deep --strict "$1" >> "$LOG_FILE" 2>&1 || return 1
  [ "$(codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p')" = "$DIALOG_TEAM_ID" ]
}

ui_start() {
  CMD_FILE="$RUN_DIR/window-commands.log"
  : > "$CMD_FILE"
  local args=(
    --title "Set up Claude"
    --message "$(intro_message)"
    --messagefont "size=14"
    --icon none
    --progress "$STEP_COUNT"
    --progresstext "Starting"
    --button1text "Working…"
    --commandfile "$CMD_FILE"
    --width 860
    --height 600
  )
  local t
  for t in "${STEP_TITLES[@]}"; do
    args+=(--listitem "$t")
  done
  # Options without a value go last: swiftDialog misreads them anywhere else.
  args+=(--button1disabled --moveable)
  "$DIALOG_BIN" "${args[@]}" >> "$LOG_FILE" 2>&1 &
  DIALOG_PID=$!
  sleep 1
  if ! ui_alive; then
    DIALOG_PID=""
    return 1
  fi
  local i
  for ((i = 0; i < STEP_COUNT; i++)); do
    ui_cmd "listitem: index: $i, status: pending, statustext: "
  done
  ui_cmd "activate:"
  return 0
}

ui_stop() {
  ui_alive || { DIALOG_PID=""; return 0; }
  ui_cmd "quit:"
  local i
  for ((i = 0; i < 20; i++)); do
    ui_alive || break
    sleep 0.25
  done
  ui_alive && kill "$DIALOG_PID" 2>/dev/null
  DIALOG_PID=""
}

# ui_final TITLE MESSAGE ICON BUTTON1 [BUTTON2]: shows the last screen and
# returns the button that was clicked (0 = first button).
ui_final() {
  local args=(
    --title "$1"
    --message "$2"
    --messagefont "size=14"
    --icon "$3"
    --iconsize 72
    --button1text "$4"
    --width 700
    --height 440
  )
  [ -n "${5:-}" ] && args+=(--button2text "$5")
  args+=(--moveable)
  "$DIALOG_BIN" "${args[@]}" >> "$LOG_FILE" 2>&1
}

# ---- Checks used by several steps ------------------------------------------

real_git_path() {
  local dev
  dev=$(xcode-select -p 2>/dev/null) || return 1
  [ -x "$dev/usr/bin/git" ] || return 1
  if ! "$dev/usr/bin/git" --version >> "${STEP_LOG:-/dev/null}" 2>&1; then
    return 1
  fi
  printf '%s\n' "$dev/usr/bin/git"
}

devtools_installer_running() {
  pgrep -f "Install Command Line Developer Tools" >/dev/null 2>&1
}

find_claude_app() {
  local d
  for d in "$APPS_DIR" "$HOME/Applications"; do
    if [ -d "$d/Claude.app" ]; then
      printf '%s\n' "$d/Claude.app"
      return 0
    fi
  done
  return 1
}

claude_app_running() {
  [ -n "$APP_PATH" ] && pgrep -f "$APP_PATH/Contents/MacOS/" >/dev/null 2>&1
}

anthropic_signed() {
  codesign --verify --deep --strict "$1" >> "$STEP_LOG" 2>&1 || return 1
  [ "$(codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p')" = "$ANTHROPIC_TEAM_ID" ]
}

cli_works() {
  [ -x "$CLAUDE_BIN" ] && "$CLAUDE_BIN" --version >/dev/null 2>&1
}

# What a brand-new Terminal window finds for a command, such as `claude`.
fresh_shell_command() {
  local out
  out=$(run_with_timeout 20 "$LOGIN_SHELL" -lic "command -v $1" < /dev/null 2>> "${STEP_LOG:-/dev/null}")
  printf '%s\n' "$out" | awk 'NF { line = $0 } END { print line }'
}

fresh_shell_claude() {
  fresh_shell_command claude
}

read_auth() {
  local f="$RUN_DIR/auth.json"
  AUTH_LOGGED_IN=false; AUTH_ORG_NAME=""; AUTH_ORG_ID=""; AUTH_PLAN=""; AUTH_EMAIL=""; AUTH_METHOD=""
  cli_works || return 1
  run_with_timeout 30 "$CLAUDE_BIN" auth status --json > "$f" 2>> "$STEP_LOG"
  AUTH_LOGGED_IN=$(json_get "$f" loggedIn)
  [ -n "$AUTH_LOGGED_IN" ] || AUTH_LOGGED_IN=false
  AUTH_ORG_NAME=$(json_get "$f" orgName)
  AUTH_ORG_ID=$(json_get "$f" orgId)
  AUTH_PLAN=$(json_get "$f" subscriptionType)
  AUTH_EMAIL=$(json_get "$f" email)
  AUTH_METHOD=$(json_get "$f" authMethod)
  return 0
}

account_ok() {
  [ "$AUTH_LOGGED_IN" = true ] || return 1
  [ -z "$ORG_ID" ] || [ "$AUTH_ORG_ID" = "$ORG_ID" ] || return 1
  if [ -n "$ORG_NAME_MATCH" ]; then
    case "$AUTH_ORG_NAME" in *"$ORG_NAME_MATCH"*) ;; *) return 1 ;; esac
  fi
  [ -z "$REQUIRED_PLAN" ] || [ "$AUTH_PLAN" = "$REQUIRED_PLAN" ] || return 1
  return 0
}

account_problem() {
  if [ "$AUTH_LOGGED_IN" != true ]; then
    echo "not signed in"
  elif [ -n "$AUTH_METHOD" ] && [ "$AUTH_METHOD" != "claude.ai" ]; then
    echo "signed in with a ${AUTH_METHOD} account instead of a Claude account"
  elif [ -n "$ORG_NAME_MATCH" ] && case "$AUTH_ORG_NAME" in *"$ORG_NAME_MATCH"*) false ;; *) true ;; esac; then
    echo "signed in to \"${AUTH_ORG_NAME:-a personal account}\" instead of $ORG_LABEL"
  elif [ -n "$ORG_ID" ] && [ "$AUTH_ORG_ID" != "$ORG_ID" ]; then
    echo "signed in to a different $ORG_LABEL organization (\"$AUTH_ORG_NAME\")"
  elif [ -n "$REQUIRED_PLAN" ] && [ "$AUTH_PLAN" != "$REQUIRED_PLAN" ]; then
    echo "the account is on the ${AUTH_PLAN:-unknown} plan instead of $REQUIRED_PLAN"
  else
    echo "the account didn't match"
  fi
}

check_network() {
  NET_PROBLEM=""
  local out rc code ctype
  # claude.ai redirects install.sh to downloads.claude.ai, so follow redirects (-L).
  out=$(curl -sSL -o /dev/null -w '%{http_code} %{content_type}' --max-time 20 "$CLI_INSTALL_URL" 2>> "$STEP_LOG")
  rc=$?
  log "Network check: curl exit $rc, response '$out'"
  code=${out%% *}
  ctype=${out#* }
  if [ $rc -eq 0 ]; then
    case "$ctype" in *html*|*HTML*) ;; *) [ "$code" = 200 ] && return 0 ;; esac
    NET_PROBLEM="claude.ai sent back a web page instead of the installer (HTTP $code). A network filter or VPN may be blocking it."
    return 1
  fi
  case $rc in
    6) NET_PROBLEM="Your Mac couldn't look up claude.ai. Check that you're connected to the internet." ;;
    7|28) NET_PROBLEM="Your Mac couldn't reach claude.ai in time. Check your internet connection or VPN." ;;
    35|51|58|60|77|90|91) NET_PROBLEM="The secure connection to claude.ai failed. Networks that inspect traffic can cause this." ;;
    *) NET_PROBLEM="Your Mac couldn't reach claude.ai (curl error $rc)." ;;
  esac
  return 1
}

# ---- Shell startup files ---------------------------------------------------

zdotdir() {
  local zd
  zd=$(run_with_timeout 10 /bin/zsh -c 'printf %s "${ZDOTDIR:-$HOME}"' < /dev/null 2>/dev/null)
  [ -n "$zd" ] && [ -d "$zd" ] || zd=$HOME
  printf '%s' "$zd"
}

startup_files() {
  local zd seen=" " f
  zd=$(zdotdir)
  for f in "$zd/.zshrc" "$zd/.zprofile" "$zd/.zshenv" "$zd/.zlogin" \
           "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zshenv" "$HOME/.zlogin" \
           "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile" "$HOME/.bashrc" \
           "$HOME/.config/fish/config.fish"; do
    [ -f "$f" ] || continue
    case "$seen" in *" $f "*) continue ;; esac
    seen="$seen$f "
    printf '%s\n' "$f"
  done
}

# Comments out lines matching an extended regex, after a backup.
comment_out() {
  local f=$1 re=$2 real
  grep -Eq "$re" "$f" 2>/dev/null || return 1
  real=$(readlink -f "$f" 2>/dev/null)
  [ -n "$real" ] || real=$f
  backup_once "$real"
  sed -i '' -E "\\%${re}%s%^%# Turned off by Claude setup: %" "$real"
}

# Sets CLEANUP_NOTES. Call it directly, not inside $(...): it records backups
# and changes in globals, which a subshell would throw away.
clean_startup_files() {
  local key_re='^[[:space:]]*(export[[:space:]]+)?ANTHROPIC_API_KEY=|^[[:space:]]*set[[:space:]]+(-[[:alpha:]]+[[:space:]]+)*ANTHROPIC_API_KEY([[:space:]]|$)'
  local legacy_alias_re='^[[:space:]]*alias[[:space:]]+claude=.*\.claude/local'
  local f notes=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ "$TURN_OFF_API_KEYS" = 1 ] && comment_out "$f" "$key_re"; then
      add_change "turned off an ANTHROPIC_API_KEY line in $(tilde "$f") (backup saved next to it)"
      notes="${notes:+$notes · }turned off an old API key in $(tilde "$f")"
    fi
    if comment_out "$f" "$legacy_alias_re"; then
      add_change "turned off an old 'alias claude=' line in $(tilde "$f") (backup saved next to it)"
      notes="${notes:+$notes · }turned off an old claude alias"
    elif grep -Eq '^[[:space:]]*alias[[:space:]]+claude=' "$f" 2>/dev/null; then
      log "An alias for claude in $f may run something other than Claude Code"
      notes="${notes:+$notes · }note: $(tilde "$f") has an alias for claude"
    fi
  done <<EOF
$(startup_files)
EOF
  CLEANUP_NOTES=$notes
}

rc_file_for_shell() {
  local f
  case "$(basename "$LOGIN_SHELL")" in
    zsh) printf '%s\n' "$(zdotdir)/.zshrc" ;;
    bash)
      # Terminal starts bash as a login shell, which reads the first of these that exists.
      for f in .bash_profile .bash_login .profile; do
        if [ -f "$HOME/$f" ]; then
          printf '%s\n' "$HOME/$f"
          return 0
        fi
      done
      printf '%s\n' "$HOME/.bash_profile"
      ;;
    fish) printf '%s\n' "$HOME/.config/fish/conf.d/claude-setup.fish" ;;
    *) printf '\n' ;;
  esac
}

ensure_path() {
  RC_FILE=$(rc_file_for_shell)
  if [ -z "$RC_FILE" ]; then
    log "Unknown login shell $LOGIN_SHELL; not editing startup files"
    return 1
  fi
  case "$RC_FILE" in
    *.fish)
      grep -q '.local/bin' "$RC_FILE" 2>/dev/null && return 0
      mkdir -p "$(dirname "$RC_FILE")"
      printf '%s\n' '# Added by Claude setup' 'contains $HOME/.local/bin $PATH; or set -gx PATH $HOME/.local/bin $PATH' >> "$RC_FILE"
      ;;
    *)
      if grep -Eq '^[^#]*\.local/bin' "$RC_FILE" 2>/dev/null; then
        return 0
      fi
      [ -f "$RC_FILE" ] && backup_once "$(readlink -f "$RC_FILE" 2>/dev/null || printf '%s' "$RC_FILE")"
      printf '\n%s\n%s\n%s\n' '# >>> Claude setup >>>' 'export PATH="$HOME/.local/bin:$PATH"' '# <<< Claude setup <<<' >> "$RC_FILE"
      ;;
  esac
  add_change "added ~/.local/bin to PATH in $(tilde "$RC_FILE")"
  return 0
}

find_other_installs() {
  OTHER_INSTALLS=""
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ "$p" = "$CLAUDE_BIN" ] && continue
    case " $OTHER_INSTALLS " in *" $p "*) continue ;; esac
    OTHER_INSTALLS="${OTHER_INSTALLS:+$OTHER_INSTALLS }$p"
  done <<EOF
$(PATH="${LOGIN_PATH:+$LOGIN_PATH:}$ORIGINAL_PATH" which -a claude 2>/dev/null)
EOF
  if [ -x "$HOME/.claude/local/claude" ]; then
    case " $OTHER_INSTALLS " in *" $HOME/.claude/local/claude "*) ;; *) OTHER_INSTALLS="${OTHER_INSTALLS:+$OTHER_INSTALLS }$HOME/.claude/local/claude" ;; esac
  fi
  log "Other copies of claude: ${OTHER_INSTALLS:-none}"
}

# ---- Steps -----------------------------------------------------------------

step_check_mac() {
  local i=$S_MAC note cleanup
  begin_step $i
  STEP_TRIED[$i]="Checked the macOS version, chip, shell, disk space, network access to claude.ai, other copies of Claude Code, and shell startup files"
  set_step $i progress "Checking"

  if [ "$OS_MAJOR" -lt 13 ]; then
    set_step $i fail "macOS $OS_VERSION is too old. Claude needs macOS 13 or newer."
    FATAL=1
    return
  fi

  ARCH=$(uname -m)
  if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = 1 ]; then
    ROSETTA=1
    ARCH=arm64
  fi
  case $ARCH in
    arm64) CHIP_LABEL="Apple silicon" ;;
    *) CHIP_LABEL="Intel" ;;
  esac
  [ "$ROSETTA" = 1 ] && CHIP_LABEL="Apple silicon (Terminal is using Rosetta)"

  LOGIN_SHELL=$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}')
  [ -n "$LOGIN_SHELL" ] || LOGIN_SHELL=${SHELL:-/bin/zsh}
  id -Gn 2>/dev/null | tr ' ' '\n' | grep -qx admin && IS_ADMIN=1
  FREE_GB=$(df -Pk / 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1048576 }')
  log "macOS $OS_VERSION ($OS_BUILD), $ARCH, rosetta=$ROSETTA, shell=$LOGIN_SHELL, admin=$IS_ADMIN, free=${FREE_GB}GB"

  set_step $i progress "Checking your connection to claude.ai" quiet
  if ! check_network; then
    set_step $i fail "$NET_PROBLEM"
    FATAL=1
    return
  fi

  # The PATH a Terminal window would have. Apps started from Finder get a much
  # shorter one, so ask the login shell.
  local path_cmd='printf "%s\n" "$PATH"'
  [ "$(basename "$LOGIN_SHELL")" = fish ] && path_cmd='string join : $PATH'
  LOGIN_PATH=$(run_with_timeout 20 "$LOGIN_SHELL" -lic "$path_cmd" < /dev/null 2>/dev/null | awk 'NF { line = $0 } END { print line }')
  find_other_installs
  clean_startup_files
  cleanup=$CLEANUP_NOTES
  if [ "$ENV_KEY_WAS_SET" = 1 ]; then
    cleanup="${cleanup:+$cleanup · }ignored an API key set in this Terminal window"
  fi

  note="macOS $OS_VERSION · $CHIP_LABEL · $(basename "$LOGIN_SHELL") shell"
  [ -n "$OTHER_INSTALLS" ] && note="$note · found an older copy of Claude Code (left in place)"
  [ -n "$cleanup" ] && note="$note · $cleanup"
  if [ -n "$FREE_GB" ] && [ "$FREE_GB" -lt 8 ] 2>/dev/null; then
    set_step $i warn "$note · only $FREE_GB GB free (Apple's tools need a few GB)"
  else
    set_step $i success "$note"
  fi
}

step_tools_start() {
  local i=$S_TOOLS out rc
  begin_step $i
  STEP_TRIED[$i]="Checked for Apple's Command Line Tools (xcode-select -p and its git), then ran xcode-select --install, which opens Apple's installer window"
  set_step $i progress "Checking"
  if GIT_BIN=$(real_git_path); then
    GIT_VERSION=$("$GIT_BIN" --version 2>/dev/null | sed 's/^git version /Git /')
    set_step $i success "Already installed · $GIT_VERSION"
    return
  fi
  out=$(xcode-select --install 2>&1)
  rc=$?
  printf '%s\n' "$out" >> "$STEP_LOG"
  if [ $rc -ne 0 ]; then
    case $out in
      *"already installed"*)
        set_step $i fail "Apple's developer tools look installed but Git doesn't work. This often happens after a macOS update." ;;
      *)
        set_step $i fail "Apple's installer didn't start: $(printf '%s' "$out" | tail -n 1)" ;;
    esac
    return
  fi
  TOOLS_NEW=1
  TOOLS_STARTED_AT=$(date +%s)
  sleep 2
  devtools_installer_running && TOOLS_SEEN=1
  set_step $i pending "Needs you: click Install in Apple's window"
}

step_app() {
  local i=$S_APP app dmg total size pct last_pct="" pid src dest_dir
  begin_step $i
  STEP_TRIED[$i]="Downloaded the Claude app from $APP_DMG_URL, checked that it's signed by Anthropic (team $ANTHROPIC_TEAM_ID), and copied it to Applications"
  set_step $i progress "Checking"
  if app=$(find_claude_app); then
    if anthropic_signed "$app"; then
      APP_PATH=$app
      set_step $i success "Already installed in $(tilde "$(dirname "$app")")"
    else
      set_step $i fail "The Claude app in $(tilde "$(dirname "$app")") isn't signed by Anthropic. Move it to the Trash and run setup again."
    fi
    return
  fi

  dmg="$RUN_DIR/Claude.dmg"
  set_step $i progress "Downloading"
  total=$(curl -sIL --max-time 30 "$APP_DMG_URL" 2>> "$STEP_LOG" | awk 'tolower($1) == "content-length:" { v = $2 } END { gsub(/\r/, "", v); print v }')
  curl -fL --max-time 1800 -o "$dmg" "$APP_DMG_URL" >> "$STEP_LOG" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ -n "$total" ] && [ "$total" -gt 0 ] 2>/dev/null && [ -f "$dmg" ]; then
      size=$(stat -f%z "$dmg" 2>/dev/null || echo 0)
      pct=$((size * 100 / total))
      if [ "$pct" != "$last_pct" ]; then
        set_step $i progress "Downloading ($pct%)" quiet
        last_pct=$pct
      fi
    fi
    sleep 1
  done
  if ! wait "$pid"; then
    set_step $i fail "Couldn't download the Claude app from claude.ai."
    return
  fi

  set_step $i progress "Checking Anthropic's signature"
  MOUNT_POINT=$(mktemp -d "$RUN_DIR/mount.XXXXXX")
  if ! hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MOUNT_POINT" "$dmg" < /dev/null >> "$STEP_LOG" 2>&1; then
    set_step $i fail "Couldn't open the downloaded Claude app installer."
    MOUNT_POINT=""
    return
  fi
  src="$MOUNT_POINT/Claude.app"
  [ -d "$src" ] || src=$(find "$MOUNT_POINT" -maxdepth 2 -type d -name 'Claude.app' 2>/dev/null | head -n 1)
  if [ -z "$src" ] || ! anthropic_signed "$src"; then
    detach_dmg
    set_step $i fail "The downloaded Claude app isn't signed by Anthropic, so it wasn't installed."
    return
  fi

  dest_dir=$APPS_DIR
  if [ ! -w "$dest_dir" ]; then
    dest_dir="$HOME/Applications"
    mkdir -p "$dest_dir"
  fi
  set_step $i progress "Copying to $(tilde "$dest_dir")"
  if ! ditto "$src" "$dest_dir/Claude.app" >> "$STEP_LOG" 2>&1; then
    detach_dmg
    set_step $i fail "Couldn't copy the Claude app to $(tilde "$dest_dir")."
    return
  fi
  detach_dmg
  rm -f "$dmg"
  APP_PATH="$dest_dir/Claude.app"
  set_step $i success "Added to $(tilde "$dest_dir")"
}

detach_dmg() {
  [ -n "$MOUNT_POINT" ] || return 0
  hdiutil detach "$MOUNT_POINT" -quiet >> "$STEP_LOG" 2>&1 || hdiutil detach "$MOUNT_POINT" -quiet -force >> "$STEP_LOG" 2>&1
  rmdir "$MOUNT_POINT" 2>/dev/null
  MOUNT_POINT=""
}

run_cli_installer() {
  if [ "$ROSETTA" = 1 ]; then
    run_with_timeout 600 arch -arm64 /bin/bash "$RUN_DIR/install.sh"
  else
    run_with_timeout 600 /bin/bash "$RUN_DIR/install.sh"
  fi
}

step_cli() {
  local i=$S_CLI expected
  begin_step $i
  STEP_TRIED[$i]="Ran Anthropic's installer (curl -fsSL $CLI_INSTALL_URL | bash), then made sure ~/.local/bin is on PATH in the shell startup file"
  if cli_works; then
    set_step $i progress "Already installed. Checking that Terminal can find it"
  else
    set_step $i progress "Downloading Anthropic's installer"
    if ! curl -fsSL --max-time 120 -o "$RUN_DIR/install.sh" "$CLI_INSTALL_URL" >> "$STEP_LOG" 2>&1; then
      set_step $i fail "Couldn't download Anthropic's installer from claude.ai."
      return
    fi
    if [ "$(head -c 2 "$RUN_DIR/install.sh")" != "#!" ]; then
      set_step $i fail "claude.ai sent a web page instead of the installer. A network filter or region block can cause this."
      return
    fi
    set_step $i progress "Installing (about a minute)"
    run_cli_installer < /dev/null >> "$STEP_LOG" 2>&1
    if ! cli_works && grep -q "Raw mode is not supported" "$STEP_LOG" && can_use_tty; then
      log "Installer needed a terminal; running it again attached to this Terminal window"
      run_cli_installer < /dev/tty >> "$STEP_LOG" 2>&1
    fi
    if ! cli_works; then
      set_step $i fail "Anthropic's installer didn't finish. Its last message: $(last_line "$STEP_LOG")"
      return
    fi
  fi
  CLI_VERSION=$("$CLAUDE_BIN" --version 2>/dev/null | head -n 1 | awk '{print $1}')

  if ! ensure_path; then
    set_step $i warn "Version $CLI_VERSION. Your shell ($(basename "$LOGIN_SHELL")) isn't one this tool knows: add ~/.local/bin to its PATH."
    return
  fi
  set_step $i progress "Checking that new Terminal windows can find it" quiet
  FRESH_SHELL_RESULT=$(fresh_shell_claude)
  log "New login shell finds: '$FRESH_SHELL_RESULT'"
  expected=$CLAUDE_BIN
  case "$FRESH_SHELL_RESULT" in
    "$expected"|"~/.local/bin/claude")
      set_step $i success "v$CLI_VERSION · works in new Terminal windows" ;;
    alias*)
      set_step $i warn "Version $CLI_VERSION. New Terminal windows use an alias for claude instead: $FRESH_SHELL_RESULT" ;;
    "")
      set_step $i fail "Version $CLI_VERSION installed but new Terminal windows can't find it. PATH was added to $(tilde "$RC_FILE")." ;;
    *)
      set_step $i warn "Version $CLI_VERSION. New Terminal windows run an older copy first: $(tilde "$FRESH_SHELL_RESULT")" ;;
  esac
}

signin_message() {
  local url=$1 text
  text="**Sign in to Claude Code in your browser.** Use your **$ORG_LABEL** account. When the browser says you're signed in, come back here. This window moves on by itself."
  [ -n "$SIGNIN_HINT" ] && text="$SIGNIN_HINT $text"
  if [ -n "$url" ]; then
    text="$text

If your browser didn't open, [open the sign-in page]($url)."
  fi
  printf '%s' "$text"
}

stop_login() {
  if [ -n "$LOGIN_PID" ]; then
    kill "$LOGIN_PID" 2>/dev/null
    wait "$LOGIN_PID" 2>/dev/null
    LOGIN_PID=""
  fi
}

# One sign-in attempt. Returns 0 once Claude Code reports a signed-in account.
signin_once() {
  local attempt=$1 out="$RUN_DIR/login-$1.out" args start url="" shown_url="" rc
  args=(auth login --claudeai)
  [ "$USE_SSO" = 1 ] && args+=(--sso)
  "$CLAUDE_BIN" "${args[@]}" < /dev/null > "$out" 2>&1 &
  LOGIN_PID=$!
  start=$(date +%s)
  ui_message "$(signin_message "")"
  while :; do
    sleep "$POLL_SECS"
    if [ -z "$url" ]; then
      url=$(sed -n 's/.*visit: \(https:[^[:space:]]*\).*/\1/p' "$out" 2>/dev/null | head -n 1)
    fi
    if [ -n "$url" ] && [ -z "$shown_url" ]; then
      ui_message "$(signin_message "$url")"
      shown_url=1
    fi
    if ! kill -0 "$LOGIN_PID" 2>/dev/null; then
      wait "$LOGIN_PID"
      rc=$?
      LOGIN_PID=""
      cat "$out" >> "$STEP_LOG"
      read_auth
      [ "$AUTH_LOGGED_IN" = true ] && return 0
      SIGNIN_FAIL="Sign-in stopped before it finished (exit $rc): $(last_line "$out")"
      return 1
    fi
    read_auth
    if [ "$AUTH_LOGGED_IN" = true ]; then
      stop_login
      cat "$out" >> "$STEP_LOG"
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge "$SIGNIN_TIMEOUT_SECS" ]; then
      stop_login
      cat "$out" >> "$STEP_LOG"
      SIGNIN_FAIL="Sign-in didn't finish within $((SIGNIN_TIMEOUT_SECS / 60)) minutes."
      return 1
    fi
  done
}

step_signin() {
  local i=$S_SIGNIN attempt=1 problem=""
  begin_step $i
  STEP_TRIED[$i]="Ran claude auth login --claudeai$([ "$USE_SSO" = 1 ] && printf ' --sso'), which opens the browser, then checked claude auth status for a signed-in $ORG_LABEL account"
  if ! cli_works; then
    set_step $i skip "Not started: Claude Code didn't install"
    return
  fi
  set_step $i progress "Checking"
  read_auth
  if account_ok; then
    set_step $i success "Signed in to $AUTH_ORG_NAME"
    return
  fi
  while [ $attempt -le 2 ]; do
    if [ "$AUTH_LOGGED_IN" = true ]; then
      log "Signing out first: $(account_problem)"
      run_with_timeout 30 "$CLAUDE_BIN" auth logout < /dev/null >> "$STEP_LOG" 2>&1
    fi
    if [ $attempt -eq 1 ]; then
      set_step $i pending "Needs you: sign in using your browser"
    else
      SIGNIN_HINT="That was a different account: $problem."
      set_step $i pending "Needs you: sign in again (different account)"
    fi
    if ! signin_once $attempt; then
      set_step $i fail "$SIGNIN_FAIL"
      ui_message "$(intro_message)"
      return
    fi
    if account_ok; then
      set_step $i success "Signed in to $AUTH_ORG_NAME"
      ui_message "$(intro_message)"
      return
    fi
    problem=$(account_problem)
    attempt=$((attempt + 1))
  done
  set_step $i fail "Claude Code is $problem."
  ui_message "$(intro_message)"
}

step_tools_wait() {
  local i=$S_TOOLS seen=$TOOLS_SEEN gone_at=0 now elapsed
  [ "${STEP_STATE[$i]}" = pending ] || return 0
  begin_step $i
  ui_message "**Apple's developer tools are still installing.** If you see Apple's window, click **Install** and then **Agree**. The download can take 5 to 15 minutes. This window moves on by itself when it's done."
  while :; do
    if GIT_BIN=$(real_git_path); then
      GIT_VERSION=$("$GIT_BIN" --version 2>/dev/null | sed 's/^git version /Git /')
      set_step $i success "Installed · $GIT_VERSION"
      break
    fi
    now=$(date +%s)
    elapsed=$((now - TOOLS_STARTED_AT))
    if devtools_installer_running; then
      seen=1
      gone_at=0
      set_step $i pending "Apple's installer is running ($((elapsed / 60)) min)" quiet
    elif [ "$seen" = 1 ]; then
      # Give the tools a moment to finish setting up after the window closes.
      [ "$gone_at" = 0 ] && gone_at=$now
      if [ $((now - gone_at)) -ge 30 ]; then
        set_step $i fail "Apple's installer closed before Git was installed. It may have been cancelled or shown an error."
        break
      fi
    elif [ "$elapsed" -ge "$DEVTOOLS_APPEAR_SECS" ]; then
      set_step $i fail "Apple's installer closed or never opened, so Git wasn't installed."
      break
    fi
    if [ "$elapsed" -ge "$DEVTOOLS_TIMEOUT_SECS" ]; then
      set_step $i fail "Apple's installer didn't finish within $((DEVTOOLS_TIMEOUT_SECS / 60)) minutes."
      break
    fi
    sleep "$POLL_SECS"
  done
  ui_message "$(intro_message)"
}

step_git() {
  local i=$S_GIT name email
  begin_step $i
  STEP_TRIED[$i]="Set git config --global user.name and user.email where they were empty, using the Mac account name and the Claude sign-in email"
  if ! GIT_BIN=$(real_git_path); then
    set_step $i skip "Not started: Apple's developer tools aren't installed"
    return
  fi
  set_step $i progress "Checking"
  name=$("$GIT_BIN" config --global user.name 2>/dev/null)
  email=$("$GIT_BIN" config --global user.email 2>/dev/null)
  if [ -z "$name" ]; then
    name=${FULL_NAME:-$USER}
    "$GIT_BIN" config --global user.name "$name" >> "$STEP_LOG" 2>&1 && add_change "set Git's user.name"
  fi
  if [ -z "$email" ] && [ -n "$AUTH_EMAIL" ]; then
    email=$AUTH_EMAIL
    "$GIT_BIN" config --global user.email "$email" >> "$STEP_LOG" 2>&1 && add_change "set Git's user.email"
  fi
  if [ -z "$email" ]; then
    set_step $i warn "Saving changes as $name. Add an email later with: git config --global user.email you@example.com"
  else
    set_step $i success "Saving changes as $name ($email)"
  fi
}

find_brew() {
  local d
  for d in $HOMEBREW_DIRS; do
    if [ -x "$d/bin/brew" ]; then
      printf '%s\n' "$d/bin/brew"
      return 0
    fi
  done
  return 1
}

# The full path of a command a new Terminal window finds, if it runs.
fresh_shell_working() {
  local p t='~'
  p=$(fresh_shell_command "$1")
  p=${p/#"$t"/$HOME}
  case $p in /*) ;; *) return 1 ;; esac
  [ -x "$p" ] && "$p" --version >/dev/null 2>&1 || return 1
  printf '%s\n' "$p"
}

# Homebrew's installer asks people to add its line to their shell startup file
# themselves, and many never do, so new Terminal windows can't find brew or
# anything it installed (gh included). When Homebrew is here but a new Terminal
# window doesn't find it, this adds Homebrew's own line. It's a repair, not an
# install: this tool never installs Homebrew, and a problem here is only a
# warning. Sets BREW_NOTE when it can't fix it.
fix_homebrew_path() {
  local brew f line marker="Claude setup (Homebrew)"
  BREW_NOTE=""
  brew=$(find_brew) || return 0
  [ -n "$(fresh_shell_command brew)" ] && return 0
  log "Homebrew is at $brew but new Terminal windows don't find it"
  case "$(basename "$LOGIN_SHELL")" in
    # Homebrew's own advice for zsh is ~/.zprofile.
    zsh) f="$(zdotdir)/.zprofile"; line="eval \"\$($brew shellenv)\"" ;;
    bash) f=$(rc_file_for_shell); line="eval \"\$($brew shellenv)\"" ;;
    fish) f="$HOME/.config/fish/conf.d/claude-setup-homebrew.fish"; line="$brew shellenv fish | source" ;;
    *)
      BREW_NOTE="Homebrew is installed but new Terminal windows don't find it. Your shell ($(basename "$LOGIN_SHELL")) isn't one this tool knows."
      return 1 ;;
  esac
  if grep -Eq '^[^#]*brew shellenv' "$f" 2>/dev/null; then
    BREW_NOTE="Homebrew is installed but new Terminal windows don't find it, though $(tilde "$f") sets it up."
    return 1
  fi
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] && backup_once "$(readlink -f "$f" 2>/dev/null || printf '%s' "$f")"
  printf '\n%s\n%s\n%s\n' "# >>> $marker >>>" "$line" "# <<< $marker <<<" >> "$f"
  add_change "added Homebrew's PATH line to $(tilde "$f")"
  if [ -z "$(fresh_shell_command brew)" ]; then
    BREW_NOTE="Added Homebrew to $(tilde "$f") but new Terminal windows still don't find it."
    return 1
  fi
  return 0
}

# Downloads GitHub's own build of gh for this Mac's chip, checks it against
# GitHub's checksum and signature, and copies it to ~/.local/bin. Sets
# GH_PROBLEM when it can't.
install_gh() {
  local i=$1 json="$RUN_DIR/gh-release.json" v arch name zip sums want got dir found team
  set_step $i progress "Downloading the GitHub CLI"
  if ! curl -fsSL --max-time 30 -o "$json" "$GH_RELEASE_API_URL" >> "$STEP_LOG" 2>&1; then
    GH_PROBLEM="Couldn't reach github.com to download the GitHub CLI."
    return 1
  fi
  v=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' "$json" | head -n 1)
  case $v in
    ''|*[!0-9.]*)
      log "Unexpected GitHub CLI release tag: '$v'"
      GH_PROBLEM="github.com didn't say which version of the GitHub CLI is the newest."
      return 1 ;;
  esac
  case $ARCH in arm64) arch=arm64 ;; *) arch=amd64 ;; esac
  name="gh_${v}_macOS_${arch}.zip"
  zip="$RUN_DIR/$name"
  sums="$RUN_DIR/gh_${v}_checksums.txt"
  if ! curl -fsSL --max-time 300 -o "$zip" "$GH_DOWNLOAD_URL/v$v/$name" >> "$STEP_LOG" 2>&1 ||
     ! curl -fsSL --max-time 30 -o "$sums" "$GH_DOWNLOAD_URL/v$v/gh_${v}_checksums.txt" >> "$STEP_LOG" 2>&1; then
    GH_PROBLEM="Couldn't download the GitHub CLI from github.com."
    return 1
  fi

  set_step $i progress "Checking GitHub's signature"
  want=$(awk -v f="$name" '$2 == f { print $1; exit }' "$sums")
  got=$(shasum -a 256 "$zip" 2>> "$STEP_LOG" | awk '{print $1}')
  log "GitHub CLI checksum: expected '$want', got '$got'"
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    rm -f "$zip"
    GH_PROBLEM="The GitHub CLI download didn't match GitHub's checksum, so it wasn't installed."
    return 1
  fi
  dir="$RUN_DIR/gh-download"
  rm -rf "$dir"
  if ! ditto -x -k "$zip" "$dir" >> "$STEP_LOG" 2>&1; then
    GH_PROBLEM="Couldn't open the GitHub CLI download."
    return 1
  fi
  found="$dir/gh_${v}_macOS_${arch}/bin/gh"
  [ -f "$found" ] || found=$(find "$dir" -maxdepth 3 -type f -path '*/bin/gh' 2>/dev/null | head -n 1)
  if [ -z "$found" ] || ! codesign --verify --strict "$found" >> "$STEP_LOG" 2>&1; then
    GH_PROBLEM="The GitHub CLI download isn't signed properly, so it wasn't installed."
    return 1
  fi
  team=$(codesign -dv "$found" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  log "GitHub CLI download is signed by team '${team:-none}' (expected $GH_TEAM_ID)"
  if [ "$team" != "$GH_TEAM_ID" ]; then
    GH_PROBLEM="The GitHub CLI download isn't signed by GitHub, so it wasn't installed."
    return 1
  fi

  set_step $i progress "Copying to ~/.local/bin"
  if ! mkdir -p "$(dirname "$GH_LOCAL_BIN")" || ! cp "$found" "$GH_LOCAL_BIN.new" ||
     ! chmod +x "$GH_LOCAL_BIN.new" || ! mv -f "$GH_LOCAL_BIN.new" "$GH_LOCAL_BIN"; then
    rm -f "$GH_LOCAL_BIN.new"
    GH_PROBLEM="Couldn't copy the GitHub CLI to ~/.local/bin."
    return 1
  fi
  rm -rf "$dir" "$zip" "$sums" "$json"
  add_change "installed the GitHub CLI $v in ~/.local/bin"
  return 0
}

github_message() {
  printf '%s' "**Sign in to GitHub in your browser.** A GitHub page just opened. Sign in there (with your organization's single sign-on if it asks), enter the code **$1**, and approve **GitHub CLI**. The code is already on your clipboard, so you can paste it with Command-V. This window moves on by itself.

If the page didn't open, [open GitHub's code page]($GH_DEVICE_URL).

**No GitHub account?** Claude doesn't need one. Leave the page, and setup moves on by itself within $((GITHUB_TIMEOUT_SECS / 60)) minutes."
}

stop_gh_login() {
  if [ -n "$GH_LOGIN_PID" ]; then
    kill "$GH_LOGIN_PID" 2>/dev/null
    wait "$GH_LOGIN_PID" 2>/dev/null
    GH_LOGIN_PID=""
  fi
}

# True when gh is signed in to github.com. Sets GH_ACCOUNT from what gh says.
gh_signed_in() {
  local out="$RUN_DIR/gh-status.txt"
  GH_ACCOUNT=""
  run_with_timeout 30 "$GH_BIN" auth status --hostname github.com < /dev/null > "$out" 2>&1 || return 1
  GH_ACCOUNT=$(sed -n -e 's/.*Logged in to github\.com account \([^[:space:]]*\).*/\1/p' \
    -e 's/.*Logged in to github\.com as \([^[:space:]]*\).*/\1/p' "$out" | head -n 1)
  return 0
}

# One GitHub sign-in with gh's device flow: with no terminal, gh prints a
# one-time code and waits for GitHub to say it was entered. BROWSER stops gh
# from opening a browser itself; this tool opens GitHub's page instead.
# Returns 0 once gh reports a signed-in account. Sets GH_PROBLEM when it doesn't.
gh_signin() {
  local i=$1 out="$RUN_DIR/gh-login.out" start code="" rc n
  BROWSER=/usr/bin/true GH_NO_UPDATE_NOTIFIER=1 "$GH_BIN" auth login --hostname github.com --web --git-protocol https --skip-ssh-key < /dev/null > "$out" 2>&1 &
  GH_LOGIN_PID=$!
  start=$(date +%s)
  while :; do
    sleep "$POLL_SECS"
    if [ -z "$code" ]; then
      code=$(sed -e $'s/\033\\[[0-9;]*[A-Za-z]//g' "$out" 2>/dev/null | sed -n 's/.*one-time code: \([A-Z0-9]\{4\}-[A-Z0-9]\{4\}\).*/\1/p' | head -n 1)
      if [ -n "$code" ]; then
        printf '%s' "$code" | pbcopy 2>/dev/null
        open "$GH_DEVICE_URL" >> "$STEP_LOG" 2>&1
        set_step $i pending "Needs you: enter the code $code on GitHub"
        ui_message "$(github_message "$code")"
      fi
    fi
    if ! kill -0 "$GH_LOGIN_PID" 2>/dev/null; then
      wait "$GH_LOGIN_PID"
      rc=$?
      GH_LOGIN_PID=""
      cat "$out" >> "$STEP_LOG"
      gh_signed_in && return 0
      GH_PROBLEM="GitHub sign-in stopped before it finished (exit $rc): $(last_line "$out")"
      return 1
    fi
    if gh_signed_in; then
      # gh saves its settings just after the sign-in, so let it finish first.
      for ((n = 0; n < 10; n++)); do
        kill -0 "$GH_LOGIN_PID" 2>/dev/null || break
        sleep 1
      done
      stop_gh_login
      cat "$out" >> "$STEP_LOG"
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge "$GITHUB_TIMEOUT_SECS" ]; then
      stop_gh_login
      cat "$out" >> "$STEP_LOG"
      GH_PROBLEM="GitHub sign-in didn't finish within $((GITHUB_TIMEOUT_SECS / 60)) minutes."
      return 1
    fi
  done
}

# Lets Git use gh's GitHub sign-in (gh auth setup-git), unless it already does.
# Returns 2 when Git doesn't work yet.
gh_setup_git() {
  local git cfg="$HOME/.gitconfig"
  git=$(real_git_path) || return 2
  if "$git" config --global --get-all credential.https://github.com.helper 2>/dev/null | grep -q 'auth git-credential'; then
    return 0
  fi
  [ -f "$cfg" ] && backup_once "$(readlink -f "$cfg" 2>/dev/null || printf '%s' "$cfg")"
  run_with_timeout 30 "$GH_BIN" auth setup-git --hostname github.com < /dev/null >> "$STEP_LOG" 2>&1 || return 1
  add_change "set Git to use the GitHub sign-in (gh auth setup-git)"
  return 0
}

# The GitHub CLI must work in new Terminal windows; signing in to GitHub is
# helpful but not needed for Claude, so sign-in problems are only warnings.
step_github() {
  local i=$S_GITHUB found note notes="" rc
  begin_step $i
  STEP_TRIED[$i]="Checked that new Terminal windows find a working GitHub CLI (gh), adding Homebrew's PATH line if Homebrew was installed but not found. If they didn't, downloaded GitHub's own gh for this Mac's chip from $GH_DOWNLOAD_URL, checked it against GitHub's checksum and signature (team $GH_TEAM_ID), and copied it to ~/.local/bin. Then signed in with gh auth login --web and ran gh auth setup-git"
  set_step $i progress "Checking"
  fix_homebrew_path
  GH_PROBLEM=""
  GH_FRESH=$(fresh_shell_working gh)
  if [ -z "$GH_FRESH" ]; then
    log "New Terminal windows don't find a working gh (they find: '$(fresh_shell_command gh)')"
    if ! install_gh $i; then
      set_step $i fail "$GH_PROBLEM"
      return
    fi
    ensure_path
    set_step $i progress "Checking that new Terminal windows can find it" quiet
    GH_FRESH=$(fresh_shell_working gh)
    if [ -z "$GH_FRESH" ]; then
      found=$(fresh_shell_command gh)
      if [ -n "$found" ]; then
        set_step $i fail "The GitHub CLI is in ~/.local/bin but new Terminal windows run a copy that doesn't work: $(tilde "$found")"
      else
        set_step $i fail "The GitHub CLI is in ~/.local/bin but new Terminal windows can't find it."
      fi
      return
    fi
  fi
  GH_BIN=$GH_FRESH
  GH_VERSION=$("$GH_BIN" --version 2>/dev/null | head -n 1 | awk '{print $3}')
  log "New Terminal windows find gh $GH_VERSION at $GH_BIN"
  [ -n "$BREW_NOTE" ] && notes=$BREW_NOTE

  set_step $i progress "Checking the GitHub sign-in"
  GH_SIGNED_IN=0
  if gh_signed_in; then
    GH_SIGNED_IN=1
  else
    if gh_signin $i; then
      GH_SIGNED_IN=1
    fi
    ui_message "$(intro_message)"
  fi
  cat "$RUN_DIR/gh-status.txt" >> "$STEP_LOG" 2>/dev/null
  if [ "$GH_SIGNED_IN" != 1 ]; then
    set_step $i warn "gh $GH_VERSION works but isn't signed in to GitHub. ${GH_PROBLEM:+$GH_PROBLEM }Sign in later with: gh auth login --web (Hangar can also sign you in)${notes:+ · $notes}"
    return
  fi
  [ -n "$GH_ACCOUNT" ] || GH_ACCOUNT=$(run_with_timeout 30 "$GH_BIN" api user --jq .login < /dev/null 2>> "$STEP_LOG")

  gh_setup_git
  rc=$?
  [ $rc = 1 ] && notes="${notes:+$notes · }Git couldn't be set to use it. Run: gh auth setup-git"
  note="gh $GH_VERSION · signed in as ${GH_ACCOUNT:-your GitHub account}"
  if [ -n "$notes" ]; then
    set_step $i warn "$note · $notes"
  else
    set_step $i success "$note"
  fi
}

step_app_signin() {
  local i=$S_APPSIGNIN
  begin_step $i
  STEP_TRIED[$i]="Opened the Claude app so the person can sign in to it"
  if [ -z "$APP_PATH" ]; then
    set_step $i skip "Not started: the Claude app didn't install"
    return
  fi
  if [ "$TOOLS_NEW" = 1 ] && claude_app_running; then
    set_step $i pending "Needs you: quit and reopen the Claude app"
    return
  fi
  open -a "$APP_PATH" >> "$STEP_LOG" 2>&1
  set_step $i pending "Needs you: check the app for a sign-in screen"
}

step_final() {
  local i=$S_FINAL problems="" fresh rc
  begin_step $i
  STEP_TRIED[$i]="Checked claude and gh in a new login shell, claude auth status, git --version, the Claude app, gh auth status, and ran claude doctor"
  if any_failed; then
    set_step $i skip "Skipped until the steps above are fixed"
    return
  fi
  set_step $i progress "Checking everything"
  fresh=$(fresh_shell_claude)
  FRESH_SHELL_RESULT=$fresh
  case "$fresh" in "$CLAUDE_BIN"|"~/.local/bin/claude") ;; *) problems="${problems:+$problems · }new Terminal windows don't find Claude Code" ;; esac
  read_auth
  account_ok || problems="${problems:+$problems · }Claude Code is $(account_problem)"
  real_git_path >/dev/null || problems="${problems:+$problems · }Git doesn't work"
  GH_FRESH=$(fresh_shell_working gh)
  [ -n "$GH_FRESH" ] || problems="${problems:+$problems · }new Terminal windows don't find the GitHub CLI"
  [ -n "$APP_PATH" ] && [ -d "$APP_PATH" ] || problems="${problems:+$problems · }the Claude app is missing"
  run_with_timeout 60 "$CLAUDE_BIN" doctor < /dev/null > "$RUN_DIR/doctor.txt" 2>&1
  rc=$?
  cat "$RUN_DIR/doctor.txt" >> "$STEP_LOG"
  [ $rc -eq 0 ] || problems="${problems:+$problems · }claude doctor reported a problem"
  if [ -z "$problems" ]; then
    GH_BIN=$GH_FRESH
    # Signing in to GitHub isn't needed for Claude, so it's only reported.
    if gh_signed_in; then
      GH_SIGNED_IN=1
      set_step $i success "Everything works"
    else
      GH_SIGNED_IN=0
      set_step $i warn "Everything works except the GitHub sign-in. Sign in later with: gh auth login --web"
    fi
  else
    set_step $i fail "$problems"
  fi
}

# ---- Help from Claude ------------------------------------------------------

redact() {
  local s t='~' home_marker="__HOME__"
  s=$(printf '%s' "$1" | sed -E \
    -e "s#$(printf '%s' "$HOME" | sed 's/[.[\*^$#]/\\&/g')#$home_marker#g" \
    -e 's#/Users/[^/[:space:]]+#/Users/<user>#g' \
    -e 's#[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}#<email>#g' \
    -e 's#sk-ant-[[:alnum:]_-]+#<api-key>#g' \
    -e 's#(gh[opusr]_|github_pat_)[[:alnum:]_]+#<github-token>#g' \
    -e 's#((code|state|code_challenge|token|access_token|refresh_token)=)[^&[:space:]]+#\1<hidden>#g' \
    -e 's#[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}#<id>#g')
  # Patterns live in variables: bash 3.2 misreads slashes inside a quoted pattern.
  s=${s//"$home_marker"/$t}
  local name_marker="<name>" user_marker="<user>"
  if [ ${#FULL_NAME} -ge 3 ]; then s=${s//"$FULL_NAME"/$name_marker}; fi
  if [ ${#USER} -ge 4 ]; then s=${s//"$USER"/$user_marker}; fi
  local github_marker="<github-account>"
  if [ ${#GH_ACCOUNT} -ge 3 ]; then s=${s//"$GH_ACCOUNT"/$github_marker}; fi
  printf '%s' "$s"
}

step_symbol() {
  case $1 in
    success|warn) printf '✓' ;;
    fail) printf '✗' ;;
    pending) printf '→' ;;
    skip) printf '–' ;;
    *) printf '·' ;;
  esac
}

build_help_message() {
  local log_lines=${1:-40} i first="" body steps tail_log="" doctor="" yes_no
  for ((i = 0; i < STEP_COUNT; i++)); do
    if [ "${STEP_STATE[$i]}" = fail ] && [ -z "$first" ]; then first=$i; fi
  done

  body="What didn't finish:"
  for ((i = 0; i < STEP_COUNT; i++)); do
    [ "${STEP_STATE[$i]}" = fail ] || continue
    body="$body
- ${STEP_TITLES[$i]}: ${STEP_NOTE[$i]}
  What the tool did: ${STEP_TRIED[$i]}"
  done

  steps="All steps:"
  for ((i = 0; i < STEP_COUNT; i++)); do
    steps="$steps
$(step_symbol "${STEP_STATE[$i]}") ${STEP_TITLES[$i]}${STEP_NOTE[$i]:+: ${STEP_NOTE[$i]}}"
  done

  [ "$IS_ADMIN" = 1 ] && yes_no=yes || yes_no=no
  body="$body

$steps

My Mac:
- macOS ${OS_VERSION:-unknown} (build ${OS_BUILD:-unknown}), ${CHIP_LABEL:-unknown chip}, login shell ${LOGIN_SHELL:-unknown}, admin rights: $yes_no, free disk space: ${FREE_GB:-?} GB
- Network to claude.ai: ${NET_PROBLEM:-OK}
- Claude Code: $(cli_works && printf '%s version %s' "$CLAUDE_BIN" "${CLI_VERSION:-unknown}" || printf 'not installed at %s' "$CLAUDE_BIN")
- What a new Terminal window finds for claude: ${FRESH_SHELL_RESULT:-nothing}
- Shell startup file for PATH: ${RC_FILE:-not chosen}
- Other copies of claude: ${OTHER_INSTALLS:-none}
- Apple's developer tools: $(xcode-select -p 2>/dev/null || printf 'not installed') · Git: ${GIT_VERSION:-not working}
- Claude app: ${APP_PATH:-not installed}
- Claude Code sign-in: $( [ "$AUTH_LOGGED_IN" = true ] && printf 'signed in, plan %s, %s' "${AUTH_PLAN:-unknown}" "$(account_ok && printf 'right organization' || account_problem)" || printf 'not signed in')
- GitHub CLI: $( [ -n "$GH_BIN" ] && printf 'gh %s at %s' "${GH_VERSION:-unknown}" "$GH_BIN" || printf 'not working') · What a new Terminal window finds for gh: ${GH_FRESH:-nothing} · GitHub sign-in: $( [ "$GH_SIGNED_IN" = 1 ] && printf 'signed in' || printf 'not signed in')
- Homebrew: $(find_brew || printf 'not installed')${BREW_NOTE:+ ($BREW_NOTE)}
- Changes this tool made: ${CHANGES:-none}"

  if [ -n "$first" ] && [ -f "$RUN_DIR/step-$first.log" ]; then
    tail_log=$(sed -e $'s/\033\\[[0-9;]*[A-Za-z]//g' "$RUN_DIR/step-$first.log" | tail -n "$log_lines")
    body="$body

Last lines of the log for \"${STEP_TITLES[$first]}\":
$tail_log"
  fi
  if [ -f "$RUN_DIR/doctor.txt" ]; then
    doctor=$(head -n 40 "$RUN_DIR/doctor.txt")
    body="$body

claude doctor output:
$doctor"
  fi

  body=$(redact "$body")

  printf '%s' "Claude setup report

I'm setting up Claude on my Mac with my team's setup tool, and something didn't finish. I'm not technical. Please help me fix it one step at a time: tell me exactly what to click, or give me one command at a time to paste into Terminal, and ask me to paste back what I see.

$body

Ground rules from my team:
- We use Claude Enterprise ($ORG_LABEL). Don't suggest API keys, personal accounts, or turning off managed settings.
- Don't suggest sudo with npm, or deleting anything without explaining what it does first.
- If this needs admin rights or an account change, say so plainly and tell me exactly what to ask for.
- $(rerun_instruction)"
}

# True when version $1 (like 1.2.3) is newer than version $2.
version_newer() {
  local a b i x y
  IFS=. read -r -a a <<< "$1"
  IFS=. read -r -a b <<< "$2"
  for ((i = 0; i < 3; i++)); do
    x=${a[$i]:-0}
    y=${b[$i]:-0}
    case $x in ''|*[!0-9]*) x=0 ;; esac
    case $y in ''|*[!0-9]*) y=0 ;; esac
    [ "$x" -gt "$y" ] && return 0
    [ "$x" -lt "$y" ] && return 1
  done
  return 1
}

# When GitHub has a newer release than this downloaded copy, says so in
# Terminal and in the window. This copy still runs.
mention_newer_version() {
  local file="$RUN_DIR/latest.json" latest
  curl -fsSL --max-time 8 -o "$file" "$LATEST_RELEASE_URL" >> "$LOG_FILE" 2>&1 || return 0
  latest=$(json_get "$file" version)
  if [ -n "$latest" ] && version_newer "$latest" "$SETUP_VERSION"; then
    NEWER_VERSION=$latest
    say "A newer version of this setup is available ($latest; this copy is $SETUP_VERSION). This copy still works."
    say "To use the newest one instead, press Control-C and run: $(rerun_command_latest)"
  fi
}

rerun_command_latest() {
  printf '/bin/bash -c "$(curl -fsSL %s)"' "$SCRIPT_URL"
}

# The command that runs this tool again: RERUN_COMMAND if it's set, otherwise
# "bash <this file>" when the tool runs from a file, otherwise the one-line
# command that downloads the newest release.
rerun_command() {
  if [ -n "$RERUN_COMMAND" ]; then
    printf '%s' "$RERUN_COMMAND"
    return 0
  fi
  if [ -z "$SCRIPT_PATH" ]; then
    rerun_command_latest
    return 0
  fi
  local p=$SCRIPT_PATH home_prefix="$HOME/" rel
  case $p in
    "$home_prefix"*)
      rel=${p#"$home_prefix"}
      case $rel in
        *[!A-Za-z0-9._/-]*) printf "bash ~/'%s'" "$rel" ;;
        *) printf 'bash ~/%s' "$rel" ;;
      esac ;;
    *[!A-Za-z0-9._/-]*) printf "bash '%s'" "$p" ;;
    *) printf 'bash %s' "$p" ;;
  esac
}

rerun_instruction() {
  local cmd
  if [ -n "$RERUN_TEXT" ]; then
    printf '%s' "Once it's fixed, tell me to $RERUN_TEXT (it skips the steps that already worked)."
    return 0
  fi
  cmd=$(rerun_command)
  if [ -n "$cmd" ]; then
    printf '%s' "Once it's fixed, tell me to run the setup tool again by pasting this into Terminal: $cmd (it skips the steps that already worked)."
  else
    printf '%s' "Once it's fixed, tell me to run the setup tool again the same way I ran it the first time. It skips the steps that already worked."
  fi
}

open_help() {
  local msg encoded lines
  for lines in 40 20 8 0; do
    msg=$(build_help_message "$lines")
    [ ${#msg} -le $HELP_MAX_CHARS ] && break
  done
  [ ${#msg} -le $HELP_MAX_CHARS ] || msg="${msg:0:$HELP_MAX_CHARS}"
  HELP_FILE="$RUN_DIR/help-message.txt"
  printf '%s\n' "$msg" > "$HELP_FILE"
  printf '%s' "$msg" | pbcopy 2>/dev/null

  if [ -n "$APP_PATH" ] && [ -d "$APP_PATH" ]; then
    encoded=$(osascript -l JavaScript -e 'function run(argv) { return encodeURIComponent(argv[0]) }' "$msg" 2>> "$LOG_FILE")
    if [ -n "$encoded" ] && open "claude://claude.ai/new?q=$encoded" >> "$LOG_FILE" 2>&1; then
      log "Opened the Claude app with the help message"
      HELP_WHERE=app
      return 0
    fi
  fi
  open "https://claude.ai/new" >> "$LOG_FILE" 2>&1
  log "Opened claude.ai in the browser; the help message is on the clipboard"
  HELP_WHERE=browser
}

# ---- Finish ----------------------------------------------------------------

finish() {
  local i failed="" todo="" github="" msg rc
  for ((i = 0; i < STEP_COUNT; i++)); do
    case ${STEP_STATE[$i]} in
      fail) failed="$failed
- **${STEP_TITLES[$i]}:** ${STEP_NOTE[$i]}" ;;
      pending) todo="$todo
- **${STEP_TITLES[$i]}:** ${STEP_NOTE[$i]#Needs you: }" ;;
    esac
  done
  [ "${STEP_STATE[$S_GITHUB]}" = warn ] && github=${STEP_NOTE[$S_GITHUB]}
  ui_stop
  printf '\n'

  if [ -z "$failed" ]; then
    msg="Claude Code is installed and signed in, and Git and the GitHub CLI work.${github:+

**GitHub:** $github}${todo:+

**Still to do:**$todo

Use your **$ORG_LABEL** account wherever you sign in.}

To use Claude Code in Terminal, open a **new** Terminal window and type **claude**."
    say "${C_BOLD}Claude is ready.${C_OFF}"
    [ -n "$github" ] && say "GitHub: $github"
    [ -n "$todo" ] && printf 'Still to do:%s\n' "${todo//\*\*/}"
    say "To use Claude Code in Terminal, open a new Terminal window and type: claude"
    say "Log: $(tilde "$LOG_FILE")"
    app_event final success "Claude is ready" "$msg"
    if [ -n "$DIALOG_BIN" ]; then
      ui_final "Claude is ready" "$msg" "SF=checkmark.circle.fill,colour=green" "Done"
    fi
    return 0
  fi

  local rerun again again_short=""
  rerun=$(rerun_command)
  if [ -n "$RERUN_TEXT" ]; then
    again="When it's fixed, $RERUN_TEXT. It skips the steps that already worked."
    again_short="When it's fixed, $RERUN_TEXT."
  elif [ -n "$rerun" ]; then
    again="When it's fixed, run setup again by pasting this into Terminal:

\`$rerun\`

It skips the steps that already worked."
    again_short="When it's fixed, run setup again: $rerun"
  else
    again="When it's fixed, run setup again. It skips the steps that already worked."
  fi

  say "${C_BOLD}Setup didn't finish.${C_OFF}"
  printf '%s\n' "${failed//\*\*/}"
  [ -n "$again_short" ] && say "$again_short"
  say "Log: $(tilde "$LOG_FILE")"
  msg="Some steps didn't finish:$failed

**Claude can help you fix this.** Click **Get help from Claude** and Claude opens with a message that explains what happened. Read it, then press send. Claude will walk you through the fix one step at a time.

$again"

  rc=1
  if [ "$UI_MODE" = app ]; then
    app_event final fail "Setup didn't finish" "$msg"
    local choice=""
    read -r choice || true
    [ "$choice" = help ] && rc=0
  elif [ -n "$DIALOG_BIN" ]; then
    ui_final "Setup didn't finish" "$msg" "SF=exclamationmark.triangle.fill,colour=orange" "Get help from Claude" "Close"
    rc=$?
  elif [ "${CLAUDE_SETUP_ASSUME_YES:-0}" = 1 ]; then
    rc=0
  elif can_use_tty; then
    printf '\nPress Return to open Claude with a message about what went wrong (or Control-C to skip). '
    read -r _ < /dev/tty && rc=0
  fi
  if [ "$rc" = 0 ]; then
    open_help
    app_event helpopened "$HELP_WHERE"
    if [ "$HELP_WHERE" = app ]; then
      say "Claude is open with a message about what happened. Read it, then press send."
      say "If the message box is empty, click in it and press Command-V. The message is on your clipboard."
    else
      say "claude.ai is open in your browser. Click in the message box, press Command-V to paste the message about what happened, then press send."
    fi
    say "A copy of the message: $(tilde "$HELP_FILE")"
  fi
  return 1
}

cleanup() {
  stop_login
  stop_gh_login
  detach_dmg
  ui_stop
  [ -n "$CAFFEINATE_PID" ] && kill "$CAFFEINATE_PID" 2>/dev/null
  return 0
}

# `--preview-help` shows exactly what "Get help from Claude" sends, using a
# pretend failure (Apple's installer cancelled, the most common one). It reads
# this Mac's real details but installs and changes nothing.
preview_help() {
  local i
  ARCH=$(uname -m)
  case $ARCH in arm64) CHIP_LABEL="Apple silicon" ;; *) CHIP_LABEL="Intel" ;; esac
  LOGIN_SHELL=$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}')
  id -Gn 2>/dev/null | tr ' ' '\n' | grep -qx admin && IS_ADMIN=1
  FREE_GB=$(df -Pk / 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1048576 }')
  APP_PATH=$(find_claude_app)
  STEP_LOG="$RUN_DIR/step-$S_SIGNIN.log"
  if cli_works; then
    CLI_VERSION=$("$CLAUDE_BIN" --version 2>/dev/null | head -n 1 | awk '{print $1}')
    read_auth
  fi
  RC_FILE=$(rc_file_for_shell)
  FRESH_SHELL_RESULT=$(fresh_shell_claude)
  GH_FRESH=$(fresh_shell_working gh)
  GH_BIN=$GH_FRESH
  local github_state=warn github_note="The GitHub CLI isn't installed yet"
  if [ -n "$GH_BIN" ]; then
    GH_VERSION=$("$GH_BIN" --version 2>/dev/null | head -n 1 | awk '{print $3}')
    if gh_signed_in; then
      GH_SIGNED_IN=1
      github_state=success
      github_note="gh $GH_VERSION · signed in as ${GH_ACCOUNT:-your GitHub account}"
    else
      github_note="gh $GH_VERSION works but isn't signed in to GitHub. Sign in later with: gh auth login --web (Hangar can also sign you in)"
    fi
  fi

  for ((i = 0; i < STEP_COUNT; i++)); do
    STEP_TRIED[$i]=""
  done
  STEP_STATE=(success fail success success success skip "$github_state" pending skip)
  STEP_NOTE=(
    "macOS $OS_VERSION · $CHIP_LABEL · $(basename "$LOGIN_SHELL") shell"
    "Apple's installer closed before Git was installed. It may have been cancelled or shown an error."
    "Already installed in $(tilde "$(dirname "${APP_PATH:-$APPS_DIR/Claude.app}")")"
    "v${CLI_VERSION:-unknown} · works in new Terminal windows"
    "Signed in to ${AUTH_ORG_NAME:-your organization}"
    "Not started: Apple's developer tools aren't installed"
    "$github_note"
    "Needs you: check the app for a sign-in screen"
    "Skipped until the steps above are fixed"
  )
  STEP_TRIED[$S_TOOLS]="Checked for Apple's Command Line Tools (xcode-select -p and its git), then ran xcode-select --install, which opens Apple's installer window"
  printf '%s\n' "== ${STEP_TITLES[$S_TOOLS]} ==" \
    "xcode-select: note: install requested for command line developer tools" \
    "(preview: Apple's installer window was closed before it finished)" > "$RUN_DIR/step-$S_TOOLS.log"

  open_help
  say "Preview of the help message (a pretend failure; nothing was installed or changed)."
  if [ "$HELP_WHERE" = app ]; then
    say "The Claude app should now show a new chat with the message filled in but not sent."
  else
    say "claude.ai is open in your browser. Paste with Command-V to see the message."
  fi
  say "The message is also on your clipboard, and saved at: $(tilde "$HELP_FILE")"
  say "Length: $(wc -c < "$HELP_FILE" | tr -d ' ') characters (Claude's link limit is about 14,000)."
}

# ---- Main ------------------------------------------------------------------

main() {
  if [ "$(uname -s)" != Darwin ]; then
    echo "This setup tool is for Macs."
    return 1
  fi
  if [ "$(id -u)" = 0 ]; then
    echo "Run this as yourself, without sudo."
    return 1
  fi

  mkdir -p "$RUN_DIR" || { echo "Couldn't create $RUN_DIR"; return 1; }
  LOG_FILE="$RUN_DIR/setup.log"
  trap cleanup EXIT
  trap 'printf "\n"; say "Setup stopped."; exit 130' INT TERM

  if [ -n "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}" ]; then
    ENV_KEY_WAS_SET=1
    unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
  fi
  OS_VERSION=$(sw_vers -productVersion 2>/dev/null)
  OS_BUILD=$(sw_vers -buildVersion 2>/dev/null)
  OS_MAJOR=${OS_VERSION%%.*}
  case $OS_MAJOR in ''|*[!0-9]*) OS_MAJOR=0 ;; esac
  FULL_NAME=$(id -F 2>/dev/null)

  if [ "${1:-}" = --preview-help ]; then
    preview_help
    return 0
  fi

  caffeinate -dims -w $$ >/dev/null 2>&1 &
  CAFFEINATE_PID=$!

  [ "$UI_MODE" = app ] && USE_WINDOW=0
  printf '%sClaude setup for Mac%s (version %s)\n' "$C_BOLD" "$C_OFF" "$SETUP_VERSION"
  log "Claude setup version $SETUP_VERSION"
  say "This installs the Claude app, Claude Code, Apple's developer tools (for Git), and the GitHub CLI, then signs you in."
  if [ "$UI_MODE" = app ]; then
    say "Keep this window open until setup finishes. Log: $(tilde "$LOG_FILE")"
    app_event steps "$(IFS='|'; printf '%s' "${STEP_TITLES[*]}")"
    app_event message "$(intro_message)"
  else
    say "Keep this Terminal window open until setup finishes. Log: $(tilde "$LOG_FILE")"
    # The app updates itself; a downloaded copy of the script can only say so.
    [ -n "$SCRIPT_PATH" ] && mention_newer_version
  fi
  printf '\n'

  if [ "$OS_MAJOR" -ge 13 ] && get_dialog; then
    case "$(readlink -f "$DIALOG_BIN" 2>/dev/null || printf '%s' "$DIALOG_BIN")" in
      *dialogcli) DIALOG_V3=1 ;;
    esac
  else
    DIALOG_BIN=""
  fi
  if [ -n "$DIALOG_BIN" ] && ui_start; then
    say "Progress is showing in the setup window."
  else
    DIALOG_BIN=""
    [ "$USE_WINDOW" = 1 ] && say "The setup window isn't available, so progress shows here instead."
  fi
  printf '\n'

  step_check_mac
  if [ "$FATAL" = 1 ]; then
    local i
    for ((i = 1; i < STEP_COUNT; i++)); do
      set_step $i skip "Not started"
    done
    finish
    return $?
  fi
  step_tools_start
  step_app
  step_cli
  step_signin
  step_tools_wait
  step_git
  step_github
  step_app_signin
  step_final
  finish
}

if [ "${CLAUDE_SETUP_SOURCE_ONLY:-0}" != 1 ]; then
  main "$@"
  exit $?
fi
