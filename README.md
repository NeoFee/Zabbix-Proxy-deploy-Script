# Zabbix Proxy Deploy Script

Automatisches Installations-Script für Zabbix Proxy mit PostgreSQL und Zabbix Agent 2 auf Linux.

## Unterstützte Plattformen

- **Ubuntu** 24.04 LTS und aufwärts (24.04, 24.10, 25.04, …)
- **Debian** 11+
- **RHEL / Rocky / AlmaLinux** 8 und 9

## Voraussetzungen

- Sudo-Rechte (für Paketinstallation)
- Internetverbindung für Paket-Downloads

## Verwendung

```bash
bash install-zabbix-proxy.sh
```

Das Script wird als eingeloggter User ausgeführt und fordert bei Bedarf sudo an. Es wird **kein separater Zabbix-Systemuser** angelegt – nur der PostgreSQL-Datenbankuser.

Das Script führt interaktiv durch:

1. **Zabbix Version** (7.0, 6.0, 5.0)
2. **Zabbix Server Hostname** – Hostname oder IP des Zabbix Servers
3. **PostgreSQL Benutzername** – Standard: eingeloggter User
4. **PostgreSQL Kennwort**
5. **PSK-Verschlüsselung** (optional) – für verschlüsselte Verbindung zum Zabbix Server

## Installierte Komponenten

- PostgreSQL (Datenbank)
- Zabbix Proxy (mit PostgreSQL)
- Zabbix Agent 2
- Automatische Konfiguration von Proxy und Agent

## Log-Datei

Die Installation wird in **`/var/log/zabbix-proxy-install/install-zabbix-proxy_YYYYMMDD_HHMMSS.log`** protokolliert. Falls das Script dort nicht schreiben kann, wird `/tmp/zabbix-proxy-install/` verwendet. Keine Passwörter oder PSK-Keys werden geloggt.

## Nach der Installation

1. Proxy im Zabbix Frontend unter **Administration → Proxies** anlegen
2. Hostname des Proxys muss mit dem konfigurierten `Hostname` übereinstimmen
3. Bei PSK: gleichen PSK-Key und Identity im Frontend eintragen

## Projektstruktur

```
Zabbix-Proxy-deploy-Script/
├── install-zabbix-proxy.sh   # Hauptscript
├── config/                   # Optionale Templates
├── logs/                     # Log-Dateien
└── README.md
```
