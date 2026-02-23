#!/bin/bash
#
# Zabbix Proxy Installations-Script
# Installiert Zabbix Proxy mit PostgreSQL und Zabbix Agent 2 auf Ubuntu/Debian und RHEL/Rocky/AlmaLinux
#
# Läuft als eingeloggter User (fordert sudo bei Bedarf an).
# Es wird kein separater Zabbix-Systemuser angelegt – nur der PostgreSQL-Datenbankuser.
# Der Zabbix-User wird von den Paketen erstellt; Proxy/Agent laufen als zabbix.
#

set -e

# === Konfiguration ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/install-zabbix-proxy_$(date +%Y%m%d_%H%M%S).log"
ZABBIX_VERSIONS=("7.0" "6.0" "5.0")
DB_NAME="zabbix_proxy"
PROXY_CONF="/etc/zabbix/zabbix_proxy.conf"
AGENT2_CONF="/etc/zabbix/zabbix_agent2.conf"
PROXY_PSK="/etc/zabbix/zabbix_proxy.psk"
AGENT2_PSK="/etc/zabbix/zabbix_agent2.psk"

# === Logging ===
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_cmd() {
    log "Ausführen: $*"
    "$@" 2>&1 || return 1
}

# === Voraussetzungen prüfen ===
# Script läuft als eingeloggter User; bei Bedarf wird sudo für privilegierte Befehle genutzt.
# Es wird kein separater Zabbix-Systemuser angelegt – nur der PostgreSQL-Datenbankuser.
check_privileges() {
    if [[ $EUID -ne 0 ]]; then
        echo "Script wird als aktueller User ($(whoami)) ausgeführt."
        echo "Für Paketinstallation wird sudo benötigt. Starte mit sudo neu..."
        exec sudo "$0" "${@}"
    fi
    # Beim Ausführen mit sudo: SUDO_USER = der eingeloggte User (für DB-User-Voreinstellung)
    RUN_AS_USER="${SUDO_USER:-$USER}"
    log "Privilegierte Befehle als root, Datenbank-User = ${RUN_AS_USER}"
}

# === Plattform-Erkennung ===
detect_platform() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
    else
        log "Fehler: /etc/os-release nicht gefunden. Unbekannte Plattform."
        exit 1
    fi

    case "${ID}" in
        ubuntu)
            if [[ "${VERSION_ID}" == "24.04" ]] || [[ "${VERSION_ID}" == "24.10" ]] || \
               [[ "${VERSION_ID}" == "25.04" ]] || [[ "${VERSION_ID}" =~ ^2[5-9]\. ]] || \
               [[ "${VERSION_ID}" == "22.04" ]] || [[ "${VERSION_ID}" == "20.04" ]]; then
                PLATFORM="debian"
                CODENAME="${VERSION_CODENAME:-noble}"
            else
                log "Fehler: Ubuntu ${VERSION_ID} wird nicht unterstützt. Bitte Ubuntu 24.04 LTS oder neuer verwenden."
                exit 1
            fi
            ;;
        debian)
            if [[ "${VERSION_ID}" == "11" ]] || [[ "${VERSION_ID}" == "12" ]] || [[ "${VERSION_ID}" =~ ^1[2-9]$ ]]; then
                PLATFORM="debian"
                CODENAME="${VERSION_CODENAME:-bookworm}"
            else
                log "Fehler: Debian ${VERSION_ID} wird nicht unterstützt."
                exit 1
            fi
            ;;
        rhel|rocky|almalinux)
            if [[ "${VERSION_ID}" == "8" ]] || [[ "${VERSION_ID}" == "9" ]] || [[ "${VERSION_ID}" =~ ^[89]\. ]]; then
                PLATFORM="rhel"
                RHEL_MAJOR="${VERSION_ID%%.*}"
            else
                log "Fehler: ${ID} ${VERSION_ID} wird nicht unterstützt."
                exit 1
            fi
            ;;
        *)
            log "Fehler: Unbekannte Distribution: ${ID}"
            exit 1
            ;;
    esac
    log "Plattform erkannt: ${ID} ${VERSION_ID} (${PLATFORM})"
}

# === Interaktive Abfragen ===
ask_version() {
    echo ""
    echo "Zabbix Version auswählen:"
    select ver in "${ZABBIX_VERSIONS[@]}"; do
        if [[ -n "${ver}" ]]; then
            ZABBIX_VERSION="${ver}"
            log "Gewählte Version: ${ZABBIX_VERSION}"
            break
        fi
    done
}

ask_zabbix_server() {
    echo ""
    read -rp "Zabbix Server Hostname oder IP: " ZABBIX_SERVER
    while [[ -z "${ZABBIX_SERVER}" ]]; do
        read -rp "Bitte Hostname eingeben (nicht leer): " ZABBIX_SERVER
    done
    log "Zabbix Server: ${ZABBIX_SERVER}"
}

ask_db_credentials() {
    echo ""
    read -rp "PostgreSQL Benutzername [${RUN_AS_USER}]: " DB_USER
    DB_USER="${DB_USER:-${RUN_AS_USER}}"

    read -rsp "PostgreSQL Kennwort: " DB_PASSWORD
    echo ""
    while [[ -z "${DB_PASSWORD}" ]]; do
        read -rsp "Bitte Kennwort eingeben (nicht leer): " DB_PASSWORD
        echo ""
    done
    log "PostgreSQL User: ${DB_USER}"
}

ask_psk() {
    echo ""
    read -rp "PSK-Verschlüsselung verwenden? (j/n) [n]: " USE_PSK
    USE_PSK="${USE_PSK:-n}"
    if [[ "${USE_PSK}" =~ ^[jJyY] ]]; then
        USE_PSK="yes"
        echo "  Optionen: 1) Key eingeben  2) Key generieren"
        read -rp "  Auswahl (1/2): " PSK_CHOICE
        if [[ "${PSK_CHOICE}" == "2" ]]; then
            PSK_KEY=$(openssl rand -hex 32)
            echo "  Generierter PSK-Key (bitte notieren): ${PSK_KEY}"
        else
            read -rsp "  PSK-Key (Hex, 32-512 Zeichen): " PSK_KEY
            echo ""
        fi
        read -rp "  PSK Identity: " PSK_IDENTITY
        while [[ -z "${PSK_IDENTITY}" ]]; do
            read -rp "  Bitte PSK Identity eingeben: " PSK_IDENTITY
        done
        log "PSK aktiviert, Identity: ${PSK_IDENTITY}"
    else
        USE_PSK="no"
    fi
}

# === Abhängigkeiten installieren ===
install_deps() {
    log "Installiere Abhängigkeiten..."
    if [[ "${PLATFORM}" == "debian" ]]; then
        apt-get update -qq
        apt-get install -y -qq curl gnupg ca-certificates
    else
        dnf install -y -q curl gnupg2
    fi
}

# === Zabbix Repo hinzufügen ===
add_zabbix_repo() {
    log "Füge Zabbix Repository hinzu..."
    if [[ "${PLATFORM}" == "debian" ]]; then
        curl -fsSL "https://repo.zabbix.com/zabbix-official-repo.key" | gpg --dearmor -o /usr/share/keyrings/zabbix-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/zabbix-archive-keyring.gpg] https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/ubuntu ${CODENAME} main" > /etc/apt/sources.list.d/zabbix.list
        apt-get update -qq
    else
        rpm -Uvh "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/rhel/${RHEL_MAJOR}/x86_64/zabbix-release-${ZABBIX_VERSION}-3.el${RHEL_MAJOR}.noarch.rpm" 2>/dev/null || true
        dnf clean all -q
    fi
}

# === PostgreSQL installieren ===
install_postgresql() {
    log "Installiere PostgreSQL..."
    if [[ "${PLATFORM}" == "debian" ]]; then
        apt-get install -y -qq postgresql postgresql-contrib
    else
        dnf install -y -q postgresql-server postgresql-contrib
        if command -v postgresql-setup &>/dev/null; then
            postgresql-setup --initdb 2>/dev/null || postgresql-setup initdb 2>/dev/null || true
        fi
    fi

    # PostgreSQL Service starten
    local pg_service="postgresql"
    if systemctl list-units --type=service | grep -q postgresql-; then
        pg_service=$(systemctl list-units --type=service --no-legend | grep postgresql | head -1 | awk '{print $1}')
    fi
    systemctl enable "${pg_service}"
    systemctl start "${pg_service}"
    log "PostgreSQL gestartet"
}

# === PostgreSQL User und DB anlegen ===
setup_postgresql_db() {
    log "Lege PostgreSQL User und Datenbank an..."
    sudo -u postgres createuser "${DB_USER}" 2>/dev/null || true
    sudo -u postgres psql -c "ALTER USER \"${DB_USER}\" WITH PASSWORD '${DB_PASSWORD}';" 2>/dev/null || true
    sudo -u postgres createdb -O "${DB_USER}" "${DB_NAME}" 2>/dev/null || true
    log "Datenbank ${DB_NAME} angelegt"
}

# === Zabbix Pakete installieren ===
install_zabbix() {
    log "Installiere Zabbix Proxy und Agent 2..."
    if [[ "${PLATFORM}" == "debian" ]]; then
        apt-get install -y -qq zabbix-proxy-pgsql zabbix-agent2 zabbix-sql-scripts
    else
        dnf install -y -q zabbix-proxy-pgsql zabbix-agent2 zabbix-sql-scripts
    fi
}

# === Schema importieren (Zabbix-Befehl) ===
import_schema() {
    log "Importiere Zabbix Proxy Schema..."
    local schema_imported=0

    if [[ -f "/usr/share/zabbix-sql-scripts/postgresql/proxy.sql.gz" ]]; then
        PGPASSWORD="${DB_PASSWORD}" zcat /usr/share/zabbix-sql-scripts/postgresql/proxy.sql.gz | psql -U "${DB_USER}" -h localhost -d "${DB_NAME}" -q
        schema_imported=1
    elif [[ -f "/usr/share/doc/zabbix-sql-scripts/postgresql/proxy.sql.gz" ]]; then
        PGPASSWORD="${DB_PASSWORD}" zcat /usr/share/doc/zabbix-sql-scripts/postgresql/proxy.sql.gz | psql -U "${DB_USER}" -h localhost -d "${DB_NAME}" -q
        schema_imported=1
    elif [[ -f "/usr/share/zabbix-sql-scripts/postgresql/proxy.sql" ]]; then
        PGPASSWORD="${DB_PASSWORD}" psql -U "${DB_USER}" -h localhost -d "${DB_NAME}" -q -f /usr/share/zabbix-sql-scripts/postgresql/proxy.sql
        schema_imported=1
    elif [[ -f "/usr/share/doc/zabbix-sql-scripts/postgresql/proxy.sql" ]]; then
        PGPASSWORD="${DB_PASSWORD}" psql -U "${DB_USER}" -h localhost -d "${DB_NAME}" -q -f /usr/share/doc/zabbix-sql-scripts/postgresql/proxy.sql
        schema_imported=1
    fi

    if [[ ${schema_imported} -eq 0 ]]; then
        log "Fehler: proxy.sql nicht gefunden!"
        exit 1
    fi
    log "Schema importiert"
}

# === Config-Parameter setzen (sed-safe) ===
set_config_param() {
    local file="$1"
    local param="$2"
    local value="$3"
    local escaped_value
    escaped_value=$(echo "${value}" | sed 's/[\/&]/\\&/g')

    if grep -q "^${param}=" "${file}" 2>/dev/null; then
        sed -i "s#^${param}=.*#${param}=${escaped_value}#" "${file}"
    elif grep -q "^#${param}=" "${file}" 2>/dev/null; then
        sed -i "s#^#${param}=.*#${param}=${escaped_value}#" "${file}"
    else
        echo "${param}=${value}" >> "${file}"
    fi
}

# === Proxy konfigurieren ===
configure_proxy() {
    log "Konfiguriere Zabbix Proxy..."
    [[ -f "${PROXY_CONF}.bak" ]] || cp "${PROXY_CONF}" "${PROXY_CONF}.bak"

    set_config_param "${PROXY_CONF}" "Server" "${ZABBIX_SERVER}"
    set_config_param "${PROXY_CONF}" "Hostname" "$(hostname)"
    set_config_param "${PROXY_CONF}" "DBName" "${DB_NAME}"
    set_config_param "${PROXY_CONF}" "DBUser" "${DB_USER}"
    set_config_param "${PROXY_CONF}" "DBPassword" "${DB_PASSWORD}"

    if [[ "${USE_PSK}" == "yes" ]]; then
        echo "${PSK_KEY}" > "${PROXY_PSK}"
        chown zabbix:zabbix "${PROXY_PSK}"
        chmod 640 "${PROXY_PSK}"
        set_config_param "${PROXY_CONF}" "TLSConnect" "psk"
        set_config_param "${PROXY_CONF}" "TLSPSKIdentity" "${PSK_IDENTITY}"
        set_config_param "${PROXY_CONF}" "TLSPSKFile" "${PROXY_PSK}"
    fi
}

# === Agent 2 konfigurieren ===
configure_agent2() {
    log "Konfiguriere Zabbix Agent 2..."
    [[ -f "${AGENT2_CONF}.bak" ]] || cp "${AGENT2_CONF}" "${AGENT2_CONF}.bak"

    set_config_param "${AGENT2_CONF}" "Server" "127.0.0.1"
    set_config_param "${AGENT2_CONF}" "ServerActive" "127.0.0.1:10051"
    set_config_param "${AGENT2_CONF}" "Hostname" "$(hostname)"

    if [[ "${USE_PSK}" == "yes" ]]; then
        echo "${PSK_KEY}" > "${AGENT2_PSK}"
        chown zabbix:zabbix "${AGENT2_PSK}"
        chmod 640 "${AGENT2_PSK}"
        set_config_param "${AGENT2_CONF}" "TLSConnect" "psk"
        set_config_param "${AGENT2_CONF}" "TLSAccept" "psk"
        set_config_param "${AGENT2_CONF}" "TLSPSKIdentity" "${PSK_IDENTITY}"
        set_config_param "${AGENT2_CONF}" "TLSPSKFile" "${AGENT2_PSK}"
    fi
}

# === Services starten ===
start_services() {
    log "Starte Services..."
    local pg_service="postgresql"
    if systemctl list-units --type=service 2>/dev/null | grep -q postgresql-; then
        pg_service=$(systemctl list-units --type=service --no-legend 2>/dev/null | grep postgresql | head -1 | awk '{print $1}' || echo "postgresql")
    fi

    systemctl enable "${pg_service}" zabbix-proxy zabbix-agent2
    systemctl restart zabbix-proxy zabbix-agent2

    sleep 2
    if systemctl is-active --quiet zabbix-proxy && systemctl is-active --quiet zabbix-agent2; then
        log "Zabbix Proxy und Agent 2 laufen erfolgreich."
    else
        log "Warnung: Bitte Service-Status prüfen: systemctl status zabbix-proxy zabbix-agent2"
    fi
}

# === Hauptablauf ===
main() {
    mkdir -p "${LOG_DIR}"
    exec > >(tee -a "${LOG_FILE}") 2>&1

    log "=== Zabbix Proxy Installation gestartet ==="
    check_privileges "$@"
    detect_platform
    install_deps

    ask_version
    add_zabbix_repo

    ask_zabbix_server
    ask_db_credentials
    ask_psk

    install_postgresql
    setup_postgresql_db
    install_zabbix
    import_schema
    configure_proxy
    configure_agent2
    start_services

    log "=== Installation abgeschlossen ==="
    log "Log-Datei: ${LOG_FILE}"
    echo ""
    echo "Installation erfolgreich! Log: ${LOG_FILE}"
}

main "$@"
