param(
    [string]$OutputRoot = "backups",
    [ValidateSet("Public", "UsGov", "UsGovHigh", "UsGovDod", "China")]
    [string]$Cloud = "Public",
    [switch]$RunAuthCreate,
    [switch]$SkipSourceExtract,
    [bool]$ExportManagedSolutions = $true,
    [bool]$ExportUnmanagedSolutions = $true,
    [string]$PersonalProdEnvironmentId = ""
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

function Invoke-Pac {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $allOutput = & pac @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "pac $($Arguments -join ' ') failed with exit code $exitCode`n$($allOutput -join [Environment]::NewLine)"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = @($allOutput | ForEach-Object { if ($null -eq $_) { "" } else { $_.ToString() } })
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
        return "unnamed"
    }

    return $safe
}

function Get-UniquePath {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$BaseName,
        [string]$Extension = ""
    )

    $candidateName = if ([string]::IsNullOrWhiteSpace($Extension)) { $BaseName } else { "{0}{1}" -f $BaseName, $Extension }
    $candidate = Join-Path -Path $Directory -ChildPath $candidateName
    if (-not (Test-Path $candidate)) {
        return $candidate
    }

    $index = 2
    while ($true) {
        $candidateName = if ([string]::IsNullOrWhiteSpace($Extension)) { "{0}-{1}" -f $BaseName, $index } else { "{0}-{1}{2}" -f $BaseName, $index, $Extension }
        $candidate = Join-Path -Path $Directory -ChildPath $candidateName
        if (-not (Test-Path $candidate)) {
            return $candidate
        }

        $index++
    }
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
                IsActive       = ($regexMatch.Groups[1].Value -eq "*")
                DisplayName    = $regexMatch.Groups[2].Value.Trim()
                EnvironmentId  = $regexMatch.Groups[3].Value.Trim()
                EnvironmentUrl = $regexMatch.Groups[4].Value.Trim()
                UniqueName     = $regexMatch.Groups[5].Value.Trim()
            })
    }

    return $result.ToArray()
}

function Get-CanvasAppNames {
    param([Parameter(Mandatory = $true)][string]$EnvironmentId)

    $lines = @(Invoke-Pac -Arguments @("canvas", "list", "--environment", $EnvironmentId)).Output
    $names = New-Object System.Collections.Generic.List[string]

    foreach ($line in $lines) {
        $trimmed = $line.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed -match "^Verbunden als" -or $trimmed -match "^Connected as") { continue }
        if ($trimmed -match "^Name\s{2,}" -or $trimmed -match "^App Name\s{2,}") { continue }

        $parts = $trimmed -split "\s{2,}"
        if ($parts.Count -lt 1) { continue }

        $name = $parts[0].Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        if (-not $names.Contains($name)) {
            $names.Add($name)
        }
    }

    return $names.ToArray()
}

function Get-SolutionUniqueNames {
    param([Parameter(Mandatory = $true)][string]$EnvironmentId)

    $lines = @(Invoke-Pac -Arguments @("solution", "list", "--environment", $EnvironmentId)).Output
    $items = New-Object System.Collections.Generic.List[string]

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $trimmed = $line.Trim()
        if ($trimmed -match "^Verbunden als" -or $trimmed -match "^Connected as") { continue }
        if ($trimmed -match "^Verbunden mit" -or $trimmed -match "^Connected to") { continue }
        if ($trimmed -match "^Alle Loesungen" -or $trimmed -match "^Listing") { continue }
        if ($trimmed -match "^Eindeutiger Name" -or $trimmed -match "^Unique Name") { continue }
        if ($trimmed -match "^\d+\.\d+(\.\d+)?(\.\d+)?\s+(True|False)$") { continue }

        $parts = $line.TrimEnd() -split "\s{2,}"
        if ($parts.Count -eq 0) { continue }

        $candidate = $parts[0].Trim()
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if ($candidate -match "\s") { continue }

        if (-not $items.Contains($candidate)) {
            $items.Add($candidate)
        }
    }

    return $items.ToArray()
}

function Get-SolutionCanvasAppDefinitions {
    param([Parameter(Mandatory = $true)][string]$ZipPath)

    $tempRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("pp-solution-unpack-{0}" -f ([guid]::NewGuid().ToString("N")))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    try {
        Expand-Archive -Path $ZipPath -DestinationPath $tempRoot -Force

        $canvasAppsDir = Join-Path -Path $tempRoot -ChildPath "CanvasApps"
        if (-not (Test-Path $canvasAppsDir)) {
            return [pscustomobject]@{
                ExtractRoot = $tempRoot
                Apps        = @()
            }
        }

        $definitions = New-Object System.Collections.Generic.List[object]
        $identityFiles = @(Get-ChildItem -Path $canvasAppsDir -Filter "*_identity.json" -File -ErrorAction SilentlyContinue)

        foreach ($identityFile in $identityFiles) {
            $prefix = $identityFile.BaseName -replace '_AdditionalUris\d+_identity$',''
            if ([string]::IsNullOrWhiteSpace($prefix)) { continue }

            $msappPath = Join-Path -Path $canvasAppsDir -ChildPath ("{0}_DocumentUri.msapp" -f $prefix)
            if (-not (Test-Path $msappPath)) { continue }

            $appId = ""
            try {
                $identity = Get-Content -Path $identityFile.FullName -Raw | ConvertFrom-Json
                if ($null -ne $identity.PSObject.Properties["App"]) {
                    $appId = [string]$identity.App
                }
            }
            catch {
                Write-WarnMsg "Konnte Identity-Datei nicht lesen: $($identityFile.FullName)"
                continue
            }

            if ([string]::IsNullOrWhiteSpace($appId)) { continue }

            $definitions.Add([pscustomobject]@{
                    SolutionExtractRoot = $tempRoot
                    Prefix    = $prefix
                    AppId     = $appId
                    MsappPath = $msappPath
                })
        }

        return [pscustomobject]@{
            ExtractRoot = $tempRoot
            Apps        = $definitions.ToArray()
        }
    }
    catch {
        throw
    }
}

function Export-ContainedCanvasApps {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentId,
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$SolutionName,
        [Parameter(Mandatory = $true)][string]$VariantLabel,
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$SolutionRoot,
        [switch]$SkipSourceExtract,
        [Parameter(Mandatory = $true)]$Results
    )

    $safeSolution = Get-SafeFileName -Name $SolutionName
    $safeVariant = Get-SafeFileName -Name $VariantLabel
    $solutionAppsRoot = Join-Path -Path $SolutionRoot -ChildPath ("{0}-{1}" -f $safeSolution, $safeVariant)
    $msappDir = Join-Path -Path $solutionAppsRoot -ChildPath "msapp"
    $srcDir = Join-Path -Path $solutionAppsRoot -ChildPath "src"

    New-Item -ItemType Directory -Path $msappDir -Force | Out-Null
    if (-not $SkipSourceExtract) {
        New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
    }

    $canvasAppData = $null
    try {
        $canvasAppData = Get-SolutionCanvasAppDefinitions -ZipPath $ZipPath
        $canvasApps = @($canvasAppData.Apps)
    }
    catch {
        Write-WarnMsg "[$($EnvironmentName)] Canvas-App-Analyse aus Solution fehlgeschlagen: $SolutionName ($VariantLabel)"
        return
    }

    $solutionExtractRoot = $canvasAppData.ExtractRoot

    try {
    if ($canvasApps.Count -eq 0) {
        Write-Info "[$($EnvironmentName)] Keine Canvas Apps in der Loesung '$SolutionName' ($VariantLabel) gefunden."
        return
    }

    Write-Info "[$($EnvironmentName)] Exportiere $($canvasApps.Count) Canvas App(s) aus '$SolutionName' ($VariantLabel)"

    foreach ($canvasApp in $canvasApps) {
        $safeAppName = Get-SafeFileName -Name $canvasApp.Prefix
        $msappPath = Get-UniquePath -Directory $msappDir -BaseName $safeAppName -Extension ".msapp"
        $extractDir = Get-UniquePath -Directory $srcDir -BaseName $safeAppName -Extension ""

        $status = "Success"
        $errorMessage = ""

        try {
            Copy-Item -Path $canvasApp.MsappPath -Destination $msappPath -Force

            if (-not $SkipSourceExtract) {
                New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
                Invoke-Pac -Arguments @(
                    "canvas", "unpack",
                    "--msapp", $msappPath,
                    "--sources", $extractDir
                ) | Out-Null
            }
        }
        catch {
            $status = "Failed"
            $errorMessage = $_.Exception.Message
            Write-WarnMsg "[$($EnvironmentName)][Solutions] Canvas App Export fehlgeschlagen: $solutionName / $($canvasApp.Prefix)"
        }

        $Results.Add([pscustomobject]@{
                Timestamp     = (Get-Date).ToString("s")
                Environment   = $EnvironmentName
                EnvironmentId = $EnvironmentId
                AssetType     = "SolutionApps"
                Name          = $canvasApp.Prefix
                Variant       = "{0}/{1}" -f $SolutionName, $VariantLabel
                Path          = $msappPath
                Status        = $status
                Error         = $errorMessage
            })
    }
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($solutionExtractRoot) -and (Test-Path $solutionExtractRoot)) {
            Remove-Item -Path $solutionExtractRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
}

function Resolve-PersonalProdEnvironmentId {
    param([string]$ExplicitEnvironmentId)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitEnvironmentId)) {
        return $ExplicitEnvironmentId
    }

    $envLines = @(Invoke-Pac -Arguments @("env", "list")).Output
    $allEnvs = @(ConvertFrom-PacEnvironmentLines -Lines $envLines)

    $candidates = @($allEnvs | Where-Object {
            $_.DisplayName -match "(?i)personal\s*productivity|personal\s*prod|personalprod"
        })

    if ($candidates.Count -eq 0) {
        throw "Konnte PersonalProd nicht automatisch finden. Setze -PersonalProdEnvironmentId explizit."
    }

    $active = @($candidates | Where-Object { $_.IsActive })
    if ($active.Count -gt 0) {
        return $active[0].EnvironmentId
    }

    return $candidates[0].EnvironmentId
}

if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
    throw "Power Platform CLI (pac) wurde nicht in PATH gefunden."
}

if (-not $ExportManagedSolutions -and -not $ExportUnmanagedSolutions) {
    throw "Mindestens eine Solution-Variante muss aktiv sein: ExportManagedSolutions oder ExportUnmanagedSolutions."
}

$personalId = Resolve-PersonalProdEnvironmentId -ExplicitEnvironmentId $PersonalProdEnvironmentId

$targets = @(
    [pscustomobject]@{ Alias = "dev"; EnvironmentId = "bfe8bb76-9c0c-e4d8-b2da-0dedc51fdd50" },
    [pscustomobject]@{ Alias = "prod"; EnvironmentId = "a7ab9d07-3149-e35b-8c2d-a6701ac40342" },
    [pscustomobject]@{ Alias = "personalprod"; EnvironmentId = $personalId }
)

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runRoot = Join-Path -Path $OutputRoot -ChildPath "monthly-dev-prod-personalprod-$timestamp"
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null

$results = New-Object System.Collections.Generic.List[object]

Write-Info "Starte Export fuer $(($targets | ForEach-Object { $_.Alias }) -join ', ')"
Write-Info "Output: $runRoot"

foreach ($target in $targets) {
    $alias = $target.Alias
    $envId = $target.EnvironmentId
    $envRoot = Join-Path -Path $runRoot -ChildPath $alias

    Write-Info "[$alias] Environment: $envId"

    if ($RunAuthCreate) {
        Write-Info "[$alias] pac auth create"
        Invoke-Pac -Arguments @("auth", "create", "--cloud", $Cloud, "--environment", $envId) | Out-Null
    }

    # Apps
    $appsRoot = Join-Path -Path $envRoot -ChildPath "apps"
    $msappDir = Join-Path -Path $appsRoot -ChildPath "msapp"
    $srcDir = Join-Path -Path $appsRoot -ChildPath "src"
    New-Item -ItemType Directory -Path $msappDir -Force | Out-Null
    if (-not $SkipSourceExtract) {
        New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
    }

    $appNames = @(Get-CanvasAppNames -EnvironmentId $envId)
    Write-Info "[$alias] Apps gefunden: $($appNames.Count)"

    foreach ($appName in $appNames) {
        $safeName = Get-SafeFileName -Name $appName
        $msappPath = Get-UniquePath -Directory $msappDir -BaseName $safeName -Extension ".msapp"
        $extractDir = Join-Path -Path $srcDir -ChildPath $safeName

        $status = "Success"
        $errorMessage = ""
        try {
            Invoke-Pac -Arguments @(
                "canvas", "download",
                "--environment", $envId,
                "--name", $appName,
                "--file-name", $msappPath,
                "--overwrite"
            ) | Out-Null

            if (-not $SkipSourceExtract) {
                Invoke-Pac -Arguments @(
                    "canvas", "download",
                    "--environment", $envId,
                    "--name", $appName,
                    "--extract-to-directory", $extractDir,
                    "--overwrite"
                ) | Out-Null
            }
        }
        catch {
            $status = "Failed"
            $errorMessage = $_.Exception.Message
            Write-WarnMsg "[$alias][Apps] Export fehlgeschlagen: $appName"
        }

        $results.Add([pscustomobject]@{
                Timestamp     = (Get-Date).ToString("s")
                Environment   = $alias
                EnvironmentId = $envId
                AssetType     = "Apps"
                Name          = $appName
                Variant       = ""
                Path          = $msappPath
                Status        = $status
                Error         = $errorMessage
            })
    }

    # Solutions
    $solutionsRoot = Join-Path -Path $envRoot -ChildPath "solutions"
    New-Item -ItemType Directory -Path $solutionsRoot -Force | Out-Null

    $solutionNames = @(Get-SolutionUniqueNames -EnvironmentId $envId)
    Write-Info "[$alias] Solutions gefunden: $($solutionNames.Count)"

    foreach ($solutionName in $solutionNames) {
        $variants = New-Object System.Collections.Generic.List[object]
        if ($ExportUnmanagedSolutions) {
            $variants.Add([pscustomobject]@{ Label = "unmanaged"; ManagedValue = "false" })
        }
        if ($ExportManagedSolutions) {
            $variants.Add([pscustomobject]@{ Label = "managed"; ManagedValue = "true" })
        }

        foreach ($variant in $variants) {
            $safeSolution = Get-SafeFileName -Name $solutionName
            $zipPath = Join-Path -Path $solutionsRoot -ChildPath ("{0}-{1}.zip" -f $safeSolution, $variant.Label)

            $status = "Success"
            $errorMessage = ""
            try {
                Invoke-Pac -Arguments @(
                    "solution", "export",
                    "--environment", $envId,
                    "--name", $solutionName,
                    "--path", $zipPath,
                    "--managed", $variant.ManagedValue,
                    "--overwrite"
                ) | Out-Null

                $results.Add([pscustomobject]@{
                        Timestamp     = (Get-Date).ToString("s")
                        Environment   = $alias
                        EnvironmentId = $envId
                        AssetType     = "Solutions"
                        Name          = $solutionName
                        Variant       = $variant.Label
                        Path          = $zipPath
                        Status        = "Success"
                        Error         = ""
                    })

                try {
                    Export-ContainedCanvasApps -EnvironmentId $envId -EnvironmentName $alias -SolutionName $solutionName -VariantLabel $variant.Label -ZipPath $zipPath -SolutionRoot $solutionsRoot -SkipSourceExtract:$SkipSourceExtract -Results $results
                }
                catch {
                    Write-WarnMsg "[$alias][Solutions] Canvas-App-Nachziehung nicht abgeschlossen: $solutionName ($($variant.Label))"
                }
            }
            catch {
                $status = "Failed"
                $errorMessage = $_.Exception.Message
                Write-WarnMsg "[$alias][Solutions] Export fehlgeschlagen: $solutionName ($($variant.Label))"
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($solutionExtractRoot) -and (Test-Path $solutionExtractRoot)) {
        Remove-Item -Path $solutionExtractRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$logPath = Join-Path -Path $runRoot -ChildPath "export-log.csv"
$results | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8

$okCount = @($results | Where-Object { $_.Status -eq "Success" }).Count
$failCount = @($results | Where-Object { $_.Status -eq "Failed" }).Count

Write-Host ""
Write-Host "Export abgeschlossen." -ForegroundColor Green
Write-Host "Success: $okCount  Failed: $failCount"
Write-Host "Output: $runRoot"
Write-Host "Log: $logPath"

if ($failCount -gt 0) {
    exit 1
}
