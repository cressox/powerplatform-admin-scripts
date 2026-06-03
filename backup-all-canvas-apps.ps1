param(
    [Parameter(Mandatory = $true)]
    [string]$EnvironmentId,

    [string]$OutputRoot = "backups",

    [ValidateSet("Public", "UsGov", "UsGovHigh", "UsGovDod", "China")]
    [string]$Cloud = "Public",

    [switch]$RunAuthCreate,

    [switch]$SkipSourceExtract
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
        Output   = $allOutput
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

if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
    throw "Power Platform CLI (pac) was not found in PATH."
}

if ($RunAuthCreate) {
    Write-Info "Running pac auth create for environment $EnvironmentId"
    Invoke-Pac -Arguments @("auth", "create", "--cloud", $Cloud, "--environment", $EnvironmentId) | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runRoot = Join-Path -Path $OutputRoot -ChildPath "canvas-backup-$timestamp"
$msappDir = Join-Path -Path $runRoot -ChildPath "msapp"
$srcDir = Join-Path -Path $runRoot -ChildPath "src"
$logPath = Join-Path -Path $runRoot -ChildPath "backup-log.csv"

New-Item -ItemType Directory -Path $msappDir -Force | Out-Null
if (-not $SkipSourceExtract) {
    New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
}

Write-Info "Listing canvas apps from environment $EnvironmentId"
$listResult = Invoke-Pac -Arguments @("canvas", "list", "--environment", $EnvironmentId)
$lines = $listResult.Output | ForEach-Object { $_.ToString() }

$appNames = New-Object System.Collections.Generic.List[string]

foreach ($line in $lines) {
    $trimmed = $line.TrimEnd()

    if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
    if ($trimmed -match "^Verbunden als") { continue }
    if ($trimmed -match "^Connected as") { continue }
    if ($trimmed -match "^Name\s{2,}") { continue }

    $parts = $trimmed -split "\s{2,}"
    if ($parts.Count -lt 2) { continue }

    $name = $parts[0].Trim()
    if (-not [string]::IsNullOrWhiteSpace($name)) {
        $appNames.Add($name)
    }
}

if ($appNames.Count -eq 0) {
    throw "No canvas apps were discovered. Check environment id and permissions."
}

Write-Info "Discovered $($appNames.Count) canvas apps"

$duplicateCheck = $appNames | Group-Object | Where-Object { $_.Count -gt 1 }
if ($duplicateCheck) {
    $dupNames = ($duplicateCheck | ForEach-Object { $_.Name }) -join ", "
    Write-WarnMsg "Duplicate app names found: $dupNames"
    Write-WarnMsg "pac canvas download uses app name or id. Duplicate names can lead to ambiguous exports."
}

$results = New-Object System.Collections.Generic.List[object]
$nameCounter = @{}

for ($i = 0; $i -lt $appNames.Count; $i++) {
    $appName = $appNames[$i]
    $safeBase = Get-SafeFileName -Name $appName

    if ($nameCounter.ContainsKey($safeBase)) {
        $nameCounter[$safeBase]++
    }
    else {
        $nameCounter[$safeBase] = 1
    }

    $nameSuffix = $nameCounter[$safeBase]
    $safeName = if ($nameSuffix -gt 1) { "$safeBase-$nameSuffix" } else { $safeBase }

    $msappPath = Join-Path -Path $msappDir -ChildPath "$safeName.msapp"
    $appSrcDir = Join-Path -Path $srcDir -ChildPath $safeName

    Write-Info "[$($i + 1)/$($appNames.Count)] Backing up '$appName'"

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

        if (-not $SkipSourceExtract) {
            Invoke-Pac -Arguments @(
                "canvas", "download",
                "--environment", $EnvironmentId,
                "--name", $appName,
                "--extract-to-directory", $appSrcDir,
                "--overwrite"
            ) | Out-Null
        }
    }
    catch {
        $status = "Failed"
        $errorMessage = $_.Exception.Message
        Write-WarnMsg "Backup failed for '$appName'"
    }

    $results.Add([pscustomobject]@{
            Timestamp      = (Get-Date).ToString("s")
            EnvironmentId  = $EnvironmentId
            AppName        = $appName
            MsappPath      = $msappPath
            SourcePath     = if ($SkipSourceExtract) { "" } else { $appSrcDir }
            Status         = $status
            Error          = $errorMessage
        })
}

$results | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8

$okCount = ($results | Where-Object { $_.Status -eq "Success" }).Count
$failCount = ($results | Where-Object { $_.Status -eq "Failed" }).Count

Write-Host ""
Write-Host "Backup completed." -ForegroundColor Green
Write-Host "Success: $okCount  Failed: $failCount"
Write-Host "Output: $runRoot"
Write-Host "Log: $logPath"

if ($failCount -gt 0) {
    exit 1
}
