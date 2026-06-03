param(
    [string]$OutputRoot = "backups",

    [ValidateSet("Public", "UsGov", "UsGovHigh", "UsGovDod", "China")]
    [string]$Cloud = "Public"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-WarnMsg {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-ErrMsg {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Invoke-Pac {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [switch]$AllowFailure
    )

    $allOutput = & pac @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "pac $($Arguments -join ' ') failed with exit code $exitCode`n$($allOutput -join [Environment]::NewLine)"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = @($allOutput | ForEach-Object { $_.ToString() })
    }
}

function Get-SafeFileName {
    param([Parameter(Mandatory = $true)][string]$Name)

    $invalidChars = [IO.Path]::GetInvalidFileNameChars()
    $safe = -join ($Name.ToCharArray() | ForEach-Object {
            if ($invalidChars -contains $_) { '_' } else { $_ }
        })

    $safe = $safe.Trim()
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return "unnamed-app"
    }

    return $safe
}

function ConvertFrom-PacEnvironmentLines {
    param([string[]]$Lines)

    $result = New-Object System.Collections.Generic.List[object]

    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match "^Verbunden als" -or $line -match "^Connected as") { continue }
        if ($line -match "Umgebungs-ID" -or $line -match "Environment ID") { continue }

        $regexMatch = [regex]::Match(
            $line,
            '^\s*(\*)?\s*(.+?)\s+([0-9a-fA-F-]{36})\s+(https?://\S+)\s+(\S+)\s*$'
        )

        if (-not $regexMatch.Success) { continue }

        $result.Add([pscustomobject]@{
                IsActive    = ($regexMatch.Groups[1].Value -eq "*")
                DisplayName = $regexMatch.Groups[2].Value.Trim()
                EnvironmentId = $regexMatch.Groups[3].Value.Trim()
                EnvironmentUrl = $regexMatch.Groups[4].Value.Trim()
                UniqueName  = $regexMatch.Groups[5].Value.Trim()
            })
    }

    return $result.ToArray()
}

function ConvertFrom-PacCanvasAppLines {
    param([string[]]$Lines)

    $result = New-Object System.Collections.Generic.List[object]

    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match "^Verbunden als" -or $line -match "^Connected as") { continue }
        if ($line -match "^Name\s{2,}" -or $line -match "^App Name\s{2,}") { continue }

        $parts = $line.TrimEnd() -split "\s{2,}"
        if ($parts.Count -lt 1) { continue }

        $name = $parts[0].Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $createdBy = if ($parts.Count -ge 2) { $parts[1].Trim() } else { "" }
        $modified = if ($parts.Count -ge 3) { $parts[2].Trim() } else { "" }

        $result.Add([pscustomobject]@{
                Name       = $name
                CreatedBy  = $createdBy
                ModifiedOn = $modified
            })
    }

    return $result.ToArray()
}

function Show-Environments {
    param([object[]]$Environments)

    if ($Environments.Count -eq 0) {
        Write-WarnMsg "Keine Environments gefunden."
        return
    }

    Write-Host ""
    Write-Host "Sichtbare Environments:" -ForegroundColor Green
    for ($i = 0; $i -lt $Environments.Count; $i++) {
        $env = $Environments[$i]
        $activeFlag = if ($env.IsActive) { "*" } else { " " }
        Write-Host ("[{0}] {1} {2}" -f ($i + 1), $activeFlag, $env.DisplayName)
        Write-Host ("     Id : {0}" -f $env.EnvironmentId)
        Write-Host ("     Url: {0}" -f $env.EnvironmentUrl)
    }
}

function Show-Apps {
    param([object[]]$Apps)

    if ($Apps.Count -eq 0) {
        Write-WarnMsg "Keine Canvas Apps gefunden."
        return
    }

    Write-Host ""
    Write-Host "Canvas Apps:" -ForegroundColor Green
    for ($i = 0; $i -lt $Apps.Count; $i++) {
        $app = $Apps[$i]
        Write-Host ("[{0}] {1}" -f ($i + 1), $app.Name)
        if (-not [string]::IsNullOrWhiteSpace($app.CreatedBy)) {
            Write-Host ("     Erstellt von: {0}" -f $app.CreatedBy)
        }
        if (-not [string]::IsNullOrWhiteSpace($app.ModifiedOn)) {
            Write-Host ("     Geaendert am: {0}" -f $app.ModifiedOn)
        }
    }
}

function Get-RunOutputPaths {
    param(
        [Parameter(Mandatory = $true)][string]$BaseOutputRoot,
        [switch]$IncludeSource
    )

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $runRoot = Join-Path -Path $BaseOutputRoot -ChildPath "canvas-menu-export-$timestamp"
    $msappDir = Join-Path -Path $runRoot -ChildPath "msapp"
    $srcDir = Join-Path -Path $runRoot -ChildPath "src"
    $logPath = Join-Path -Path $runRoot -ChildPath "backup-log.csv"

    New-Item -ItemType Directory -Path $msappDir -Force | Out-Null
    if ($IncludeSource) {
        New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
    }

    return [pscustomobject]@{
        RunRoot  = $runRoot
        MsappDir = $msappDir
        SrcDir   = $srcDir
        LogPath  = $logPath
    }
}

function Export-Apps {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentId,
        [Parameter(Mandatory = $true)][object[]]$Apps,
        [Parameter(Mandatory = $true)][int[]]$SelectedIndexes,
        [Parameter(Mandatory = $true)][string]$BaseOutputRoot,
        [switch]$IncludeSource
    )

    $selectedApps = New-Object System.Collections.Generic.List[object]
    foreach ($idx in $SelectedIndexes) {
        if ($idx -lt 0 -or $idx -ge $Apps.Count) {
            throw "Ungueltiger App-Index: $($idx + 1)"
        }

        $selectedApps.Add($Apps[$idx])
    }

    if ($selectedApps.Count -eq 0) {
        throw "Keine Apps fuer Export ausgewaehlt."
    }

    $paths = Get-RunOutputPaths -BaseOutputRoot $BaseOutputRoot -IncludeSource:$IncludeSource
    $results = New-Object System.Collections.Generic.List[object]
    $nameCounter = @{}

    for ($i = 0; $i -lt $selectedApps.Count; $i++) {
        $app = $selectedApps[$i]
        $appName = $app.Name

        $safeBase = Get-SafeFileName -Name $appName
        if ($nameCounter.ContainsKey($safeBase)) {
            $nameCounter[$safeBase]++
        }
        else {
            $nameCounter[$safeBase] = 1
        }

        $suffix = $nameCounter[$safeBase]
        $safeName = if ($suffix -gt 1) { "$safeBase-$suffix" } else { $safeBase }

        $msappPath = Join-Path -Path $paths.MsappDir -ChildPath "$safeName.msapp"
        $srcPath = Join-Path -Path $paths.SrcDir -ChildPath $safeName

        Write-Info "[$($i + 1)/$($selectedApps.Count)] Exportiere '$appName'"

        $status = "Success"
        $errorMessage = ""

        try {
            Invoke-Pac -Arguments @(
                "canvas", "download",
                "--environment", $EnvironmentId,
                "--name", $appName,
                "--file-name", $msappPath,
                "--overwrite"
            ) | Out-Null

            if ($IncludeSource) {
                Invoke-Pac -Arguments @(
                    "canvas", "download",
                    "--environment", $EnvironmentId,
                    "--name", $appName,
                    "--extract-to-directory", $srcPath,
                    "--overwrite"
                ) | Out-Null
            }
        }
        catch {
            $status = "Failed"
            $errorMessage = $_.Exception.Message
            Write-WarnMsg "Export fehlgeschlagen fuer '$appName'"
        }

        $results.Add([pscustomobject]@{
                Timestamp     = (Get-Date).ToString("s")
                EnvironmentId = $EnvironmentId
                AppName       = $appName
                MsappPath     = $msappPath
                SourcePath    = if ($IncludeSource) { $srcPath } else { "" }
                Status        = $status
                Error         = $errorMessage
            })
    }

    $results | Export-Csv -Path $paths.LogPath -NoTypeInformation -Encoding UTF8

    $okCount = ($results | Where-Object { $_.Status -eq "Success" }).Count
    $failCount = ($results | Where-Object { $_.Status -eq "Failed" }).Count

    Write-Host ""
    Write-Host "Export abgeschlossen." -ForegroundColor Green
    Write-Host "Success: $okCount  Failed: $failCount"
    Write-Host "Output: $($paths.RunRoot)"
    Write-Host "Log: $($paths.LogPath)"
}

function Resolve-SelectionToIndexes {
    param(
        [Parameter(Mandatory = $true)][string]$Selection,
        [Parameter(Mandatory = $true)][int]$MaxCount
    )

    $trimmed = $Selection.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return @()
    }

    if ($trimmed -eq "*") {
        return @(0..($MaxCount - 1))
    }

    $indexes = New-Object System.Collections.Generic.List[int]
    $tokens = $trimmed -split ","
    foreach ($token in $tokens) {
        $value = $token.Trim()
        if ([string]::IsNullOrWhiteSpace($value)) { continue }

        $number = 0
        if (-not [int]::TryParse($value, [ref]$number)) {
            throw "Ungueltige Auswahl '$value'. Nutze z. B. 1,3,5 oder *"
        }

        if ($number -lt 1 -or $number -gt $MaxCount) {
            throw "Auswahl '$value' liegt ausserhalb des gueltigen Bereichs 1..$MaxCount"
        }

        $zeroBased = $number - 1
        if (-not $indexes.Contains($zeroBased)) {
            $indexes.Add($zeroBased)
        }
    }

    return @($indexes)
}

if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
    throw "Power Platform CLI (pac) wurde nicht in PATH gefunden."
}

$environmentCache = @()
$appCache = @()
$selectedEnvironment = $null

while ($true) {
    Write-Host ""
    Write-Host "==============================================" -ForegroundColor DarkGray
    Write-Host " Power Apps Menu" -ForegroundColor Green
    Write-Host "==============================================" -ForegroundColor DarkGray

    if ($null -ne $selectedEnvironment) {
        Write-Host "Aktive Environment: $($selectedEnvironment.DisplayName)" -ForegroundColor Cyan
        Write-Host "EnvironmentId    : $($selectedEnvironment.EnvironmentId)" -ForegroundColor Cyan
    }
    else {
        Write-Host "Aktive Environment: (keine ausgewaehlt)" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "1) Login erneuern (pac auth create)"
    Write-Host "2) Environments laden und anzeigen"
    Write-Host "3) Environment auswaehlen"
    Write-Host "4) Apps der aktiven Environment laden"
    Write-Host "5) Apps anzeigen"
    Write-Host "6) App-Details lesen (eine App)"
    Write-Host "7) Exportieren: eine/mehrere Apps (.msapp)"
    Write-Host "8) Exportieren: eine/mehrere Apps (.msapp + Source)"
    Write-Host "9) Beenden"

    $choice = Read-Host "Bitte Auswahl eingeben"

    try {
        switch ($choice) {
            "1" {
                if ($null -ne $selectedEnvironment) {
                    Write-Info "Starte pac auth create fuer aktive Environment"
                    Invoke-Pac -Arguments @("auth", "create", "--cloud", $Cloud, "--environment", $selectedEnvironment.EnvironmentId) | Out-Null
                }
                else {
                    Write-Info "Starte pac auth create ohne vorbelegte Environment"
                    Invoke-Pac -Arguments @("auth", "create", "--cloud", $Cloud) | Out-Null
                }
                Write-Info "Login aktualisiert."
            }
            "2" {
                Write-Info "Lade sichtbare Environments"
                $envResult = Invoke-Pac -Arguments @("env", "list")
                $environmentCache = ConvertFrom-PacEnvironmentLines -Lines $envResult.Output
                Show-Environments -Environments $environmentCache
            }
            "3" {
                if ($environmentCache.Count -eq 0) {
                    Write-Info "Environment-Cache ist leer, lade zuerst Environments"
                    $envResult = Invoke-Pac -Arguments @("env", "list")
                    $environmentCache = ConvertFrom-PacEnvironmentLines -Lines $envResult.Output
                }

                Show-Environments -Environments $environmentCache
                if ($environmentCache.Count -eq 0) { break }

                $idxInput = Read-Host "Welche Environment-Nummer auswaehlen?"
                $idxNumber = 0
                if (-not [int]::TryParse($idxInput, [ref]$idxNumber)) {
                    throw "Ungueltige Eingabe '$idxInput'"
                }

                if ($idxNumber -lt 1 -or $idxNumber -gt $environmentCache.Count) {
                    throw "Auswahl ausserhalb des gueltigen Bereichs 1..$($environmentCache.Count)"
                }

                $selectedEnvironment = $environmentCache[$idxNumber - 1]
                $appCache = @()

                Write-Info "Ausgewaehlt: $($selectedEnvironment.DisplayName)"
            }
            "4" {
                if ($null -eq $selectedEnvironment) {
                    throw "Bitte zuerst eine Environment auswaehlen (Option 3)."
                }

                Write-Info "Lade Canvas Apps aus aktiver Environment"
                $appResult = Invoke-Pac -Arguments @("canvas", "list", "--environment", $selectedEnvironment.EnvironmentId)
                $appCache = ConvertFrom-PacCanvasAppLines -Lines $appResult.Output
                Show-Apps -Apps $appCache
            }
            "5" {
                Show-Apps -Apps $appCache
            }
            "6" {
                if ($appCache.Count -eq 0) {
                    throw "Keine Apps geladen. Erst Option 4 ausfuehren."
                }

                Show-Apps -Apps $appCache
                $appInput = Read-Host "Welche App-Nummer lesen?"
                $appNumber = 0
                if (-not [int]::TryParse($appInput, [ref]$appNumber)) {
                    throw "Ungueltige Eingabe '$appInput'"
                }

                if ($appNumber -lt 1 -or $appNumber -gt $appCache.Count) {
                    throw "Auswahl ausserhalb des gueltigen Bereichs 1..$($appCache.Count)"
                }

                $app = $appCache[$appNumber - 1]
                Write-Host ""
                Write-Host "App-Details" -ForegroundColor Green
                Write-Host "Name       : $($app.Name)"
                Write-Host "Erstellt von: $($app.CreatedBy)"
                Write-Host "Geaendert am: $($app.ModifiedOn)"
            }
            "7" {
                if ($null -eq $selectedEnvironment) {
                    throw "Bitte zuerst eine Environment auswaehlen (Option 3)."
                }
                if ($appCache.Count -eq 0) {
                    throw "Keine Apps geladen. Erst Option 4 ausfuehren."
                }

                Show-Apps -Apps $appCache
                $selection = Read-Host "Welche Apps exportieren? (z. B. 1,3,5 oder * fuer alle)"
                $indexes = Resolve-SelectionToIndexes -Selection $selection -MaxCount $appCache.Count

                Export-Apps -EnvironmentId $selectedEnvironment.EnvironmentId -Apps $appCache -SelectedIndexes $indexes -BaseOutputRoot $OutputRoot
            }
            "8" {
                if ($null -eq $selectedEnvironment) {
                    throw "Bitte zuerst eine Environment auswaehlen (Option 3)."
                }
                if ($appCache.Count -eq 0) {
                    throw "Keine Apps geladen. Erst Option 4 ausfuehren."
                }

                Show-Apps -Apps $appCache
                $selection = Read-Host "Welche Apps exportieren? (z. B. 1,3,5 oder * fuer alle)"
                $indexes = Resolve-SelectionToIndexes -Selection $selection -MaxCount $appCache.Count

                Export-Apps -EnvironmentId $selectedEnvironment.EnvironmentId -Apps $appCache -SelectedIndexes $indexes -BaseOutputRoot $OutputRoot -IncludeSource
            }
            "9" {
                Write-Info "Beende Menue."
                return
            }
            default {
                Write-WarnMsg "Unbekannte Auswahl '$choice'"
            }
        }
    }
    catch {
        Write-ErrMsg $_.Exception.Message
    }
}
