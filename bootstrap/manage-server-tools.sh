#!/usr/bin/env bash
set -Eeuo pipefail
umask 022
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

readonly account=server-tools launcher=/usr/local/sbin/server-tools-launcher
die(){ echo "server-tools: $*" >&2; exit 1; }
require_root(){ [[ $EUID == 0 ]] || die "Root required"; }
install_base(){
 local p missing=()
 for p in git curl jq mosquitto-clients cron util-linux ca-certificates openssh-client; do
  [[ $(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null || true) == installed ]] || missing+=("$p")
 done
 if (( ${#missing[@]} )); then apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"; fi
}
setup_account(){
 local n
 if id "$account" >/dev/null 2>&1; then
  [[ $(id -gn "$account") == "$account" && $(id -u "$account") != 0 && $(getent passwd "$account" | cut -d: -f7) == /usr/sbin/nologin ]] || die "Existing service account inconsistent"
  return
 fi
 getent group "$account" >/dev/null && die "Unexpected existing group"
 for ((n=621;n<=999;n++)); do
  if ! getent passwd "$n" >/dev/null && ! getent group "$n" >/dev/null; then
   groupadd --system --gid "$n" "$account"
   useradd --system --uid "$n" --gid "$n" --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$account"
   return
  fi
 done
 die "No free UID/GID from 621 to 999"
}
setup_dirs(){
 install -d -o root -g root -m 755 /etc/server-tools /var/lib/server-tools /var/log/server-tools /run/server-tools
 install -d -o root -g root -m 700 /etc/server-tools/config /etc/server-tools/scheduler /var/lib/server-tools/bootstrap /var/log/server-tools/jobs
 install -d -o root -g "$account" -m 750 /etc/server-tools/credentials
 install -d -o "$account" -g "$account" -m 750 /var/lib/server-tools/mqtt
}
setup_github(){
 local repo=$ssh_repo
 local key=/etc/server-tools/credentials/github.key
 local hosts=/etc/server-tools/credentials/github_known_hosts
 local answer
 [[ ! -L "$key" && ! -L "$key.pub" && ! -L "$hosts" ]] || die "Unexpected credential symlink"
 if [[ ! -e "$key" ]]; then
  [[ ! -e "$key.pub" ]] || die "Public key exists but private key is missing"
  (umask 077; ssh-keygen -q -t ed25519 -N '' -C "server-tools@$(hostname)" -f "$key")
 fi
 chown root:root "$key"
 chmod 600 "$key"
 if [[ ! -e "$key.pub" ]]; then
  (umask 077; ssh-keygen -y -f "$key" > "$key.pub")
 fi
 chown root:root "$key.pub"
 chmod 644 "$key.pub"
 # Pinned public host key from https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
 if [[ ! -e "$hosts" ]]; then
  (umask 077; set -o noclobber; printf '%s\n' 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' > "$hosts")
 fi
 chown root:root "$hosts"
 chmod 600 "$hosts"
 until timeout 30 git ls-remote --exit-code "$repo" refs/heads/main >/dev/null; do
  echo "GitHub access not available. Add this PUBLIC key as a read-only Deploy Key:"
  echo "https://github.com/Sorcanius/server-tools/settings/keys"
  cat "$key.pub"
  if ! read -r -p "Press Enter to retry, or q to quit: " answer </dev/tty; then
   die "Interactive terminal required to register the Deploy Key"
  fi
  [[ "$answer" != q && "$answer" != Q ]] || die "Installation paused; rerun after registering the key"
 done
}
choose_auth(){
 local answer
 if [[ -e "$auth_file" ]]; then
  read_auth || die "Invalid GitHub authentication configuration"
  return
 fi
 if timeout 30 git -c credential.helper= ls-remote --exit-code "$https_repo" refs/heads/main >/dev/null 2>&1; then
  echo "Public HTTPS access available." >&2
  echo "[1] HTTPS (public, no credentials) [2] SSH (deploy key)" >&2
  if [[ -t 0 ]]; then
   read -r -p "Select [1]: " answer </dev/tty
  else
   answer=1
  fi
  case "$answer" in ""|1) echo https;; 2) echo ssh;; *) die "Invalid selection";; esac
 else
  echo "Anonymous HTTPS unavailable (private repository or network failure)." >&2
  if ! read -r -p "Configure SSH? [y/N] " answer </dev/tty; then die "Use an interactive terminal"; fi
  case "$answer" in y|Y|yes) echo ssh;; *) die "Installation paused";; esac
 fi
}
verify_auth(){
 case "$1" in
  ssh) setup_github ;;
  https) timeout 30 git -c credential.helper= ls-remote --exit-code "$https_repo" refs/heads/main >/dev/null || die "Anonymous HTTPS access failed" ;;
  *) die "Expected https or ssh" ;;
 esac
}
save_auth(){
 local tmp
 tmp=$(mktemp /etc/server-tools/config/.github.conf.XXXXXX)
 printf '%s\n' '# Authentication method: https (public) or ssh (public/private).' "AUTH_METHOD=$1" > "$tmp"
 chmod 600 "$tmp"
 mv -T -- "$tmp" "$auth_file"
}
change_auth(){
 require_root
 local mode="${1:-}" old remote
 case "$mode" in https|ssh) ;; *) die "Usage: $0 auth {https|ssh}";; esac
 [[ -d "$target/.git" && ! -L "$target" && ! -L "$target/.git" && $(stat -c %u:%g "$target") == 0:0 ]] || die "Unsafe or missing checkout"
 old=$(read_auth) || die "Invalid current authentication configuration"
 remote=$(git -C "$target" remote get-url origin)
 [[ "$remote" == "$(repo_for "$old")" ]] || die "Unexpected remote"
 verify_auth "$mode"
 install -d -o root -g root -m 755 /run/server-tools\n install -d -o root -g root -m 700 /run/server-tools/locks
 (
  flock -n -x 9 || die "Launcher busy; retry"
  flock -n -x 8 || die "Repository busy; retry"
  git -C "$target" remote set-url origin "$(repo_for "$mode")"
  if ! save_auth "$mode"; then
   git -C "$target" remote set-url origin "$remote"
   die "Could not save authentication configuration"
  fi
 ) 9>/run/server-tools/locks/launcher.lock 8<>/run/server-tools/locks/repository.lock
 echo "Authentication changed to $mode. Existing SSH keys are preserved."
 "$launcher" --sync-now
}
update_launcher(){
 require_root
 [[ -f "$target/bootstrap/server-tools-launcher.sh" && ! -L "$target/bootstrap/server-tools-launcher.sh" ]] || die "Launcher source unavailable"
 install -d -o root -g root -m 755 /run/server-tools
 install -d -o root -g root -m 700 /run/server-tools/locks
 local tmp
 tmp=$(mktemp /usr/local/sbin/.server-tools-launcher.XXXXXX)
 install -o root -g root -m 700 "$target/bootstrap/server-tools-launcher.sh" "$tmp"
 (
  flock -x 9
  mv -T -- "$tmp" "$launcher"
 ) 9>/run/server-tools/locks/launcher.lock
 echo "Launcher updated: $launcher"
}
install_all(){
 local mode repo
 require_root
 [[ ! -L /opt && ! -L "$target" ]] || die "Unsafe checkout path"
 install_base
 setup_account
 setup_dirs
 mode=$(choose_auth)
 verify_auth "$mode"
 repo=$(repo_for "$mode")
 if [[ ! -d "$target/.git" ]]; then
  [[ ! -e "$target" || ( -d "$target" && -z $(ls -A "$target") ) ]] || die "Target not empty"
  git clone --branch main --single-branch "$repo" "$target"
 fi
 [[ $(stat -c %u:%g "$target") == 0:0 && ! -L "$target/.git" ]] || die "Unsafe repository owner"
 [[ $(git -C "$target" remote get-url origin) == "$repo" ]] || die "Unexpected remote"
 save_auth "$mode"
 if [[ ! -e "$launcher" ]]; then
  install -o root -g root -m 700 "$target/bootstrap/server-tools-launcher.sh" "$launcher"
 fi
 "$launcher" --sync-now
 install -d -m 755 /etc/cron.d
 printf '%s\n' '* * * * * root /usr/local/sbin/server-tools-launcher >> /var/log/server-tools/launcher.log 2>&1' > /etc/cron.d/server-tools
 chmod 600 /etc/cron.d/server-tools
 if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then systemctl enable --now cron; else service cron start; fi
 echo "Installation finished. Configure /etc/server-tools/credentials/mqtt.env"
}
case "${1:-help}" in
 install|auto) install_all ;;
 auth) change_auth "${2:-}" ;;
 launcher-update) update_launcher ;;
 sync) require_root; "$launcher" --sync-now ;;
 status) git -c safe.directory="$target" -C "$target" status --short --branch; git -C "$target" -c safe.directory="$target" log -1 --oneline ;;
 help|-h|--help) echo "Usage: $0 {install|auto|sync|launcher-update|status|help|auth https|auth ssh}" ;;
 *) die "Unknown action" ;;
esac
