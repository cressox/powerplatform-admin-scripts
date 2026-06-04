param(
    [Parameter(Mandatory = $true)]
    [string]$EnvironmentId,

    [string[]]$SolutionNames,

    [string]$OutputRoot = "backups",

    [ValidateSet("Public", "UsGov", "UsGovHigh", "UsGovDod", "China")]
    [string]$Cloud = "Public",

    [switch]$RunAuthCreate,

    [switch]$Managed,

    [switch]$Unmanaged,

    [ValidateSet(
        "autonumbering",
        "calendar",
        "customization",
        "emailtracking",
        "externalapplications",
        "general",
        "isvconfig",
        "marketing",
        "outlooksynchronization",
        "relationshiproles",
        "sales"
    )]
    [string[]]$IncludeSettings,

    [switch]$ListOnly
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
        return "solution"
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
                    Prefix       = $prefix
                    AppId        = $appId
                    IdentityPath = $identityFile.FullName
                    MsappPath    = $msappPath
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
        [Parameter(Mandatory = $true)][string]$SolutionName,
        [Parameter(Mandatory = $true)][string]$VariantLabel,
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [switch]$SkipSourceExtract,
        [Parameter(Mandatory = $true)]$ExportedCanvasAppIds,
        [Parameter(Mandatory = $true)]$Results
    )

    $safeSolutionName = Get-SafeFileName -Name $SolutionName
    $appsRoot = Join-Path -Path $RunRoot -ChildPath "apps"
    $solutionAppsRoot = Join-Path -Path $appsRoot -ChildPath $safeSolutionName
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
        $Results.Add([pscustomobject]@{
                Timestamp     = (Get-Date).ToString("s")
                EnvironmentId = $EnvironmentId
                SolutionName  = $SolutionName
                Variant       = $VariantLabel
                AssetType     = "CanvasApp"
                ItemName      = ""
                ItemId        = ""
                Path          = ""
                SourcePath    = ""
                ZipPath       = $ZipPath
                Status        = "Failed"
                Error         = $_.Exception.Message
            })
        Write-WarnMsg "Canvas-App-Analyse aus Solution fehlgeschlagen fuer '$SolutionName' ($VariantLabel)"
        return
    }

    $solutionExtractRoot = $canvasAppData.ExtractRoot

    try {
        if ($canvasApps.Count -eq 0) {
            Write-Info "Keine Canvas Apps in der Loesung '$SolutionName' ($VariantLabel) gefunden."
            return
        }

        Write-Info "Exportiere $($canvasApps.Count) Canvas App(s) aus '$SolutionName' ($VariantLabel)"

        foreach ($canvasApp in $canvasApps) {
            if ($ExportedCanvasAppIds.Contains($canvasApp.AppId)) {
                continue
            }

            $ExportedCanvasAppIds.Add($canvasApp.AppId) | Out-Null

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
                Write-WarnMsg "Canvas App Export fehlgeschlagen fuer '$($canvasApp.Prefix)'"
            }

            $Results.Add([pscustomobject]@{
                    Timestamp     = (Get-Date).ToString("s")
                    EnvironmentId = $EnvironmentId
                    SolutionName  = $SolutionName
                    Variant       = $VariantLabel
                    AssetType     = "CanvasApp"
                    ItemName      = $canvasApp.Prefix
                    ItemId        = $canvasApp.AppId
                    Path          = $msappPath
                    SourcePath    = if ($SkipSourceExtract) { "" } else { $extractDir }
                    ZipPath       = $ZipPath
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
}

function Get-SolutionUniqueNames {
    param([AllowNull()][string[]]$Lines = @())

    $items = New-Object System.Collections.Generic.List[string]

    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $trimmed = $line.Trim()
        if ($trimmed -match "^Verbunden als" -or $trimmed -match "^Connected as") { continue }
        if ($trimmed -match "^Verbunden mit" -or $trimmed -match "^Connected to") { continue }
        if ($trimmed -match "^Alle Loesungen" -or $trimmed -match "^Listing") { continue }
        if ($trimmed -match "^Eindeutiger Name" -or $trimmed -match "^Unique Name") { continue }

        if ($trimmed -match "^\d+\.\d+(\.\d+)?(\.\d+)?\s+(True|False)$") {
            continue
        }

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

function Show-Solutions {
    param([Parameter(Mandatory = $true)][string[]]$Names)

    if ($Names.Count -eq 0) {
        Write-WarnMsg "Keine Loesungen gefunden."
        return
    }

    Write-Host ""
    Write-Host "Loesungen in Environment:" -ForegroundColor Green
    for ($i = 0; $i -lt $Names.Count; $i++) {
        Write-Host ("[{0}] {1}" -f ($i + 1), $Names[$i])
    }
}

function Resolve-ExportSelection {
    param(
        [string[]]$Available,
        [string[]]$Requested
    )

    if ($Requested -and $Requested.Count -gt 0) {
        return $Requested
    }

    Show-Solutions -Names $Available

    if ($Available.Count -eq 0) {
        return @()
    }

    $inputText = Read-Host "Welche Loesungen exportieren? (z. B. 1,3 oder * fuer alle)"
    $trimmed = $inputText.Trim()

    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return @()
    }

    if ($trimmed -eq "*") {
        return $Available
    }

    $selected = New-Object System.Collections.Generic.List[string]
    $tokens = $trimmed -split ","

    foreach ($token in $tokens) {
        $value = $token.Trim()
        if ([string]::IsNullOrWhiteSpace($value)) { continue }

        $index = 0
        if (-not [int]::TryParse($value, [ref]$index)) {
            throw "Ungueltige Auswahl '$value'. Nutze z. B. 1,3 oder *"
        }

        if ($index -lt 1 -or $index -gt $Available.Count) {
            throw "Auswahl '$value' liegt ausserhalb des gueltigen Bereichs 1..$($Available.Count)"
        }

        $solution = $Available[$index - 1]
        if (-not $selected.Contains($solution)) {
            $selected.Add($solution)
        }
    }

    return $selected.ToArray()
}

if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
    throw "Power Platform CLI (pac) wurde nicht in PATH gefunden."
}

if ($RunAuthCreate) {
    Write-Info "Running pac auth create for environment $EnvironmentId"
    Invoke-Pac -Arguments @("auth", "create", "--cloud", $Cloud, "--environment", $EnvironmentId) | Out-Null
}

if (-not $Managed -and -not $Unmanaged) {
    # Standard: unmanaged exportieren, weil das der uebliche ALM-Quellstand ist.
    $Unmanaged = $true
}

Write-Info "Lese Loesungen aus Environment $EnvironmentId"
$listResult = Invoke-Pac -Arguments @("solution", "list", "--environment", $EnvironmentId)
$normalizedLines = @($listResult.Output | ForEach-Object {
        if ($null -eq $_) { "" } else { $_.ToString() }
    })
$availableSolutions = @(Get-SolutionUniqueNames -Lines $normalizedLines)

if ($ListOnly) {
    Show-Solutions -Names $availableSolutions
    return
}

$solutionsToExport = @(Resolve-ExportSelection -Available $availableSolutions -Requested $SolutionNames)

if ($solutionsToExport.Count -eq 0) {
    throw "Keine Loesungen fuer den Export ausgewaehlt."
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runRoot = Join-Path -Path $OutputRoot -ChildPath "solution-export-$timestamp"
$zipDir = Join-Path -Path $runRoot -ChildPath "zip"
$appsDir = Join-Path -Path $runRoot -ChildPath "apps"
$logPath = Join-Path -Path $runRoot -ChildPath "export-log.csv"

New-Item -ItemType Directory -Path $zipDir -Force | Out-Null
New-Item -ItemType Directory -Path $appsDir -Force | Out-Null

$results = New-Object System.Collections.Generic.List[object]
$exportedCanvasAppIds = New-Object 'System.Collections.Generic.HashSet[string]'

foreach ($solutionName in $solutionsToExport) {
    $safeName = Get-SafeFileName -Name $solutionName

    $variants = New-Object System.Collections.Generic.List[object]
    if ($Unmanaged) {
        $variants.Add([pscustomobject]@{ Label = "unmanaged"; ManagedValue = "false" })
    }
    if ($Managed) {
        $variants.Add([pscustomobject]@{ Label = "managed"; ManagedValue = "true" })
    }

    foreach ($variant in $variants) {
        $fileName = "$safeName-$($variant.Label).zip"
        $zipPath = Join-Path -Path $zipDir -ChildPath $fileName

        Write-Info "Exportiere Loesung '$solutionName' als $($variant.Label)"

        $pacArgs = @(
            "solution", "export",
            "--environment", $EnvironmentId,
            "--name", $solutionName,
            "--path", $zipPath,
            "--managed", $variant.ManagedValue,
            "--overwrite"
        )

        if ($IncludeSettings -and $IncludeSettings.Count -gt 0) {
            $pacArgs += @("--include", ($IncludeSettings -join ","))
        }

        $status = "Success"
        $errorMessage = ""

        try {
            Invoke-Pac -Arguments $pacArgs | Out-Null
        }
        catch {
            $status = "Failed"
            $errorMessage = $_.Exception.Message
            Write-WarnMsg "Export fehlgeschlagen fuer '$solutionName' ($($variant.Label))"
        }

        $results.Add([pscustomobject]@{
                Timestamp      = (Get-Date).ToString("s")
                EnvironmentId  = $EnvironmentId
                SolutionName   = $solutionName
                Variant        = $variant.Label
                AssetType      = "SolutionZip"
                ItemName       = $solutionName
                ItemId         = ""
                Path           = $zipPath
                SourcePath     = ""
                ZipPath        = $zipPath
                Status         = $status
                Error          = $errorMessage
            })

        if ($status -eq "Success") {
            try {
                Export-ContainedCanvasApps -EnvironmentId $EnvironmentId -SolutionName $solutionName -VariantLabel $variant.Label -ZipPath $zipPath -RunRoot $runRoot -SkipSourceExtract:$SkipSourceExtract -ExportedCanvasAppIds $exportedCanvasAppIds -Results $results
            }
            catch {
                Write-WarnMsg "Canvas-App-Nachziehung nicht abgeschlossen fuer '$solutionName' ($($variant.Label))"
            }
        }
    }

}

$results | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8

$okCount = @($results | Where-Object { $_.Status -eq "Success" }).Count
$failCount = @($results | Where-Object { $_.Status -eq "Failed" }).Count

Write-Host ""
Write-Host "Solution export completed." -ForegroundColor Green
Write-Host "Success: $okCount  Failed: $failCount"
Write-Host "Output: $runRoot"
Write-Host "Log: $logPath"

if ($failCount -gt 0) {
    exit 1
}
