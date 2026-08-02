[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Host", "Client")]
    [string]$Role,

    [ValidateSet("Lobby", "Direct", "Impact")]
    [string]$Scenario = "Lobby",

    [ValidateSet("Baseline", "AdmissionGate", "RpcDefense")]
    [string]$Protection = "Baseline",

    [Parameter(Mandatory = $true)]
    [string]$GamePath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^7656119[0-9]{10}$')]
    [string]$ExpectedPeerSteamId,

    [string]$EvidenceRoot = "",

    [string]$ProbeDll = "",

    [string]$GuardDll = "",

    [ValidatePattern('^(|7656119[0-9]{10})$')]
    [string]$HostSteamId = "",

    [ValidatePattern('^(|[0-9]{15,20})$')]
    [string]$LobbyId = "",

    [ValidateRange(60, 300)]
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ProbeDll)) {
    $bundledProbe = Join-Path $PSScriptRoot "S1NetGuard.AdmissionRepro.dll"
    $ProbeDll = if (Test-Path -LiteralPath $bundledProbe -PathType Leaf) {
        $bundledProbe
    }
    else {
        Join-Path $PSScriptRoot "bin\Release\netstandard2.1\S1NetGuard.AdmissionRepro.dll"
    }
}

if ([string]::IsNullOrWhiteSpace($GuardDll)) {
    $bundledGuard = Join-Path $PSScriptRoot "S1NetGuard_Mono.dll"
    $GuardDll = if (Test-Path -LiteralPath $bundledGuard -PathType Leaf) {
        $bundledGuard
    }
    else {
        Join-Path $PSScriptRoot "..\..\bin\Mono\netstandard2.1\S1NetGuard_Mono.dll"
    }
}

function Assert-File {
    param([string]$Path, [string]$Description)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description not found: $Path"
    }
}

function Read-EvidenceText {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $reader = [System.IO.StreamReader]::new($stream)
        try {
            return $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

$resolvedGamePath = [System.IO.Path]::GetFullPath($GamePath)
$resolvedProbeDll = [System.IO.Path]::GetFullPath($ProbeDll)
$executable = Join-Path $resolvedGamePath "Schedule I.exe"
$managedAssembly = Join-Path $resolvedGamePath "Schedule I_Data\Managed\Assembly-CSharp.dll"
$fishNetAssembly = Join-Path $resolvedGamePath "Schedule I_Data\Managed\FishNet.Runtime.dll"
$steamworksNetAssembly = Join-Path $resolvedGamePath "Schedule I_Data\Managed\com.rlabrecque.steamworks.net.dll"
$melonLoaderAssembly = Join-Path $resolvedGamePath "MelonLoader\net35\MelonLoader.dll"
$steamApi = Join-Path $resolvedGamePath "Schedule I_Data\Plugins\x86_64\steam_api64.dll"
$modsPath = Join-Path $resolvedGamePath "Mods"
$cloneMarker = Join-Path $resolvedGamePath ".s1ng-live-control-clone"
$defaultSave = Join-Path $resolvedGamePath "Schedule I_Data\StreamingAssets\DefaultSave"

Assert-File $executable "Schedule I executable"
Assert-File $managedAssembly "Mono Assembly-CSharp"
Assert-File $fishNetAssembly "FishNet runtime assembly"
Assert-File $steamworksNetAssembly "Steamworks.NET assembly"
Assert-File $melonLoaderAssembly "MelonLoader assembly"
Assert-File $steamApi "Steam API"
Assert-File $resolvedProbeDll "Probe DLL"

if (-not (Test-Path -LiteralPath $cloneMarker -PathType Leaf)) {
    throw "The selected game path is not an isolated live-control clone. Create it with New-CleanMonoClone.ps1."
}

if ((Get-Item -LiteralPath $steamApi).VersionInfo.CompanyName -eq "GSE") {
    throw "The selected game uses GSE. This control requires Valve's Steam API."
}

if (-not (Get-Process -Name "steam" -ErrorAction SilentlyContinue)) {
    throw "The Steam client is not running. A live Valve control cannot use the game's mock lobby fallback."
}

if ($Role -eq "Client" -and ([string]::IsNullOrWhiteSpace($HostSteamId) -or [string]::IsNullOrWhiteSpace($LobbyId))) {
    throw "Client role requires both -HostSteamId and -LobbyId from the host handoff."
}

if ($Protection -ne "Baseline" -and $Role -ne "Host") {
    throw "Protection is configured only on the host. Use -Protection Baseline for the client."
}
if ($Protection -eq "AdmissionGate" -and $Scenario -ne "Direct") {
    throw "AdmissionGate protection is valid only for the Direct scenario."
}
if ($Protection -eq "RpcDefense" -and $Scenario -ne "Impact") {
    throw "RpcDefense protection is valid only for the Impact scenario."
}
if ($Scenario -eq "Lobby" -and $Protection -ne "Baseline") {
    throw "The Lobby control must run without S1NetGuard protection."
}
if ($Scenario -ne "Lobby" -and -not (Test-Path -LiteralPath $defaultSave -PathType Container)) {
    throw "Default save fixture not found: $defaultSave"
}

$resolvedGuardDll = ""
if ($Protection -ne "Baseline") {
    $resolvedGuardDll = [System.IO.Path]::GetFullPath($GuardDll)
    Assert-File $resolvedGuardDll "S1NetGuard Mono DLL"
}

$existingModDlls = @(Get-ChildItem -LiteralPath $modsPath -File -Filter "*.dll" -ErrorAction SilentlyContinue)
if ($existingModDlls.Count -gt 0) {
    $names = ($existingModDlls.Name | Sort-Object) -join ", "
    throw "The live control requires a clean Mods directory. Found: $names"
}

$existingGame = @(Get-CimInstance Win32_Process | Where-Object {
    $_.ExecutablePath -and
    [System.IO.Path]::GetFullPath($_.ExecutablePath).Equals($executable, [System.StringComparison]::OrdinalIgnoreCase)
})
if ($existingGame.Count -gt 0) {
    throw "Schedule I is already running from the selected game path."
}

if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    $EvidenceRoot = Join-Path ([System.IO.Path]::GetTempPath()) "S1NetGuard.LiveValveEvidence"
}
$resolvedEvidenceRoot = [System.IO.Path]::GetFullPath($EvidenceRoot)
$runId = "{0}-{1}-{2}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $Role.ToLowerInvariant(), ([Guid]::NewGuid().ToString("N").Substring(0, 8))
$runPath = Join-Path $resolvedEvidenceRoot $runId
$eventPath = Join-Path $runPath "$($Role.ToLowerInvariant())-events.txt"
$playerLog = Join-Path $runPath "$($Role.ToLowerInvariant())-player.log"
$deployedProbe = Join-Path $modsPath "S1NetGuard.AdmissionRepro.dll"
$deployedGuard = Join-Path $modsPath "S1NetGuard_Mono.dll"
$preferencesPath = Join-Path $resolvedGamePath "UserData\MelonPreferences.cfg"
$preferencesBackup = Join-Path $runPath "MelonPreferences.before-run.cfg"
$process = $null
$deployed = $false
$guardDeployed = $false
$preferencesExisted = Test-Path -LiteralPath $preferencesPath -PathType Leaf

New-Item -ItemType Directory -Path $runPath -Force | Out-Null

$protectionPreferences = @()
$protectionConfigPath = Join-Path $runPath "applied-protection.cfg"
$protectionConfigHash = "none"
if ($Protection -ne "Baseline") {
    $protectionPreferences = if ($Protection -eq "RpcDefense") {
        @(
            "[S1NetGuard]",
            "EnableAdmissionGate = true",
            "AllowedSteamIds = `"$ExpectedPeerSteamId`"",
            "EnableRpcDefenseInDepth = true",
            "DisconnectOnRpcViolation = false"
        )
    }
    else {
        @(
            "[S1NetGuard]",
            "EnableAdmissionGate = true",
            "AllowedSteamIds = `"`"",
            "EnableRpcDefenseInDepth = true",
            "DisconnectOnRpcViolation = false"
        )
    }
    [System.IO.File]::WriteAllLines($protectionConfigPath, $protectionPreferences)
    $protectionConfigHash = (Get-FileHash -LiteralPath $protectionConfigPath -Algorithm SHA256).Hash
}

$manifest = @(
    "runId=$runId",
    "role=$Role",
    "backend=ValveSteam",
    "runtime=Mono",
    "scenario=$Scenario",
    "protection=$Protection",
    "expectedPeerSteamId=$ExpectedPeerSteamId",
    "suppliedHostSteamId=$HostSteamId",
    "suppliedLobbyId=$LobbyId",
    "gamePath=$resolvedGamePath",
    "assemblySha256=$((Get-FileHash -LiteralPath $managedAssembly -Algorithm SHA256).Hash)",
    "fishNetSha256=$((Get-FileHash -LiteralPath $fishNetAssembly -Algorithm SHA256).Hash)",
    "steamworksNetSha256=$((Get-FileHash -LiteralPath $steamworksNetAssembly -Algorithm SHA256).Hash)",
    "melonLoaderSha256=$((Get-FileHash -LiteralPath $melonLoaderAssembly -Algorithm SHA256).Hash)",
    "steamApiSha256=$((Get-FileHash -LiteralPath $steamApi -Algorithm SHA256).Hash)",
    "probeSha256=$((Get-FileHash -LiteralPath $resolvedProbeDll -Algorithm SHA256).Hash)",
    "guardSha256=$(if ($Protection -eq 'Baseline') { 'none' } else { (Get-FileHash -LiteralPath $resolvedGuardDll -Algorithm SHA256).Hash })",
    "protectionConfigSha256=$protectionConfigHash",
    "startedUtc=$([DateTime]::UtcNow.ToString('O'))"
)
[System.IO.File]::WriteAllLines((Join-Path $runPath "manifest.txt"), $manifest)

try {
    if ($Role -eq "Host" -and $Scenario -ne "Lobby") {
        Copy-Item -LiteralPath $defaultSave -Destination (Join-Path $runPath "host-save") -Recurse -Force
    }

    Copy-Item -LiteralPath $resolvedProbeDll -Destination $deployedProbe
    $deployed = $true

    if ($Protection -ne "Baseline") {
        Copy-Item -LiteralPath $resolvedGuardDll -Destination $deployedGuard
        $guardDeployed = $true
        if ($preferencesExisted) {
            Copy-Item -LiteralPath $preferencesPath -Destination $preferencesBackup -Force
        }

        [System.IO.File]::WriteAllLines($preferencesPath, $protectionPreferences)
    }

    $arguments = @(
        "--s1ng-repro-role", $Role.ToLowerInvariant(),
        "--s1ng-repro-scenario", $Scenario.ToLowerInvariant(),
        "--s1ng-repro-evidence", "`"$eventPath`"",
        "--s1ng-repro-peer", $ExpectedPeerSteamId,
        "-logFile", "`"$playerLog`""
    )
    if ($Role -eq "Client") {
        $arguments += @(
            "--s1ng-repro-host-steamid", $HostSteamId,
            "--s1ng-repro-lobby-id", $LobbyId
        )
    }
    elseif ($Protection -eq "RpcDefense") {
        $arguments += "--s1ng-repro-expect-blocked-impact"
    }

    $process = Start-Process -FilePath $executable -ArgumentList $arguments -WorkingDirectory $resolvedGamePath -PassThru -WindowStyle Hidden
    $terminalEvent = if ($Scenario -eq "Lobby") {
        if ($Role -eq "Host") { "host_lobby_final" } else { "client_lobby_final" }
    }
    elseif ($Scenario -eq "Impact") {
        if ($Role -eq "Host") {
            if ($Protection -eq "RpcDefense") { "host_impact_blocked_persistence_final" } else { "host_impact_persistence_final" }
        }
        else {
            "client_impact_after"
        }
    }
    else {
        if ($Role -eq "Host") { "host_direct_final" } else { "client_direct_final" }
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $handoffShown = $false

    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) {
            throw "Game exited before $terminalEvent. ExitCode=$($process.ExitCode)"
        }

        $text = Read-EvidenceText $eventPath
        $playerText = Read-EvidenceText $playerLog
        if ($playerText -match "SteamAPI_Init\(\) failed" -or
            $playerText -match "Lobby service not available, using mock implementation") {
            throw "Valve Steam initialization failed; this run is invalid and must not be used as live-backend evidence."
        }

        if ($Role -eq "Host" -and -not $handoffShown) {
            $handoffPath = Join-Path $runPath "host-ready.txt"
            if (Test-Path -LiteralPath $handoffPath) {
                $handoff = (Get-Content -LiteralPath $handoffPath -Raw).Trim()
                Write-Host "HOST_HANDOFF=$handoff" -ForegroundColor Yellow
                Write-Host "Give this exact value to the controlled client operator." -ForegroundColor Yellow
                $handoffShown = $true
            }
        }

        if ($text -match "\|$terminalEvent\|") {
            break
        }

        Start-Sleep -Milliseconds 500
    }

    $finalText = Read-EvidenceText $eventPath
    if ($finalText -notmatch "\|$terminalEvent\|") {
        throw "Timed out waiting for $terminalEvent."
    }

    if ($Role -eq "Client" -and $Scenario -eq "Lobby" -and $finalText -notmatch "\|lobby_enter_callback\|.*lobbyId=$LobbyId\|") {
        throw "Client completed without a LobbyEnter_t callback for lobby $LobbyId."
    }

    Write-Output "PASS|S1NetGuard.LiveValveProbe|$Scenario|$Protection|$Role|evidence=$runPath"
}
finally {
    $melonLog = Join-Path $resolvedGamePath "MelonLoader\Latest.log"
    if (Test-Path -LiteralPath $melonLog) {
        Copy-Item -LiteralPath $melonLog -Destination (Join-Path $runPath "$($Role.ToLowerInvariant())-melon.log") -Force
    }

    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit(10000) | Out-Null
    }

    if ($deployed -and (Test-Path -LiteralPath $deployedProbe)) {
        Remove-Item -LiteralPath $deployedProbe -Force
    }
    if ($guardDeployed -and (Test-Path -LiteralPath $deployedGuard)) {
        Remove-Item -LiteralPath $deployedGuard -Force
    }
    if ($Protection -ne "Baseline") {
        if ($preferencesExisted -and (Test-Path -LiteralPath $preferencesBackup -PathType Leaf)) {
            Copy-Item -LiteralPath $preferencesBackup -Destination $preferencesPath -Force
        }
        elseif (Test-Path -LiteralPath $preferencesPath -PathType Leaf) {
            Remove-Item -LiteralPath $preferencesPath -Force
        }
    }
}
