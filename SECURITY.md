# Signed server-tools updates (migration draft)

Threat model: a local unprivileged user, compromised service account, or compromised GitHub write access must not be able to cause unauthorized root execution. Existing root compromise and compromise of the independent signing key are outside this boundary.

## Trust setup

Use Git >= 2.34 and OpenSSH with SSH signing support. On a trusted administrator workstation, create a dedicated signing key (not a deploy key):

```sh
ssh-keygen -t ed25519 -f ~/.ssh/server-tools-signing -C server-tools-release
git config gpg.format ssh
git config user.signingkey ~/.ssh/server-tools-signing.pub
git config commit.gpgsign true
```

Protect the private key with a passphrase; never upload it to GitHub or distribute it to managed hosts. Review the complete tree before signing the release tip. GitHub web/API edits and merge commits do not automatically satisfy this independent trust policy. A trusted workstation must sign the final main tip, for example after reviewing the full tree with a signed empty commit and pushing it.

On every managed host independently provision the public signing key. Transfer it via an authenticated administrative channel, confirm its fingerprint against the workstation, and create /etc/server-tools/config/allowed-signers (root:root, 0600) containing one line:

```text
server-tools-release namespaces="git" ssh-ed25519 AAAA...actual-public-key...
```

Never use the example placeholder as a key. The launcher checks the signature of the exact candidate tip using this locally pinned trust file. Ancestry from the last accepted commit is required thereafter; a signed revert or a compromised signing key remains a risk.

## Migration / first installation

Do not merge or deploy this draft until integration tests pass. Existing launchers execute unsigned code; disable their cron entry and stop/wait for active scheduler and project jobs during migration. Verify installed local directories, ACLs and credentials independently. Review and transfer the new launcher and manager from a trusted workstation (not via curl | bash). Install the launcher as /usr/local/sbin/server-tools-launcher, root:root mode 0700, and provision the key as above. Use the reviewed manager to install or migrate, after publishing a signed main tip. Never run the old manager's launcher-update command after migration. Keep a root-controlled offline backup of local configuration and the old checkout for recovery. Do not execute an unverified fallback.

The launcher stages a fresh clone without checkout, verifies its tip, rejects Git symlinks/submodules, checks filesystem ownership and write permissions, and then activates the verified checkout under an exclusive lock. Before dispatch it checks the accepted commit, signature, tracked changes and untracked entries. Failed signature or download checks leave the existing accepted checkout available. Interrupted activation may require manual recovery and must fail closed. Local trust and launcher updates are intentional administrator operations. HTTPS and read-only SSH remain supported.

## Acceptance checklist (not yet executed)

- Valid signed main activates; unsigned tip, wrong signing key, modified signed commit, symlink/submodule and non-descendant revision do not.
- Network outage retains last accepted revision; first installation without trust does not execute remote code.
- Unprivileged service account cannot write any privileged path, including parent directories and local config; test ACLs, symlinks, lock paths and environment.
- Check every job, service unit, sourced file, command argument and external input for injection and privilege boundaries. Verify all direct root entry points and project jobs use protected code and honor locks.
- Run fresh install, existing HTTPS/SSH migration, scheduler, MQTT, package updates, service accounts, Zomboid and concurrent/interrupt recovery tests in disposable Debian VM.
- Verify manual launcher replacement procedure, mode preservation and permissions checks; reconcile bootstrap README with final workflow before rollout.

This draft is not a completed security audit. No key is included and no host is migrated by creating this branch.
