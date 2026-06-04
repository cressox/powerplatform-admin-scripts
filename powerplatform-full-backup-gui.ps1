param(
    [string]$DefaultOutputRoot = "backups"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Write-LogLine {
    param(
        [System.Windows.Forms.TextBox]$LogBox,
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogBox.AppendText("[$timestamp] $Message" + [Environment]::NewLine)
    $LogBox.SelectionStart = $LogBox.TextLength
    $LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Invoke-Pac {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & pac @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw "pac $($Arguments -join ' ') failed with exit code $exitCode`n$($output -join [Environment]::NewLine)"
    }

    return @($output | ForEach-Object { if ($null -eq $_) { "" } else { $_.ToString() } })
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [int]$MaxAttempts = 4,
        [int]$InitialDelaySeconds = 2,
        [string]$OperationName = "Operation",
        [System.Windows.Forms.TextBox]$LogBox
    )

    $attempt = 0
    $delay = $InitialDelaySeconds

    while ($true) {
        $attempt++
        try {
            return & $Action
        }
        catch {
            $message = $_.Exception.Message
            $isTransient = $message -match "429|throttl|timeout|timed out|temporarily|service unavailable|503|500|connection|transient"

            if (-not $isTransient -or $attempt -ge $MaxAttempts) {
                throw
            }

            if ($LogBox) {
                Write-LogLine -LogBox $LogBox -Message ("WARN {0}: Versuch {1}/{2} fehlgeschlagen, neuer Versuch in {3}s ({4})" -f $OperationName, $attempt, $MaxAttempts, $delay, $message)
            }

            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, 30)
        }
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
        [Parameter(Mandatory = $true)][string]$Extension
    )

    $candidate = Join-Path -Path $Directory -ChildPath ("{0}{1}" -f $BaseName, $Extension)
    if (-not (Test-Path $candidate)) {
        return $candidate
    }

    $index = 2
    while ($true) {
        $candidate = Join-Path -Path $Directory -ChildPath ("{0}-{1}{2}" -f $BaseName, $index, $Extension)
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

function Get-CanvasAppItems {
    param([Parameter(Mandatory = $true)]$Environment)

    $lines = Invoke-Pac -Arguments @("canvas", "list", "--environment", $Environment.EnvironmentId)
    $items = New-Object System.Collections.Generic.List[object]

    foreach ($line in $lines) {
        if ($null -eq $line) { continue }
        $trimmed = $line.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed -match "^Verbunden als" -or $trimmed -match "^Connected as") { continue }
        if ($trimmed -match "^Name\s{2,}" -or $trimmed -match "^App Name\s{2,}") { continue }

        $parts = $trimmed -split "\s{2,}"
        if ($parts.Count -lt 1) { continue }

        $name = $parts[0].Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $key = "app|{0}|{1}" -f $Environment.EnvironmentId, $name
        $items.Add([pscustomobject]@{
                Key             = $key
                Type            = "Apps"
                EnvironmentId   = $Environment.EnvironmentId
                EnvironmentName = $Environment.DisplayName
                Name            = $name
            })
    }

    return $items.ToArray()
}

function Get-SolutionItems {
    param([Parameter(Mandatory = $true)]$Environment)

    $lines = Invoke-Pac -Arguments @("solution", "list", "--environment", $Environment.EnvironmentId)
    $items = New-Object System.Collections.Generic.List[object]

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

        $solutionName = $parts[0].Trim()
        if ([string]::IsNullOrWhiteSpace($solutionName)) { continue }
        if ($solutionName -match "\s") { continue }

        $key = "sol|{0}|{1}" -f $Environment.EnvironmentId, $solutionName
        $items.Add([pscustomobject]@{
                Key             = $key
                Type            = "Solutions"
                EnvironmentId   = $Environment.EnvironmentId
                EnvironmentName = $Environment.DisplayName
                Name            = $solutionName
            })
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
            return @()
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
                continue
            }

            if ([string]::IsNullOrWhiteSpace($appId)) { continue }

            $definitions.Add([pscustomobject]@{
                    Prefix    = $prefix
                    AppId     = $appId
                    MsappPath = $msappPath
                })
        }

        return $definitions.ToArray()
    }
    finally {
        if (Test-Path $tempRoot) {
            Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Export-ContainedCanvasApps {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentId,
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$SolutionName,
        [Parameter(Mandatory = $true)][string]$VariantLabel,
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][bool]$IncludeCanvasSource,
        [Parameter(Mandatory = $true)][System.Windows.Forms.TextBox]$LogBox,
        [Parameter(Mandatory = $true)]$Results
    )

    $envSafe = Get-SafeFileName -Name $EnvironmentName
    $safeSolution = Get-SafeFileName -Name $SolutionName
    $safeVariant = Get-SafeFileName -Name $VariantLabel
    $solutionAppsRoot = Join-Path -Path $RunRoot -ChildPath ("{0}/apps/{1}-{2}" -f $envSafe, $safeSolution, $safeVariant)
    $msappDir = Join-Path -Path $solutionAppsRoot -ChildPath "msapp"
    $srcDir = Join-Path -Path $solutionAppsRoot -ChildPath "src"

    New-Item -ItemType Directory -Path $msappDir -Force | Out-Null
    if ($IncludeCanvasSource) {
        New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
    }

    $canvasApps = @()
    try {
        $canvasApps = @(Get-SolutionCanvasAppDefinitions -ZipPath $ZipPath)
    }
    catch {
        Write-LogLine -LogBox $LogBox -Message ("WARN [Solutions] Canvas-App-Analyse fehlgeschlagen: {0} / {1} ({2})" -f $EnvironmentName, $SolutionName, $VariantLabel)
        return
    }

    if ($canvasApps.Count -eq 0) {
        Write-LogLine -LogBox $LogBox -Message ("[Solutions] Keine Canvas Apps in der Loesung gefunden: {0} / {1} ({2})" -f $EnvironmentName, $SolutionName, $VariantLabel)
        return
    }

    Write-LogLine -LogBox $LogBox -Message ("[Solutions] Exportiere {0} Canvas App(s) aus {1} / {2} ({3})" -f $canvasApps.Count, $EnvironmentName, $SolutionName, $VariantLabel)

    foreach ($canvasApp in $canvasApps) {
        $safeAppName = Get-SafeFileName -Name $canvasApp.Prefix
        $msappPath = Get-UniquePath -Directory $msappDir -BaseName $safeAppName -Extension ".msapp"
        $extractDir = Get-UniquePath -Directory $srcDir -BaseName $safeAppName -Extension ""

        $status = "Success"
        $errorMessage = ""

        try {
            Invoke-Pac -Arguments @(
                "canvas", "download",
                "--environment", $EnvironmentId,
                "--name", $canvasApp.AppId,
                "--file-name", $msappPath,
                "--overwrite"
            ) | Out-Null

            if ($IncludeCanvasSource) {
                Invoke-Pac -Arguments @(
                    "canvas", "download",
                    "--environment", $EnvironmentId,
                    "--name", $canvasApp.AppId,
                    "--extract-to-directory", $extractDir,
                    "--overwrite"
                ) | Out-Null
            }
        }
        catch {
            $status = "Failed"
            $errorMessage = $_.Exception.Message
            Write-LogLine -LogBox $LogBox -Message ("WARN [Solutions] Canvas App Export fehlgeschlagen: {0} / {1} / {2}" -f $EnvironmentName, $SolutionName, $canvasApp.Prefix)
        }

        $Results.Add([pscustomobject]@{
                Timestamp = (Get-Date).ToString("s")
                Type      = "SolutionApps"
                Scope     = $EnvironmentName
                Name      = $canvasApp.Prefix
                Variant   = "{0}/{1}" -f $SolutionName, $VariantLabel
                Path      = $msappPath
                Status    = $status
                Error     = $errorMessage
            })
    }
}

function Add-DedupedItems {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [AllowEmptyCollection()][object[]]$NewItems = @()
    )

    if ($null -eq $NewItems -or $NewItems.Count -eq 0) {
        return
    }

    $known = @{}
    foreach ($item in $Target) {
        if ($null -ne $item -and $item.PSObject.Properties.Name -contains "Key") {
            $known[$item.Key] = $true
        }
    }

    foreach ($item in $NewItems) {
        if ($null -eq $item -or -not ($item.PSObject.Properties.Name -contains "Key")) {
            continue
        }

        if (-not $known.ContainsKey($item.Key)) {
            $Target.Add($item)
            $known[$item.Key] = $true
        }
    }
}

function Get-CheckedKeys {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Forms.CheckedListBox]$ListControl,
        [AllowEmptyCollection()][object[]]$Items = @()
    )

    $keys = New-Object System.Collections.Generic.HashSet[string]
    if ($null -eq $Items -or $Items.Count -eq 0) {
        return , $keys
    }

    foreach ($idx in $ListControl.CheckedIndices) {
        if ($idx -ge 0 -and $idx -lt $Items.Count) {
            [void]$keys.Add($Items[$idx].Key)
        }
    }

    return , $keys
}

function Set-ModernButtonStyle {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Forms.Button]$Button,
        [ValidateSet("Primary", "Success", "Secondary")][string]$Kind = "Primary"
    )

    switch ($Kind) {
        "Success" {
            $back = [System.Drawing.Color]::FromArgb(22, 163, 74)
            $hover = [System.Drawing.Color]::FromArgb(21, 128, 61)
            $fore = [System.Drawing.Color]::White
        }
        "Secondary" {
            $back = [System.Drawing.Color]::FromArgb(229, 231, 235)
            $hover = [System.Drawing.Color]::FromArgb(209, 213, 219)
            $fore = [System.Drawing.Color]::FromArgb(31, 41, 55)
        }
        default {
            $back = [System.Drawing.Color]::FromArgb(37, 99, 235)
            $hover = [System.Drawing.Color]::FromArgb(29, 78, 216)
            $fore = [System.Drawing.Color]::White
        }
    }

    $Button.FlatStyle = "Flat"
    $Button.FlatAppearance.BorderSize = 0
    $Button.FlatAppearance.MouseOverBackColor = $hover
    $Button.FlatAppearance.MouseDownBackColor = $hover
    $Button.BackColor = $back
    $Button.ForeColor = $fore
    $Button.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Button.UseVisualStyleBackColor = $false
}

function New-Card {
    param([string]$Title)

    $outer = New-Object System.Windows.Forms.Panel
    $outer.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $outer.Padding = New-Object System.Windows.Forms.Padding(1)

    $inner = New-Object System.Windows.Forms.Panel
    $inner.Dock = "Fill"
    $inner.BackColor = [System.Drawing.Color]::White
    $inner.Padding = New-Object System.Windows.Forms.Padding(14, 12, 14, 14)

    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        $body = New-Object System.Windows.Forms.Panel
        $body.Dock = "Fill"
        $body.BackColor = [System.Drawing.Color]::White

        $header = New-Object System.Windows.Forms.Label
        $header.Text = $Title
        $header.Dock = "Top"
        $header.Height = 24
        $header.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
        $header.ForeColor = [System.Drawing.Color]::FromArgb(17, 24, 39)

        $inner.Controls.Add($body)
        $inner.Controls.Add($header)
        $outer.Controls.Add($inner)

        return [pscustomobject]@{ Outer = $outer; Body = $body }
    }

    $outer.Controls.Add($inner)
    return [pscustomobject]@{ Outer = $outer; Body = $inner }
}

function New-Spacer {
    param([int]$Height = 12, [string]$Dock = "Top")

    $spacer = New-Object System.Windows.Forms.Panel
    $spacer.Dock = $Dock
    $spacer.Height = $Height
    $spacer.Width = $Height
    $spacer.BackColor = [System.Drawing.Color]::FromArgb(243, 244, 246)
    return $spacer
}

function New-FilterPanel {
    param(
        [Parameter(Mandatory = $true)][string]$Placeholder,
        [Parameter(Mandatory = $true)][System.Windows.Forms.CheckedListBox]$ListControl
    )

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = "Top"
    $panel.Height = 38
    $panel.Padding = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    $panel.BackColor = [System.Drawing.Color]::White

    $field = New-Object System.Windows.Forms.Panel
    $field.Dock = "Fill"
    $field.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $field.Padding = New-Object System.Windows.Forms.Padding(1)

    $inner = New-Object System.Windows.Forms.Panel
    $inner.Dock = "Fill"
    $inner.BackColor = [System.Drawing.Color]::FromArgb(249, 250, 251)
    $inner.Padding = New-Object System.Windows.Forms.Padding(8, 4, 4, 4)

    $icon = New-Object System.Windows.Forms.Label
    $icon.Text = [char]0x2315
    $icon.Dock = "Left"
    $icon.Width = 22
    $icon.TextAlign = "MiddleCenter"
    $icon.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
    $icon.BackColor = [System.Drawing.Color]::FromArgb(249, 250, 251)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Dock = "Fill"
    $txt.Text = ""
    $txt.Tag = $Placeholder
    $txt.BorderStyle = "None"
    $txt.BackColor = [System.Drawing.Color]::FromArgb(249, 250, 251)
    $txt.Font = New-Object System.Drawing.Font("Segoe UI", 10)

    $clear = New-Object System.Windows.Forms.Button
    $clear.Text = [char]0x2715
    $clear.Width = 28
    $clear.Dock = "Right"
    $clear.FlatStyle = "Flat"
    $clear.FlatAppearance.BorderSize = 0
    $clear.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
    $clear.BackColor = [System.Drawing.Color]::FromArgb(249, 250, 251)
    $clear.Cursor = [System.Windows.Forms.Cursors]::Hand

    $inner.Controls.Add($txt)
    $inner.Controls.Add($icon)
    $inner.Controls.Add($clear)
    $field.Controls.Add($inner)
    $panel.Controls.Add($field)

    $clear.Tag = $txt
    $clear.Add_Click({
            param($sender, $eventArgs)
            $target = $sender.Tag
            if ($null -ne $target) {
                $target.Text = ""
            }
        })

    return [pscustomobject]@{
        Panel   = $panel
        TextBox = $txt
    }
}

function Update-AssetLists {
    $checkedAppKeys = Get-CheckedKeys -ListControl $checkedApps -Items $script:viewModels.Apps
    $checkedSolutionKeys = Get-CheckedKeys -ListControl $checkedSolutions -Items $script:viewModels.Solutions

    $appsFilter = $script:filters.Apps
    $solFilter = $script:filters.Solutions

    $script:viewModels.Apps = @($script:fetchedAssets.Apps | Where-Object {
            [string]::IsNullOrWhiteSpace($appsFilter) -or $_.Name -like "*$appsFilter*" -or $_.EnvironmentName -like "*$appsFilter*"
        })
    $script:viewModels.Solutions = @($script:fetchedAssets.Solutions | Where-Object {
            [string]::IsNullOrWhiteSpace($solFilter) -or $_.Name -like "*$solFilter*" -or $_.EnvironmentName -like "*$solFilter*"
        })

    $checkedApps.Items.Clear()
    foreach ($item in $script:viewModels.Apps) {
        [void]$checkedApps.Items.Add(("{0} :: {1}" -f $item.EnvironmentName, $item.Name), $checkedAppKeys.Contains($item.Key))
    }

    $checkedSolutions.Items.Clear()
    foreach ($item in $script:viewModels.Solutions) {
        [void]$checkedSolutions.Items.Add(("{0} :: {1}" -f $item.EnvironmentName, $item.Name), $checkedSolutionKeys.Contains($item.Key))
    }

    $lblCounts.Text = "Apps: {0} | Solutions: {1}" -f $script:viewModels.Apps.Count, $script:viewModels.Solutions.Count
}

function Get-SelectedItems {
    $selected = New-Object System.Collections.Generic.List[object]

    foreach ($idx in $checkedApps.CheckedIndices) {
        $selected.Add($script:viewModels.Apps[$idx])
    }
    foreach ($idx in $checkedSolutions.CheckedIndices) {
        $selected.Add($script:viewModels.Solutions[$idx])
    }

    return $selected.ToArray()
}

function Export-Items {
    param(
        [Parameter(Mandatory = $true)][object[]]$Items,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][bool]$IncludeCanvasSource,
        [Parameter(Mandatory = $true)][bool]$ExportManagedSolutions,
        [Parameter(Mandatory = $true)][bool]$ExportUnmanagedSolutions,
        [Parameter(Mandatory = $true)][System.Windows.Forms.TextBox]$LogBox
    )

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($item in $Items) {
        $status = "Success"
        $errorMessage = ""
        $savedPath = ""

        try {
            switch ($item.Type) {
                "Apps" {
                    $envSafe = Get-SafeFileName -Name $item.EnvironmentName
                    $msappDir = Join-Path -Path $RunRoot -ChildPath ("{0}/apps/msapp" -f $envSafe)
                    New-Item -ItemType Directory -Path $msappDir -Force | Out-Null

                    $safeName = Get-SafeFileName -Name $item.Name
                    $msappPath = Get-UniquePath -Directory $msappDir -BaseName $safeName -Extension ".msapp"

                    Write-LogLine -LogBox $LogBox -Message ("[Apps] Exportiere {0} / {1}" -f $item.EnvironmentName, $item.Name)
                    Invoke-Pac -Arguments @(
                        "canvas", "download",
                        "--environment", $item.EnvironmentId,
                        "--name", $item.Name,
                        "--file-name", $msappPath,
                        "--overwrite"
                    ) | Out-Null

                    if ($IncludeCanvasSource) {
                        $srcDir = Join-Path -Path $RunRoot -ChildPath ("{0}/apps/src" -f $envSafe)
                        New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
                        $extractDir = Join-Path -Path $srcDir -ChildPath $safeName
                        Invoke-Pac -Arguments @(
                            "canvas", "download",
                            "--environment", $item.EnvironmentId,
                            "--name", $item.Name,
                            "--extract-to-directory", $extractDir,
                            "--overwrite"
                        ) | Out-Null
                    }

                    $savedPath = $msappPath
                }
                "Solutions" {
                    if (-not $ExportManagedSolutions -and -not $ExportUnmanagedSolutions) {
                        throw "Solutions sind aktiv, aber weder managed noch unmanaged ist ausgewaehlt."
                    }

                    $envSafe = Get-SafeFileName -Name $item.EnvironmentName
                    $solDir = Join-Path -Path $RunRoot -ChildPath ("{0}/solutions" -f $envSafe)
                    New-Item -ItemType Directory -Path $solDir -Force | Out-Null

                    $variants = New-Object System.Collections.Generic.List[object]
                    if ($ExportUnmanagedSolutions) {
                        $variants.Add([pscustomobject]@{ Label = "unmanaged"; ManagedValue = "false" })
                    }
                    if ($ExportManagedSolutions) {
                        $variants.Add([pscustomobject]@{ Label = "managed"; ManagedValue = "true" })
                    }

                    foreach ($variant in $variants) {
                        Write-LogLine -LogBox $LogBox -Message ("[Solutions] Exportiere {0} / {1} ({2})" -f $item.EnvironmentName, $item.Name, $variant.Label)
                        $zipPath = Join-Path -Path $solDir -ChildPath ((Get-SafeFileName -Name $item.Name) + "-" + $variant.Label + ".zip")
                        Invoke-Pac -Arguments @(
                            "solution", "export",
                            "--environment", $item.EnvironmentId,
                            "--name", $item.Name,
                            "--path", $zipPath,
                            "--managed", $variant.ManagedValue,
                            "--overwrite"
                        ) | Out-Null
                        $savedPath = $zipPath

                        Export-ContainedCanvasApps -EnvironmentId $item.EnvironmentId -EnvironmentName $item.EnvironmentName -SolutionName $item.Name -VariantLabel $variant.Label -ZipPath $zipPath -RunRoot $RunRoot -IncludeCanvasSource $IncludeCanvasSource -LogBox $LogBox -Results $results

                        $results.Add([pscustomobject]@{
                                Timestamp = (Get-Date).ToString("s")
                                Type      = "Solutions"
                                Scope     = $item.EnvironmentName
                                Name      = $item.Name
                                Variant   = $variant.Label
                                Path      = $zipPath
                                Status    = "Success"
                                Error     = ""
                            })
                    }

                    continue
                }
                default {
                    throw "Unbekannter Typ '$($item.Type)'"
                }
            }
        }
        catch {
            $status = "Failed"
            $errorMessage = $_.Exception.Message
            Write-LogLine -LogBox $LogBox -Message ("WARN Export fehlgeschlagen ({0}): {1}" -f $item.Type, $item.Name)
        }

        $results.Add([pscustomobject]@{
                Timestamp = (Get-Date).ToString("s")
                Type      = $item.Type
            Scope     = $item.EnvironmentName
                Name      = $item.Name
                Variant   = ""
                Path      = $savedPath
                Status    = $status
                Error     = $errorMessage
            })
    }

    return $results.ToArray()
}

if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
    throw "Power Platform CLI (pac) wurde nicht in PATH gefunden."
}

$clrBg = [System.Drawing.Color]::FromArgb(243, 244, 246)
$clrHeader = [System.Drawing.Color]::FromArgb(17, 24, 39)
$clrText = [System.Drawing.Color]::FromArgb(31, 41, 55)
$clrMuted = [System.Drawing.Color]::FromArgb(107, 114, 128)

$form = New-Object System.Windows.Forms.Form
$form.Text = "Power Platform Backup Center"
$form.Size = New-Object System.Drawing.Size(1360, 880)
$form.MinimumSize = New-Object System.Drawing.Size(1120, 720)
$form.StartPosition = "CenterScreen"
$form.BackColor = $clrBg
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

# ----- Header -----
$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = "Top"
$headerPanel.Height = 74
$headerPanel.BackColor = $clrHeader

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "Power Platform Backup Center"
$titleLabel.Location = New-Object System.Drawing.Point(24, 14)
$titleLabel.AutoSize = $true
$titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = [System.Drawing.Color]::White
$titleLabel.BackColor = [System.Drawing.Color]::Transparent
$headerPanel.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = "Lokales Voll-Backup fuer Apps und Solutions"
$subtitleLabel.Location = New-Object System.Drawing.Point(26, 48)
$subtitleLabel.AutoSize = $true
$subtitleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
$subtitleLabel.BackColor = [System.Drawing.Color]::Transparent
$headerPanel.Controls.Add($subtitleLabel)

# ----- Status bar -----
$statusBar = New-Object System.Windows.Forms.Panel
$statusBar.Dock = "Bottom"
$statusBar.Height = 30
$statusBar.BackColor = [System.Drawing.Color]::White
$statusBar.Padding = New-Object System.Windows.Forms.Padding(16, 0, 16, 0)

$lblCounts = New-Object System.Windows.Forms.Label
$lblCounts.Text = "Apps: 0 | Solutions: 0"
$lblCounts.Dock = "Fill"
$lblCounts.TextAlign = "MiddleLeft"
$lblCounts.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblCounts.ForeColor = $clrMuted
$statusBar.Controls.Add($lblCounts)

# ----- Body -----
$bodyPanel = New-Object System.Windows.Forms.Panel
$bodyPanel.Dock = "Fill"
$bodyPanel.BackColor = $clrBg
$bodyPanel.Padding = New-Object System.Windows.Forms.Padding(16)

# Main area (right) - added first so it fills remaining space
$mainArea = New-Object System.Windows.Forms.TableLayoutPanel
$mainArea.Dock = "Fill"
$mainArea.BackColor = $clrBg
$mainArea.ColumnCount = 1
$mainArea.RowCount = 4
$mainArea.Padding = New-Object System.Windows.Forms.Padding(16, 0, 0, 0)
[void]$mainArea.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$mainArea.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 64)))
[void]$mainArea.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 154)))
[void]$mainArea.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$mainArea.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 240)))

# Action card (toolbar)
$actionCardObj = New-Card
$actionCard = $actionCardObj.Outer
$actionCard.Dock = "Fill"
$actionCard.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)

$actionTable = New-Object System.Windows.Forms.TableLayoutPanel
$actionTable.Dock = "Fill"
$actionTable.ColumnCount = 4
$actionTable.RowCount = 1
[void]$actionTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$actionTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 160)))
[void]$actionTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 160)))
[void]$actionTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 160)))

$lblActions = New-Object System.Windows.Forms.Label
$lblActions.Text = "Aktionen"
$lblActions.Dock = "Fill"
$lblActions.TextAlign = "MiddleLeft"
$lblActions.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$lblActions.ForeColor = $clrText

$btnFetch = New-Object System.Windows.Forms.Button
$btnFetch.Text = "Fetch anzeigen"
$btnFetch.Dock = "Fill"
$btnFetch.Margin = New-Object System.Windows.Forms.Padding(6, 4, 6, 4)
Set-ModernButtonStyle -Button $btnFetch -Kind Primary

$btnExportAll = New-Object System.Windows.Forms.Button
$btnExportAll.Text = "Export komplett"
$btnExportAll.Dock = "Fill"
$btnExportAll.Margin = New-Object System.Windows.Forms.Padding(6, 4, 6, 4)
Set-ModernButtonStyle -Button $btnExportAll -Kind Success

$btnExportSelected = New-Object System.Windows.Forms.Button
$btnExportSelected.Text = "Export individuell"
$btnExportSelected.Dock = "Fill"
$btnExportSelected.Margin = New-Object System.Windows.Forms.Padding(6, 4, 6, 4)
Set-ModernButtonStyle -Button $btnExportSelected -Kind Success

$actionTable.Controls.Add($lblActions, 0, 0)
$actionTable.Controls.Add($btnFetch, 1, 0)
$actionTable.Controls.Add($btnExportAll, 2, 0)
$actionTable.Controls.Add($btnExportSelected, 3, 0)
$actionCardObj.Body.Controls.Add($actionTable)

# Options card (areas + export options)
$optionsCardObj = New-Card -Title "Auswahl und Optionen"
$optionsCard = $optionsCardObj.Outer
$optionsCard.Dock = "Fill"
$optionsCard.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)

$optTable = New-Object System.Windows.Forms.TableLayoutPanel
$optTable.Dock = "Fill"
$optTable.ColumnCount = 2
$optTable.RowCount = 1
[void]$optTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$optTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))

# Areas column
$areasPanel = New-Object System.Windows.Forms.Panel
$areasPanel.Dock = "Fill"

$areasTable = New-Object System.Windows.Forms.TableLayoutPanel
$areasTable.Dock = "Fill"
$areasTable.ColumnCount = 2
$areasTable.RowCount = 1
[void]$areasTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$areasTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))

$lblAreas = New-Object System.Windows.Forms.Label
$lblAreas.Text = "Bereiche"
$lblAreas.Dock = "Top"
$lblAreas.Height = 22
$lblAreas.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblAreas.ForeColor = $clrMuted

$chkApps = New-Object System.Windows.Forms.CheckBox
$chkApps.Text = "Apps"
$chkApps.AutoSize = $true
$chkApps.Checked = $true
$chkApps.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 6)
$chkApps.ForeColor = $clrText

$chkSolutions = New-Object System.Windows.Forms.CheckBox
$chkSolutions.Text = "Solutions"
$chkSolutions.AutoSize = $true
$chkSolutions.Checked = $true
$chkSolutions.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 6)
$chkSolutions.ForeColor = $clrText

$areasTable.Controls.Add($chkApps, 0, 0)
$areasTable.Controls.Add($chkSolutions, 1, 0)
$areasPanel.Controls.Add($areasTable)
$areasPanel.Controls.Add($lblAreas)

# Options column
$optionsPanel = New-Object System.Windows.Forms.Panel
$optionsPanel.Dock = "Fill"

$optionsInner = New-Object System.Windows.Forms.FlowLayoutPanel
$optionsInner.Dock = "Fill"
$optionsInner.FlowDirection = "TopDown"
$optionsInner.WrapContents = $false

$lblOptions = New-Object System.Windows.Forms.Label
$lblOptions.Text = "Export-Optionen"
$lblOptions.Dock = "Top"
$lblOptions.Height = 22
$lblOptions.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblOptions.ForeColor = $clrMuted

$chkCanvasSource = New-Object System.Windows.Forms.CheckBox
$chkCanvasSource.Text = "Canvas Source-Extract"
$chkCanvasSource.AutoSize = $true
$chkCanvasSource.Checked = $true
$chkCanvasSource.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
$chkCanvasSource.ForeColor = $clrText

$chkUnmanaged = New-Object System.Windows.Forms.CheckBox
$chkUnmanaged.Text = "Solutions unmanaged"
$chkUnmanaged.AutoSize = $true
$chkUnmanaged.Checked = $true
$chkUnmanaged.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
$chkUnmanaged.ForeColor = $clrText

$chkManaged = New-Object System.Windows.Forms.CheckBox
$chkManaged.Text = "Solutions managed"
$chkManaged.AutoSize = $true
$chkManaged.Checked = $true
$chkManaged.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
$chkManaged.ForeColor = $clrText

$optionsInner.Controls.Add($chkCanvasSource)
$optionsInner.Controls.Add($chkUnmanaged)
$optionsInner.Controls.Add($chkManaged)
$optionsPanel.Controls.Add($optionsInner)
$optionsPanel.Controls.Add($lblOptions)

$optTable.Controls.Add($areasPanel, 0, 0)
$optTable.Controls.Add($optionsPanel, 1, 0)
$optionsCardObj.Body.Controls.Add($optTable)

# Tabs
$tabAssets = New-Object System.Windows.Forms.TabControl
$tabAssets.Dock = "Fill"
$tabAssets.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
$tabAssets.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabAssets.Padding = New-Object System.Drawing.Point(12, 6)

$tabApps = New-Object System.Windows.Forms.TabPage
$tabApps.Text = "Apps"
$tabApps.BackColor = [System.Drawing.Color]::White
$tabApps.Padding = New-Object System.Windows.Forms.Padding(10)
$tabSolutions = New-Object System.Windows.Forms.TabPage
$tabSolutions.Text = "Solutions"
$tabSolutions.BackColor = [System.Drawing.Color]::White
$tabSolutions.Padding = New-Object System.Windows.Forms.Padding(10)

$tabAssets.TabPages.AddRange(@($tabApps, $tabSolutions))

$checkedApps = New-Object System.Windows.Forms.CheckedListBox
$checkedApps.Dock = "Fill"
$checkedApps.CheckOnClick = $true
$checkedApps.BorderStyle = "None"
$checkedApps.IntegralHeight = $false
$appFilter = New-FilterPanel -Placeholder "Name oder Environment" -ListControl $checkedApps
$tabApps.Controls.Add($checkedApps)
$tabApps.Controls.Add($appFilter.Panel)

$checkedSolutions = New-Object System.Windows.Forms.CheckedListBox
$checkedSolutions.Dock = "Fill"
$checkedSolutions.CheckOnClick = $true
$checkedSolutions.BorderStyle = "None"
$checkedSolutions.IntegralHeight = $false
$solutionFilter = New-FilterPanel -Placeholder "Name oder Environment" -ListControl $checkedSolutions
$tabSolutions.Controls.Add($checkedSolutions)
$tabSolutions.Controls.Add($solutionFilter.Panel)

# Log card
$logCardObj = New-Card -Title "Aktivitaetslog"
$logCard = $logCardObj.Outer
$logCard.Dock = "Fill"
$logCard.Margin = New-Object System.Windows.Forms.Padding(0)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Dock = "Fill"
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.ReadOnly = $true
$logBox.BorderStyle = "None"
$logBox.BackColor = [System.Drawing.Color]::FromArgb(249, 250, 251)
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$logCardObj.Body.Controls.Add($logBox)

$mainArea.Controls.Add($actionCard, 0, 0)
$mainArea.Controls.Add($optionsCard, 0, 1)
$mainArea.Controls.Add($tabAssets, 0, 2)
$mainArea.Controls.Add($logCard, 0, 3)

# Sidebar (left)
$sidebar = New-Object System.Windows.Forms.TableLayoutPanel
$sidebar.Dock = "Left"
$sidebar.Width = 360
$sidebar.BackColor = $clrBg
$sidebar.ColumnCount = 1
$sidebar.RowCount = 3
[void]$sidebar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$sidebar.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$sidebar.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 168)))
[void]$sidebar.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 120)))

# Environments card
$envCardObj = New-Card -Title "Environments"
$envCard = $envCardObj.Outer
$envCard.Dock = "Fill"
$envCard.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)

$checkedEnvs = New-Object System.Windows.Forms.CheckedListBox
$checkedEnvs.Dock = "Fill"
$checkedEnvs.CheckOnClick = $true
$checkedEnvs.BorderStyle = "None"
$checkedEnvs.IntegralHeight = $false
$checkedEnvs.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$envBtnPanel = New-Object System.Windows.Forms.Panel
$envBtnPanel.Dock = "Bottom"
$envBtnPanel.Height = 42
$envBtnPanel.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
$envBtnPanel.BackColor = [System.Drawing.Color]::White

$btnLoadEnvs = New-Object System.Windows.Forms.Button
$btnLoadEnvs.Text = "Environments laden"
$btnLoadEnvs.Dock = "Fill"
Set-ModernButtonStyle -Button $btnLoadEnvs -Kind Primary
$envBtnPanel.Controls.Add($btnLoadEnvs)

$envCardObj.Body.Controls.Add($checkedEnvs)
$envCardObj.Body.Controls.Add($envBtnPanel)

# Login card
$loginCardObj = New-Card -Title "Anmeldung"
$loginCard = $loginCardObj.Outer
$loginCard.Dock = "Fill"
$loginCard.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)

$loginTable = New-Object System.Windows.Forms.TableLayoutPanel
$loginTable.Dock = "Fill"
$loginTable.ColumnCount = 1
$loginTable.RowCount = 1
[void]$loginTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$loginTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

$btnPacLogin = New-Object System.Windows.Forms.Button
$btnPacLogin.Text = "pac auth create"
$btnPacLogin.Dock = "Fill"
$btnPacLogin.Margin = New-Object System.Windows.Forms.Padding(0, 3, 0, 3)
Set-ModernButtonStyle -Button $btnPacLogin -Kind Secondary

$loginTable.Controls.Add($btnPacLogin, 0, 0)
$loginCardObj.Body.Controls.Add($loginTable)

# Output card
$outputCardObj = New-Card -Title "Speicherort"
$outputCard = $outputCardObj.Outer
$outputCard.Dock = "Fill"
$outputCard.Margin = New-Object System.Windows.Forms.Padding(0)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "Ordner waehlen"
$btnBrowse.Dock = "Bottom"
$btnBrowse.Height = 30
Set-ModernButtonStyle -Button $btnBrowse -Kind Secondary

$txtOutput = New-Object System.Windows.Forms.TextBox
$txtOutput.Dock = "Top"
$txtOutput.BorderStyle = "FixedSingle"
$txtOutput.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$txtOutput.Text = (Resolve-Path -Path ".").Path + "\" + $DefaultOutputRoot

$outputCardObj.Body.Controls.Add($txtOutput)
$outputCardObj.Body.Controls.Add($btnBrowse)

$sidebar.Controls.Add($envCard, 0, 0)
$sidebar.Controls.Add($loginCard, 0, 1)
$sidebar.Controls.Add($outputCard, 0, 2)

$bodyPanel.Controls.Add($mainArea)
$bodyPanel.Controls.Add($sidebar)

$form.Controls.Add($bodyPanel)
$form.Controls.Add($headerPanel)
$form.Controls.Add($statusBar)

$folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog

$script:environments = @()
$script:fetchedAssets = @{
    Apps      = New-Object System.Collections.Generic.List[object]
    Solutions = New-Object System.Collections.Generic.List[object]
}
$script:viewModels = @{
    Apps      = @()
    Solutions = @()
}
$script:filters = @{
    Apps      = ""
    Solutions = ""
}

$appFilter.TextBox.Add_TextChanged({
        $script:filters.Apps = $appFilter.TextBox.Text.Trim()
        Update-AssetLists
    })
$solutionFilter.TextBox.Add_TextChanged({
        $script:filters.Solutions = $solutionFilter.TextBox.Text.Trim()
        Update-AssetLists
    })

$btnBrowse.Add_Click({
        if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtOutput.Text = $folderBrowser.SelectedPath
        }
    })

$btnPacLogin.Add_Click({
        try {
            Write-LogLine -LogBox $logBox -Message "Starte pac auth create"
            Invoke-Pac -Arguments @("auth", "create") | Out-Null
            Write-LogLine -LogBox $logBox -Message "pac Login erfolgreich aktualisiert."
        }
        catch {
            Write-LogLine -LogBox $logBox -Message ("ERROR pac Login fehlgeschlagen: " + $_.Exception.Message)
        }
    })

$btnLoadEnvs.Add_Click({
        try {
            Write-LogLine -LogBox $logBox -Message "Lade Environments..."
            $lines = Invoke-Pac -Arguments @("env", "list")
            $script:environments = @(ConvertFrom-PacEnvironmentLines -Lines $lines)

            $checkedEnvs.Items.Clear()
            foreach ($env in $script:environments) {
                $label = "{0} ({1})" -f $env.DisplayName, $env.EnvironmentId
                [void]$checkedEnvs.Items.Add($label, [bool]$env.IsActive)
            }

            Write-LogLine -LogBox $logBox -Message ("Environments geladen: " + $script:environments.Count)
        }
        catch {
            Write-LogLine -LogBox $logBox -Message ("ERROR Environments konnten nicht geladen werden: " + $_.Exception.Message)
        }
    })

$btnFetch.Add_Click({
        $totalStopwatch = $null
        try {
            if ($script:environments.Count -eq 0) {
                throw "Bitte zuerst Environments laden."
            }

            if ($checkedEnvs.CheckedIndices.Count -eq 0) {
                throw "Bitte mindestens eine Environment auswaehlen."
            }

            $btnFetch.Enabled = $false
            $btnExportAll.Enabled = $false
            $btnExportSelected.Enabled = $false
            $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

            $selectedEnvs = New-Object System.Collections.Generic.List[object]
            foreach ($checkedIndex in $checkedEnvs.CheckedIndices) {
                $selectedEnvs.Add($script:environments[$checkedIndex])
            }

            $totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            Write-LogLine -LogBox $logBox -Message ("=== Fetch gestartet fuer {0} Environment(s) ===" -f $selectedEnvs.Count)

            if ($chkApps.Checked) {
                foreach ($env in $selectedEnvs) {
                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    Write-LogLine -LogBox $logBox -Message ("[Apps] Lade aus " + $env.DisplayName + " ...")
                    try {
                        $appItems = @(Get-CanvasAppItems -Environment $env)
                        Add-DedupedItems -Target $script:fetchedAssets.Apps -NewItems $appItems
                        $sw.Stop()
                        Write-LogLine -LogBox $logBox -Message ("[Apps] {0}: {1} gefunden ({2:n1}s)" -f $env.DisplayName, $appItems.Count, $sw.Elapsed.TotalSeconds)
                    }
                    catch {
                        $sw.Stop()
                        Write-LogLine -LogBox $logBox -Message ("[Apps] WARN {0} uebersprungen nach {1:n1}s: {2}" -f $env.DisplayName, $sw.Elapsed.TotalSeconds, $_.Exception.Message)
                    }
                }
            }

            if ($chkSolutions.Checked) {
                foreach ($env in $selectedEnvs) {
                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    Write-LogLine -LogBox $logBox -Message ("[Solutions] Lade aus " + $env.DisplayName + " ...")
                    try {
                        $solItems = @(Get-SolutionItems -Environment $env)
                        Add-DedupedItems -Target $script:fetchedAssets.Solutions -NewItems $solItems
                        $sw.Stop()
                        Write-LogLine -LogBox $logBox -Message ("[Solutions] {0}: {1} gefunden ({2:n1}s)" -f $env.DisplayName, $solItems.Count, $sw.Elapsed.TotalSeconds)
                    }
                    catch {
                        $sw.Stop()
                        Write-LogLine -LogBox $logBox -Message ("[Solutions] WARN {0} uebersprungen nach {1:n1}s: {2}" -f $env.DisplayName, $sw.Elapsed.TotalSeconds, $_.Exception.Message)
                    }
                }
            }

            Update-AssetLists
            $totalStopwatch.Stop()
            Write-LogLine -LogBox $logBox -Message ("=== Fetch abgeschlossen in {0:n1}s | Apps: {1}, Solutions: {2} ===" -f `
                    $totalStopwatch.Elapsed.TotalSeconds, `
                    $script:fetchedAssets.Apps.Count, `
                    $script:fetchedAssets.Solutions.Count)
        }
        catch {
            Write-LogLine -LogBox $logBox -Message ("ERROR Fetch fehlgeschlagen (Zeile {0}): {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message)
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Fehler", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
        finally {
            $btnFetch.Enabled = $true
            $btnExportAll.Enabled = $true
            $btnExportSelected.Enabled = $true
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

$btnExportAll.Add_Click({
        try {
            $items = @()
            if ($chkApps.Checked) { $items += @($script:fetchedAssets.Apps) }
            if ($chkSolutions.Checked) { $items += @($script:fetchedAssets.Solutions) }

            if ($items.Count -eq 0) {
                throw "Keine gefetchten Daten fuer den Komplett-Export vorhanden."
            }

            $outputRoot = $txtOutput.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($outputRoot)) {
                throw "Bitte gueltigen Speicherort angeben."
            }

            if (-not (Test-Path $outputRoot)) {
                New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
            }

            $runRoot = Join-Path -Path $outputRoot -ChildPath ("full-export-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
            New-Item -ItemType Directory -Path $runRoot -Force | Out-Null

            Write-LogLine -LogBox $logBox -Message ("Export komplett gestartet: " + $runRoot)
            $results = @(Export-Items -Items $items -RunRoot $runRoot -IncludeCanvasSource $chkCanvasSource.Checked -ExportManagedSolutions $chkManaged.Checked -ExportUnmanagedSolutions $chkUnmanaged.Checked -LogBox $logBox)
            $results | Export-Csv -Path (Join-Path $runRoot "export-log.csv") -NoTypeInformation -Encoding UTF8

            $okCount = @($results | Where-Object { $_.Status -eq "Success" }).Count
            $failCount = @($results | Where-Object { $_.Status -eq "Failed" }).Count
            Write-LogLine -LogBox $logBox -Message ("Komplett-Export fertig. Success: $okCount Failed: $failCount")
            [System.Windows.Forms.MessageBox]::Show(("Komplett-Export abgeschlossen.`nSuccess: {0}  Failed: {1}`nOutput: {2}" -f $okCount, $failCount, $runRoot), "Fertig", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
        catch {
            Write-LogLine -LogBox $logBox -Message ("ERROR Komplett-Export fehlgeschlagen (Zeile {0}): {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message)
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Fehler", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    })

$btnExportSelected.Add_Click({
        try {
            $items = @(Get-SelectedItems)
            if ($items.Count -eq 0) {
                throw "Keine individuellen Eintraege markiert."
            }

            $outputRoot = $txtOutput.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($outputRoot)) {
                throw "Bitte gueltigen Speicherort angeben."
            }

            if (-not (Test-Path $outputRoot)) {
                New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
            }

            $runRoot = Join-Path -Path $outputRoot -ChildPath ("individual-export-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
            New-Item -ItemType Directory -Path $runRoot -Force | Out-Null

            Write-LogLine -LogBox $logBox -Message ("Individueller Export gestartet: " + $runRoot)
            $results = @(Export-Items -Items $items -RunRoot $runRoot -IncludeCanvasSource $chkCanvasSource.Checked -ExportManagedSolutions $chkManaged.Checked -ExportUnmanagedSolutions $chkUnmanaged.Checked -LogBox $logBox)
            $results | Export-Csv -Path (Join-Path $runRoot "export-log.csv") -NoTypeInformation -Encoding UTF8

            $okCount = @($results | Where-Object { $_.Status -eq "Success" }).Count
            $failCount = @($results | Where-Object { $_.Status -eq "Failed" }).Count
            Write-LogLine -LogBox $logBox -Message ("Individueller Export fertig. Success: $okCount Failed: $failCount")
            [System.Windows.Forms.MessageBox]::Show(("Individueller Export abgeschlossen.`nSuccess: {0}  Failed: {1}`nOutput: {2}" -f $okCount, $failCount, $runRoot), "Fertig", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
        catch {
            Write-LogLine -LogBox $logBox -Message ("ERROR Individueller Export fehlgeschlagen (Zeile {0}): {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message)
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Fehler", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    })

Write-LogLine -LogBox $logBox -Message "GUI gestartet. Schritte: (1) Login (2) Environments laden (3) Apps/Solutions fetchen (4) Komplett oder individuell exportieren."
[void]$form.ShowDialog()
