#!/bin/zsh
# Project Vault uninstaller (macOS).
#
# Removes the program, the background job, the `vault` command and the app.
# It never deletes your vault, its encrypted copies or the backup password;
# it tells you where they are so you can remove them yourself.

emulate -R zsh
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

APP_DIR="$HOME/Library/Application Support/ProjectVault"
CONFIG="$APP_DIR/config"
LINK="$HOME/.local/bin/vault"
APP_BUNDLE="$HOME/Applications/Project Vault.app"
LABEL="com.projectvault.sync"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

step() { print -P "%F{blue}==>%f %B$*%b" }
info() { print -r -- "    $*" }

vault="" root=""
if [[ -f $CONFIG ]]; then
  while IFS='=' read -r k v || [[ -n $k ]]; do
    case $k in ROOT) root="$v" ;; VAULT) vault="$v" ;; esac
  done < "$CONFIG"
fi
vault="${vault:-${root:-$HOME/Documents}/_ProjectVault}"

step "Removing Project Vault"
# Only a job this install owns (its plist is in this home folder) is touched.
if [[ -f $PLIST ]]; then
  if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    for i in {1..60}; do
      launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q 'state = running' || break
      (( i == 1 )) && info "waiting for a running backup to finish..."
      sleep 2
    done
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
  fi
  launchctl enable "$DOMAIN/$LABEL" 2>/dev/null   # clear a 'vault stop' setting
  rm -f "$PLIST" && info "background job removed"
fi

if [[ -f "$vault/.state/ui.json" ]]; then
  pid=$(sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "$vault/.state/ui.json")
  [[ -n $pid ]] && kill "$pid" 2>/dev/null
  rm -f "$vault/.state/ui.json"
fi

[[ -L $LINK && ${LINK:A} == "$APP_DIR/vault" ]] && rm -f "$LINK" && info "vault command removed"
[[ -d $APP_BUNDLE ]] && rm -rf "$APP_BUNDLE" && info "Project Vault app removed"
rm -rf "$APP_DIR" && info "program files removed"
rm -rf "$HOME/Library/Logs/ProjectVault"

step "Kept (remove these yourself only if you are sure)"
info "your vault, with every backed-up file and its history:"
info "  $vault"
if [[ -f "$vault/offsite.conf" ]]; then
  dest=$(sed -n 's/^DEST=//p' "$vault/offsite.conf")
  info "your encrypted copies: ${dest:-see offsite.conf}"
fi
if security find-generic-password -s "Project Vault backup" -a "$USER" >/dev/null 2>&1; then
  info "the backup password in your login Keychain. Delete it with:"
  info "  security delete-generic-password -s \"Project Vault backup\" -a \"\$USER\""
fi
