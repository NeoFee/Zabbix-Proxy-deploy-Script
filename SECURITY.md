# Sicherheitshinweise zum Zabbix-Proxy-Installations-Script

## Umgesetzte Maßnahmen

### 1. SQL-Injection (PostgreSQL)
- **Risiko:** Das DB-Kennwort wurde unescaped in `ALTER USER ... PASSWORD '...'` verwendet. Enthielt es ein einfaches Anführungszeichen (`'`), konnte die SQL-Anweisung manipuliert werden.
- **Maßnahme:** Kennwort-Escaping für SQL: `'` wird durch `''` ersetzt (`escape_password_for_sql`).

### 2. PostgreSQL-Benutzername
- **Risiko:** Beliebige Zeichen in `DB_USER` konnten zu Fehlverhalten oder Injection führen.
- **Maßnahme:** Validierung mit Regex: nur `[a-zA-Z_][a-zA-Z0-9_]*` erlaubt (`validate_db_user`).

### 3. Config-Werte (sed/Injection)
- **Risiko:** Benutzereingaben (Server, Hostname, Kennwort, PSK Identity etc.) werden per `sed` in Config-Dateien geschrieben. Sonderzeichen (`\`, `&`, `#`, `/`, Zeilenumbruch) konnten die sed-Ersetzung verfälschen.
- **Maßnahme:** Zentrale Escaping-Funktion `escape_config_value` für alle Werte, die in Config-Zeilen geschrieben werden.

### 4. PGPASSWORD in der Umgebung
- **Risiko:** `PGPASSWORD` bleibt nach dem Schema-Import in der Prozessumgebung und könnte in Prozesslisten sichtbar sein.
- **Maßnahme:** `unset PGPASSWORD` direkt nach dem Schema-Import.

### 5. Logging sensibler Daten
- **Bereits umgesetzt:** DB-Kennwort und PSK-Key werden nicht in die Log-Datei geschrieben (nur User, Hostname, Server, PSK Identity).

## Empfehlungen für den Betrieb

- Script nur aus vertrauenswürdigen Quellen verwenden und vor Ausführung prüfen.
- Log-Dateien (z. B. unter `logs/`) Zugriffsrechten entsprechend schützen.
- Nach der Installation: Berechtigungen der Config- und PSK-Dateien prüfen (z. B. nur root/zabbix lesbar).
- Starke Kennwörter und PSK-Keys verwenden; bei generiertem PSK den Key sicher notieren.
