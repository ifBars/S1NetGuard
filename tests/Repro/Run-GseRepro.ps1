[CmdletBinding()]
param(
    [ValidateSet("Lobby", "Direct", "Impact")]
    [string]$Scenario = "Lobby",

    [Parameter(Mandatory = $true)]
    [string]$GamePath,

    [Parameter(Mandatory = $true)]
    [string]$GseSteamApiPath,

    [string]$InstanceRoot = "",

    [string]$EvidenceRoot = "",

    [string]$HostSteamId = "76561198000000021",

    [string]$ClientSteamId = "76561198000000022",

    [ValidateRange(30, 240)]
    [int]$TimeoutSeconds = 150,

    [switch]$ProtectHost,

    [switch]$VerifyRpcDefense,

    [switch]$KeepInstances
)

$ErrorActionPreference = "Stop"

function Assert-Path {
    param([string]$Path, [string]$Description)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Description not found: $Path"
    }
}

function New-FileLinkOrCopy {
    param([string]$SourcePath, [string]$DestinationPath)

    try {
        New-Item -ItemType HardLink -Path $DestinationPath -Target $SourcePath -Force | Out-Null
    }
    catch {
        Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
    }
}

function Copy-IsolatedGame {
    param([string]$SourcePath, [string]$DestinationPath)

    New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null

    foreach ($fileName in @(
        "Schedule I.exe",
        "UnityCrashHandler64.exe",
        "UnityPlayer.dll",
        "steam_appid.txt",
        "version.dll",
        "baselib.dll"
    )) {
        $sourceFile = Join-Path $SourcePath $fileName
        if (Test-Path -LiteralPath $sourceFile) {
            New-FileLinkOrCopy -SourcePath $sourceFile -DestinationPath (Join-Path $DestinationPath $fileName)
        }
    }

    $monoRuntime = Join-Path $SourcePath "MonoBleedingEdge"
    if (Test-Path -LiteralPath $monoRuntime) {
        New-Item -ItemType Junction -Path (Join-Path $DestinationPath "MonoBleedingEdge") -Target $monoRuntime | Out-Null
    }

    $sourceData = Join-Path $SourcePath "Schedule I_Data"
    $destinationData = Join-Path $DestinationPath "Schedule I_Data"
    New-Item -ItemType Directory -Path $destinationData -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $sourceData -Force) {
        $destinationItem = Join-Path $destinationData $item.Name
        if ($item.PSIsContainer) {
            if ($item.Name -eq "Plugins") {
                Copy-Item -LiteralPath $item.FullName -Destination $destinationItem -Recurse -Force
            }
            else {
                New-Item -ItemType Junction -Path $destinationItem -Target $item.FullName | Out-Null
            }
        }
        else {
            New-FileLinkOrCopy -SourcePath $item.FullName -DestinationPath $destinationItem
        }
    }

    $sourceMelonLoader = Join-Path $SourcePath "MelonLoader"
    Copy-Item -LiteralPath $sourceMelonLoader -Destination (Join-Path $DestinationPath "MelonLoader") -Recurse -Force

    New-Item -ItemType Directory -Path (Join-Path $DestinationPath "UserLibs") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $DestinationPath "Mods") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $DestinationPath "UserData") -Force | Out-Null
}

function Set-GseIdentity {
    param([string]$InstancePath, [string]$SteamId, [string]$AccountName, [string]$SteamApiSource)

    $pluginDirectory = Join-Path $InstancePath "Schedule I_Data\Plugins\x86_64"
    $steamApiTarget = Join-Path $pluginDirectory "steam_api64.dll"
    Copy-Item -LiteralPath $SteamApiSource -Destination $steamApiTarget -Force

    $settingsDirectory = Join-Path $pluginDirectory "steam_settings"
    New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null
    $config = @(
        "[user::general]",
        "account_name=$AccountName",
        "account_steamid=$SteamId",
        "language=english"
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText((Join-Path $settingsDirectory "configs.user.ini"), $config)
}

function Wait-ForFile {
    param(
        [string]$Path,
        [datetime]$Deadline,
        [System.Diagnostics.Process]$Owner,
        [string]$Phase
    )

    $lastProgress = [datetime]::MinValue
    while ((Get-Date) -lt $Deadline) {
        if (Test-Path -LiteralPath $Path) {
            return
        }

        if ($Owner.HasExited) {
            throw "$Phase failed because process $($Owner.Id) exited with code $($Owner.ExitCode)."
        }

        if (((Get-Date) - $lastProgress).TotalSeconds -ge 5) {
            Write-Host "${Phase}: waiting for $Path" -ForegroundColor DarkGray
            $lastProgress = Get-Date
        }

        Start-Sleep -Milliseconds 500
    }

    throw "$Phase timed out waiting for $Path"
}

function Stop-LaunchedProcess {
    param([System.Diagnostics.Process]$Process, [string]$Role)

    if ($Process -and -not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        Write-Host "Stopped $Role process $($Process.Id)." -ForegroundColor DarkGray
    }
}

function Remove-IsolatedRoot {
    param([string]$Path, [string]$AllowedRoot)

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $resolvedAllowedRoot = [System.IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\') + '\'
    if (-not $resolvedPath.StartsWith($resolvedAllowedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove isolated path outside the instance root: $resolvedPath"
    }

    Get-ChildItem -LiteralPath $resolvedPath -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        ForEach-Object {
            if ($_.PSIsContainer) {
                [System.IO.Directory]::Delete($_.FullName, $false)
            }
            else {
                Remove-Item -LiteralPath $_.FullName -Force
            }
        }
    Remove-Item -LiteralPath $resolvedPath -Recurse -Force
}

$resolvedGamePath = [System.IO.Path]::GetFullPath($GamePath)
$resolvedGsePath = [System.IO.Path]::GetFullPath($GseSteamApiPath)
$gameParent = Split-Path -Parent $resolvedGamePath
if ([string]::IsNullOrWhiteSpace($InstanceRoot)) {
    $InstanceRoot = Join-Path $gameParent "S1NetGuard.ReproInstances"
}
$resolvedInstanceRoot = [System.IO.Path]::GetFullPath($InstanceRoot)
$gamePrefix = $resolvedGamePath.TrimEnd('\') + '\'
$instancePrefix = $resolvedInstanceRoot.TrimEnd('\') + '\'
if ($resolvedInstanceRoot.StartsWith($gamePrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
    $resolvedGamePath.StartsWith($instancePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "The game and instance roots must not contain one another."
}
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot "..\.."))

if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    $EvidenceRoot = Join-Path $repoRoot "artifacts\admission-repro"
}
$resolvedEvidenceRoot = [System.IO.Path]::GetFullPath($EvidenceRoot)

Assert-Path -Path (Join-Path $resolvedGamePath "Schedule I.exe") -Description "Schedule I executable"
Assert-Path -Path (Join-Path $resolvedGamePath "Schedule I_Data\Managed\Assembly-CSharp.dll") -Description "Mono Assembly-CSharp"
Assert-Path -Path $resolvedGsePath -Description "GSE steam_api64.dll"
Assert-Path -Path (Join-Path $resolvedGamePath "Schedule I_Data\StreamingAssets\DefaultSave") -Description "Default save fixture"

if ($HostSteamId -eq $ClientSteamId) {
    throw "HostSteamId and ClientSteamId must be different."
}

if ($VerifyRpcDefense -and (-not $ProtectHost -or $Scenario -ne "Impact")) {
    throw "VerifyRpcDefense requires -ProtectHost -Scenario Impact."
}

$gseVersion = (Get-Item -LiteralPath $resolvedGsePath).VersionInfo
if ($gseVersion.CompanyName -ne "GSE") {
    throw "The supplied Steam API is not identified as GSE: $resolvedGsePath"
}

$existingProcesses = @(Get-CimInstance Win32_Process | Where-Object {
    $_.ExecutablePath -and $_.Name -eq "Schedule I.exe"
})
if ($existingProcesses.Count -gt 0) {
    throw "Refusing to run while an existing Schedule I process is active."
}

$runId = "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), ([Guid]::NewGuid().ToString("N").Substring(0, 8))
$runRoot = Join-Path $resolvedInstanceRoot $runId
$hostPath = Join-Path $runRoot "host"
$clientPath = Join-Path $runRoot "client"
$sharedPath = Join-Path $runRoot "shared"
$evidencePath = Join-Path $resolvedEvidenceRoot $runId
$hostEvidence = Join-Path $sharedPath "host-events.txt"
$clientEvidence = Join-Path $sharedPath "client-events.txt"
$hostReady = Join-Path $sharedPath "host-ready.txt"
$hostPlayerLog = Join-Path $sharedPath "host-player.log"
$clientPlayerLog = Join-Path $sharedPath "client-player.log"
$hostProcess = $null
$clientProcess = $null

try {
    New-Item -ItemType Directory -Path $sharedPath -Force | Out-Null
    New-Item -ItemType Directory -Path $evidencePath -Force | Out-Null

    Write-Host "Building admission probe..." -ForegroundColor Cyan
    & dotnet build (Join-Path $scriptRoot "S1NetGuard.ReproProbe.csproj") -c Release -p:GamePath=$resolvedGamePath
    if ($LASTEXITCODE -ne 0) {
        throw "Admission probe build failed."
    }

    $probeDll = Join-Path $scriptRoot "bin\Release\netstandard2.1\S1NetGuard.AdmissionRepro.dll"
    Assert-Path -Path $probeDll -Description "Admission probe DLL"

    $guardDll = $null
    if ($ProtectHost) {
        Write-Host "Building S1NetGuard host protection..." -ForegroundColor Cyan
        & dotnet build (Join-Path $repoRoot "S1NetGuard.csproj") -c Mono -p:AutomateLocalDeployment=false
        if ($LASTEXITCODE -ne 0) {
            throw "S1NetGuard Mono build failed."
        }

        $guardDll = Join-Path $repoRoot "bin\Mono\netstandard2.1\S1NetGuard_Mono.dll"
        Assert-Path -Path $guardDll -Description "S1NetGuard Mono DLL"
    }

    Write-Host "Preparing isolated host and client installs..." -ForegroundColor Cyan
    Copy-IsolatedGame -SourcePath $resolvedGamePath -DestinationPath $hostPath
    Copy-IsolatedGame -SourcePath $resolvedGamePath -DestinationPath $clientPath
    Set-GseIdentity -InstancePath $hostPath -SteamId $HostSteamId -AccountName "S1NG-Repro-Host" -SteamApiSource $resolvedGsePath
    Set-GseIdentity -InstancePath $clientPath -SteamId $ClientSteamId -AccountName "S1NG-Repro-Client" -SteamApiSource $resolvedGsePath
    Copy-Item -LiteralPath $probeDll -Destination (Join-Path $hostPath "Mods") -Force
    Copy-Item -LiteralPath $probeDll -Destination (Join-Path $clientPath "Mods") -Force
    if ($ProtectHost) {
        Copy-Item -LiteralPath $guardDll -Destination (Join-Path $hostPath "Mods") -Force
    }
    if ($VerifyRpcDefense) {
        $preferences = @(
            "[S1NetGuard]",
            "EnableAdmissionGate = true",
            "AllowedSteamIds = `"$ClientSteamId`"",
            "EnableRpcDefenseInDepth = true",
            "DisconnectOnRpcViolation = false"
        ) -join [Environment]::NewLine
        [System.IO.File]::WriteAllText((Join-Path $hostPath "UserData\MelonPreferences.cfg"), $preferences)
    }
    Copy-Item -LiteralPath (Join-Path $resolvedGamePath "Schedule I_Data\StreamingAssets\DefaultSave") -Destination (Join-Path $sharedPath "host-save") -Recurse -Force

    $manifest = @(
        "runId=$runId",
        "scenario=$Scenario",
        "runtime=Mono",
        "protectHost=$($ProtectHost.IsPresent.ToString().ToLowerInvariant())",
        "verifyRpcDefense=$($VerifyRpcDefense.IsPresent.ToString().ToLowerInvariant())",
        "gamePath=$resolvedGamePath",
        "assemblySha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $resolvedGamePath 'Schedule I_Data\Managed\Assembly-CSharp.dll')).Hash)",
        "gsePath=$resolvedGsePath",
        "gseSha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedGsePath).Hash)",
        "gseVersion=$($gseVersion.FileVersion)",
        "hostSteamId=$HostSteamId",
        "clientSteamId=$ClientSteamId",
        "startedUtc=$([DateTime]::UtcNow.ToString('O'))"
    )
    [System.IO.File]::WriteAllLines((Join-Path $sharedPath "manifest.txt"), $manifest)

    $scenarioArgument = $Scenario.ToLowerInvariant()
    $hostArguments = @(
        "--s1ng-repro-role", "host",
        "--s1ng-repro-scenario", $scenarioArgument,
        "--s1ng-repro-evidence", "`"$hostEvidence`"",
        "--s1ng-repro-peer", $ClientSteamId,
        "-logFile", "`"$hostPlayerLog`""
    )
    $clientArguments = @(
        "--s1ng-repro-role", "client",
        "--s1ng-repro-scenario", $scenarioArgument,
        "--s1ng-repro-evidence", "`"$clientEvidence`"",
        "--s1ng-repro-peer", $HostSteamId,
        "-logFile", "`"$clientPlayerLog`""
    )
    if ($VerifyRpcDefense) {
        $hostArguments += "--s1ng-repro-expect-blocked-impact"
    }

    Write-Host "Launching host..." -ForegroundColor Cyan
    $hostProcess = Start-Process -FilePath (Join-Path $hostPath "Schedule I.exe") -ArgumentList $hostArguments -WorkingDirectory $hostPath -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Wait-ForFile -Path $hostReady -Deadline $deadline -Owner $hostProcess -Phase "host-ready"

    Write-Host "Launching client..." -ForegroundColor Cyan
    $clientProcess = Start-Process -FilePath (Join-Path $clientPath "Schedule I.exe") -ArgumentList $clientArguments -WorkingDirectory $clientPath -PassThru -WindowStyle Hidden

    $terminalEvent = if ($Scenario -eq "Lobby") {
        "client_lobby_final"
    }
    elseif ($VerifyRpcDefense) {
        "host_impact_blocked_persistence_final"
    }
    elseif ($Scenario -eq "Impact") {
        "host_impact_persistence_final"
    }
    else {
        "client_direct_final"
    }
    $expectedRejection = "Rejected SteamID $ClientSteamId \(NotInCurrentLobby, connection"
    $lastProgress = [datetime]::MinValue
    while ((Get-Date) -lt $deadline) {
        if ($clientProcess.HasExited) {
            throw "Client exited before $terminalEvent. ExitCode=$($clientProcess.ExitCode)"
        }
        if ($hostProcess.HasExited) {
            throw "Host exited before $terminalEvent. ExitCode=$($hostProcess.ExitCode)"
        }

        if ($ProtectHost -and $Scenario -eq "Direct") {
            $hostMelonLog = Join-Path $hostPath "MelonLoader\Latest.log"
            if ((Test-Path -LiteralPath $hostMelonLog) -and
                (Get-Content -LiteralPath $hostMelonLog -Raw -ErrorAction SilentlyContinue) -match $expectedRejection) {
                Start-Sleep -Seconds 8
                break
            }
        }
        else {
            $terminalEvidence = if ($Scenario -eq "Impact") { $hostEvidence } else { $clientEvidence }
            if ((Test-Path -LiteralPath $terminalEvidence) -and
                (Get-Content -LiteralPath $terminalEvidence -Raw -ErrorAction SilentlyContinue) -match "\|$terminalEvent\|") {
                break
            }
        }

        if (((Get-Date) - $lastProgress).TotalSeconds -ge 5) {
            $hostLast = if (Test-Path -LiteralPath $hostEvidence) { Get-Content -LiteralPath $hostEvidence | Select-Object -Last 1 } else { "no host evidence" }
            $clientLast = if (Test-Path -LiteralPath $clientEvidence) { Get-Content -LiteralPath $clientEvidence | Select-Object -Last 1 } else { "no client evidence" }
            Write-Host "Host: $hostLast" -ForegroundColor DarkGray
            Write-Host "Client: $clientLast" -ForegroundColor DarkGray
            $lastProgress = Get-Date
        }

        Start-Sleep -Milliseconds 500
    }

    if ($ProtectHost -and $Scenario -eq "Direct") {
        $hostMelonLog = Join-Path $hostPath "MelonLoader\Latest.log"
        $hostEventsText = Get-Content -LiteralPath $hostEvidence -Raw
        $clientEventsText = Get-Content -LiteralPath $clientEvidence -Raw
        if ((Get-Content -LiteralPath $hostMelonLog -Raw) -notmatch $expectedRejection) {
            throw "Protected host did not log the expected NotInCurrentLobby rejection."
        }
        if ($hostEventsText -match "fishnet_client_authenticated.*transportAddress=$ClientSteamId") {
            throw "Protected host authenticated the rejected client."
        }
        if ($clientEventsText -match "\|client_direct_final\|") {
            throw "Rejected client still reached the loaded-game terminal event."
        }
    }
    else {
        $terminalEvidence = if ($Scenario -eq "Impact") { $hostEvidence } else { $clientEvidence }
        if (-not (Test-Path -LiteralPath $terminalEvidence) -or
            (Get-Content -LiteralPath $terminalEvidence -Raw) -notmatch "\|$terminalEvent\|") {
            throw "Timed out waiting for terminal event $terminalEvent."
        }
        if ($Scenario -eq "Impact") {
            $hostEventsText = Get-Content -LiteralPath $hostEvidence -Raw
            if ($VerifyRpcDefense) {
                $hostMelonText = Get-Content -LiteralPath (Join-Path $hostPath "MelonLoader\Latest.log") -Raw
                foreach ($capability in @("shared-money mutation", "free-text worldspace dialogue", "NPC target control")) {
                    if ($hostMelonText -notmatch "Blocked remote $([regex]::Escape($capability)) RPC from SteamID $ClientSteamId") {
                        throw "RPC defense did not log a block for $capability."
                    }
                }
                if ($hostEventsText -notmatch "\|host_impact_blocked_runtime_final\|.*onlineBalance=0(?:\.0+)?(?:\||$)") {
                    throw "RPC defense did not preserve the baseline runtime balance."
                }
                if ($hostEventsText -notmatch "\|host_impact_blocked_persistence_final\|.*persisted=true.*persistedOnlineBalance=0(?:\.0+)?(?:\||$)") {
                    throw "RPC defense did not preserve the baseline persisted balance."
                }
            }
            else {
                if ($hostEventsText -notmatch "\|host_impact_runtime_final\|.*moneyApplied=true.*dialogueApplied=true.*combatApplied=true") {
                    throw "Impact runtime assertions did not all pass."
                }
                if ($hostEventsText -notmatch "\|host_impact_persistence_final\|.*persisted=true") {
                    throw "Impact persistence assertion did not pass."
                }
            }
        }
    }

    Start-Sleep -Seconds 2
}
finally {
    New-Item -ItemType Directory -Path $evidencePath -Force | Out-Null
    foreach ($entry in @(
        @{ Source = (Join-Path $sharedPath "manifest.txt"); Name = "manifest.txt" },
        @{ Source = $hostEvidence; Name = "host-events.txt" },
        @{ Source = $clientEvidence; Name = "client-events.txt" },
        @{ Source = $hostPlayerLog; Name = "host-player.log" },
        @{ Source = $clientPlayerLog; Name = "client-player.log" },
        @{ Source = (Join-Path $hostPath "MelonLoader\Latest.log"); Name = "host-melon.log" },
        @{ Source = (Join-Path $clientPath "MelonLoader\Latest.log"); Name = "client-melon.log" }
    )) {
        if (Test-Path -LiteralPath $entry.Source) {
            Copy-Item -LiteralPath $entry.Source -Destination (Join-Path $evidencePath $entry.Name) -Force
        }
    }

    Stop-LaunchedProcess -Process $clientProcess -Role "client"
    Stop-LaunchedProcess -Process $hostProcess -Role "host"

    if (-not $KeepInstances -and (Test-Path -LiteralPath $runRoot)) {
        Start-Sleep -Seconds 1
        Remove-IsolatedRoot -Path $runRoot -AllowedRoot $resolvedInstanceRoot
    }

    Write-Host "Evidence preserved at: $evidencePath" -ForegroundColor Green
}

$clientFinal = Get-Content -LiteralPath (Join-Path $evidencePath "client-events.txt") | Select-Object -Last 1
$hostFinal = Get-Content -LiteralPath (Join-Path $evidencePath "host-events.txt") | Select-Object -Last 1
Write-Host "Host final: $hostFinal" -ForegroundColor Gray
Write-Host "Client final: $clientFinal" -ForegroundColor Gray
$protectionLabel = if ($VerifyRpcDefense) { "RpcDefense" } elseif ($ProtectHost) { "Protected" } else { "Baseline" }
Write-Output "PASS|S1NetGuard.AdmissionRepro|$Scenario|$protectionLabel|evidence=$evidencePath"
