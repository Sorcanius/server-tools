#!/usr/bin/env bash
set -Eeuo pipefail
umask 022
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export GIT_SSH_COMMAND='/usr/bin/ssh -F /dev/null -i /etc/server-tools/credentials/github.key -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/server-tools/credentials/github_known_hosts -o GlobalKnownHostsFile=/dev/null -o HostKeyAlgorithms=ssh-ed25519 -o ConnectTimeout=15'
export GIT_TERMINAL_PROMPT=0
readonly repo=git@github.com:Sorcanius/server-tools.git target=/opt/server-tools
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
 install -d -o root -g root -m 755 /etc/server-tools /etc/server-tools/config /etc/server-tools/scheduler /var/lib/server-tools /var/log/server-tools /run/server-tools
 install -d -o root -g "$account" -m 750 /etc/server-tools/credentials
 install -d -o root -g root -m 755 /var/lib/server-tools/bootstrap
 install -d -o "$account" -g "$account" -m 750 /var/lib/server-tools/mqtt /var/log/server-tools/jobs
}
setup_github(){
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
 chmod 644 "$hosts"
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
install_all(){
 require_root
 [[ ! -L /opt && ! -L "$target" ]] || die "Unsafe checkout path"
 install_base
 setup_account
 setup_dirs
 setup_github
 if [[ ! -d "$target/.git" ]]; then
  [[ ! -e "$target" || ( -d "$target" && -z $(ls -A "$target") ) ]] || die "Target not empty"
  git clone --branch main --single-branch "$repo" "$target"
 fi
 [[ $(stat -c %u:%g "$target") == 0:0 && ! -L "$target/.git" ]] || die "Unsafe repository owner"
 [[ $(git -C "$target" remote get-url origin) == "$repo" ]] || die "Unexpected remote"
 if [[ ! -e "$launcher" ]]; then
  install -o root -g root -m 755 "$target/bootstrap/server-tools-launcher.sh" "$launcher"
 fi
 "$launcher" --sync-now
 install -d -m 755 /etc/cron.d
 printf '%s\n' '* * * * * root /usr/local/sbin/server-tools-launcher >> /var/log/server-tools/launcher.log 2>&1' > /etc/cron.d/server-tools
 chmod 644 /etc/cron.d/server-tools
 if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then systemctl enable --now cron; else service cron start; fi
 echo "Installation finished. Configure /etc/server-tools/credentials/mqtt.env"
}
case "${1:-help}" in
 install|auto) install_all ;;
 sync) require_root; "$launcher" --sync-now ;;
 status) git -c safe.directory="$target" -C "$target" status --short --branch; git -C "$target" -c safe.directory="$target" log -1 --oneline ;;
 help|-h|--help) echo "Usage: $0 {install|auto|sync|status|help}" ;;
 *) die "Unknown action" ;;
esac
