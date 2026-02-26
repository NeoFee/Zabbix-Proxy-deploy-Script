#!/usr/bin/env bash
#
# Zabbix Agent 2 Deploy-Skript (Linux)
# Installiert Zabbix Agent 2 im passiven, aktiven oder kombinierten Modus,
# inkl. optionaler SQL-Plugins und optionaler TLS/PSK-Verschlüsselung.
# Konfiguriert Server/Hostname/Modus/PSK, loggt jeden Schritt, startet und aktiviert den Dienst.
# Läuft unter dem Benutzer, der das Skript ausführt (kein neuer Benutzer).
#
set -euo pipefail

# Unterstützte Zabbix-Versionen (Agent 2); erste = Default (alle verfügbaren Repos)
readonly ZABBIX_VERSIONS="8.0 7.4 7.2 7.0 6.5 6.4 6.3 6.2 6.1 6.0"
ZABBIX_VERSION="8.0"
readonly CONFIG_FILE="/etc/zabbix/zabbix_agent2.conf"
readonly SERVICE_NAME="zabbix-agent2"
readonly SERVER_ACTIVE_PORT=10051
readonly REPO_BASE="https://repo.zabbix.com"
REPO_ZABBIX=""   # wird in select_zabbix_version gesetzt
readonly REPO_PLUGINS="${REPO_BASE}/zabbix-agent2-plugins"

# Logdatei: mit root unter /var/log, sonst im aktuellen Verzeichnis
if [[ -w /var/log ]]; then
  LOG_FILE="/var/log/zabbix-agent2-deploy.log"
else
  LOG_FILE="$(cd -- "$(dirname "$0")" && pwd)/zabbix-agent2-deploy.log"
fi

# Optionale Kommandozeilen-Argumente (für unbeaufsichtigte Ausführung)
ZABBIX_SERVER=""
ZABBIX_HOSTNAME=""
AGENT_MODE="passive"   # passive | active | both
MODE_FROM_CLI=false
VERSION_FROM_CLI=false
USE_PSK=false
PSK_FROM_CLI=false
PSK_GENERATE=false
PSK_IDENTITY=""
PSK_KEY=""
readonly PSK_FILE="/etc/zabbix/zabbix_agent2.psk"

while getopts "s:n:v:m:h" opt; do
  case "$opt" in
    s) ZABBIX_SERVER="$OPTARG" ;;
    n) ZABBIX_HOSTNAME="$OPTARG" ;;
    v) ZABBIX_VERSION="$OPTARG"; VERSION_FROM_CLI=true ;;
    m)
      AGENT_MODE="$OPTARG"
      MODE_FROM_CLI=true
      case "$AGENT_MODE" in
        passive|active|both) ;;
        *) die "Ungültiger Modus: $AGENT_MODE. Erlaubt: passive, active, both" ;;
      esac
      ;;
    h)
      echo "Verwendung: $0 [-s SERVER] [-n HOSTNAME] [-v VERSION] [-m MODUS] [--psk-generate] [--psk-identity ID] [--psk-key HEX]"
      echo "  -s SERVER   Zabbix-Server/Proxy-Adresse(n), kommagetrennt (sonst interaktive Eingabe)"
      echo "  -n HOSTNAME Hostname dieses Hosts (Default: hostname)"
      echo "  -v VERSION  Zabbix-Version (z.B. 8.0, 7.4, 7.0, 6.0; Default: 8.0)"
      echo "  -m MODUS    Agent-Modus: passive, active oder both (Default: passive)"
      echo "  --psk-generate    PSK automatisch erzeugen (unbeaufsichtigt)"
      echo "  --psk-identity ID  PSK-Identity (mit --psk-key für eigene Eingabe)"
      echo "  --psk-key HEX      PSK im Hex-Format (z.B. 64 Zeichen; mit --psk-identity)"
      exit 0
      ;;
    *) exit 1 ;;
  esac
done
shift $((OPTIND - 1))

# Lange Optionen für PSK parsen
while [[ $# -gt 0 ]]; do
  case "$1" in
    --psk-generate)
      USE_PSK=true
      PSK_FROM_CLI=true
      PSK_GENERATE=true
      shift
      ;;
    --psk-identity)
      USE_PSK=true
      PSK_FROM_CLI=true
      [[ -z "${2:-}" || "$2" == -* ]] && die "Fehler: --psk-identity erfordert einen Wert."
      PSK_IDENTITY="$2"
      shift 2
      ;;
    --psk-key)
      [[ -z "${2:-}" || "$2" == -* ]] && die "Fehler: --psk-key erfordert einen Wert."
      PSK_KEY="$2"
      shift 2
      ;;
    *)
      die "Unbekannte Option: $1"
      ;;
  esac
done
if [[ -n "$PSK_KEY" && -z "$PSK_IDENTITY" ]]; then
  die "Option --psk-key erfordert auch --psk-identity."
fi

# #region agent log
DEBUG_LOG="$(cd -- "$(dirname "$0")" 2>/dev/null && pwd)/debug-8ee17d.log"
debug_log() { local h="$1" l="$2" m="$3" d="${4:-{}}"; echo "{\"sessionId\":\"8ee17d\",\"location\":\"$l\",\"message\":\"$m\",\"data\":$d,\"timestamp\":$(($(date +%s)*1000)),\"hypothesisId\":\"$h\"}" >> "$DEBUG_LOG" 2>/dev/null || true; }
# #endregion

# Benutzer, unter dem der Dienst laufen soll (kein neuer Benutzer angelegt)
if [[ -n "${SUDO_USER:-}" ]]; then
  RUN_AS_USER="$SUDO_USER"
else
  RUN_AS_USER="$(whoami)"
fi
RUN_AS_GROUP="$(id -gn "$RUN_AS_USER" 2>/dev/null || echo "$RUN_AS_USER")"
# #region agent log
debug_log "D" "deploy-zabbix-agent2.sh:cli" "after getopts" "{\"ZABBIX_VERSION\":\"$ZABBIX_VERSION\",\"VERSION_FROM_CLI\":$VERSION_FROM_CLI,\"RUN_AS_USER\":\"$RUN_AS_USER\",\"RUN_AS_GROUP\":\"$RUN_AS_GROUP\"}"
# #endregion

log() {
  local level="${1:-INFO}"
  shift
  echo "$(date -Iseconds) [${level}] $*" | tee -a "$LOG_FILE"
}

log_error() {
  log "ERROR" "$@"
}

log_info() {
  log "INFO" "$@"
}

die() {
  # #region agent log
  debug_log "E" "deploy-zabbix-agent2.sh:die" "script exit" "{\"reason\":\"$*\"}"
  # #endregion
  log_error "$@"
  exit 1
}

# --- Root-Check ---
check_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "Dieses Skript muss mit root-Rechten ausgeführt werden (z.B. sudo $0)."
  fi
  log_info "Root-Check bestanden."
}

# --- OS-Erkennung ---
detect_os() {
  if [[ ! -f /etc/os-release ]]; then
    die "Betriebssystem kann nicht erkannt werden (/etc/os-release fehlt)."
  fi
  # shellcheck source=/dev/null
  source /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_VERSION_CODENAME="${VERSION_CODENAME:-}"
  OS_ID_LIKE="${ID_LIKE:-}"

  case "$OS_ID" in
    ubuntu|debian|raspbian)
      PKG_MGR="apt"
      if [[ "$OS_ID" == "ubuntu" ]]; then
        REPO_DIST="ubuntu"
        REPO_CODENAME="ubuntu${OS_VERSION_ID}"
      elif [[ "$OS_ID" == "raspbian" ]]; then
        REPO_DIST="raspbian"
        REPO_CODENAME="debian${OS_VERSION_ID%%.*}"
      else
        REPO_DIST="debian"
        REPO_CODENAME="debian${OS_VERSION_ID%%.*}"
      fi
      log_info "OS erkannt: $OS_ID ($PRETTY_NAME), Paketmanager: apt, Repo: $REPO_DIST ($REPO_CODENAME)."
      ;;
    rhel|centos|rocky|almalinux|ol|fedora)
      PKG_MGR="dnf"
      command -v dnf &>/dev/null || PKG_MGR="yum"
      case "$OS_ID" in
        rhel|fedora) REPO_EL_DIST="rhel" ;;
        centos)      REPO_EL_DIST="centos" ;;
        rocky)       REPO_EL_DIST="rocky" ;;
        almalinux)   REPO_EL_DIST="alma" ;;
        ol)          REPO_EL_DIST="oracle" ;;
        *)           REPO_EL_DIST="rhel" ;;
      esac
      if [[ "$OS_VERSION_ID" =~ ^7 ]]; then
        REPO_EL="7"
      elif [[ "$OS_VERSION_ID" =~ ^8 ]]; then
        REPO_EL="8"
      elif [[ "$OS_VERSION_ID" =~ ^9 ]]; then
        REPO_EL="9"
      elif [[ "$OS_VERSION_ID" =~ ^10 ]]; then
        REPO_EL="10"
      else
        REPO_EL="${OS_VERSION_ID%%.*}"
      fi
      if [[ "$OS_ID" == "fedora" ]]; then
        REPO_EL="${REPO_EL:-9}"
        if [[ "$REPO_EL" -lt 9 ]] 2>/dev/null; then REPO_EL="9"; fi
      else
        REPO_EL="${REPO_EL:-8}"
      fi
      log_info "OS erkannt: $OS_ID ($PRETTY_NAME), Paketmanager: $PKG_MGR, Repo: $REPO_EL_DIST/$REPO_EL."
      ;;
    amzn)
      PKG_MGR="dnf"
      command -v dnf &>/dev/null || PKG_MGR="yum"
      REPO_EL_DIST="amazonlinux"
      if [[ "$OS_VERSION_ID" == "2" ]] || [[ "$OS_VERSION_ID" =~ ^2\. ]]; then
        REPO_AMZN_VER="2"
      else
        REPO_AMZN_VER="${OS_VERSION_ID%%.*}"
      fi
      log_info "OS erkannt: $OS_ID ($PRETTY_NAME), Paketmanager: $PKG_MGR, Repo: amazonlinux/$REPO_AMZN_VER."
      ;;
    opensuse-leap|sles|suse)
      PKG_MGR="zypper"
      REPO_SLE_VERSION="${OS_VERSION_ID%%.*}"
      REPO_SLE_VERSION="${REPO_SLE_VERSION:-15}"
      log_info "OS erkannt: $OS_ID ($PRETTY_NAME), Paketmanager: zypper, Repo: sles/$REPO_SLE_VERSION."
      ;;
    *)
      die "Nicht unterstütztes Betriebssystem: ID=$OS_ID. Unterstützt: Debian, Ubuntu, Raspbian, RHEL, CentOS, Rocky, Alma, Oracle Linux, Amazon Linux, Fedora, openSUSE, SLES."
      ;;
  esac
  # #region agent log
  debug_log "B" "deploy-zabbix-agent2.sh:detect_os" "exit" "{\"OS_ID\":\"$OS_ID\",\"PKG_MGR\":\"$PKG_MGR\",\"REPO_DIST\":\"${REPO_DIST:-}\",\"REPO_EL\":\"${REPO_EL:-}\",\"REPO_EL_DIST\":\"${REPO_EL_DIST:-}\",\"REPO_CODENAME\":\"${REPO_CODENAME:-}\",\"REPO_AMZN_VER\":\"${REPO_AMZN_VER:-}\"}"
  # #endregion
}

# --- Zabbix-Version wählen (LTS/ältere Versionen) ---
select_zabbix_version() {
  # #region agent log
  debug_log "A" "deploy-zabbix-agent2.sh:select_zabbix_version" "entry" "{\"VERSION_FROM_CLI\":$VERSION_FROM_CLI,\"ZABBIX_VERSION\":\"$ZABBIX_VERSION\"}"
  # #endregion
  if [[ "$VERSION_FROM_CLI" == true ]]; then
    # Prüfen, ob Version unterstützt wird
    if [[ " $ZABBIX_VERSIONS " != *" $ZABBIX_VERSION "* ]]; then
      die "Nicht unterstützte Zabbix-Version: $ZABBIX_VERSION. Erlaubt: $ZABBIX_VERSIONS"
    fi
    log_info "Zabbix-Version (via -v): $ZABBIX_VERSION."
  else
    echo
    echo "Verfügbare Zabbix-Versionen (Agent 2):"
    echo "  1)  8.0 (Standard, aktuell)"
    echo "  2)  7.4"
    echo "  3)  7.2"
    echo "  4)  7.0 LTS"
    echo "  5)  6.5"
    echo "  6)  6.4"
    echo "  7)  6.3"
    echo "  8)  6.2"
    echo "  9)  6.1"
    echo " 10)  6.0 LTS"
    read -r -p "Auswahl [1]: " ver_choice
    ver_choice="${ver_choice:-1}"
    case "$ver_choice" in
      1)  ZABBIX_VERSION="8.0" ;;
      2)  ZABBIX_VERSION="7.4" ;;
      3)  ZABBIX_VERSION="7.2" ;;
      4)  ZABBIX_VERSION="7.0" ;;
      5)  ZABBIX_VERSION="6.5" ;;
      6)  ZABBIX_VERSION="6.4" ;;
      7)  ZABBIX_VERSION="6.3" ;;
      8)  ZABBIX_VERSION="6.2" ;;
      9)  ZABBIX_VERSION="6.1" ;;
      10) ZABBIX_VERSION="6.0" ;;
      *) die "Ungültige Auswahl: $ver_choice" ;;
    esac
    log_info "Zabbix-Version gewählt: $ZABBIX_VERSION."
  fi
  if [[ "$ZABBIX_VERSION" == "8.0" ]]; then
    REPO_ZABBIX="${REPO_BASE}/zabbix/${ZABBIX_VERSION}/release"
  elif [[ "$ZABBIX_VERSION" == "7.4" ]]; then
    REPO_ZABBIX="${REPO_BASE}/zabbix/${ZABBIX_VERSION}/stable"
  else
    REPO_ZABBIX="${REPO_BASE}/zabbix/${ZABBIX_VERSION}"
  fi
  # #region agent log
  debug_log "A" "deploy-zabbix-agent2.sh:select_zabbix_version" "exit" "{\"ZABBIX_VERSION\":\"$ZABBIX_VERSION\",\"REPO_ZABBIX\":\"$REPO_ZABBIX\"}"
  # #endregion
}

# --- Zabbix-Repo einrichten ---
setup_repo_debian() {
  log_info "Richte Zabbix-Repo für $REPO_DIST ein."
  local release_pkg release_url tmpdir
  tmpdir="$(mktemp -d)"
  release_pkg="zabbix-release_${ZABBIX_VERSION}-1+${REPO_CODENAME}_all.deb"
  release_url="${REPO_ZABBIX}/${REPO_DIST}/pool/main/z/zabbix-release/${release_pkg}"
  if ! curl -sSfL -o "${tmpdir}/${release_pkg}" "$release_url"; then
    if [[ "$ZABBIX_VERSION" == "8.0" ]]; then
      pkg_vers="-0.1"
      release_pkg="zabbix-release_${ZABBIX_VERSION}-0.1+${REPO_CODENAME}_all.deb"
      release_url="${REPO_ZABBIX}/${REPO_DIST}/pool/main/z/zabbix-release/${release_pkg}"
      if ! curl -sSfL -o "${tmpdir}/${release_pkg}" "$release_url"; then
        rm -rf "$tmpdir"
        die "Download des Repo-Pakets fehlgeschlagen: $release_url"
      fi
    elif [[ "$REPO_DIST" == "raspbian" ]]; then
      release_url="${REPO_ZABBIX}/debian/pool/main/z/zabbix-release/${release_pkg}"
      if ! curl -sSfL -o "${tmpdir}/${release_pkg}" "$release_url"; then
        rm -rf "$tmpdir"
        die "Download des Repo-Pakets fehlgeschlagen: $release_url"
      fi
      log_info "Raspbian: Debian-Repo verwendet (kein eigenes Raspbian-Repo für diese Version)."
    else
      rm -rf "$tmpdir"
      die "Download des Repo-Pakets fehlgeschlagen: $release_url"
    fi
  fi
  dpkg -i "${tmpdir}/${release_pkg}" || true
  apt-get update -qq
  rm -rf "$tmpdir"
  log_info "Zabbix-Repo eingerichtet."
}

setup_repo_rhel() {
  local repofile="/etc/yum.repos.d/zabbix.repo"
  local base_path el_repo plugins_el

  if [[ "${REPO_EL_DIST:-}" == "amazonlinux" ]]; then
    log_info "Richte Zabbix-Repo für Amazon Linux $REPO_AMZN_VER ein."
    base_path="${REPO_ZABBIX}/amazonlinux/${REPO_AMZN_VER}/\$basearch/"
    plugins_el="$([[ "$REPO_AMZN_VER" == "2" ]] && echo "7" || echo "9")"
  else
    if [[ "$REPO_ZABBIX" == *"/release"* || "$REPO_ZABBIX" == *"/stable"* ]]; then
      el_repo="${REPO_EL_DIST:-rhel}"
    else
      el_repo="rhel"
    fi
    log_info "Richte Zabbix-Repo für $el_repo $REPO_EL ein."
    base_path="${REPO_ZABBIX}/${el_repo}/${REPO_EL}/\$basearch/"
    plugins_el="$REPO_EL"
  fi

  cat > "$repofile" << EOF
[zabbix]
name=Zabbix Official Repository - \$basearch
baseurl=${base_path}
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-ZABBIX-A14FE591

[zabbix-agent2-plugins]
name=Zabbix Agent 2 Plugins - \$basearch
baseurl=${REPO_PLUGINS}/1/rhel/${plugins_el}/\$basearch/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-ZABBIX-A14FE591
EOF
  local keyfile="/etc/pki/rpm-gpg/RPM-GPG-KEY-ZABBIX-A14FE591"
  if [[ ! -f "$keyfile" ]]; then
    mkdir -p "$(dirname "$keyfile")"
    curl -sSfL -o "$keyfile" "https://repo.zabbix.com/RPM-GPG-KEY-ZABBIX-A14FE591" || true
  fi
  if [[ "$PKG_MGR" == "dnf" ]]; then
    dnf makecache -q
  else
    yum makecache -q
  fi
  log_info "Zabbix-Repo eingerichtet."
}

setup_repo_suse() {
  log_info "Richte Zabbix-Repo für SUSE $REPO_SLE_VERSION ein."
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|aarch64|ppc64le|s390x) ;;
    *) arch="x86_64" ;;
  esac
  zypper -q ar -G -f "${REPO_ZABBIX}/sles/${REPO_SLE_VERSION}/${arch}/" zabbix || true
  zypper -q ref
  log_info "Zabbix-Repo eingerichtet."
}

setup_repo() {
  case "$PKG_MGR" in
    apt)     setup_repo_debian ;;
    dnf|yum) setup_repo_rhel ;;
    zypper)  setup_repo_suse ;;
    *) die "Unbekannter Paketmanager: $PKG_MGR" ;;
  esac
}

# --- Zabbix Agent 2 installieren ---
install_agent() {
  log_info "Installiere Zabbix Agent 2."
  case "$PKG_MGR" in
    apt)
      apt-get install -y zabbix-agent2
      ;;
    dnf|yum)
      $PKG_MGR install -y zabbix-agent2
      ;;
    zypper)
      zypper -n in zabbix-agent2
      ;;
    *) die "Unbekannter Paketmanager: $PKG_MGR" ;;
  esac
  log_info "Zabbix Agent 2 installiert."
}

# --- SQL-Dienste prüfen und Plugins installieren ---
service_is_active() {
  systemctl is-active --quiet "$1" 2>/dev/null
}

install_sql_plugins() {
  log_info "Prüfe laufende SQL-Dienste."

  # MySQL/MariaDB
  local mysql_running=false
  for svc in mysql mariadb mysqld; do
    if systemctl list-unit-files --type=service --quiet "$svc.service" 2>/dev/null && service_is_active "$svc"; then
      mysql_running=true
      log_info "Laufenden MySQL/MariaDB-Dienst erkannt: $svc."
      break
    fi
  done
  if [[ "$mysql_running" == true ]]; then
    log_info "Installiere zabbix-agent2-plugin-mysql."
    case "$PKG_MGR" in
      apt)  apt-get install -y zabbix-agent2-plugin-mysql 2>/dev/null || log_info "Plugin mysql nicht verfügbar oder bereits installiert."
        ;;
      dnf|yum) $PKG_MGR install -y zabbix-agent2-plugin-mysql 2>/dev/null || log_info "Plugin mysql nicht verfügbar oder bereits installiert."
        ;;
      zypper) zypper -n in zabbix-agent2-plugin-mysql 2>/dev/null || log_info "Plugin mysql nicht verfügbar oder bereits installiert."
        ;;
    esac
  fi

  # PostgreSQL
  local pg_running=false
  if service_is_active "postgresql"; then
    pg_running=true
    log_info "Laufenden PostgreSQL-Dienst erkannt."
  else
    for u in $(systemctl list-units --type=service --no-legend --no-pager 2>/dev/null | awk '{print $1}' | grep -E '^postgresql(-[0-9]+)?\.service$'); do
      if service_is_active "${u%.service}"; then
        pg_running=true
        log_info "Laufenden PostgreSQL-Dienst erkannt: $u."
        break
      fi
    done
  fi
  if [[ "$pg_running" == true ]]; then
    log_info "Installiere zabbix-agent2-plugin-postgresql."
    case "$PKG_MGR" in
      apt)  apt-get install -y zabbix-agent2-plugin-postgresql 2>/dev/null || log_info "Plugin postgresql nicht verfügbar oder bereits installiert."
        ;;
      dnf|yum) $PKG_MGR install -y zabbix-agent2-plugin-postgresql 2>/dev/null || log_info "Plugin postgresql nicht verfügbar oder bereits installiert."
        ;;
      zypper) zypper -n in zabbix-agent2-plugin-postgresql 2>/dev/null || log_info "Plugin postgresql nicht verfügbar oder bereits installiert."
        ;;
    esac
  fi

  # MS SQL (Linux)
  if systemctl list-unit-files --type=service --quiet "mssql-server.service" 2>/dev/null && service_is_active "mssql-server"; then
    log_info "Laufenden MS-SQL-Dienst erkannt. Installiere zabbix-agent2-plugin-mssql."
    case "$PKG_MGR" in
      apt)  apt-get install -y zabbix-agent2-plugin-mssql 2>/dev/null || log_info "Plugin mssql nicht verfügbar oder bereits installiert."
        ;;
      dnf|yum) $PKG_MGR install -y zabbix-agent2-plugin-mssql 2>/dev/null || log_info "Plugin mssql nicht verfügbar oder bereits installiert."
        ;;
      zypper) zypper -n in zabbix-agent2-plugin-mssql 2>/dev/null || log_info "Plugin mssql nicht verfügbar oder bereits installiert."
        ;;
    esac
  fi

  log_info "SQL-Plugin-Prüfung abgeschlossen."
}

# --- Agent-Modus wählen (passiv / aktiv / beides) ---
read_agent_mode() {
  if [[ "$MODE_FROM_CLI" == true ]]; then
    log_info "Agent-Modus (via -m): $AGENT_MODE."
    return
  fi
  echo
  echo "Agent-Modus:"
  echo "  1) Nur passiv (Server fragt Agent ab)"
  echo "  2) Nur aktiv (Agent verbindet sich zum Server)"
  echo "  3) Beides (passiv und aktiv)"
  read -r -p "Auswahl [1]: " mode_choice
  mode_choice="${mode_choice:-1}"
  case "$mode_choice" in
    1) AGENT_MODE="passive" ;;
    2) AGENT_MODE="active" ;;
    3) AGENT_MODE="both" ;;
    *) die "Ungültige Auswahl: $mode_choice" ;;
  esac
  log_info "Agent-Modus gewählt: $AGENT_MODE."
}

# --- User-Eingabe Server / Hostname (oder aus -s/-n) ---
read_server_hostname() {
  if [[ -z "$ZABBIX_SERVER" ]]; then
    echo
    read -r -p "Zabbix-Server/Proxy-Adresse(n) für Server= (kommagetrennt): " ZABBIX_SERVER
    ZABBIX_SERVER="${ZABBIX_SERVER// /}"
  fi
  if [[ -z "$ZABBIX_SERVER" ]]; then
    die "Server-Adresse darf nicht leer sein."
  fi
  if [[ -z "$ZABBIX_HOSTNAME" ]]; then
    read -r -p "Hostname dieses Hosts für Hostname= [$(hostname)]: " ZABBIX_HOSTNAME
    ZABBIX_HOSTNAME="${ZABBIX_HOSTNAME:-$(hostname)}"
  fi
  log_info "Konfiguration: Server=$ZABBIX_SERVER, Hostname=$ZABBIX_HOSTNAME."
}

# --- Erreichbarkeit Port 10051 (Active) prüfen, bevor installiert wird ---
check_serveractive_reachable() {
  [[ "$AGENT_MODE" != "active" && "$AGENT_MODE" != "both" ]] && return 0
  log_info "Prüfe Erreichbarkeit von Proxy/Server auf Port ${SERVER_ACTIVE_PORT} (Active Checks) …"
  local reached=false
  local host
  local parts
  IFS=',' read -ra parts <<< "${ZABBIX_SERVER}"
  for part in "${parts[@]}"; do
    part="${part// /}"
    [[ -z "$part" ]] && continue
    if [[ "$part" == *:* ]]; then
      host="${part%%:*}"
    else
      host="$part"
    fi
    if timeout 3 bash -c "echo >/dev/tcp/${host}/${SERVER_ACTIVE_PORT}" 2>/dev/null; then
      log_info "Port ${SERVER_ACTIVE_PORT} auf ${host} erreichbar."
      reached=true
      break
    fi
    log_info "Port ${SERVER_ACTIVE_PORT} auf ${host} nicht erreichbar (Timeout)."
  done
  if [[ "$reached" != true ]]; then
    log_error "Proxy/Server für Active Checks (Port ${SERVER_ACTIVE_PORT}) nicht erreichbar."
    echo
    echo "Hinweis: Der Zabbix-Server/Proxy war auf Port ${SERVER_ACTIVE_PORT} nicht erreichbar."
    echo "Die Installation wird fortgesetzt. Bitte nach der Installation Netzwerk/Firewall prüfen,"
    echo "damit Active Checks funktionieren können."
    echo
  fi
}

# --- PSK einrichten (erzeugen oder selbst eingeben) ---
setup_psk() {
  if [[ "$PSK_FROM_CLI" == true ]]; then
    if [[ "$PSK_GENERATE" == true ]]; then
      PSK_IDENTITY="${PSK_IDENTITY:-zabbix-agent-${ZABBIX_HOSTNAME}}"
      PSK_KEY="$(openssl rand -hex 32)"
      echo "$PSK_KEY" > "$PSK_FILE"
      chmod 600 "$PSK_FILE"
      log_info "PSK erzeugt. Identity=$PSK_IDENTITY, Datei=$PSK_FILE. Bitte Identity und PSK im Zabbix-Frontend eintragen."
      echo "  Identity: $PSK_IDENTITY"
      echo "  PSK (Hex): $PSK_KEY"
      return
    fi
    if [[ -n "$PSK_IDENTITY" && -n "$PSK_KEY" ]]; then
      if [[ ! "$PSK_KEY" =~ ^[0-9a-fA-F]+$ ]] || [[ $((${#PSK_KEY} % 2)) -ne 0 ]]; then
        die "PSK muss eine gerade Anzahl Hex-Zeichen sein (z.B. 64 Zeichen)."
      fi
      echo "$PSK_KEY" > "$PSK_FILE"
      chmod 600 "$PSK_FILE"
      log_info "PSK aus CLI übernommen. Identity=$PSK_IDENTITY, Datei=$PSK_FILE."
      return
    fi
    if [[ -n "$PSK_IDENTITY" ]]; then
      read -r -p "PSK (Hex, z.B. 64 Zeichen): " PSK_KEY
      PSK_KEY="${PSK_KEY// /}"
      if [[ ! "$PSK_KEY" =~ ^[0-9a-fA-F]+$ ]] || [[ $((${#PSK_KEY} % 2)) -ne 0 ]]; then
        die "PSK muss eine gerade Anzahl Hex-Zeichen sein (z.B. 64 Zeichen)."
      fi
      echo "$PSK_KEY" > "$PSK_FILE"
      chmod 600 "$PSK_FILE"
      log_info "PSK eingetragen. Identity=$PSK_IDENTITY, Datei=$PSK_FILE."
      return
    fi
  fi

  echo
  read -r -p "TLS mit PSK verwenden? (j/n) [n]: " psk_use
  psk_use="${psk_use:-n}"
  if [[ "${psk_use,,}" != "j" && "${psk_use,,}" != "ja" ]]; then
    log_info "Kein PSK gewünscht."
    return
  fi
  USE_PSK=true

  echo "  1) PSK erzeugen (empfohlen)"
  echo "  2) PSK selbst eingeben"
  read -r -p "Auswahl [1]: " psk_choice
  psk_choice="${psk_choice:-1}"

  if [[ "$psk_choice" == "1" ]]; then
    PSK_IDENTITY="${PSK_IDENTITY:-zabbix-agent-${ZABBIX_HOSTNAME}}"
    read -r -p "PSK-Identity [${PSK_IDENTITY}]: " psk_id_in
    [[ -n "$psk_id_in" ]] && PSK_IDENTITY="$psk_id_in"
    PSK_KEY="$(openssl rand -hex 32)"
    echo "$PSK_KEY" > "$PSK_FILE"
    chmod 600 "$PSK_FILE"
    log_info "PSK erzeugt. Identity=$PSK_IDENTITY, Datei=$PSK_FILE."
    echo
    echo "Bitte im Zabbix-Frontend beim Host unter 'Verschlüsselung' eintragen:"
    echo "  Verbindung: PSK"
    echo "  PSK-Identity: $PSK_IDENTITY"
    echo "  PSK: $PSK_KEY"
    echo
  else
    read -r -p "PSK-Identity: " PSK_IDENTITY
    [[ -z "$PSK_IDENTITY" ]] && die "PSK-Identity darf nicht leer sein."
    read -r -p "PSK (Hex, z.B. 64 Zeichen): " PSK_KEY
    PSK_KEY="${PSK_KEY// /}"
    if [[ ! "$PSK_KEY" =~ ^[0-9a-fA-F]+$ ]] || [[ $((${#PSK_KEY} % 2)) -ne 0 ]]; then
      die "PSK muss eine gerade Anzahl Hex-Zeichen sein (z.B. 64 Zeichen)."
    fi
    echo "$PSK_KEY" > "$PSK_FILE"
    chmod 600 "$PSK_FILE"
    log_info "PSK eingetragen. Identity=$PSK_IDENTITY, Datei=$PSK_FILE."
  fi
}

# --- Config anpassen (Modus aktiv/passiv, optional PSK) ---
configure_agent() {
  log_info "Passe Agent-Config an (Modus: $AGENT_MODE)."
  # #region agent log
  _cfg_exist=0; _cfg_writable=0; [[ -f "$CONFIG_FILE" ]] && _cfg_exist=1; [[ -w "$CONFIG_FILE" ]] && _cfg_writable=1
  debug_log "C" "deploy-zabbix-agent2.sh:configure_agent" "before config write" "{\"CONFIG_FILE\":\"$CONFIG_FILE\",\"exists\":$_cfg_exist,\"writable\":$_cfg_writable}"
  # #endregion
  if [[ ! -f "$CONFIG_FILE" ]]; then
    die "Config-Datei nicht gefunden: $CONFIG_FILE"
  fi
  cp -a "$CONFIG_FILE" "${CONFIG_FILE}.bak"
  log_info "Backup erstellt: ${CONFIG_FILE}.bak"

  # ServerActive: bei passivem Modus nie setzen; bei aktiv/beides setzen
  sed -i '/^[[:space:]]*#*[[:space:]]*ServerActive[[:space:]]*=/d' "$CONFIG_FILE"

  if [[ "$AGENT_MODE" == "active" || "$AGENT_MODE" == "both" ]]; then
    # ServerActive-Wert mit Port 10051 pro Adresse erzeugen (ohne Port → :10051 anhängen)
    ZABBIX_SERVER_ACTIVE=""
    IFS=',' read -ra parts <<< "${ZABBIX_SERVER}"
    for h in "${parts[@]}"; do
      h="${h// /}"
      [[ -z "$h" ]] && continue
      if [[ "$h" == *:* ]]; then
        seg="$h"
      else
        seg="${h}:${SERVER_ACTIVE_PORT}"
      fi
      if [[ -n "$ZABBIX_SERVER_ACTIVE" ]]; then
        ZABBIX_SERVER_ACTIVE="$ZABBIX_SERVER_ACTIVE,$seg"
      else
        ZABBIX_SERVER_ACTIVE="$seg"
      fi
    done
    [[ -z "$ZABBIX_SERVER_ACTIVE" ]] && ZABBIX_SERVER_ACTIVE="${ZABBIX_SERVER}:${SERVER_ACTIVE_PORT}"

    echo "ServerActive=${ZABBIX_SERVER_ACTIVE}" >> "$CONFIG_FILE"
    log_info "ServerActive=${ZABBIX_SERVER_ACTIVE} gesetzt ($AGENT_MODE)."
  else
    # Passiver Modus: sicherstellen, dass keine ServerActive-Zeile in der Config steht
    sed -i '/^[[:space:]]*#*[[:space:]]*ServerActive[[:space:]]*=/d' "$CONFIG_FILE"
    log_info "ServerActive nicht konfiguriert (passiver Modus)."
  fi

  # Server= setzen
  if grep -qE '^Server=' "$CONFIG_FILE"; then
    sed -i "s|^Server=.*|Server=${ZABBIX_SERVER}|" "$CONFIG_FILE"
  else
    echo "Server=${ZABBIX_SERVER}" >> "$CONFIG_FILE"
  fi

  # Hostname= setzen
  if grep -qE '^Hostname=' "$CONFIG_FILE"; then
    sed -i "s|^Hostname=.*|Hostname=${ZABBIX_HOSTNAME}|" "$CONFIG_FILE"
  else
    echo "Hostname=${ZABBIX_HOSTNAME}" >> "$CONFIG_FILE"
  fi

  # TLS/PSK: vorhandene Zeilen entfernen, bei USE_PSK neu setzen
  for key in TLSConnect TLSAccept TLSPSKIdentity TLSPSKFile; do
    if grep -qE "^#*${key}=" "$CONFIG_FILE"; then
      sed -i "/^#*${key}=/d" "$CONFIG_FILE"
    fi
  done
  if [[ "$USE_PSK" == true ]]; then
    echo "TLSConnect=psk" >> "$CONFIG_FILE"
    echo "TLSAccept=psk" >> "$CONFIG_FILE"
    echo "TLSPSKIdentity=${PSK_IDENTITY}" >> "$CONFIG_FILE"
    echo "TLSPSKFile=${PSK_FILE}" >> "$CONFIG_FILE"
    log_info "TLS/PSK konfiguriert: Identity=$PSK_IDENTITY."
  fi

  log_info "Config angepasst: Server=${ZABBIX_SERVER}, Hostname=${ZABBIX_HOSTNAME}, Modus=$AGENT_MODE."
}

# --- Dienst unter Run-As-Benutzer und Berechtigungen ---
configure_service_user() {
  log_info "Konfiguriere Dienst für Benutzer: $RUN_AS_USER (kein neuer Benutzer angelegt)."
  local dropin_dir="/etc/systemd/system/${SERVICE_NAME}.service.d"
  mkdir -p "$dropin_dir"
  cat > "${dropin_dir}/run-as-user.conf" << EOF
[Service]
User=${RUN_AS_USER}
Group=${RUN_AS_GROUP}
RuntimeDirectory=zabbix
RuntimeDirectoryMode=0750
EOF
  log_info "Systemd-Drop-in erstellt: ${dropin_dir}/run-as-user.conf"

  # PID/Runtime-Verzeichnis /run/zabbix anlegen und dem Run-As-Benutzer geben (Agent schreibt zabbix_agent2.pid)
  mkdir -p /run/zabbix
  chown "${RUN_AS_USER}:${RUN_AS_GROUP}" /run/zabbix 2>/dev/null || true
  chmod 750 /run/zabbix 2>/dev/null || true

  # Berechtigungen: Config, PSK-Datei und typische Verzeichnisse dem Run-As-Benutzer geben
  for path in "$CONFIG_FILE" /etc/zabbix /var/log/zabbix; do
    if [[ -e "$path" ]]; then
      chown -R "${RUN_AS_USER}:${RUN_AS_GROUP}" "$path" 2>/dev/null || true
    fi
  done
  if [[ "$USE_PSK" == true && -f "$PSK_FILE" ]]; then
    chown "${RUN_AS_USER}:${RUN_AS_GROUP}" "$PSK_FILE" 2>/dev/null || true
  fi
  log_info "Dienst wird unter Benutzer $RUN_AS_USER ausgeführt."
}

# --- Prüfen, ob der Run-As-Benutzer alle benötigten Rechte hat ---
run_as_user() {
  if command -v runuser &>/dev/null; then
    runuser -u "$RUN_AS_USER" -- "$@"
  else
    sudo -u "$RUN_AS_USER" "$@"
  fi
}

check_run_as_permissions() {
  log_info "Prüfe Berechtigungen für Benutzer: $RUN_AS_USER."
  local err=0

  if ! id -u "$RUN_AS_USER" &>/dev/null; then
    log_error "Benutzer $RUN_AS_USER existiert nicht."
    err=1
  fi

  if [[ -f "$CONFIG_FILE" ]]; then
    if ! run_as_user test -r "$CONFIG_FILE" 2>/dev/null; then
      log_error "Benutzer $RUN_AS_USER kann die Config-Datei nicht lesen: $CONFIG_FILE"
      err=1
    fi
  fi

  if [[ "$USE_PSK" == true && -f "$PSK_FILE" ]]; then
    if ! run_as_user test -r "$PSK_FILE" 2>/dev/null; then
      log_error "Benutzer $RUN_AS_USER kann die PSK-Datei nicht lesen: $PSK_FILE"
      err=1
    fi
  fi

  if [[ -d /var/log/zabbix ]]; then
    if ! run_as_user test -w /var/log/zabbix 2>/dev/null; then
      log_error "Benutzer $RUN_AS_USER kann nicht in /var/log/zabbix schreiben."
      err=1
    fi
  fi

  if [[ -d /run/zabbix ]]; then
    if ! run_as_user test -w /run/zabbix 2>/dev/null; then
      log_error "Benutzer $RUN_AS_USER kann nicht in /run/zabbix schreiben (PID-Datei)."
      err=1
    fi
  fi

  local agent_bin
  agent_bin="$(command -v zabbix_agent2 2>/dev/null)" || true
  [[ -z "$agent_bin" ]] && agent_bin="/usr/sbin/zabbix_agent2"
  if [[ -e "$agent_bin" ]]; then
    if ! run_as_user test -r "$agent_bin" 2>/dev/null; then
      log_error "Benutzer $RUN_AS_USER kann die Agent-Binary nicht lesen/ausführen: $agent_bin"
      err=1
    fi
  fi

  if [[ $err -ne 0 ]]; then
    die "Berechtigungsprüfung fehlgeschlagen. Bitte Eigentümer/Berechtigungen anpassen (z. B. chown $RUN_AS_USER:$RUN_AS_GROUP $CONFIG_FILE /etc/zabbix /var/log/zabbix /run/zabbix)."
  fi
  log_info "Berechtigungsprüfung für $RUN_AS_USER bestanden."
}

# --- Agent starten und aktivieren ---
start_and_enable() {
  log_info "Starte und aktiviere Zabbix Agent 2."
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  if ! systemctl start "$SERVICE_NAME"; then
    log_error "Start von $SERVICE_NAME fehlgeschlagen."
    systemctl status "$SERVICE_NAME" || true
    exit 1
  fi
  systemctl status "$SERVICE_NAME" --no-pager || true
  log_info "Zabbix Agent 2 läuft und ist aktiviert."
}

# --- Hauptablauf ---
main() {
  log_info "=== Zabbix Agent 2 Deploy gestartet ==="
  check_root
  detect_os
  select_zabbix_version
  setup_repo
  read_agent_mode
  read_server_hostname
  check_serveractive_reachable
  install_agent
  install_sql_plugins
  setup_psk
  configure_agent
  configure_service_user
  check_run_as_permissions
  start_and_enable
  log_info "=== Zabbix Agent 2 Deploy erfolgreich beendet. Log: $LOG_FILE ==="
}

main "$@"
