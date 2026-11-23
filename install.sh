#!/bin/zsh
# Project Vault installer (macOS).
#
#   ./install.sh                        your projects are in ~/Documents
#   ./install.sh --root ~/Developer     your projects are somewhere else
#   ./install.sh --no-app --no-agent    only the `vault` command
#
# Run it again at any time to update. Your vault, its history, extras.txt,
# exclude.txt, offsite.conf and the backup password in the Keychain are kept.

emulate -R zsh
setopt pipe_fail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

HERE="${0:A:h}"
APP_DIR="$HOME/Library/Application Support/ProjectVault"
CONFIG="$APP_DIR/config"
LINK_DIR="$HOME/.local/bin"
APP_BUNDLE="$HOME/Applications/Project Vault.app"
LABEL="com.projectvault.sync"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

ROOT="" VAULT="" WITH_APP=1 WITH_AGENT=1 FIRST_SYNC=1

step() { print -P "%F{blue}==>%f %B$*%b" }
info() { print -r -- "    $*" }
fail() { print -P "%F{red}error:%f $*" >&2; exit 1 }

usage() {
  cat <<EOF
Install or update Project Vault.

  ./install.sh [--root DIR] [--vault DIR] [--no-app] [--no-agent] [--no-sync]

  --root DIR    the folder that holds your projects (default: ~/Documents,
                or the folder chosen at the last install)
  --vault DIR   where the vault goes (default: <root>/_ProjectVault)
  --no-app      do not create ~/Applications/Project Vault.app
  --no-agent    do not install the background job (back up with: vault sync)
  --no-sync     do not run the first backup now
EOF
}

while (( $# )); do
  case $1 in
    --root)     shift; ROOT="${1:-}" ;;
    --vault)    shift; VAULT="${1:-}" ;;
    --no-app)   WITH_APP=0 ;;
    --no-agent) WITH_AGENT=0 ;;
    --no-sync)  FIRST_SYNC=0 ;;
    -h|--help)  usage; exit 0 ;;
    *)          usage; fail "unknown option: $1" ;;
  esac
  shift
done

# ---------- checks ----------
[[ $OSTYPE == darwin* ]] || fail "Project Vault needs macOS (it uses launchd, the Keychain and hdiutil)."
xcode-select -p >/dev/null 2>&1 || fail "the Xcode command line tools are missing. Install them with: xcode-select --install"
for f in vault vault_ui.py vault_ui.html ProjectVaultAgent.c; do
  [[ -f "$HERE/src/$f" ]] || fail "src/$f is missing; run install.sh from the project-vault folder"
done
/usr/bin/python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null \
  || fail "/usr/bin/python3 (3.8 or newer) is needed for the Project Vault window"

# ---------- folders ----------
old_root="" old_vault=""
if [[ -f $CONFIG ]]; then
  while IFS='=' read -r k v || [[ -n $k ]]; do
    case $k in ROOT) old_root="${v/#\~/$HOME}" ;; VAULT) old_vault="${v/#\~/$HOME}" ;; esac
  done < "$CONFIG"
fi
ROOT="${ROOT:-${old_root:-$HOME/Documents}}"; ROOT="${ROOT/#\~/$HOME}"
[[ -d $ROOT ]] || fail "projects folder not found: $ROOT"
ROOT="${ROOT:A}"
if [[ -z $VAULT ]]; then
  if [[ -n $old_vault && $ROOT == "$old_root" ]]; then VAULT="$old_vault"; else VAULT="$ROOT/_ProjectVault"; fi
fi
VAULT="${VAULT/#\~/$HOME}"; VAULT="${VAULT:a}"

step "Installing Project Vault"
info "projects folder: $ROOT"
info "vault folder:    $VAULT"
info "program files:   $APP_DIR"

# ---------- stop what is running (update) ----------
# Only a job this install owns (its plist is in this home folder) is touched.
was_disabled=0
if (( WITH_AGENT )) && [[ -f $PLIST ]] \
   && launchctl print-disabled "$DOMAIN" 2>/dev/null | grep -qF "\"$LABEL\" => disabled"; then was_disabled=1; fi
if (( WITH_AGENT )) && [[ -f $PLIST ]] && launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  for i in {1..60}; do
    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q 'state = running' || break
    (( i == 1 )) && info "waiting for a running backup to finish..."
    sleep 2
  done
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
fi
if [[ -f "$VAULT/.state/ui.json" ]]; then
  pid=$(sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "$VAULT/.state/ui.json")
  [[ -n $pid ]] && kill "$pid" 2>/dev/null && info "closed the open Project Vault window (open it again after this)"
  rm -f "$VAULT/.state/ui.json"
fi

# ---------- program files ----------
mkdir -p "$APP_DIR" || fail "cannot create $APP_DIR"
agent_changed=1
[[ -x "$APP_DIR/ProjectVaultAgent" && -f "$APP_DIR/ProjectVaultAgent.c" ]] \
  && cmp -s "$HERE/src/ProjectVaultAgent.c" "$APP_DIR/ProjectVaultAgent.c" && agent_changed=0
cp "$HERE/src/vault" "$HERE/src/vault_ui.py" "$HERE/src/vault_ui.html" "$HERE/src/ProjectVaultAgent.c" "$APP_DIR/" \
  || fail "could not copy the program files"
[[ -f "$HERE/assets/ProjectVault.icns" ]] && cp "$HERE/assets/ProjectVault.icns" "$APP_DIR/"
chmod 755 "$APP_DIR/vault"
{ print -r -- "ROOT=$ROOT"; print -r -- "VAULT=$VAULT"; } > "$CONFIG"
if (( agent_changed )); then
  xcrun clang -O2 -o "$APP_DIR/ProjectVaultAgent" "$APP_DIR/ProjectVaultAgent.c" \
    || fail "could not build the background helper (clang failed)"
fi
info "installed $(zsh "$APP_DIR/vault" version)"

# ---------- the vault command ----------
mkdir -p "$LINK_DIR"
ln -sf "$APP_DIR/vault" "$LINK_DIR/vault"
found=$(whence -p vault 2>/dev/null)
if [[ :$PATH: != *":$LINK_DIR:"* ]]; then
  info "the vault command is in $LINK_DIR, which is not on your PATH yet. Add it with:"
  info "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
elif [[ -n $found && ${found:A} != "${APP_DIR}/vault" ]]; then
  info "note: another 'vault' command comes first on your PATH ($found)."
  info "Run Project Vault as: $LINK_DIR/vault"
fi

# ---------- the vault folder ----------
mkdir -p "$VAULT"/{current,history,logs,.state} && chmod 700 "$VAULT" || fail "cannot create $VAULT"
sed -e "s|@ROOT@|$ROOT|g" -e "s|@VAULT@|$VAULT|g" "$HERE/src/vault-README.md" > "$VAULT/README.md"
[[ -f "$VAULT/extras.txt" ]] || cp "$HERE/src/extras.txt" "$VAULT/extras.txt"
[[ -f "$VAULT/exclude.txt" ]] || cp "$HERE/src/exclude.txt" "$VAULT/exclude.txt"

# ---------- first backup ----------
if (( FIRST_SYNC )); then
  step "First backup (this can take a minute on a big folder)"
  zsh "$APP_DIR/vault" sync --quiet >/dev/null && info "$(sed 's/^[0-9-]* [0-9:]*  //' "$VAULT/.state/last-sync" 2>/dev/null)"
fi

# ---------- background job ----------
if (( WITH_AGENT )); then
  step "Background backup every 15 minutes"
  rm -f "$PLIST"
  if (( was_disabled )); then
    zsh "$APP_DIR/vault" _write-job
    info "it was turned off with 'vault stop', so it stays off. Turn it on with: vault start"
  else
    zsh "$APP_DIR/vault" start | sed 's/^/    /'
  fi
fi

# ---------- the app ----------
if (( WITH_APP )); then
  step "Project Vault app in ~/Applications"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/pvapp.XXXXXX")
  cat > "$tmp/launcher.applescript" <<EOF
-- Project Vault: opens the vault window (a local page in your browser).
do shell script "/bin/zsh " & quoted form of "$APP_DIR/vault" & " ui > /dev/null 2>&1 &"
EOF
  mkdir -p "${APP_BUNDLE:h}"
  rm -rf "$APP_BUNDLE"
  if osacompile -o "$APP_BUNDLE" "$tmp/launcher.applescript" 2>/dev/null; then
    res="$APP_BUNDLE/Contents/Resources"; plist="$APP_BUNDLE/Contents/Info.plist"
    if [[ -f "$APP_DIR/ProjectVault.icns" ]]; then
      cp "$APP_DIR/ProjectVault.icns" "$res/applet.icns"
      rm -f "$res/Assets.car"
      /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$plist" 2>/dev/null
    fi
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Project Vault" "$plist" 2>/dev/null
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.projectvault.ui" "$plist" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.projectvault.ui" "$plist"
    codesign --force --sign - "$APP_BUNDLE" 2>/dev/null
    touch "$APP_BUNDLE"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_BUNDLE" 2>/dev/null
    info "open it from Launchpad or Spotlight: Project Vault"
  else
    info "could not create the app; open the window with: vault ui"
  fi
  rm -rf "$tmp"
fi

step "Done"
cat <<EOF
    vault service         check the background backup
    vault ui              open the Project Vault window (or the Project Vault app)
    vault offsite setup   keep encrypted copies in iCloud Drive or another cloud folder (recommended)
    vault usb setup       keep encrypted copies on a USB drive whenever it is plugged in
    vault help            every command

    Spotlight indexes the vault by default. To keep secrets out of search results,
    add $VAULT in System Settings > Spotlight > Search Privacy.
EOF
