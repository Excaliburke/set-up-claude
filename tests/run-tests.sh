#!/bin/bash
#
# Runs claude-setup.sh against a pretend Mac: a throwaway home folder and
# stand-in versions of curl, xcode-select, claude, git, gh, Homebrew, hdiutil,
# codesign, open, and swiftDialog. Nothing on this computer is installed or
# changed.
#
#   bash tests/run-tests.sh

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../claude-setup.sh"
PASS=0
FAILS=0
KEEP=${KEEP_SANDBOX:-0}

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAILS=$((FAILS + 1)); printf '  FAIL  %s\n' "$1"; }
check() {
  local desc=$1
  shift
  if "$@"; then ok "$desc"; else bad "$desc"; fi
}
has() { grep -q -- "$2" "$1" 2>/dev/null; }
lacks() { ! grep -q -- "$2" "$1" 2>/dev/null; }
count_is() { [ "$(grep -c -- "$2" "$1" 2>/dev/null)" = "$3" ]; }

new_sandbox() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/claude-setup-test.XXXXXX")
  T=$(cd "$T" && pwd -P)
  mkdir -p "$T/home" "$T/apps" "$T/bin" "$T/state" "$T/payload" "$T/shells"
  write_stubs
  # By default the GitHub CLI is already installed and signed in.
  mkdir -p "$T/home/.local/bin"
  cp "$T/payload/gh" "$T/home/.local/bin/gh"
  echo testgh > "$T/state/gh_auth"
}

# put_homebrew TOOL...: a pretend Homebrew in $T/homebrew with those tools.
put_homebrew() {
  local tool
  mkdir -p "$T/homebrew/bin"
  for tool in "$@"; do cp "$T/payload/$tool" "$T/homebrew/bin/$tool"; done
}

end_sandbox() {
  if [ "$KEEP" = 1 ]; then
    echo "  (sandbox kept at $T)"
  else
    rm -rf "$T"
  fi
}

write_stubs() {
  cat > "$T/bin/sw_vers" <<'EOF'
#!/bin/sh
case "$1" in
  -productVersion) cat "$SANDBOX/state/osver" 2>/dev/null || echo 15.5 ;;
  -buildVersion) echo TEST1 ;;
esac
EOF

  cat > "$T/bin/dscl" <<'EOF'
#!/bin/sh
echo "UserShell: $(cat "$SANDBOX/state/shell" 2>/dev/null || echo "$SANDBOX/shells/zsh")"
EOF

  # zsh without the Mac's own startup files, whose path_helper would add this
  # computer's real /usr/local/bin and /opt/homebrew/bin to new shells.
  cat > "$T/shells/zsh" <<'EOF'
#!/bin/sh
exec /bin/zsh +o globalrcs "$@"
EOF

  cat > "$T/bin/uname" <<'EOF'
#!/bin/sh
if [ "$1" = -m ]; then cat "$SANDBOX/state/arch" 2>/dev/null || echo arm64; exit 0; fi
exec /usr/bin/uname "$@"
EOF

  cat > "$T/bin/id" <<'EOF'
#!/bin/sh
case "$1" in
  -F) echo "Test Person" ;;
  -Gn) echo "staff admin" ;;
  -u) echo 501 ;;
  *) /usr/bin/id "$@" ;;
esac
EOF

  cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
url="" out="" wfmt="" head=0 follow=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    -w) wfmt=$2; shift ;;
    --max-time) shift ;;
    http*) url=$1 ;;
    -*)
      case "$1" in *I*) head=1 ;; esac
      case "$1" in *L*) follow=1 ;; esac ;;
  esac
  shift
done
echo "curl $url out=$out head=$head" >> "$SANDBOX/state/curl.log"
net=$(cat "$SANDBOX/state/net" 2>/dev/null || echo ok)
if [ "$net" = dns ]; then echo "curl: (6) Could not resolve host: claude.ai" >&2; exit 6; fi
case "$url" in
  *install.sh)
    # Like the real claude.ai: install.sh redirects to downloads.claude.ai.
    if [ "$follow" = 0 ]; then
      [ -n "$wfmt" ] && printf '302 '
      exit 0
    fi
    if [ -n "$wfmt" ]; then printf '200 text/x-sh'; exit 0; fi
    cp "$SANDBOX/payload/install.sh" "$out" ;;
  *dmg*)
    if [ "$head" = 1 ]; then printf 'HTTP/2 200\r\ncontent-length: 7\r\n\r\n'; exit 0; fi
    printf 'fakedmg' > "$out" ;;
  *latest.json)
    # The newest GitHub release, when a test sets one.
    if [ -f "$SANDBOX/state/latest_version" ]; then
      printf '{"version": "%s", "url": "https://example.invalid/Origami.zip", "sha256": "0"}' "$(cat "$SANDBOX/state/latest_version")" > "$out"
      exit 0
    fi
    echo "curl: (22) The requested URL returned error: 404" >&2; exit 22 ;;
  https://api.github.com/repos/cli/cli/releases/latest)
    printf '{\n  "url": "https://api.github.com/repos/cli/cli/releases/1",\n  "tag_name": "v2.99.0",\n  "name": "GitHub CLI 2.99.0",\n  "draft": false\n}\n' > "$out" ;;
  https://github.com/cli/cli/releases/download/v2.99.0/gh_2.99.0_checksums.txt)
    for f in gh_2.99.0_macOS_amd64.zip gh_2.99.0_macOS_arm64.zip; do
      sum=$(cat "$SANDBOX/state/gh_checksum" 2>/dev/null || shasum -a 256 "$SANDBOX/payload/$f" | awk '{print $1}')
      printf '%s  %s\n' "$sum" "$f"
    done > "$out"
    printf '%s  %s\n' 0123abcd gh_2.99.0_linux_amd64.tar.gz >> "$out" ;;
  https://github.com/cli/cli/releases/download/v2.99.0/gh_2.99.0_macOS_*.zip)
    cp "$SANDBOX/payload/$(basename "$url")" "$out" ;;
  *) echo "curl: (22) The requested URL returned error: 404" >&2; exit 22 ;;
esac
EOF

  cat > "$T/payload/install.sh" <<'EOF'
#!/bin/bash
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/claude/versions"
cp "$SANDBOX/payload/claude" "$HOME/.local/share/claude/versions/2.1.999"
chmod +x "$HOME/.local/share/claude/versions/2.1.999"
ln -sf "$HOME/.local/share/claude/versions/2.1.999" "$HOME/.local/bin/claude"
echo "Claude Code successfully installed!"
EOF

  cat > "$T/payload/claude" <<'EOF'
#!/bin/bash
S="$SANDBOX/state"
[ -n "$ANTHROPIC_API_KEY" ] && echo "claude saw ANTHROPIC_API_KEY" >> "$S/env.log"
case "$1" in
  --version) echo "2.1.999 (Claude Code)" ;;
  auth)
    case "$2" in
      status)
        if [ -f "$S/auth.json" ]; then cat "$S/auth.json"; exit 0; fi
        echo '{"loggedIn": false, "authMethod": "none", "apiProvider": "firstParty"}'
        exit 1 ;;
      login)
        echo "args: $*" >> "$S/login.log"
        n=$(cat "$S/login_count" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$S/login_count"
        echo "Opening browser to sign in…"
        echo "If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&state=secretstate123"
        sleep 2
        org=$(sed -n "${n}p" "$S/login_orgs" 2>/dev/null)
        [ -n "$org" ] || org=$(tail -n 1 "$S/login_orgs" 2>/dev/null)
        [ -n "$org" ] || org="Premium Seat - Northeastern University"
        if [ "$org" = FAIL ]; then echo "OAuth error: Invalid code. Please make sure the full code was copied"; exit 1; fi
        printf '{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "email": "tester@example.edu", "orgId": "11111111-2222-3333-4444-555555555555", "orgName": "%s", "subscriptionType": "enterprise"}' "$org" > "$S/auth.json"
        echo "Login successful" ;;
      logout) rm -f "$S/auth.json"; echo "Successfully logged out" ;;
    esac ;;
  doctor) echo "Claude Code doctor"; echo "No installation issues found." ;;
esac
EOF

  cat > "$T/bin/xcode-select" <<'EOF'
#!/bin/bash
S="$SANDBOX/state"
case "$1" in
  -p)
    if [ -f "$S/clt_installed" ]; then echo "$SANDBOX/clt"; exit 0; fi
    echo "xcode-select: error: unable to get active developer directory" >&2
    exit 2 ;;
  --install)
    mode=$(cat "$S/clt_mode" 2>/dev/null || echo succeed)
    if [ "$mode" = broken ]; then
      echo 'xcode-select: error: command line tools are already installed, use "Software Update" in System Settings to install updates' >&2
      exit 1
    fi
    nohup "$SANDBOX/Install Command Line Developer Tools" "$mode" >/dev/null 2>&1 &
    echo "xcode-select: note: install requested for command line developer tools" ;;
esac
EOF

  cat > "$T/Install Command Line Developer Tools" <<'EOF'
#!/bin/bash
sleep 4
if [ "$1" = succeed ]; then
  mkdir -p "$SANDBOX/clt/usr/bin"
  cp "$SANDBOX/payload/git" "$SANDBOX/clt/usr/bin/git"
  touch "$SANDBOX/state/clt_installed"
  sleep 1
fi
exit 0
EOF

  cat > "$T/payload/git" <<'EOF'
#!/bin/bash
CFG="$HOME/.gitconfig-test"
case "$1" in
  --version) echo "git version 2.50.1 (Apple Git-155)" ;;
  config)
    shift
    args=()
    for a in "$@"; do case $a in --*) ;; *) args+=("$a") ;; esac; done
    key=${args[0]} val=${args[1]}
    if [ -n "$val" ]; then
      awk -v k="$key=" 'index($0, k) != 1' "$CFG" 2>/dev/null > "$CFG.tmp"
      echo "$key=$val" >> "$CFG.tmp"
      mv "$CFG.tmp" "$CFG"
    else
      v=$(awk -v k="$key=" 'index($0, k) == 1 { print substr($0, length(k) + 1) }' "$CFG" 2>/dev/null | head -n 1)
      [ -n "$v" ] && echo "$v"
    fi ;;
esac
EOF

  # The GitHub CLI. state/gh_auth holds the signed-in account; state/gh_login_mode
  # is succeed (the default), fail, or hang.
  cat > "$T/payload/gh" <<'EOF'
#!/bin/bash
S="$SANDBOX/state"
case "$1" in
  --version) printf 'gh version 2.99.0 (2026-09-01)\nhttps://github.com/cli/cli/releases/tag/v2.99.0\n' ;;
  auth)
    case "$2" in
      status)
        if [ -f "$S/gh_auth" ]; then
          printf 'github.com\n  ✓ Logged in to github.com account %s (keyring)\n  - Token: gho_************************************\n' "$(cat "$S/gh_auth")"
          exit 0
        fi
        echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" >&2
        exit 1 ;;
      login)
        echo "args: $* BROWSER=$BROWSER" >> "$S/gh-login.log"
        echo "! First copy your one-time code: AB12-CD34" >&2
        echo "Open this URL to continue in your web browser: https://github.com/login/device" >&2
        case $(cat "$S/gh_login_mode" 2>/dev/null) in
          hang) exec sleep 600 ;;
          fail) sleep 2; echo "error: access_denied" >&2; exit 1 ;;
        esac
        sleep 2
        echo testgh > "$S/gh_auth"
        echo "✓ Authentication complete." >&2
        echo "✓ Logged in as testgh" >&2 ;;
      setup-git)
        echo "setup-git $*" >> "$S/gh-setup-git.log"
        echo 'credential.https://github.com.helper=!gh auth git-credential' >> "$HOME/.gitconfig-test" ;;
    esac ;;
  api) cat "$S/gh_auth" ;;
esac
EOF

  cat > "$T/payload/brew" <<'EOF'
#!/bin/bash
case "$1" in
  shellenv) echo "export PATH=\"$(cd "$(dirname "$0")" && pwd):\$PATH\"" ;;
  --version) echo "Homebrew 4.6.0" ;;
  *) echo "brew $*" >> "$SANDBOX/state/brew.log" ;;
esac
EOF

  cat > "$T/bin/hdiutil" <<'EOF'
#!/bin/bash
case "$1" in
  attach)
    mp=""
    while [ $# -gt 0 ]; do [ "$1" = -mountpoint ] && { mp=$2; shift; }; shift; done
    mkdir -p "$mp/Claude.app/Contents/MacOS"
    printf '#!/bin/sh\nexit 0\n' > "$mp/Claude.app/Contents/MacOS/Claude"
    chmod +x "$mp/Claude.app/Contents/MacOS/Claude" ;;
  detach) rm -rf "$2" ;;
esac
EOF

  cat > "$T/bin/codesign" <<'EOF'
#!/bin/sh
# The GitHub CLI has its own team, in state/gh_teamid.
case "$*" in
  *--verify*/bin/gh) [ -f "$SANDBOX/state/gh_badsig" ] && exit 1; exit 0 ;;
  -dv*/bin/gh) echo "TeamIdentifier=$(cat "$SANDBOX/state/gh_teamid" 2>/dev/null || echo VEKTX9H2N7)" >&2; exit 0 ;;
esac
case "$1" in
  --verify) [ -f "$SANDBOX/state/badsig" ] && exit 1; exit 0 ;;
  -dv) echo "TeamIdentifier=$(cat "$SANDBOX/state/teamid" 2>/dev/null || echo Q6L2SF6YDW)" >&2 ;;
esac
EOF

  cat > "$T/bin/open" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$SANDBOX/state/open.log"
EOF

  # The Claude app counts as running when state/app_running exists; any other
  # process (Apple's installer) is looked for for real.
  cat > "$T/bin/pgrep" <<'EOF'
#!/bin/sh
case "$*" in
  *Claude.app*) [ -f "$SANDBOX/state/app_running" ] ;;
  *) exec /usr/bin/pgrep "$@" ;;
esac
EOF

  cat > "$T/bin/pbcopy" <<'EOF'
#!/bin/sh
cat > "$SANDBOX/state/clipboard"
EOF

  cat > "$T/bin/caffeinate" <<'EOF'
#!/bin/sh
exit 0
EOF

  # Stand-in for swiftDialog. With --commandfile it stays open until "quit:";
  # otherwise it's the final screen and "clicks" the button in state/button.
  cat > "$T/bin/fakedialog" <<'EOF'
#!/bin/bash
S="$SANDBOX/state"
cmdfile=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [ "${args[$i]}" = --commandfile ] && cmdfile=${args[$((i + 1))]}
done
if [ -n "$cmdfile" ]; then
  printf '%s\n' "$@" > "$S/dialog-progress-args"
  while ! grep -q '^quit:' "$cmdfile" 2>/dev/null; do sleep 0.2; done
  cp "$cmdfile" "$S/dialog-commands"
  exit 5
fi
printf '%s\n' "$@" > "$S/dialog-final-args"
exit "$(cat "$S/button" 2>/dev/null || echo 0)"
EOF

  chmod +x "$T/bin/"* "$T/payload/"* "$T/shells/"* "$T/Install Command Line Developer Tools"

  # GitHub's downloads: a real zip for each chip, with gh in bin/.
  local arch dir
  for arch in arm64 amd64; do
    dir="$T/payload/zips/gh_2.99.0_macOS_$arch"
    mkdir -p "$dir/bin"
    cp "$T/payload/gh" "$dir/bin/gh"
    ditto -c -k --keepParent "$dir" "$T/payload/gh_2.99.0_macOS_$arch.zip"
  done
}

# run_setup [extra VAR=value ...]: runs the tool in the sandbox. With
# RUN_AS_WEB=1 it runs the way the one-line web command does, not from a file.
run_setup() {
  local launch=(/bin/bash "$SCRIPT")
  [ "${RUN_AS_WEB:-0}" = 1 ] && launch=(/bin/bash -c "$(cat "$SCRIPT")")
  env -i \
    HOME="$T/home" USER="$USER" LANG=en_US.UTF-8 TMPDIR="${TMPDIR:-/tmp}" \
    PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    SANDBOX="$T" \
    CLAUDE_SETUP_STUB_PATH="$T/bin" \
    CLAUDE_SETUP_WINDOW=0 \
    CLAUDE_SETUP_APPS_DIR="$T/apps" \
    CLAUDE_SETUP_HOMEBREW_DIRS="$T/homebrew" \
    CLAUDE_SETUP_POLL_SECS=1 \
    CLAUDE_SETUP_DEVTOOLS_APPEAR=8 \
    CLAUDE_SETUP_ASSUME_YES=1 \
    "$@" \
    "${launch[@]}" $SCRIPT_ARGS > "$T/output.txt" 2>&1
  echo $? > "$T/exit-code"
}

exit_is() { [ "$(cat "$T/exit-code")" = "$1" ]; }
gitcfg() { sed -n "s/^$1=//p" "$T/home/.gitconfig-test" 2>/dev/null; }
help_text() { cat "$T/state/clipboard" 2>/dev/null; }

# test-app.sh loads the helpers above without running the scenarios below.
if [ "${RUN_TESTS_HELPERS_ONLY:-0}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------------------

echo "1. A fresh Mac where everything works"
new_sandbox
run_setup
check "finishes successfully" exit_is 0
check "says Your tools are ready" has "$T/output.txt" "Your tools are ready"
check "adds the PATH block to ~/.zshrc once" count_is "$T/home/.zshrc" '>>> Claude setup >>>' 1
check "installs Claude Code" test -x "$T/home/.local/bin/claude"
check "copies the Claude app to Applications" test -d "$T/apps/Claude.app"
check "new Terminal windows find claude" has "$T/output.txt" "works in new Terminal windows"
check "signs in with --claudeai" has "$T/state/login.log" "--claudeai"
check "waits for Apple's tools and reports Git" has "$T/output.txt" "Installed · Git 2.50.1"
check "sets Git's name from the Mac account" [ "$(gitcfg user.name)" = "Test Person" ]
check "sets Git's email from the sign-in" [ "$(gitcfg user.email)" = "tester@example.edu" ]
check "opens the Claude app for sign-in" has "$T/state/open.log" "-a $T/apps/Claude.app"
check "lists the app sign-in as still to do" has "$T/output.txt" "Still to do"
check "doesn't open the help message" lacks "$T/state/open.log" "claude://"
check "uses the GitHub CLI new Terminal windows find" has "$T/output.txt" "gh 2.99.0 · signed in as testgh"
check "doesn't download the GitHub CLI" lacks "$T/state/curl.log" "cli/cli"
check "doesn't start a GitHub sign-in" test ! -e "$T/state/gh-login.log"
check "sets Git to use the GitHub sign-in" has "$T/home/.gitconfig-test" "credential.https://github.com.helper="

echo "2. Running it again on the same Mac"
run_setup
check "finishes successfully" exit_is 0
check "doesn't add the PATH block twice" count_is "$T/home/.zshrc" '>>> Claude setup >>>' 1
check "doesn't download the installer again" count_is "$T/state/curl.log" "install.sh out=$T" 1
check "reports the app as already installed" has "$T/output.txt" "Already installed in"
check "doesn't sign in again" [ "$(cat "$T/state/login_count")" = 1 ]
end_sandbox

echo "3. Bash user with an existing ~/.profile"
new_sandbox
echo /bin/bash > "$T/state/shell"
printf 'export EDITOR=nano\n' > "$T/home/.profile"
run_setup
check "finishes successfully" exit_is 0
check "adds PATH to ~/.profile" has "$T/home/.profile" '.local/bin'
check "doesn't create ~/.bash_profile" test ! -e "$T/home/.bash_profile"
check "keeps the existing ~/.profile content" has "$T/home/.profile" 'EDITOR=nano'
check "new Terminal windows find claude" has "$T/output.txt" "works in new Terminal windows"
end_sandbox

echo "4. Old API key and old claude alias in ~/.zshrc"
new_sandbox
printf 'export ANTHROPIC_API_KEY=sk-ant-oldkey123\nalias claude="$HOME/.claude/local/claude"\nalias ll="ls -l"\n' > "$T/home/.zshrc"
run_setup ANTHROPIC_API_KEY=sk-ant-fromterminal
check "finishes successfully" exit_is 0
check "turns off the API key line" has "$T/home/.zshrc" '^# Turned off by Claude setup: export ANTHROPIC_API_KEY'
check "turns off the old alias" has "$T/home/.zshrc" '^# Turned off by Claude setup: alias claude='
check "leaves other aliases alone" has "$T/home/.zshrc" '^alias ll='
check "saves a backup first" sh -c "ls '$T/home'/.zshrc.before-claude-setup-* >/dev/null 2>&1"
check "the backup has the original lines" sh -c "grep -q '^export ANTHROPIC_API_KEY' '$T/home'/.zshrc.before-claude-setup-*"
check "says what it turned off" has "$T/output.txt" "turned off an old API key"
check "notes the API key set in Terminal" has "$T/output.txt" "ignored an API key set in this Terminal window"
check "keeps the API key away from Claude Code" test ! -e "$T/state/env.log"
end_sandbox

echo "5. Signs in with a personal account first, then the right one"
new_sandbox
printf 'Personal\nPremium Seat - Northeastern University\n' > "$T/state/login_orgs"
run_setup
check "finishes successfully" exit_is 0
check "asks for a second sign-in" [ "$(cat "$T/state/login_count")" = 2 ]
check "ends signed in to the right organization" has "$T/output.txt" "Signed in to Premium Seat - Northeastern University"
end_sandbox

echo "6. Keeps signing in with the wrong account"
new_sandbox
printf 'Personal\n' > "$T/state/login_orgs"
run_setup
check "exits with an error" exit_is 1
check "explains the wrong account" has "$T/output.txt" 'signed in to "Personal" instead of Northeastern University'
check "opens Claude with the help message" has "$T/state/open.log" "claude://claude.ai/new?q="
check "puts the message on the clipboard" has "$T/state/clipboard" "Claude setup report"
check "message names the failed step" has "$T/state/clipboard" "Sign in to Claude Code:"
check "message includes the team's ground rules" has "$T/state/clipboard" "Ground rules from my team:"
check "message names no contact person" lacks "$T/state/clipboard" "contact"
check "message gives the exact command to run setup again" has "$T/state/clipboard" "pasting this into Terminal: bash '\{0,1\}[~/].*claude-setup.sh"
check "message hides the home folder path" lacks "$T/state/clipboard" "$T/home"
check "message hides the sign-in email" lacks "$T/state/clipboard" "tester@example.edu"
check "message hides the sign-in link's secret" lacks "$T/state/clipboard" "secretstate123"
check "message describes the GitHub CLI" has "$T/state/clipboard" "GitHub CLI: gh 2.99.0 at ~/.local/bin/gh"
check "message hides the GitHub account" lacks "$T/state/clipboard" "testgh"
check "message fits in Claude's limit" [ "$(help_text | wc -c)" -le 14000 ]
check "saves a copy of the message" sh -c "ls '$T/home/Library/Application Support/ClaudeSetup/logs'/*/help-message.txt >/dev/null 2>&1"
end_sandbox

echo "7. Apple's installer is cancelled"
new_sandbox
echo cancel > "$T/state/clt_mode"
printf "export ANTHROPIC_API_KEY=sk-ant-oldkey123\n" > "$T/home/.zshrc"
run_setup
check "exits with an error" exit_is 1
check "explains that Apple's installer closed" has "$T/output.txt" "Apple's installer closed before Git was installed"
check "skips Git setup" has "$T/output.txt" "Set up Git — Not started"
check "still installs and signs in Claude Code" has "$T/output.txt" "Signed in to Premium Seat"
check "help message describes the developer tools step" has "$T/state/clipboard" "Install Git (Apple's developer tools):"
check "help message lists the changes made" has "$T/state/clipboard" "turned off an ANTHROPIC_API_KEY line in ~/.zshrc"
check "help message hides the old API key" lacks "$T/state/clipboard" "oldkey123"
end_sandbox

echo "8. Apple's tools are installed but broken"
new_sandbox
echo broken > "$T/state/clt_mode"
touch "$T/state/clt_installed"
run_setup
check "exits with an error" exit_is 1
check "explains the broken tools" has "$T/output.txt" "look installed but Git doesn't work"
end_sandbox

echo "9. No internet"
new_sandbox
echo dns > "$T/state/net"
run_setup
check "exits with an error" exit_is 1
check "explains the network problem" has "$T/output.txt" "couldn't look up claude.ai"
check "doesn't start the other steps" has "$T/output.txt" "Install the Claude app — Not started"
check "opens claude.ai in the browser (no app yet)" has "$T/state/open.log" "https://claude.ai/new"
check "still puts the message on the clipboard" has "$T/state/clipboard" "couldn't look up claude.ai"
end_sandbox

echo "10. macOS too old"
new_sandbox
echo 12.7.4 > "$T/state/osver"
run_setup
check "exits with an error" exit_is 1
check "explains the macOS version" has "$T/output.txt" "macOS 12.7.4 is too old"
end_sandbox

echo "11. Claude app that isn't signed by Anthropic"
new_sandbox
mkdir -p "$T/apps/Claude.app"
echo XXXXXXXXXX > "$T/state/teamid"
run_setup
check "exits with an error" exit_is 1
check "refuses to use it" has "$T/output.txt" "isn't signed by Anthropic"
end_sandbox

echo "12. Setup window: progress, then the final screen"
new_sandbox
run_setup CLAUDE_SETUP_WINDOW=1 CLAUDE_SETUP_DIALOG_BIN="$T/bin/fakedialog"
check "finishes successfully" exit_is 0
check "opens the progress window with all 9 steps" [ "$(grep -c '^--listitem$' "$T/state/dialog-progress-args")" = 9 ]
check "puts options without a value last (swiftDialog needs this)" [ "$(tail -n 2 "$T/state/dialog-progress-args" | tr '\n' ' ')" = "--button1disabled --moveable " ]
check "final screen also ends with its no-value option" [ "$(tail -n 1 "$T/state/dialog-final-args")" = "--moveable" ]
check "sends list updates to the window" has "$T/state/dialog-commands" "^listitem: index: 8, status: success"
check "list updates have no extra commas or colons" sh -c "! grep '^listitem:' '$T/state/dialog-commands' | sed 's/^listitem: index: [0-9]*, status: [a-z]*, statustext: //' | grep -q '[,:]'"
check "uses only valid statuses" sh -c "! grep '^listitem:' '$T/state/dialog-commands' | grep -vqE 'status: (wait|success|fail|pending|error),'"
check "shows not-started steps as waiting, not spinning" has "$T/state/dialog-commands" "^listitem: index: 8, status: pending, statustext: $"
check "shows the step that's running as a spinner" has "$T/state/dialog-commands" "^listitem: index: 2, status: wait, statustext: Checking"
check "flags steps that need the person" has "$T/state/dialog-commands" "^listitem: index: 4, status: error, statustext: Needs you — sign in using your browser"
check "progress text follows the current step" has "$T/state/dialog-commands" "^progresstext: Install the Claude app"
check "shows the sign-in link in the window" has "$T/state/dialog-commands" "open the sign-in page"
check "shows the ready screen" has "$T/state/dialog-final-args" "Your tools are ready"
end_sandbox

echo "13. Setup window: failure, then Get help from Claude"
new_sandbox
echo cancel > "$T/state/clt_mode"
echo 0 > "$T/state/button"
run_setup CLAUDE_SETUP_WINDOW=1 CLAUDE_SETUP_DIALOG_BIN="$T/bin/fakedialog" CLAUDE_SETUP_ASSUME_YES=0
check "exits with an error" exit_is 1
check "shows the Get help from Claude button" has "$T/state/dialog-final-args" "Get help from Claude"
check "opens Claude after the click" has "$T/state/open.log" "claude://claude.ai/new?q="
check "the Claude app was opened for sign-in before the failure" [ "$(grep -n -- "-a $T/apps/Claude.app" "$T/state/open.log" | head -n 1 | cut -d: -f1)" -lt "$(grep -n -- "claude://" "$T/state/open.log" | head -n 1 | cut -d: -f1)" ]
end_sandbox

echo "14. Setup window: failure, then Close"
new_sandbox
echo cancel > "$T/state/clt_mode"
echo 2 > "$T/state/button"
run_setup CLAUDE_SETUP_WINDOW=1 CLAUDE_SETUP_DIALOG_BIN="$T/bin/fakedialog" CLAUDE_SETUP_ASSUME_YES=0
check "exits with an error" exit_is 1
check "doesn't open Claude" lacks "$T/state/open.log" "claude://"
end_sandbox

echo "15. Homebrew-style tools earlier in PATH (GNU sed, another curl)"
new_sandbox
mkdir -p "$T/otherbin"
printf '#!/bin/sh\necho "this is not the sed setup expects" >&2\nexit 1\n' > "$T/otherbin/sed"
printf '#!/bin/sh\necho "curl: (60) SSL certificate problem" >&2\nexit 60\n' > "$T/otherbin/curl"
chmod +x "$T/otherbin/"*
printf 'export ANTHROPIC_API_KEY=sk-ant-oldkey123\n' > "$T/home/.zshrc"
run_setup PATH="$T/otherbin:$T/bin:/usr/bin:/bin:/usr/sbin:/sbin"
check "finishes successfully" exit_is 0
check "still turns off the API key line" has "$T/home/.zshrc" '^# Turned off by Claude setup: export ANTHROPIC_API_KEY'
end_sandbox

echo "16. Previewing the help message"
new_sandbox
mkdir -p "$T/apps/Claude.app"
SCRIPT_ARGS=--preview-help run_setup
SCRIPT_ARGS=""
check "finishes successfully" exit_is 0
check "opens the Claude app with a sample message" has "$T/state/open.log" "claude://claude.ai/new?q="
check "the sample describes a failed step" has "$T/state/clipboard" "What didn't finish:"
check "says it's a preview" has "$T/output.txt" "nothing was installed or changed"
check "doesn't install Claude Code" test ! -e "$T/home/.local/bin/claude"
check "doesn't download anything" test ! -s "$T/state/curl.log"
check "doesn't touch shell startup files" test ! -e "$T/home/.zshrc"
end_sandbox

echo "17. Run from ~/Downloads: the rerun command points there"
new_sandbox
mkdir -p "$T/home/Downloads"
cp "$SCRIPT" "$T/home/Downloads/claude-setup.sh"
echo dns > "$T/state/net"
saved_script=$SCRIPT
SCRIPT="$T/home/Downloads/claude-setup.sh"
run_setup
SCRIPT=$saved_script
check "exits with an error" exit_is 1
check "Terminal shows the exact rerun command" has "$T/output.txt" "run setup again: bash ~/Downloads/claude-setup.sh"
check "help message gives the same command" has "$T/state/clipboard" "pasting this into Terminal: bash ~/Downloads/claude-setup.sh"
end_sandbox

echo "18. Shared as a web address, with RERUN_COMMAND set"
new_sandbox
echo dns > "$T/state/net"
run_setup CLAUDE_SETUP_RERUN_COMMAND='/bin/bash -c "$(curl -fsSL https://example.edu/claude-setup.sh)"'
check "help message uses the configured command" has "$T/state/clipboard" 'pasting this into Terminal: /bin/bash -c "$(curl -fsSL https://example.edu/claude-setup.sh)"'
end_sandbox

echo "19. macOS 14 (Sonoma)"
new_sandbox
echo 14.6 > "$T/state/osver"
run_setup CLAUDE_SETUP_WINDOW=1
check "finishes successfully" exit_is 0
check "isn't treated as too old" lacks "$T/output.txt" "too old"
check "asks for the macOS 13-14 version of the window (swiftDialog 2.5.6)" has "$T/state/curl.log" "dialog-2.5.6"
check "doesn't ask for the macOS 15 version" lacks "$T/state/curl.log" "dialog-3.1.0"
check "falls back to Terminal when the window can't be set up" has "$T/output.txt" "progress shows here instead"
check "reports macOS 14.6" has "$T/output.txt" "macOS 14.6"
end_sandbox

echo "20. macOS 13 (Ventura), the oldest supported"
new_sandbox
echo 13.0 > "$T/state/osver"
run_setup CLAUDE_SETUP_WINDOW=1
check "finishes successfully" exit_is 0
check "asks for swiftDialog 2.5.6" has "$T/state/curl.log" "dialog-2.5.6"
end_sandbox

echo "21. macOS 15 (Sequoia) and newer"
new_sandbox
echo 15.0 > "$T/state/osver"
run_setup CLAUDE_SETUP_WINDOW=1
check "finishes successfully" exit_is 0
check "asks for swiftDialog 3.1.0" has "$T/state/curl.log" "dialog-3.1.0"
end_sandbox

TAB=$'\t'
APP_RERUN="open the Origami app again and click Start setup"

echo "22. Inside the Origami app: a fresh Mac"
new_sandbox
run_setup CLAUDE_SETUP_UI=app CLAUDE_SETUP_WINDOW=1 < /dev/null
check "finishes successfully" exit_is 0
check "sends the app the list of steps" has "$T/output.txt" "^@@steps${TAB}Check your Mac|Install Git.*|Sign in to the Claude app|Set up Git|Set up GitHub|Final check$"
check "sends step updates" has "$T/output.txt" "^@@step${TAB}2${TAB}success${TAB}Added to"
# Claude has to be ready before the steps that can fail, or Get help from Claude has nowhere to go.
first_line() { grep -n -- "$2" "$1" | head -n 1 | cut -d: -f1; }
check "opens the Claude app for sign-in before setting up Git" [ "$(first_line "$T/output.txt" "^@@step${TAB}5${TAB}pending${TAB}Needs you: check the app")" -lt "$(first_line "$T/output.txt" "^@@step${TAB}6${TAB}progress")" ]
check "and after Claude Code is signed in" [ "$(first_line "$T/output.txt" "^@@step${TAB}4${TAB}success")" -lt "$(first_line "$T/output.txt" "^@@step${TAB}5${TAB}pending")" ]
check "doesn't ask to reopen an app that isn't running" lacks "$T/output.txt" "quit and reopen"
end_sandbox

echo "22b. Inside the app: the Claude app is open when Apple's tools arrive"
new_sandbox
touch "$T/state/app_running"
run_setup CLAUDE_SETUP_UI=app CLAUDE_SETUP_WINDOW=1 < /dev/null
check "finishes successfully" exit_is 0
check "asks to quit and reopen the Claude app so it finds Git" has "$T/output.txt" "^@@step${TAB}5${TAB}pending${TAB}Needs you: sign in if you haven't, then quit and reopen the Claude app so it finds Git"
check "sends the sign-in instructions" has "$T/output.txt" "^@@message${TAB}.*open the sign-in page"
check "sends the ready screen" has "$T/output.txt" "^@@final${TAB}success${TAB}Your tools are ready${TAB}"
check "doesn't download swiftDialog (the app draws the window)" lacks "$T/state/curl.log" "github.com"
check "tells people to keep the window open, not Terminal" lacks "$T/output.txt" "Terminal window open until"
end_sandbox

echo "23. Inside the app: a failure, then Get help from Claude"
new_sandbox
echo cancel > "$T/state/clt_mode"
printf 'help\n' | run_setup CLAUDE_SETUP_UI=app CLAUDE_SETUP_ASSUME_YES=0 CLAUDE_SETUP_RERUN_TEXT="$APP_RERUN"
check "exits with an error" exit_is 1
check "sends the failure screen" has "$T/output.txt" "^@@final${TAB}fail${TAB}Setup didn't finish${TAB}"
check "the failure screen says how to run setup again" has "$T/output.txt" "When it's fixed, $APP_RERUN"
check "opens Claude after the click" has "$T/state/open.log" "claude://claude.ai/new?q="
check "tells the app where Claude opened" has "$T/output.txt" "^@@helpopened${TAB}app"
check "the help message says to reopen the app" has "$T/state/clipboard" "tell me to $APP_RERUN"
end_sandbox

echo "24. Inside the app: a failure, then Close"
new_sandbox
echo cancel > "$T/state/clt_mode"
printf 'close\n' | run_setup CLAUDE_SETUP_UI=app CLAUDE_SETUP_ASSUME_YES=0 CLAUDE_SETUP_RERUN_TEXT="$APP_RERUN"
check "exits with an error" exit_is 1
check "doesn't open Claude" lacks "$T/state/open.log" "claude://"
check "doesn't tell the app help opened" lacks "$T/output.txt" "@@helpopened"
end_sandbox

LATEST_SCRIPT_LINE='/bin/bash -c "$(curl -fsSL https://github.com/Excaliburke/set-up-claude/releases/latest/download/claude-setup.sh)"'

echo "25. Run from the one-line web command"
new_sandbox
echo dns > "$T/state/net"
RUN_AS_WEB=1 run_setup
check "exits with an error" exit_is 1
check "the rerun command downloads the newest release" has "$T/state/clipboard" "pasting this into Terminal: $LATEST_SCRIPT_LINE"
end_sandbox

echo "26. An older downloaded copy, with a newer release on GitHub"
new_sandbox
echo 99.0.0 > "$T/state/latest_version"
run_setup
check "finishes successfully" exit_is 0
check "shows its own version" has "$T/output.txt" "Claude setup for Mac (version "
check "says a newer version is available" has "$T/output.txt" "A newer version of this setup is available (99.0.0"
check "says how to get the newest one" has "$T/output.txt" "To use the newest one instead, press Control-C and run: $LATEST_SCRIPT_LINE"
end_sandbox

echo "27. The newest copy, matching the GitHub release"
new_sandbox
grep -m1 '^SETUP_VERSION=' "$SCRIPT" | cut -d'"' -f2 > "$T/state/latest_version"
run_setup
check "finishes successfully" exit_is 0
check "doesn't mention a newer version" lacks "$T/output.txt" "A newer version"
end_sandbox

echo "28. The GitHub CLI is missing: GitHub's download, then sign-in (in the app)"
new_sandbox
rm "$T/home/.local/bin/gh" "$T/state/gh_auth"
run_setup CLAUDE_SETUP_UI=app CLAUDE_SETUP_WINDOW=1 < /dev/null
check "finishes successfully" exit_is 0
check "asks GitHub for the newest version" has "$T/state/curl.log" "api.github.com/repos/cli/cli/releases/latest"
check "downloads the Apple silicon build" has "$T/state/curl.log" "gh_2.99.0_macOS_arm64.zip"
check "doesn't download the Intel build" lacks "$T/state/curl.log" "macOS_amd64"
check "gets GitHub's checksums" has "$T/state/curl.log" "gh_2.99.0_checksums.txt"
check "installs gh in ~/.local/bin" test -x "$T/home/.local/bin/gh"
check "signs in on the web" has "$T/state/gh-login.log" "--hostname github.com --web"
check "keeps gh from opening a browser itself" has "$T/state/gh-login.log" "BROWSER=/usr/bin/true"
check "waits for the person with the code" has "$T/output.txt" "^@@step${TAB}7${TAB}pending${TAB}Needs you: enter the code AB12-CD34 on GitHub"
check "shows the code in the window" has "$T/output.txt" "^@@message${TAB}.*AB12-CD34"
check "puts the code on the clipboard" [ "$(cat "$T/state/clipboard")" = AB12-CD34 ]
check "opens GitHub's code page" has "$T/state/open.log" "https://github.com/login/device"
check "sets Git to use the GitHub sign-in" count_is "$T/state/gh-setup-git.log" "setup-git" 1
check "reports the account" has "$T/output.txt" "^@@step${TAB}7${TAB}success${TAB}gh 2.99.0 · signed in as testgh"
run_setup
check "running it again finishes successfully" exit_is 0
check "doesn't download gh again" count_is "$T/state/curl.log" "gh_2.99.0_macOS_arm64.zip" 1
check "doesn't sign in to GitHub again" count_is "$T/state/gh-login.log" "args" 1
check "doesn't set up Git for GitHub again" count_is "$T/state/gh-setup-git.log" "setup-git" 1
end_sandbox

echo "29. An Intel Mac with a gh that new Terminal windows can't find"
new_sandbox
echo x86_64 > "$T/state/arch"
put_homebrew gh
rm "$T/home/.local/bin/gh"
run_setup
check "finishes successfully" exit_is 0
check "reports an Intel Mac" has "$T/output.txt" "Intel"
check "downloads the Intel build" has "$T/state/curl.log" "gh_2.99.0_macOS_amd64.zip"
check "doesn't download the Apple silicon build" lacks "$T/state/curl.log" "macOS_arm64"
check "installs gh in ~/.local/bin" test -x "$T/home/.local/bin/gh"
check "new Terminal windows find the new gh" has "$T/output.txt" "Set up GitHub — gh 2.99.0"
end_sandbox

echo "30. Homebrew is installed but new Terminal windows don't find it"
new_sandbox
put_homebrew gh brew
rm "$T/home/.local/bin/gh"
printf 'export EDITOR=nano\n' > "$T/home/.zprofile"
run_setup
check "finishes successfully" exit_is 0
check "adds Homebrew's line to ~/.zprofile" has "$T/home/.zprofile" "^eval \"\$($T/homebrew/bin/brew shellenv)\"$"
check "marks the line as added by setup" has "$T/home/.zprofile" "^# >>> Claude setup (Homebrew) >>>$"
check "saves a backup first" sh -c "ls '$T/home'/.zprofile.before-claude-setup-* >/dev/null 2>&1"
check "keeps the existing ~/.zprofile content" has "$T/home/.zprofile" "^export EDITOR=nano$"
check "says what it changed" has "$T/home/Library/Application Support/ClaudeSetup/logs"/*/setup.log "added Homebrew's PATH line to ~/.zprofile"
check "uses Homebrew's gh without downloading one" lacks "$T/state/curl.log" "cli/cli"
check "doesn't put another gh in ~/.local/bin" test ! -e "$T/home/.local/bin/gh"
check "never asks Homebrew to install anything" lacks "$T/state/brew.log" "install"
run_setup
check "running it again finishes successfully" exit_is 0
check "doesn't add Homebrew's line twice" count_is "$T/home/.zprofile" "brew shellenv" 1
end_sandbox

echo "31. The GitHub CLI download doesn't match GitHub's checksum"
new_sandbox
rm "$T/home/.local/bin/gh"
echo 0000000000000000000000000000000000000000000000000000000000000000 > "$T/state/gh_checksum"
run_setup
check "exits with an error" exit_is 1
check "explains the checksum problem" has "$T/output.txt" "Set up GitHub — The GitHub CLI download didn't match GitHub's checksum"
check "doesn't install gh" test ! -e "$T/home/.local/bin/gh"
check "skips the final check" has "$T/output.txt" "Final check — Skipped"
check "help message names the GitHub step" has "$T/state/clipboard" "Set up GitHub: The GitHub CLI download"
end_sandbox

echo "32. The GitHub CLI download isn't signed by GitHub"
new_sandbox
rm "$T/home/.local/bin/gh"
echo XXXXXXXXXX > "$T/state/gh_teamid"
run_setup
check "exits with an error" exit_is 1
check "explains the signature problem" has "$T/output.txt" "isn't signed by GitHub, so it wasn't installed"
check "doesn't install gh" test ! -e "$T/home/.local/bin/gh"
check "logs which team signed it" has "$T/home/Library/Application Support/ClaudeSetup/logs"/*/setup.log "signed by team 'XXXXXXXXXX'"
end_sandbox

echo "33. The GitHub sign-in never finishes"
new_sandbox
rm "$T/state/gh_auth"
echo hang > "$T/state/gh_login_mode"
run_setup CLAUDE_SETUP_GITHUB_TIMEOUT=4
check "finishes successfully" exit_is 0
check "says Your tools are ready" has "$T/output.txt" "Your tools are ready"
check "explains the sign-in didn't finish" has "$T/output.txt" "GitHub sign-in didn't finish"
check "says how to sign in later" has "$T/output.txt" "Sign in later with: gh auth login --web"
check "the final check only warns about it" has "$T/output.txt" "Final check — Everything works except the GitHub sign-in"
check "doesn't open the help message" lacks "$T/state/open.log" "claude://"
end_sandbox

echo "34. Someone turns down the GitHub sign-in"
new_sandbox
rm "$T/state/gh_auth"
echo fail > "$T/state/gh_login_mode"
run_setup
check "finishes successfully" exit_is 0
check "explains the sign-in stopped" has "$T/output.txt" "GitHub sign-in stopped before it finished"
check "doesn't set up Git for GitHub" test ! -e "$T/state/gh-setup-git.log"
end_sandbox

echo "35. The help message hides GitHub tokens and the GitHub account"
cleaned=$(CLAUDE_SETUP_SOURCE_ONLY=1 /bin/bash -c 'source "$1"; GH_ACCOUNT=octotester; redact "gho_abc123 ghp_Def456 ghu_x ghs_y ghr_z github_pat_11AB_cd9 octotester"' _ "$SCRIPT")
check "hides every kind of GitHub token" [ "$cleaned" = "<github-token> <github-token> <github-token> <github-token> <github-token> <github-token> <github-account>" ]

printf '\n%s passed, %s failed\n' "$PASS" "$FAILS"
[ "$FAILS" = 0 ]
