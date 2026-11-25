#!/usr/bin/env bash
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# server-tools bootstrap / sync helper
# -----------------------------------------------------------------------------
#
# Ziel auf allen Geräten:
#   /opt/server-tools
#
# Einmalige Installation auf einem neuen Gerät:
#
#   curl -fsSL \
#     https://raw.githubusercontent.com/Sorcanius/server-tools/main/manage-server-tools.sh \
#     | sudo bash -s -- install
#
# Bereits vorhandene Installation hart mit GitHub synchronisieren:
#
#   bash /opt/server-tools/manage-server-tools.sh sync
#
# Automatik:
#   - installiert, wenn /opt/server-tools noch nicht vorhanden ist
#   - synchronisiert sonst hart mit GitHub
#
#   curl -fsSL \
#     https://raw.githubusercontent.com/Sorcanius/server-tools/main/manage-server-tools.sh \
#     | sudo bash -s -- auto
#
# WICHTIG:
# - GitHub ist die Quelle der Wahrheit.
# - Lokale Änderungen an versionierten Dateien werden bei "sync" verworfen.
# - Nicht ignorierte, unversionierte Dateien unter /opt/server-tools werden
#   bei "sync" gelöscht.
# - Lokale Konfigurationen, Credentials, Logs und Laufzeitdaten gehören NICHT
#   nach /opt/server-tools.
# -----------------------------------------------------------------------------

REPO_URL="${SERVER_TOOLS_REPO:-https://github.com/Sorcanius/server-tools.git}"
TARGET_DIR="${SERVER_TOOLS_DIR:-/opt/server-tools}"
REMOTE_NAME="${SERVER_TOOLS_REMOTE:-origin}"
REMOTE_BRANCH="${SERVER_TOOLS_BRANCH:-main}"

usage() {
    cat <<EOF
Verwendung:
  $0 install   Repository einmalig nach $TARGET_DIR klonen
  $0 sync      Lokalen Checkout hart mit GitHub synchronisieren
  $0 auto      Installieren, falls nicht vorhanden; sonst synchronisieren
  $0 status    Git-Status und aktuellen Commit anzeigen
  $0 help      Diese Hilfe anzeigen

Optionale Umgebungsvariablen:
  SERVER_TOOLS_REPO    Default: $REPO_URL
  SERVER_TOOLS_DIR     Default: $TARGET_DIR
  SERVER_TOOLS_REMOTE  Default: $REMOTE_NAME
  SERVER_TOOLS_BRANCH  Default: $REMOTE_BRANCH
  SERVER_TOOLS_OWNER   Besitzer bei "install"
                       Default: SUDO_USER bzw. aktueller Benutzer
EOF
}

require_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "FEHLER: Benötigter Befehl fehlt: $cmd" >&2
        exit 1
    }
}

default_install_owner() {
    if [[ -n "${SERVER_TOOLS_OWNER:-}" ]]; then
        printf '%s\n' "$SERVER_TOOLS_OWNER"
    elif (( EUID == 0 )) && [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        printf '%s\n' "$SUDO_USER"
    else
        id -un
    fi
}

repo_owner() {
    stat -c '%U' "$TARGET_DIR"
}

run_as_user() {
    local user="$1"
    shift

    if (( EUID == 0 )) && [[ "$user" != "root" ]]; then
        if command -v runuser >/dev/null 2>&1; then
            runuser -u "$user" -- "$@"
        elif command -v sudo >/dev/null 2>&1; then
            sudo -u "$user" -- "$@"
        else
            echo "FEHLER: Weder runuser noch sudo vorhanden." >&2
            exit 1
        fi
    else
        "$@"
    fi
}

mark_scripts_executable() {
    find "$TARGET_DIR" -maxdepth 1 -type f -name '*.sh' -exec chmod +x {} +
}

install_repo() {
    require_command git
    require_command stat
    require_command find

    if [[ -d "$TARGET_DIR/.git" ]]; then
        echo "ABBRUCH: $TARGET_DIR ist bereits ein Git-Repository."
        echo "Für ein Update:"
        echo "  bash $TARGET_DIR/manage-server-tools.sh sync"
        exit 1
    fi

    if [[ -e "$TARGET_DIR" ]] && [[ -n "$(ls -A "$TARGET_DIR" 2>/dev/null || true)" ]]; then
        echo "FEHLER: $TARGET_DIR existiert bereits und ist nicht leer." >&2
        exit 1
    fi

    if (( EUID != 0 )); then
        echo "FEHLER: Die Erstinstallation nach $TARGET_DIR benötigt Root-Rechte." >&2
        exit 1
    fi

    local owner group
    owner="$(default_install_owner)"
    id "$owner" >/dev/null 2>&1 || {
        echo "FEHLER: Benutzer '$owner' existiert nicht." >&2
        exit 1
    }
    group="$(id -gn "$owner")"

    echo "Installiere server-tools:"
    echo "  Repository : $REPO_URL"
    echo "  Ziel       : $TARGET_DIR"
    echo "  Besitzer   : $owner:$group"

    install -d -o "$owner" -g "$group" "$TARGET_DIR"
    run_as_user "$owner" git clone "$REPO_URL" "$TARGET_DIR"
    run_as_user "$owner" git -C "$TARGET_DIR" config pull.ff only
    mark_scripts_executable

    echo
    echo "FERTIG: $TARGET_DIR"
    echo "Später synchronisieren mit:"
    echo "  bash $TARGET_DIR/manage-server-tools.sh sync"
}

sync_repo() {
    require_command git
    require_command stat
    require_command find

    if [[ ! -d "$TARGET_DIR/.git" ]]; then
        echo "FEHLER: Kein Git-Repository unter $TARGET_DIR gefunden." >&2
        exit 1
    fi

    local owner current_user
    owner="$(repo_owner)"
    current_user="$(id -un)"

    if (( EUID != 0 )) && [[ "$current_user" != "$owner" ]]; then
        echo "FEHLER: $TARGET_DIR gehört '$owner', aktueller Benutzer ist '$current_user'." >&2
        echo "Sync als '$owner' oder über sudo ausführen." >&2
        exit 1
    fi

    echo "Synchronisiere $TARGET_DIR mit $REMOTE_NAME/$REMOTE_BRANCH ..."
    echo "Lokale Änderungen im Repository werden verworfen."

    run_as_user "$owner" git -C "$TARGET_DIR" fetch --prune "$REMOTE_NAME"
    run_as_user "$owner" git -C "$TARGET_DIR" reset --hard "$REMOTE_NAME/$REMOTE_BRANCH"

    # Löscht unversionierte, nicht ignorierte Dateien/Verzeichnisse.
    # Ignorierte Dateien werden absichtlich NICHT mit -x gelöscht.
    run_as_user "$owner" git -C "$TARGET_DIR" clean -fd

    mark_scripts_executable

    echo
    echo "FERTIG: server-tools ist synchron."
    run_as_user "$owner" git -C "$TARGET_DIR" log -1         --format='Commit: %h  %cd  %s' --date=iso-local
}

show_status() {
    require_command git
    require_command stat

    if [[ ! -d "$TARGET_DIR/.git" ]]; then
        echo "Kein Repository unter $TARGET_DIR."
        exit 1
    fi

    local owner
    owner="$(repo_owner)"

    echo "Repository: $TARGET_DIR"
    echo "Besitzer  : $owner"
    run_as_user "$owner" git -C "$TARGET_DIR" status --short --branch
    run_as_user "$owner" git -C "$TARGET_DIR" log -1         --format='Commit    : %h%nDatum     : %cd%nNachricht : %s' --date=iso-local
}

case "${1:-help}" in
    install) install_repo ;;
    sync)    sync_repo ;;
    auto)
        if [[ -d "$TARGET_DIR/.git" ]]; then
            sync_repo
        else
            install_repo
        fi
        ;;
    status)  show_status ;;
    help|-h|--help) usage ;;
    *)
        echo "FEHLER: Unbekannte Aktion: ${1:-}" >&2
        echo >&2
        usage >&2
        exit 2
        ;;
esac
