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
| `backup-dev-prod-personalprod.ps1` | One-Click-Export fuer die drei Ziel-Umgebungen `dev`, `prod` und `personalprod` (Apps + Solutions inkl. separater Canvas-App-Exports aus Solutions) | `pac` CLI | Strukturierter Laufordner je Zielumgebung, CSV-Log |
| `powerapps-interactive-menu.ps1` | Interaktive Menuefuehrung fuer sichtbare Environments, App-Liste, Details und selektiven Export | `pac` CLI | Selektiver Export als `.msapp` und optional Source-Extract, CSV-Log |
| `powerplatform-full-backup-gui.ps1` | GUI-Programm fuer lokalen Voll-Export: mehrere Environments auswaehlen, Zielordner waehlen und dann alle Canvas Apps + alle Solutions exportieren; Solution-Exporte sichern enthaltene Canvas Apps separat | PowerShell Windows Forms + `pac` CLI | Strukturierte Vollbackups pro Environment mit CSV-Log |
| `export-powerapps-solutions.ps1` | Gezielter Export von Loesungen aus einer Environment (inkl. enthaltener Komponenten wie Canvas Apps, Flows, Tabellen, etc.) | `pac` CLI | Solution ZIP(s) managed/unmanaged plus separate Canvas-App-Exports, CSV-Log |
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

### One-Click Export fuer dev, prod und personalprod

Dieses Skript exportiert automatisch Apps und Solutions fuer:

- `dev`: `bfe8bb76-9c0c-e4d8-b2da-0dedc51fdd50`
- `prod`: `a7ab9d07-3149-e35b-8c2d-a6701ac40342`
- `personalprod`: automatisch aus `pac env list` erkannt (oder per Parameter gesetzt)

Standardaufruf:

```powershell
.\backup-dev-prod-personalprod.ps1
```

Optional ohne Source-Extract:

```powershell
.\backup-dev-prod-personalprod.ps1 -SkipSourceExtract
```

Optional mit expliziter PersonalProd-ID:

```powershell
.\backup-dev-prod-personalprod.ps1 -PersonalProdEnvironmentId "<ENV-ID>"
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

### Lokales GUI Vollbackup (mehrere Environments per Klick)

Dieses Programm ist fuer den manuellen Start am eigenen PC gedacht.

Features:

- Sichtbare Environments laden und per Checkbox auswaehlen
- Zielordner per Dialog waehlen
- Zwei Bereiche: `Solutions` und `Apps`
- Inhalte pro Bereich fetchen und im GUI anzeigen
- Live-Filter pro Tab (Suche nach Name/Environment)
- Exportmodus `komplett` (alles Gefetchte) oder `individuell` (nur angehaktes)
- Live-Log im GUI sowie CSV-Log je Lauf

Wichtige Login-Buttons im GUI:

- `pac auth create` fuer Environment-/App-/Solution-Operationen

Start:

```powershell
.\powerplatform-full-backup-gui.ps1
```

### Power Automate Flows exportieren

```powershell
.\backup-all-powerautomate-flows.ps1 -EnvironmentId "<ENV-ID>" -RunLogin
```

### Loesungen gezielt exportieren (wichtig fuer App-Komponenten ausserhalb "Meine Apps")

Beispiel fuer eine konkrete Loesung:

```powershell
.\export-powerapps-solutions.ps1 -EnvironmentId "<ENV-ID>" -SolutionNames "OnOffboardingApp"
```

Managed und Unmanaged in einem Lauf:

```powershell
.\export-powerapps-solutions.ps1 -EnvironmentId "<ENV-ID>" -SolutionNames "OnOffboardingApp" -Managed -Unmanaged
```

Interaktive Auswahl aus den Loesungen der Environment:

```powershell
.\export-powerapps-solutions.ps1 -EnvironmentId "<ENV-ID>"
```

Nur Loesungen anzeigen (kein Export):

```powershell
.\export-powerapps-solutions.ps1 -EnvironmentId "<ENV-ID>" -ListOnly
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
- Solutions: `solution-export-YYYYMMDD-HHMMSS`
	- `zip/`
	- `apps/<solution>/msapp/`
	- `apps/<solution>/src/`
	- `export-log.csv`

- One-Click dev/prod/personalprod: `monthly-dev-prod-personalprod-YYYYMMDD-HHMMSS`
	- `dev/apps`, `dev/solutions`
	- `prod/apps`, `prod/solutions`
	- `personalprod/apps`, `personalprod/solutions`
	- Solution-Canvas-Apps liegen jeweils unter `apps/<solution>-<variant>/msapp/` und `apps/<solution>-<variant>/src/`
	- `export-log.csv`
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

## Detaillierte Setup-Anleitung

Fuer den lokalen GUI-Ansatz ist keine Azure-Runbook-Einrichtung notwendig.
