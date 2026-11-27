#!/usr/bin/env bash
set -Eeuo pipefail
umask 022
cd /
unset BASH_ENV ENV CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CONFIG GIT_CONFIG_SYSTEM GIT_SSL_NO_VERIFY GIT_SSL_CAINFO GIT_SSL_CAPATH GIT_PROXY_COMMAND GIT_SSH GIT_SSH_VARIANT
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

safe_path(){
 local p=$1 m
 while [[ "$p" != / ]]; do
  [[ -e "$p" && ! -L "$p" && $(stat -c %u -- "$p") == 0 ]] || die "Unsafe owner or path: $p"
  m=$(stat -c %a -- "$p")
  (( (8#$m & 0022) == 0 )) || die "Non-root writable path: $p"
  p=$(dirname -- "$p")
 done
}
safe_tree(){
 local bad
 safe_path "$1"
 bad=$(find "$1" \( -type l -o ! -user root -o -perm /022 -o \( ! -type f ! -type d \) \) -print -quit) || die "Cannot inspect $1"
 [[ -z "$bad" ]] || die "Unsafe repository or framework entry: $bad"
}
git(){
 /usr/bin/git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c http.sslVerify=true -c http.followRedirects=false -c protocol.file.allow=never -c protocol.ext.allow=never "$@"
}
safe_path /opt
safe_path /usr/local/sbin/server-tools-launcher
safe_path /run
safe_path /var
safe_path /var/lib
safe_path /var/log
safe_path "$auth_file"
for p in /etc/server-tools /var/lib/server-tools /var/log/server-tools "$runtime"; do
 [[ ! -e "$p" && ! -L "$p" ]] || safe_path "$p"
done
for p in /etc/server-tools /var/lib/server-tools/scheduler /var/log/server-tools "$runtime/locks" "$state"; do
 [[ ! -e "$p" && ! -L "$p" ]] || safe_tree "$p"
done
if [[ -e "$target" || -L "$target" ]]; then safe_tree "$target"; fi
install -d -m 755 -o root -g root "$runtime"
install -d -m 700 -o root -g root "$runtime/locks" "$state"
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
 for file in /etc/server-tools/config/sync.conf "$target/config/sync.conf"; do
  [[ -f "$file" ]] || continue
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
 local stage
 if [[ -d "$target/.git" && ! -L "$target/.git" ]] &&
    [[ $(stat -c %u:%g "$target") == 0:0 ]] &&
    [[ $(git -C "$target" remote get-url origin 2>/dev/null) == "$repo" ]]; then
  timeout "$network" /usr/bin/git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c http.sslVerify=true -c http.followRedirects=false -c protocol.file.allow=never -c protocol.ext.allow=never -C "$target" fetch --prune "$repo" +refs/heads/main:refs/remotes/origin/main &&
  git -C "$target" checkout -f -B main origin/main &&
  git -C "$target" reset --hard origin/main &&
  git -C "$target" clean -ffdx || return 1
 else
  if [[ -e "$target" ]]; then
   [[ -d "$target" && -z $(ls -A "$target") ]] || { echo "Unsafe or damaged checkout; manual inspection required" >&2; return 1; }
   rmdir "$target" || return 1
  fi
  stage=$(mktemp -d /opt/.server-tools.XXXXXX) || return 1
  if ! timeout "$network" /usr/bin/git -c core.hooksPath=/dev/null -c http.sslVerify=true -c http.followRedirects=false -c protocol.file.allow=never -c protocol.ext.allow=never clone --branch main --single-branch "$repo" "$stage"; then rm -rf -- "$stage"; return 1; fi
  chmod 755 "$stage"
  mv -T -- "$stage" "$target" || return 1
 fi
}
if [[ ${1:-} == --sync-now ]] || (( now-last >= interval && now-attempt >= retry )); then
 if flock -n -x 8; then
  printf '%s\n' "$now" > "$state/last-attempt"
  if sync_repo; then
   date +%s > "$state/last-success"
   echo "server-tools: sync successful"
  else
   die "Sync failed; retry later"
  fi
  flock -u 8
 elif [[ ${1:-} == --sync-now ]]; then
  die "Repository busy"
 fi
fi
safe_tree "$target"
[[ "$(git -C "$target" remote get-url origin)" == "$repo" ]] || die "Unexpected remote"
[[ -f "$target/bootstrap/dispatch.sh" && -f "$target/bootstrap/apply-permissions.sh" ]] || die "Dispatcher unavailable"
chown root:root "$target/bootstrap/dispatch.sh" "$target/bootstrap/apply-permissions.sh"
chmod 755 "$target/bootstrap/dispatch.sh" "$target/bootstrap/apply-permissions.sh"
flock -n -s 8 || exit 0
/usr/bin/bash "$target/bootstrap/dispatch.sh" 9>&- || die "Dispatcher failed"
