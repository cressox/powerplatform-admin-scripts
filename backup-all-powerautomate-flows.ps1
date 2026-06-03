param(
    [Parameter(Mandatory = $true)]
    [string]$EnvironmentId,

    [string]$OutputRoot = "backups",

    [string]$ApiVersion = "2016-11-01",

    [switch]$RunLogin,

    [switch]$IncludeDeleted
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

function Get-SafeFileName {
    param([Parameter(Mandatory = $true)][string]$Name)

    $invalidChars = [IO.Path]::GetInvalidFileNameChars()
    $safe = -join ($Name.ToCharArray() | ForEach-Object {
            if ($invalidChars -contains $_) { '_' } else { $_ }
        })

    $safe = $safe.Trim()
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return "unnamed-flow"
    }

    return $safe
}

function Get-FlowNameFromObject {
    param([Parameter(Mandatory = $true)]$Flow)

    if ($Flow.PSObject.Properties.Name -contains "FlowName" -and -not [string]::IsNullOrWhiteSpace($Flow.FlowName)) {
        return $Flow.FlowName
    }

    if ($Flow.PSObject.Properties.Name -contains "Name" -and -not [string]::IsNullOrWhiteSpace($Flow.Name)) {
        $match = [regex]::Match($Flow.Name, "/flows/([^/]+)$")
        if ($match.Success) {
            return $match.Groups[1].Value
        }
    }

    return $null
}

if (-not (Get-Command Add-PowerAppsAccount -ErrorAction SilentlyContinue)) {
    throw "Cmdlet 'Add-PowerAppsAccount' not found. Install/import Microsoft.PowerApps.Administration.PowerShell first."
}

if (-not (Get-Command Get-AdminFlow -ErrorAction SilentlyContinue)) {
    throw "Cmdlet 'Get-AdminFlow' not found. Install/import Microsoft.PowerApps.Administration.PowerShell first."
}

if (-not (Get-Command InvokeApi -ErrorAction SilentlyContinue)) {
    throw "Cmdlet 'InvokeApi' not found. Install/import Microsoft.PowerApps.Administration.PowerShell first."
}

if ($RunLogin) {
    Write-Info "Running Add-PowerAppsAccount login"
    Add-PowerAppsAccount | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runRoot = Join-Path -Path $OutputRoot -ChildPath "flow-backup-$timestamp"
$jsonDir = Join-Path -Path $runRoot -ChildPath "json"
$logPath = Join-Path -Path $runRoot -ChildPath "backup-log.csv"

New-Item -ItemType Directory -Path $jsonDir -Force | Out-Null

Write-Info "Listing flows from environment $EnvironmentId"
if ($IncludeDeleted) {
    $flows = @(Get-AdminFlow -EnvironmentName $EnvironmentId -IncludeDeleted $true -ApiVersion $ApiVersion)
}
else {
    $flows = @(Get-AdminFlow -EnvironmentName $EnvironmentId -ApiVersion $ApiVersion)
}

if ($flows.Count -eq 0) {
    throw "No flows were discovered. Check environment id, permissions, and authentication."
}

Write-Info "Discovered $($flows.Count) flows"

$results = New-Object System.Collections.Generic.List[object]
$nameCounter = @{}

for ($i = 0; $i -lt $flows.Count; $i++) {
    $flow = $flows[$i]

    $displayName = if (-not [string]::IsNullOrWhiteSpace($flow.DisplayName)) {
        $flow.DisplayName
    }
    else {
        "unnamed-flow"
    }

    $flowName = Get-FlowNameFromObject -Flow $flow
    if ([string]::IsNullOrWhiteSpace($flowName)) {
        Write-WarnMsg "[$($i + 1)/$($flows.Count)] Skipping '$displayName' because flow id could not be determined"
        $results.Add([pscustomobject]@{
                Timestamp     = (Get-Date).ToString("s")
                EnvironmentId = $EnvironmentId
                FlowName      = ""
                DisplayName   = $displayName
                JsonPath      = ""
                Status        = "Failed"
                Error         = "FlowName could not be resolved from Get-AdminFlow output."
            })
        continue
    }

    $safeBase = Get-SafeFileName -Name $displayName
    if ($nameCounter.ContainsKey($safeBase)) {
        $nameCounter[$safeBase]++
    }
    else {
        $nameCounter[$safeBase] = 1
    }

    $nameSuffix = $nameCounter[$safeBase]
    $safeName = if ($nameSuffix -gt 1) { "$safeBase-$nameSuffix" } else { $safeBase }

    $shortFlowId = if ($flowName.Length -gt 8) { $flowName.Substring(0, 8) } else { $flowName }
    $jsonPath = Join-Path -Path $jsonDir -ChildPath "$safeName-$shortFlowId.json"

    Write-Info "[$($i + 1)/$($flows.Count)] Exporting '$displayName'"

    $status = "Success"
    $errorMessage = ""

    try {
        # Uses the same endpoint shape as Get-AdminFlow but targets one specific flow.
        $route = "https://{flowEndpoint}/providers/Microsoft.ProcessSimple/scopes/admin/environments/$EnvironmentId/flows/$flowName?api-version=$ApiVersion"
        $flowDetail = InvokeApi -Method GET -Route $route -ApiVersion $ApiVersion -ThrowOnFailure

        $flowDetail | ConvertTo-Json -Depth 100 | Set-Content -Path $jsonPath -Encoding UTF8
    }
    catch {
        $status = "Failed"
        $errorMessage = $_.Exception.Message
        Write-WarnMsg "Export failed for '$displayName'"
    }

    $results.Add([pscustomobject]@{
            Timestamp     = (Get-Date).ToString("s")
            EnvironmentId = $EnvironmentId
            FlowName      = $flowName
            DisplayName   = $displayName
            JsonPath      = $jsonPath
            Status        = $status
            Error         = $errorMessage
        })
}

$results | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8

$okCount = ($results | Where-Object { $_.Status -eq "Success" }).Count
$failCount = ($results | Where-Object { $_.Status -eq "Failed" }).Count

Write-Host ""
Write-Host "Flow backup completed." -ForegroundColor Green
Write-Host "Success: $okCount  Failed: $failCount"
Write-Host "Output: $runRoot"
Write-Host "Log: $logPath"

if ($failCount -gt 0) {
    exit 1
}
