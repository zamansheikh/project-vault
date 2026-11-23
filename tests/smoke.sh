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
for i in 1 2; do sleep 1; vault offsite >/dev/null; done
dmg=( "$T"/offsite/ProjectVault-*.dmg(N) )
check "only KEEP=2 copies are kept"               test ${#dmg} -eq 2

print
if (( failed )); then print -P "%F{red}$failed failed%f, $pass passed"; exit 1; fi
print -P "%F{green}all $pass checks passed%f"
