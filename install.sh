#!/usr/bin/env bash
# Builds Lid Awake and installs it for the current user:
#   ~/Applications/Lid Awake.app, a LaunchAgent that starts it at login, and
#   /etc/sudoers.d/lid-awake, which lets this user run only
#   `pmset -a disablesleep 0` and `1` without a password.
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
user="$(id -un)"
app="$HOME/Applications/Lid Awake.app"
label="dev.yclpaiva.lid-awake"
agent="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"
rule="/etc/sudoers.d/lid-awake"
status="$HOME/Library/Application Support/Lid Awake/status.json"
receipt="$app/Contents/Resources/source.sha256"

usage() { printf 'Usage: %s [--check | --uninstall]\n' "$(basename "$0")"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Arguments must not contain spaces: the GUI fallback joins them into one shell line.
as_root() {
  if [[ -t 0 ]]; then
    sudo "$@"
  else
    osascript -e "do shell script \"$*\" with administrator privileges" >/dev/null
  fi
}

sudo_allowed() {
  sudo -n -l /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1 &&
    sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1
}

stop_agent() {
  # Stopping the app turns lid-closed awake mode off.
  launchctl bootout "$domain/$label" 2>/dev/null || true
  for _ in {1..25}; do
    launchctl print "$domain/$label" >/dev/null 2>&1 || return 0
    sleep 0.2
  done
}

install_rule() {
  sudo_allowed && return
  local tmp
  tmp="$(mktemp)"
  printf '# Installed by lid-awake. Lets %s toggle lid-closed sleep; nothing else.\n%s ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n' \
    "$user" "$user" >"$tmp"
  /usr/sbin/visudo -cf "$tmp" >/dev/null
  printf 'Asking for your admin password to allow only "pmset -a disablesleep 0|1"...\n'
  as_root /usr/bin/install -m 0440 -o root -g wheel "$tmp" "$rule"
  rm -f "$tmp"
  sudo_allowed || fail "$rule was installed but sudo still asks for a password"
}

install() {
  install_rule
  # Reinstalling restarts the app and turns the mode off, so skip it when nothing changed.
  if [[ "$(cat "$receipt" 2>/dev/null)" == "$("$root/Scripts/build.sh" --digest)" ]] &&
    launchctl print "$domain/$label" >/dev/null 2>&1; then
    printf 'Lid Awake is up to date in %s.\n' "$app"
    return
  fi
  "$root/Scripts/build.sh" >/dev/null
  stop_agent
  mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  rm -rf "$app"
  ditto "$root/.build/Lid Awake.app" "$app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
  rm -f "$agent"
  cat >"$agent" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$app/Contents/MacOS/LidAwake</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/lid-awake.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/lid-awake.log</string>
</dict>
</plist>
PLIST
  launchctl enable "$domain/$label"
  launchctl bootstrap "$domain" "$agent"
  printf 'Lid Awake installed in %s; it starts at login.\n' "$app"
}

check() {
  codesign --verify --deep --strict "$app" 2>/dev/null || fail "$app is missing or not signed; run ./install.sh"
  sudo_allowed || fail "$rule is missing; run ./install.sh"
  launchctl print "$domain/$label" >/dev/null 2>&1 || fail "LaunchAgent $label is not loaded"
  [[ -f "$status" ]] || fail "no status from the app yet"
  (($(date +%s) - $(stat -f %m "$status") <= 30)) || fail "the app has not reported in the last 30 seconds"
  kill -0 "$(plutil -extract pid raw "$status")" 2>/dev/null || fail "the app is not running"
  [[ "$(plutil -extract statusItemVisible raw "$status")" == true ]] || fail "the menu bar item is not visible"
  if message="$(plutil -extract error raw "$status" 2>/dev/null)"; then fail "$message"; fi
  local mode=off
  [[ "$(plutil -extract sleepDisabled raw "$status")" == true ]] && mode=on
  printf 'ok Lid Awake (lid-closed awake mode %s)\n' "$mode"
}

uninstall() {
  stop_agent
  sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null || true
  rm -f "$agent"
  rm -rf "$app"
  if [[ -e "$rule" ]] || sudo_allowed; then as_root /bin/rm -f "$rule"; fi
  printf 'Lid Awake removed. Settings stay in the %s defaults domain.\n' "$label"
}

case "${1:-}" in
  "") install ;;
  --check) check ;;
  --uninstall) uninstall ;;
  -h | --help) usage ;;
  *) usage >&2; exit 1 ;;
esac
