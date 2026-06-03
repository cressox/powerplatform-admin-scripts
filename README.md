# powerplatform-admin-scripts

Praktische, produktionsnahe PowerShell-Skripte fuer Power Platform und Power BI Backup- und Admin-Aufgaben.

## Ziel des Repos

- Wiederkehrende Aufgaben standardisieren
- Exporte nachvollziehbar und reproduzierbar machen
- Betrieb durch klare Parameter und Logs absichern

## Enthaltene Skripte

| Skript | Zweck | Technologie | Output |
|---|---|---|---|
| `backup-all-canvas-apps.ps1` | Export aller Canvas Apps einer Environment | `pac` CLI | `.msapp`, optional Source-Extract, CSV-Log |
| `powerapps-interactive-menu.ps1` | Interaktive Menuefuehrung fuer sichtbare Environments, App-Liste, Details und selektiven Export | `pac` CLI | Selektiver Export als `.msapp` und optional Source-Extract, CSV-Log |
| `backup-all-powerautomate-flows.ps1` | Export aller Power Automate Flows einer Environment | PowerApps Admin PowerShell | JSON je Flow, CSV-Log |
| `backup-all-powerbi-dashboards.ps1` | Export von Power BI Dashboard-Metadaten aus Workspaces in der Cloud | MicrosoftPowerBIMgmt + REST | JSON je Dashboard (inkl. Tiles), CSV-Log |

## Voraussetzungen

### 1) Canvas Apps

- Power Platform CLI (`pac`) installiert und in `PATH`
- Berechtigung auf die Ziel-Environment

### 2) Power Automate Flows

- Modul `Microsoft.PowerApps.Administration.PowerShell`
- Berechtigung als Environment Admin (oder hoeher)

### 3) Power BI Dashboards

- Module `MicrosoftPowerBIMgmt.Profile` und `MicrosoftPowerBIMgmt.Workspaces`
- Bei `-Scope Organization`: Power BI Admin-Berechtigung

Empfohlene Installation:

```powershell
Install-Module Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser
Install-Module MicrosoftPowerBIMgmt -Scope CurrentUser
```

## Schnellstart

### Canvas Apps exportieren

```powershell
.\backup-all-canvas-apps.ps1 -EnvironmentId "<ENV-ID>" -RunAuthCreate
```

### Interaktive PowerApps-Menuefuehrung

```powershell
.\powerapps-interactive-menu.ps1
```

Optional mit abweichendem Zielpfad:

```powershell
.\powerapps-interactive-menu.ps1 -OutputRoot "D:\PowerPlatformBackups"
```

Ablauf im Menue:

- Login fuer das aktuelle Profil aktualisieren
- Sichtbare Environments laden und auswaehlen
- Canvas Apps der gewaehlten Environment laden
- Details einzelner Apps anzeigen
- Gezielten Export ausfuehren (einzeln, mehrfach oder alle)
- Optional zusaetzlich Source-Extract exportieren

Menueoptionen im Skript:

- `1` Login erneuern (`pac auth create`)
- `2` Environments laden und anzeigen
- `3` Environment auswaehlen
- `4` Apps der aktiven Environment laden
- `5` Geladene Apps anzeigen
- `6` App-Details lesen
- `7` Export als `.msapp`
- `8` Export als `.msapp` plus Source-Extract
- `9` Menue beenden

### Power Automate Flows exportieren

```powershell
.\backup-all-powerautomate-flows.ps1 -EnvironmentId "<ENV-ID>" -RunLogin
```

### Power BI Dashboards exportieren (Interactive Login)

```powershell
.\backup-all-powerbi-dashboards.ps1 -RunLogin -Scope Organization
```

Nur Dashboard-Metadaten ohne Tiles exportieren:

```powershell
.\backup-all-powerbi-dashboards.ps1 -RunLogin -Scope Organization -NoTiles
```

### Power BI Dashboards exportieren (Service Principal)

```powershell
.\backup-all-powerbi-dashboards.ps1 \
	-RunLogin \
	-Scope Organization \
	-TenantId "<TENANT-ID>" \
	-ClientId "<APP-ID>" \
	-ClientSecret "<CLIENT-SECRET>"
```

## Output-Struktur

Standard-Ausgabeverzeichnis ist `backups`.

- Canvas: `canvas-backup-YYYYMMDD-HHMMSS`
	- `msapp/`
	- `src/` (optional)
	- `backup-log.csv`
- Flows: `flow-backup-YYYYMMDD-HHMMSS`
	- `json/`
	- `backup-log.csv`
- Power BI Dashboards: `powerbi-dashboard-backup-YYYYMMDD-HHMMSS`
	- `json/`
	- `backup-log.csv`

## Betriebs- und Sicherheits-Hinweise

- Alle Skripte laufen mit `Set-StrictMode -Version Latest` und brechen bei Fehlern sauber ab.
- Exit Code `1` signalisiert partielle oder komplette Exportfehler.
- Das Power BI Dashboard-Skript exportiert Dashboard-Metadaten (kein PBIX-Report-Export).
- Fuer Automatisierung wird die Ablage von Secrets im Klartext nicht empfohlen; nutze stattdessen Secret Store, Key Vault oder CI/CD Secret Variables.

## Geplante Erweiterungen

- Optionale Archivierung (ZIP) pro Lauf
- Optionales Upload-Target (z. B. Azure Storage)
- Optionales Delta-Export-Verhalten
