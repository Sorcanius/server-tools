#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
unset BASH_ENV ENV CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export GIT_SSH_COMMAND='/usr/bin/ssh -F /dev/null -i /etc/server-tools/credentials/github.key -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/server-tools/credentials/github_known_hosts -o GlobalKnownHostsFile=/dev/null -o HostKeyAlgorithms=ssh-ed25519 -o ConnectTimeout=15'
export GIT_TERMINAL_PROMPT=0
readonly target=/opt/server-tools
readonly https_repo=https://github.com/Sorcanius/server-tools.git ssh_repo=git@github.com:Sorcanius/server-tools.git
readonly auth_file=/etc/server-tools/config/github.conf
read_auth(){
 local mode
 [[ -f "$auth_file" && ! -L "$auth_file" ]] || return 1
 mode=$(awk -F= '$1=="AUTH_METHOD" && NF==2 {v=$2} END {print v}' "$auth_file")
 case "$mode" in https|ssh) printf '%s\n' "$mode";; *) return 1;; esac
}
repo_for(){
 case "$1" in https) printf '%s\n' "$https_repo";; ssh) printf '%s\n' "$ssh_repo";; *) return 1;; esac
}

readonly state=/var/lib/server-tools/bootstrap runtime=/run/server-tools
die(){ echo "server-tools: $*" >&2; exit 1; }
[[ $EUID == 0 ]] || die "Root required"
cd /

readonly signers=/etc/server-tools/config/allowed-signers
safe_path(){
 local p=$1 mode
 while [[ "$p" != / ]]; do
  [[ -e "$p" && ! -L "$p" && $(stat -c %u -- "$p") == 0 ]] || die "Unsafe path: $p"
  mode=$(stat -c %a -- "$p")
  (( (8#$mode & 0022) == 0 )) || die "Writable privileged path: $p"
  p=$(dirname -- "$p")
 done
}
safe_tree(){
 local p=$1 bad
 safe_path "$p"
 bad=$(find "$p" \( -type l -o ! -user root -o -perm /022 -o \( ! -type f ! -type d \) \) -print -quit) || die "Tree inspection failed"
 [[ -z "$bad" ]] || die "Unsafe repository entry: $bad"
}
git_safe(){
 /usr/bin/git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.fileMode=false -c gpg.format=ssh -c gpg.ssh.program=/usr/bin/ssh-keygen -c gpg.ssh.allowedSignersFile="$signers" "$@"
}
verify_revision(){
 local dir=$1 rev=$2 modes
 git_safe -C "$dir" verify-commit "$rev" || return 1
 modes=$(git_safe -C "$dir" ls-tree -r "$rev") || return 1
 if grep -Eq '^(120000|160000) ' <<<"$modes"; then return 1; fi
}
verify_active(){
 safe_tree "$target"
 verify_revision "$target" HEAD || die "Active commit not signed by trusted key"
 [[ $(git_safe -C "$target" rev-parse HEAD) == "$(cat "$state/accepted-commit")" ]] || die "Active commit differs from accepted revision"
 git_safe -C "$target" diff --no-ext-diff --quiet HEAD -- || die "Modified tracked files"
 local untracked
 untracked=$(git_safe -C "$target" ls-files --others) || die "Cannot inspect untracked files"
 [[ -z "$untracked" ]] || die "Untracked files"
}
safe_path /opt
safe_path /etc/server-tools/config
safe_path "$signers"
safe_path "$auth_file"
safe_path /var/lib/server-tools
safe_path /usr/local/sbin
[[ -f "$signers" ]] || die "Signing trust not provisioned"

[[ ! -e "$runtime" && ! -L "$runtime" ]] || safe_path "$runtime"
install -d -m 755 -o root -g root "$runtime"
for p in "$runtime/locks" "$state"; do
 [[ ! -e "$p" && ! -L "$p" ]] || safe_path "$p"
done
install -d -m 700 -o root -g root "$runtime/locks" "$state"
for p in "$runtime/locks/launcher.lock" "$runtime/locks/repository.lock" "$state/last-success" "$state/last-attempt" "$state/accepted-commit"; do
 [[ ! -e "$p" && ! -L "$p" ]] || safe_path "$p"
done
exec 9>"$runtime/locks/launcher.lock"
flock -n 9 || exit 0
mode=$(read_auth) || die "Invalid GitHub authentication configuration"
repo=$(repo_for "$mode")
if [[ "$mode" == ssh ]]; then
 safe_path /etc/server-tools/credentials/github.key
 safe_path /etc/server-tools/credentials/github_known_hosts
else
 export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
fi
setting(){
 local key=$1 fallback=$2 file value
 for file in /etc/server-tools/config/sync.conf; do
  [[ -f "$file" ]] || continue
  safe_path "$file"
  value=$(awk -F= -v k="$key" '$1==k && $2 ~ /^[0-9]+$/ && NF==2 {v=$2} END {print v}' "$file")
  if [[ $value =~ ^[1-9][0-9]{0,5}$ ]]; then printf '%s\n' "$value"; return; fi
 done
 printf '%s\n' "$fallback"
}
interval=$(setting interval_seconds 3600)
retry=$(setting retry_seconds 300)
network=$(setting network_timeout_seconds 120)
now=$(date +%s)
last=$(cat "$state/last-success" 2>/dev/null || echo 0)
attempt=$(cat "$state/last-attempt" 2>/dev/null || echo 0)
[[ $last =~ ^[0-9]{1,12}$ ]] || last=0
[[ $attempt =~ ^[0-9]{1,12}$ ]] || attempt=0
exec 8<>"$runtime/locks/repository.lock"
sync_repo(){
 local stage candidate previous tmp
 stage=$(mktemp -d /opt/.server-tools.XXXXXX) || return 1
 if ! timeout "$network" /usr/bin/git -c core.hooksPath=/dev/null clone --no-checkout --branch main --single-branch "$repo" "$stage"; then rm -rf -- "$stage"; return 1; fi
 candidate=$(git_safe -C "$stage" rev-parse refs/remotes/origin/main) || return 1
 if ! verify_revision "$stage" "$candidate"; then rm -rf -- "$stage"; return 1; fi
 if [[ -e "$state/accepted-commit" ]]; then
  previous=$(cat "$state/accepted-commit")
  [[ "$previous" =~ ^[0-9a-f]{40}$ ]] || return 1
  if ! git_safe -C "$stage" merge-base --is-ancestor "$previous" "$candidate"; then rm -rf -- "$stage"; return 1; fi
 fi
 if ! git_safe -C "$stage" checkout --detach "$candidate"; then rm -rf -- "$stage"; return 1; fi
 find "$stage" -path "$stage/.git" -prune -o -type d -exec chmod 755 {} + || return 1
 safe_tree "$stage"
 chmod 755 "$stage"
 # All readers must honor the repository lock. Interrupted activation fails closed.
 if [[ -e "$target" || -L "$target" ]]; then
  safe_tree "$target"
  [[ ! -e "$target.previous" && ! -L "$target.previous" ]] || return 1
  mv -T -- "$target" "$target.previous" || return 1
 fi
 if ! mv -T -- "$stage" "$target"; then
  [[ ! -d "$target.previous" ]] || mv -T -- "$target.previous" "$target"
  return 1
 fi
 tmp=$(mktemp "$state/.accepted.XXXXXX") || return 1
 printf '%s\n' "$candidate" > "$tmp" && mv -T -- "$tmp" "$state/accepted-commit" || return 1
 if [[ -d "$target.previous" ]]; then rm -rf -- "$target.previous"; fi
}
if [[ ${1:-} == --sync-now ]] || (( now-last >= interval && now-attempt >= retry )); then
 if flock -n -x 8; then
  printf '%s\n' "$now" > "$state/last-attempt"
  if sync_repo; then
   date +%s > "$state/last-success"
   echo "server-tools: sync successful"
  else
   echo "server-tools: update rejected; checking last accepted version" >&2
  fi
  flock -u 8
 elif [[ ${1:-} == --sync-now ]]; then
  die "Repository busy"
 fi
fi
flock -n -s 8 || exit 0
verify_active
[[ -f "$target/bootstrap/dispatch.sh" && -f "$target/bootstrap/apply-permissions.sh" ]] || die "Dispatcher unavailable"
chown root:root "$target/bootstrap/dispatch.sh" "$target/bootstrap/apply-permissions.sh"
chmod 700 "$target/bootstrap/dispatch.sh" "$target/bootstrap/apply-permissions.sh"
/usr/bin/bash "$target/bootstrap/dispatch.sh" 9>&- || die "Dispatcher failed"
