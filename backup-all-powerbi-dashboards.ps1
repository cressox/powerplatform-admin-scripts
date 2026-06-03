param(
    [string]$OutputRoot = "backups",

    [ValidateSet("Individual", "Organization")]
    [string]$Scope = "Individual",

    [string]$WorkspaceId,

    [string]$WorkspaceName,

    [switch]$RunLogin,

    [string]$TenantId,

    [string]$ClientId,

    [string]$ClientSecret,

    [switch]$NoTiles
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
        return "unnamed"
    }

    return $safe
}

function Invoke-PbiRest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    $raw = Invoke-PowerBIRestMethod -Url $Url -Method Get
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return $raw | ConvertFrom-Json
}

$requiredCommands = @(
    "Connect-PowerBIServiceAccount",
    "Get-PowerBIWorkspace",
    "Invoke-PowerBIRestMethod"
)

foreach ($commandName in $requiredCommands) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "Cmdlet '$commandName' not found. Install/import MicrosoftPowerBIMgmt modules first."
    }
}

if ($RunLogin) {
    if (-not [string]::IsNullOrWhiteSpace($ClientId) -and -not [string]::IsNullOrWhiteSpace($ClientSecret) -and -not [string]::IsNullOrWhiteSpace($TenantId)) {
        Write-Info "Running service principal login with Connect-PowerBIServiceAccount"
        $secureSecret = ConvertTo-SecureString -String $ClientSecret -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($ClientId, $secureSecret)
        Connect-PowerBIServiceAccount -ServicePrincipal -Tenant $TenantId -Credential $credential | Out-Null
    }
    else {
        Write-Info "Running interactive login with Connect-PowerBIServiceAccount"
        Connect-PowerBIServiceAccount | Out-Null
    }
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runRoot = Join-Path -Path $OutputRoot -ChildPath "powerbi-dashboard-backup-$timestamp"
$jsonDir = Join-Path -Path $runRoot -ChildPath "json"
$logPath = Join-Path -Path $runRoot -ChildPath "backup-log.csv"

New-Item -ItemType Directory -Path $jsonDir -Force | Out-Null

Write-Info "Resolving target workspaces"
$workspaceQueryParams = @{
    Scope = $Scope
}

if ($Scope -eq "Organization") {
    $workspaceQueryParams["All"] = $true
}

if (-not [string]::IsNullOrWhiteSpace($WorkspaceId)) {
    $workspaces = @(Get-PowerBIWorkspace -Id $WorkspaceId -Scope $Scope)
}
else {
    $allWorkspaces = @(Get-PowerBIWorkspace @workspaceQueryParams)

    if (-not [string]::IsNullOrWhiteSpace($WorkspaceName)) {
        $workspaces = @($allWorkspaces | Where-Object { $_.Name -like $WorkspaceName })
    }
    else {
        $workspaces = $allWorkspaces
    }
}

if ($workspaces.Count -eq 0) {
    throw "No Power BI workspaces found with current filter and permissions."
}

Write-Info "Discovered $($workspaces.Count) workspaces"

$results = New-Object System.Collections.Generic.List[object]

for ($w = 0; $w -lt $workspaces.Count; $w++) {
    $workspace = $workspaces[$w]
    $workspaceIdResolved = $workspace.Id.ToString()
    $workspaceNameResolved = if ([string]::IsNullOrWhiteSpace($workspace.Name)) { "unnamed-workspace" } else { $workspace.Name }

    Write-Info "[$($w + 1)/$($workspaces.Count)] Reading dashboards from workspace '$workspaceNameResolved'"

    $dashboardsResponse = Invoke-PbiRest -Url "groups/$workspaceIdResolved/dashboards"
    $dashboards = @()
    if ($null -ne $dashboardsResponse -and $dashboardsResponse.PSObject.Properties.Name -contains "value") {
        $dashboards = @($dashboardsResponse.value)
    }

    if ($dashboards.Count -eq 0) {
        Write-WarnMsg "No dashboards found in workspace '$workspaceNameResolved'"
        continue
    }

    $nameCounter = @{}

    for ($d = 0; $d -lt $dashboards.Count; $d++) {
        $dashboard = $dashboards[$d]

        $dashboardId = $dashboard.id
        $dashboardDisplayName = if (-not [string]::IsNullOrWhiteSpace($dashboard.displayName)) {
            $dashboard.displayName
        }
        else {
            "unnamed-dashboard"
        }

        $safeBase = Get-SafeFileName -Name $dashboardDisplayName
        if ($nameCounter.ContainsKey($safeBase)) {
            $nameCounter[$safeBase]++
        }
        else {
            $nameCounter[$safeBase] = 1
        }

        $nameSuffix = $nameCounter[$safeBase]
        $safeName = if ($nameSuffix -gt 1) { "$safeBase-$nameSuffix" } else { $safeBase }

        $workspaceSafe = Get-SafeFileName -Name $workspaceNameResolved
        $shortDashboardId = if ($dashboardId.Length -gt 8) { $dashboardId.Substring(0, 8) } else { $dashboardId }
        $jsonPath = Join-Path -Path $jsonDir -ChildPath "$workspaceSafe-$safeName-$shortDashboardId.json"

        Write-Info "  [$($d + 1)/$($dashboards.Count)] Exporting dashboard '$dashboardDisplayName'"

        $status = "Success"
        $errorMessage = ""

        try {
            $dashboardDetail = Invoke-PbiRest -Url "groups/$workspaceIdResolved/dashboards/$dashboardId"
            $tiles = @()
            if (-not $NoTiles) {
                $tilesResponse = Invoke-PbiRest -Url "groups/$workspaceIdResolved/dashboards/$dashboardId/tiles"
                if ($null -ne $tilesResponse -and $tilesResponse.PSObject.Properties.Name -contains "value") {
                    $tiles = @($tilesResponse.value)
                }
            }

            $exportObject = [pscustomobject]@{
                ExportedAt    = (Get-Date).ToString("s")
                Workspace     = [pscustomobject]@{
                    Id   = $workspaceIdResolved
                    Name = $workspaceNameResolved
                }
                Dashboard     = $dashboardDetail
                Tiles         = $tiles
                ExportVersion = 1
            }

            $exportObject | ConvertTo-Json -Depth 100 | Set-Content -Path $jsonPath -Encoding UTF8
        }
        catch {
            $status = "Failed"
            $errorMessage = $_.Exception.Message
            Write-WarnMsg "Export failed for dashboard '$dashboardDisplayName'"
        }

        $results.Add([pscustomobject]@{
                Timestamp      = (Get-Date).ToString("s")
                WorkspaceId    = $workspaceIdResolved
                WorkspaceName  = $workspaceNameResolved
                DashboardId    = $dashboardId
                DashboardName  = $dashboardDisplayName
                JsonPath       = $jsonPath
                Status         = $status
                Error          = $errorMessage
            })
    }
}

$results | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8

$okCount = ($results | Where-Object { $_.Status -eq "Success" }).Count
$failCount = ($results | Where-Object { $_.Status -eq "Failed" }).Count

Write-Host ""
Write-Host "Power BI dashboard backup completed." -ForegroundColor Green
Write-Host "Success: $okCount  Failed: $failCount"
Write-Host "Output: $runRoot"
Write-Host "Log: $logPath"

if ($results.Count -eq 0) {
    Write-WarnMsg "No dashboard exports were executed."
    exit 2
}

if ($failCount -gt 0) {
    exit 1
}
