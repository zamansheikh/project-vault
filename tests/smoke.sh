#!/bin/zsh
# Smoke test: runs src/vault against a throwaway projects folder and checks
# backups, versions, missing sources, restores and an encrypted copy.
# It never touches your real vault, config, background job or login Keychain.
#
#   zsh tests/smoke.sh

emulate -R zsh
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
HERE="${0:A:h}"
V="$HERE/../src/vault"
T=$(mktemp -d "${TMPDIR:-/tmp}/pv-smoke.XXXXXX")
P="$T/projects"
KC="$T/test.keychain-db"
export VAULT_CONFIG="$T/no-config" VAULT_ROOT="$P" VAULT_KEYCHAIN="$KC"
VA="$P/_ProjectVault"
pass=0 failed=0

cleanup() { security delete-keychain "$KC" 2>/dev/null; rm -rf "$T" }
trap cleanup EXIT

check() {   # check "what" command...
  local what=$1; shift
  if "$@" >/dev/null 2>&1; then print -P "  %F{green}ok%f    $what"; (( pass++ ))
  else print -P "  %F{red}FAIL%f  $what"; (( failed++ )); fi
}
vault() { zsh "$V" "$@" }

print "Project Vault smoke test in $T"

# A repo with an ignored .env, a tracked file, a keystore and noise.
mkdir -p "$P/acme/shop-app/android/app" "$P/acme/shop-app/node_modules/x" "$P/notes"
(cd "$P/acme/shop-app" && git init -q && printf '.env\n*.jks\nandroid/key.properties\nnode_modules\n' > .gitignore \
  && echo 'tracked' > README.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm init)
echo 'API_KEY=one' > "$P/acme/shop-app/.env"
echo 'TEMPLATE=1'  > "$P/acme/shop-app/.env.example"
echo 'storePassword=x' > "$P/acme/shop-app/android/key.properties"
head -c 1024 /dev/urandom > "$P/acme/shop-app/android/app/upload.jks"
echo 'NOPE=1' > "$P/acme/shop-app/node_modules/x/.env"
echo 'loose=1' > "$P/notes/credentials.json"

vault sync -q >/dev/null
check "first sync backs up .env"                  test -f "$VA/current/acme/shop-app/.env"
check "first sync backs up the keystore"          test -f "$VA/current/acme/shop-app/android/app/upload.jks"
check "first sync backs up key.properties"        test -f "$VA/current/acme/shop-app/android/key.properties"
check "non-repo credentials.json is backed up"    test -f "$VA/current/notes/credentials.json"
check ".env.example is skipped"                   test ! -e "$VA/current/acme/shop-app/.env.example"
check "tracked files are skipped"                 test ! -e "$VA/current/acme/shop-app/README.md"
check "node_modules is skipped"                   test ! -e "$VA/current/acme/shop-app/node_modules"
check "INDEX.md is written"                       grep -q 'acme/shop-app' "$VA/INDEX.md"

echo 'API_KEY=two' > "$P/acme/shop-app/.env"; vault sync -q >/dev/null
echo 'API_KEY=three' > "$P/acme/shop-app/.env"; vault sync -q >/dev/null
check "two edits make v1 and v2 in history"       zsh -c "ls -A '$VA/history/acme/shop-app/' | grep -c '^\.env\.v[12]_' | grep -qx 2"
check "current copy is the newest content"        grep -qx 'API_KEY=three' "$VA/current/acme/shop-app/.env"
check "vault history lists v3 as current"         zsh -c "zsh '$V' history acme/shop-app/.env | grep -q 'v3.*(current)'"
check "vault diff shows the change"               zsh -c "zsh '$V' diff acme/shop-app/.env | grep -q '^+API_KEY=three'"

rm -rf "$P/acme/shop-app"
check "status reports the missing source"         zsh -c "zsh '$V' status | grep -q 'MISSING.*acme/shop-app/.env'"
vault sync -q >/dev/null
check "the vault keeps files of a lost project"   test -f "$VA/current/acme/shop-app/.env"
check "INDEX.md lists the missing source"         grep -q 'Source missing' "$VA/INDEX.md"

vault restore acme/shop-app </dev/null >/dev/null
check "restore brings the project's files back"   grep -qx 'API_KEY=three' "$P/acme/shop-app/.env"
check "restore brings the keystore back"          cmp -s "$P/acme/shop-app/android/app/upload.jks" "$VA/current/acme/shop-app/android/app/upload.jks"
echo 'LOCAL=edit' > "$P/acme/shop-app/.env"
vault restore acme/shop-app/.env </dev/null >/dev/null
check "restore does not overwrite without asking" grep -qx 'LOCAL=edit' "$P/acme/shop-app/.env"
vault restore acme/shop-app/.env --version 1 --force >/dev/null
check "--version 1 --force restores version 1"    grep -qx 'API_KEY=one' "$P/acme/shop-app/.env"
check "--force saved the local copy first"        zsh -c "ls -A '$VA/history/acme/shop-app/' | grep -q '^\.env\.pre-restore_'"

mkdir -p "$VA/.state/sync.lock" && echo 99999 > "$VA/.state/sync.lock/pid"
vault sync -q >/dev/null
check "a stale lock from a stopped run is cleared" test ! -d "$VA/.state/sync.lock"

# Encrypted copy, with a throwaway keychain and password.
TP=$(openssl rand -hex 16)
security create-keychain -p "$TP" "$KC" && security unlock-keychain -p "$TP" "$KC" \
  && security add-generic-password -s "Project Vault backup" -a "$USER" -w "$TP" "$KC"
printf 'DEST=%s\nKEEP=2\n' "$T/offsite" > "$VA/offsite.conf"
vault offsite >/dev/null
dmg=( "$T"/offsite/ProjectVault-*.dmg(N) )
check "vault offsite makes one .dmg"              test ${#dmg} -eq 1
check "the .dmg is encrypted"                     zsh -c "hdiutil isencrypted '${dmg[1]}' | grep -q 'encrypted: YES'"
mkdir -p "$T/m"
check "a wrong password does not open it"         zsh -c "! printf wrong | hdiutil attach -quiet -nobrowse -readonly -stdinpass -mountpoint '$T/m' '${dmg[1]}'"
check "the right password opens it"               zsh -c "printf '%s' '$TP' | hdiutil attach -quiet -nobrowse -readonly -stdinpass -mountpoint '$T/m' '${dmg[1]}' && test -f '$T/m/_ProjectVault/current/acme/shop-app/.env' && hdiutil detach -quiet '$T/m'"
enc=( "$T"/offsite/ProjectVault-*.tar.gz.enc(N) )
ENC=( enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 -pass stdin -in "${enc[1]}" )
check "a Windows/Linux .tar.gz.enc is made too"   test ${#enc} -eq 1
check "it starts with OpenSSL's Salted__ header"  zsh -c "head -c 8 '${enc[1]}' | grep -q Salted__"
check "the right password opens it (LibreSSL)"    zsh -c "printf '%s\n' '$TP' | /usr/bin/openssl ${ENC[*]} | tar -tzf - | grep -q '_ProjectVault/current/acme/shop-app/.env'"
check "a wrong password does not open it"         zsh -c "! printf 'wrong\n' | /usr/bin/openssl ${ENC[*]} -out /dev/null"
OSSL3=/opt/homebrew/opt/openssl@3/bin/openssl
if [[ -x $OSSL3 ]]; then
  check "OpenSSL 3 (as in Git for Windows) opens it" zsh -c "printf '%s\n' '$TP' | $OSSL3 ${ENC[*]} | tar -tzf - | grep -q 'HOW TO RESTORE.txt'"
  # Exactly what tools/restore-windows.ps1 runs: password in an environment variable.
  mkdir -p "$T/win"
  check "the Windows script's OpenSSL command works" zsh -c "PV_BACKUP_PASSWORD='$TP' $OSSL3 enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 -pass env:PV_BACKUP_PASSWORD -in '${enc[1]}' -out '$T/win/x.tar.gz' && tar -xzf '$T/win/x.tar.gz' -C '$T/win' && test -f '$T/win/_ProjectVault/current/acme/shop-app/.env'"
fi
check "the archive has no Mac-only ._ files"      zsh -c "! (printf '%s\n' '$TP' | /usr/bin/openssl ${ENC[*]} | tar -tzf - | grep -q '/\._')"
check "README-RESTORE.txt is next to the copies"  grep -q 'restore-windows.ps1' "$T/offsite/README-RESTORE.txt"
for i in 1 2; do sleep 1; vault offsite >/dev/null; done
dmg=( "$T"/offsite/ProjectVault-*.dmg(N) ); enc=( "$T"/offsite/ProjectVault-*.tar.gz.enc(N) )
check "only KEEP=2 copies of each kind are kept"  test ${#dmg} -eq 2 -a ${#enc} -eq 2

# Recover: lose part of the vault, then bring it back from an encrypted copy.
rm -rf "$VA/history/acme/shop-app"; rm -f "$VA/current/acme/shop-app/android/key.properties"
echo 'API_KEY=vault-differs' > "$VA/current/acme/shop-app/.env"
vault recover "${enc[1]}" >/dev/null
check "recover brings back a missing file"        test -f "$VA/current/acme/shop-app/android/key.properties"
check "recover brings back older versions"        zsh -c "ls -A '$VA/history/acme/shop-app/' | grep -q '^\.env\.v1_'"
check "recover keeps the copy's differing file"   zsh -c "ls -A '$VA/history/acme/shop-app/' | grep -q '^\.env\.recovered_'"
check "recover never throws away the vault's copy" zsh -c "grep -rqx 'API_KEY=vault-differs' '$VA/current' '$VA/history'"

# Cloud folder set up and removed without questions (as the window does it).
vault offsite remove >/dev/null
check "offsite remove turns cloud copies off"     zsh -c "! grep -q '^DEST=' '$VA/offsite.conf'"
mkdir -p "$T/offsite2"; vault offsite setup "$T/offsite2" >/dev/null
check "offsite setup <folder> needs no questions" zsh -c "ls '$T/offsite2' | grep -q '\.tar\.gz\.enc$'"

# A USB drive: an ExFAT disk image mounted outside /Volumes stands in for one.
hdiutil create -quiet -size 40m -fs ExFAT -volname PVSMOKE "$T/usb.dmg"
mkdir -p "$T/usb"
if hdiutil attach -quiet -nobrowse -mountpoint "$T/usb" "$T/usb.dmg"; then
  uuid=$(diskutil info -plist "$T/usb" | plutil -extract VolumeUUID raw -o - -)
  printf 'USB_UUID=%s\nUSB_NAME=PVSMOKE\n' "$uuid" >> "$VA/offsite.conf"
  vault sync -q >/dev/null
  usbc=( "$T"/usb/"ProjectVault Backups"/ProjectVault-*(N) )
  check "plugging in the USB drive makes a copy"  test ${#usbc} -eq 2
  check "no hidden ._ files left on the drive"    zsh -c "! ls -A '$T/usb' '$T/usb/ProjectVault Backups' | grep -q '^\._'"
  check "vault usb status sees the drive"         zsh -c "zsh '$V' usb status | grep -q 'plugged in'"
  vault sync -q >/dev/null
  usbc=( "$T"/usb/"ProjectVault Backups"/ProjectVault-*(N) )
  check "no new USB copy when nothing changed"    test ${#usbc} -eq 2
  sleep 1; echo 'API_KEY=four' > "$P/acme/shop-app/.env"; vault sync -q >/dev/null
  usbc=( "$T"/usb/"ProjectVault Backups"/ProjectVault-*(N) )
  check "a change makes a new USB copy"           test ${#usbc} -eq 4
  hdiutil detach -quiet "$T/usb" || hdiutil detach -quiet -force "$T/usb"
  check "unplugged: status says not plugged in"   zsh -c "zsh '$V' usb status | grep -q 'not plugged in'"
else
  print -P "  %F{yellow}skip%f  could not mount a test USB image"
fi

print
if (( failed )); then print -P "%F{red}$failed failed%f, $pass passed"; exit 1; fi
print -P "%F{green}all $pass checks passed%f"
