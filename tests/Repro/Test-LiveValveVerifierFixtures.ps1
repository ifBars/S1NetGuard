[CmdletBinding()]
param(
    [string]$OutputRoot = (Join-Path $PSScriptRoot ("live-validator-tests-v2\" + (Get-Date -Format "yyyyMMdd-HHmmss")))
)

$ErrorActionPreference = "Stop"
$verifier = Join-Path $PSScriptRoot "Test-LiveValveEvidence.ps1"
$hostId = "76561198000000071"
$clientId = "76561198000000072"
$lobbyId = "109775240000000001"
$assemblyHash = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
$steamApiHash = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
$probeHash = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
$guardHash = $assemblyHash.Replace('A', 'D')

function New-Fixture {
    param(
        [string]$Name,
        [string]$Scenario,
        [string]$Protection,
        [string[]]$HostEvents,
        [string[]]$ClientEvents,
        [string[]]$HostMelon = @()
    )

    $root = Join-Path $OutputRoot $Name
    $hostPath = Join-Path $root "host"
    $clientPath = Join-Path $root "client"
    New-Item -ItemType Directory -Path $hostPath,$clientPath -Force | Out-Null

    $protectionConfigHash = "none"
    if ($Protection -ne 'Baseline') {
        $protectionConfig = if ($Protection -eq 'RpcDefense') {
            @(
                '[S1NetGuard]',
                'EnableAdmissionGate = true',
                "AllowedSteamIds = `"$clientId`"",
                'EnableRpcDefenseInDepth = true',
                'DisconnectOnRpcViolation = false'
            )
        }
        else {
            @(
                '[S1NetGuard]',
                'EnableAdmissionGate = true',
                'AllowedSteamIds = ""',
                'EnableRpcDefenseInDepth = true',
                'DisconnectOnRpcViolation = false'
            )
        }
        $protectionConfigPath = Join-Path $hostPath 'applied-protection.cfg'
        [System.IO.File]::WriteAllLines($protectionConfigPath, $protectionConfig)
        $protectionConfigHash = (Get-FileHash -LiteralPath $protectionConfigPath -Algorithm SHA256).Hash
    }

    $hostManifest = @(
        "runId=$Name-host",
        "role=Host",
        "backend=ValveSteam",
        "runtime=Mono",
        "scenario=$Scenario",
        "protection=$Protection",
        "expectedPeerSteamId=$clientId",
        "suppliedHostSteamId=",
        "suppliedLobbyId=",
        "assemblySha256=$assemblyHash",
        "steamApiSha256=$steamApiHash",
        "probeSha256=$probeHash",
        "guardSha256=$(if ($Protection -eq 'Baseline') { 'none' } else { $guardHash })",
        "protectionConfigSha256=$protectionConfigHash"
    )
    $clientManifest = @(
        "runId=$Name-client",
        "role=Client",
        "backend=ValveSteam",
        "runtime=Mono",
        "scenario=$Scenario",
        "protection=Baseline",
        "expectedPeerSteamId=$hostId",
        "suppliedHostSteamId=$hostId",
        "suppliedLobbyId=$lobbyId",
        "assemblySha256=$assemblyHash",
        "steamApiSha256=$steamApiHash",
        "probeSha256=$probeHash",
        "guardSha256=none",
        "protectionConfigSha256=none"
    )

    [System.IO.File]::WriteAllLines((Join-Path $hostPath "manifest.txt"), $hostManifest)
    [System.IO.File]::WriteAllLines((Join-Path $clientPath "manifest.txt"), $clientManifest)
    [System.IO.File]::WriteAllLines((Join-Path $hostPath "host-events.txt"), $HostEvents)
    [System.IO.File]::WriteAllLines((Join-Path $clientPath "client-events.txt"), $ClientEvents)
    if ($HostMelon.Count -gt 0) {
        [System.IO.File]::WriteAllLines((Join-Path $hostPath "host-melon.log"), $HostMelon)
    }

    return @{ Host = $hostPath; Client = $clientPath }
}

function Invoke-Fixture {
    param(
        [hashtable]$Fixture,
        [string]$Scenario,
        [string]$Protection,
        [string]$ExpectedVerdict
    )

    $result = & $verifier `
        -HostRunPath $Fixture.Host `
        -ClientRunPath $Fixture.Client `
        -HostSteamId $hostId `
        -ClientSteamId $clientId `
        -LobbyId $lobbyId `
        -Scenario $Scenario `
        -Protection $Protection
    if ($result -notlike "$ExpectedVerdict*") {
        throw "Expected $ExpectedVerdict, received: $result"
    }
    Write-Output "PASS|Fixture|$ExpectedVerdict"
}

function Get-CommonHostEvents {
    param([string]$Scenario)
    return @(
        "t|probe_initialized|role=host|scenario=$($Scenario.ToLowerInvariant())|applicationVersion=0.4.6f11 Alternate",
        "t|steam_ready|role=host|scenario=$($Scenario.ToLowerInvariant())|localSteamId=$hostId|expectedPeerSteamId=$clientId|expectedPeerIsImmediateFriend=false|scene=Menu",
        "t|host_create_lobby_requested|role=host|scenario=$($Scenario.ToLowerInvariant())|requestedType=k_ELobbyTypeFriendsOnly",
        "t|steam_create_lobby_api|role=host|scenario=$($Scenario.ToLowerInvariant())|requestedType=k_ELobbyTypeFriendsOnly|maxMembers=4",
        "t|lobby_created_callback|role=host|scenario=$($Scenario.ToLowerInvariant())|result=k_EResultOK|lobbyId=$lobbyId|localSteamId=$hostId"
    )
}

function Get-CommonClientEvents {
    param([string]$Scenario)
    return @(
        "t|probe_initialized|role=client|scenario=$($Scenario.ToLowerInvariant())|applicationVersion=0.4.6f11 Alternate",
        "t|steam_ready|role=client|scenario=$($Scenario.ToLowerInvariant())|localSteamId=$clientId|expectedPeerSteamId=$hostId|expectedPeerIsImmediateFriend=false|scene=Menu"
    )
}

$hostLobbyAccepted = (Get-CommonHostEvents "Lobby") + @(
    "t|lobby_chat_update_callback|role=host|scenario=lobby|lobbyId=$lobbyId|changedSteamId=$clientId|actorSteamId=$clientId|state=k_EChatMemberStateChangeEntered|stateRaw=1",
    "t|host_lobby_final|role=host|scenario=lobby|lobbyId=$lobbyId|isInLobby=true|isHost=true|memberCount=2|memberIds=$hostId,$clientId"
)
$clientLobbyAccepted = (Get-CommonClientEvents "Lobby") + @(
    "t|client_join_lobby_requested|role=client|scenario=lobby|lobbyId=$lobbyId",
    "t|steam_join_lobby_api|role=client|scenario=lobby|lobbyId=$lobbyId",
    "t|lobby_enter_callback|role=client|scenario=lobby|lobbyId=$lobbyId|locked=0|response=k_EChatRoomEnterResponseSuccess|responseRaw=1",
    "t|client_lobby_final|role=client|scenario=lobby|lobbyId=$lobbyId|isInLobby=true|isHost=false|memberCount=2|memberIds=$hostId,$clientId"
)
$fixture = New-Fixture "lobby-accepted" "Lobby" "Baseline" $hostLobbyAccepted $clientLobbyAccepted
Invoke-Fixture $fixture "Lobby" "Baseline" "VERDICT|ValveAcceptedUnrelatedIdentity|"

$hostLobbyDenied = (Get-CommonHostEvents "Lobby") + @(
    "t|host_lobby_final|role=host|scenario=lobby|lobbyId=$lobbyId|isInLobby=true|isHost=true|memberCount=1|memberIds=$hostId"
)
$clientLobbyDenied = (Get-CommonClientEvents "Lobby") + @(
    "t|client_join_lobby_requested|role=client|scenario=lobby|lobbyId=$lobbyId",
    "t|steam_join_lobby_api|role=client|scenario=lobby|lobbyId=$lobbyId",
    "t|lobby_enter_callback|role=client|scenario=lobby|lobbyId=$lobbyId|locked=0|response=k_EChatRoomEnterResponseNotAllowed|responseRaw=4",
    "t|client_lobby_final|role=client|scenario=lobby|lobbyId=$lobbyId|isInLobby=false|isHost=false|memberCount=0|memberIds="
)
$fixture = New-Fixture "lobby-denied" "Lobby" "Baseline" $hostLobbyDenied $clientLobbyDenied
Invoke-Fixture $fixture "Lobby" "Baseline" "VERDICT|ValveEnforcedFriendsOnly|"

function Get-DirectHostEvents {
    param([string]$Scenario, [bool]$Authenticated)
    $events = (Get-CommonHostEvents $Scenario) + @(
        "t|host_direct_ready|role=host|scenario=$($Scenario.ToLowerInvariant())|lobbyId=$lobbyId|isInLobby=true|isHost=true|memberCount=1|memberIds=$hostId",
        "t|fishnet_remote_started|role=host|scenario=$($Scenario.ToLowerInvariant())|connectionId=1|transportIndex=0|transportAddress=$clientId|peerInLobby=false"
    )
    if ($Authenticated) {
        $events += "t|fishnet_client_authenticated|role=host|scenario=$($Scenario.ToLowerInvariant())|connectionId=1|transportAddress=$clientId|peerInLobby=false|authenticatedBeforeCall=false"
    }
    return $events
}

function Get-DirectClientEvents {
    param([string]$Scenario, [bool]$Loaded)
    return (Get-CommonClientEvents $Scenario) + @(
        "t|client_host_ready|role=client|scenario=$($Scenario.ToLowerInvariant())|hostSteamId=$hostId|lobbyId=$lobbyId|clientInLobbyBeforeAction=false",
        "t|client_direct_start|role=client|scenario=$($Scenario.ToLowerInvariant())|hostSteamId=$hostId|clientInLobby=false",
        "t|client_direct_final|role=client|scenario=$($Scenario.ToLowerInvariant())|clientInLobby=false|fishNetClient=$($Loaded.ToString().ToLowerInvariant())|localPlayerSpawned=$($Loaded.ToString().ToLowerInvariant())|gameLoaded=$($Loaded.ToString().ToLowerInvariant())|authenticated=$($Loaded.ToString().ToLowerInvariant())|scene=$(if ($Loaded) { 'Main' } else { 'Menu' })"
    )
}

$hostDirect = (Get-DirectHostEvents "Direct" $true) + @(
    "t|host_direct_final|role=host|scenario=direct|peerInLobby=false|peerConnectionPresent=true|peerAuthenticated=true|lobbyMembers=1"
)
$clientDirect = Get-DirectClientEvents "Direct" $true
$fixture = New-Fixture "direct-baseline" "Direct" "Baseline" $hostDirect $clientDirect
Invoke-Fixture $fixture "Direct" "Baseline" "VERDICT|DirectAdmissionConfirmed|"

$hostAdmission = (Get-DirectHostEvents "Direct" $false) + @(
    "t|host_direct_final|role=host|scenario=direct|peerInLobby=false|peerConnectionPresent=false|peerAuthenticated=null|lobbyMembers=1"
)
$clientAdmission = Get-DirectClientEvents "Direct" $false
$fixture = New-Fixture "direct-protected" "Direct" "AdmissionGate" $hostAdmission $clientAdmission @(
    "[S1NetGuard] Rejected SteamID $clientId (NotInCurrentLobby, connection 1)."
)
Invoke-Fixture $fixture "Direct" "AdmissionGate" "VERDICT|AdmissionGateRejectedNonMember|"

$hostImpact = (Get-DirectHostEvents "Impact" $true) + @(
    "t|host_direct_final|role=host|scenario=impact|peerInLobby=false|peerConnectionPresent=true|peerAuthenticated=true|lobbyMembers=1",
    "t|host_money_rpc_logic_after|role=host|scenario=impact|onlineBalanceBefore=0|onlineBalanceAfter=-123.45|expectedDelta=-123.45|applied=true",
    "t|host_dialogue_rpc_logic|role=host|scenario=impact|npcId=test|npcObjectId=3|text=S1NG controlled dialogue proof|duration=3",
    "t|host_combat_rpc_logic|role=host|scenario=impact|npcId=test|targetObjectId=4",
    "t|host_impact_runtime_final|role=host|scenario=impact|moneyApplied=true|moneyBefore=0|moneyAfter=-123.45|dialogueApplied=true|combatApplied=true|npcId=test",
    "t|host_impact_persistence_final|role=host|scenario=impact|moneyPath=x|persisted=true|persistedOnlineBalance=-123.45|runtimeOnlineBalance=-123.45"
)
$clientImpact = (Get-DirectClientEvents "Impact" $true) + @(
    "t|client_impact_sent|role=client|scenario=impact|moneyDelta=-123.45|dialogue=S1NG controlled dialogue proof|npcId=test|targetObjectId=4",
    "t|client_impact_after|role=client|scenario=impact|onlineBalance=-123.45"
)
$fixture = New-Fixture "impact-baseline" "Impact" "Baseline" $hostImpact $clientImpact
Invoke-Fixture $fixture "Impact" "Baseline" "VERDICT|ImpactConfirmed|"

$hostRpcDefense = (Get-DirectHostEvents "Impact" $true) + @(
    "t|host_direct_final|role=host|scenario=impact|peerInLobby=false|peerConnectionPresent=true|peerAuthenticated=true|lobbyMembers=1",
    "t|host_impact_blocked_runtime_final|role=host|scenario=impact|onlineBalance=0|moneySinkObserved=false|dialogueLogicPrefixObserved=true|combatLogicPrefixObserved=true",
    "t|host_impact_blocked_persistence_final|role=host|scenario=impact|moneyPath=x|persisted=true|persistedOnlineBalance=0|runtimeOnlineBalance=0"
)
$clientRpcDefense = (Get-DirectClientEvents "Impact" $true) + @(
    "t|client_impact_sent|role=client|scenario=impact|moneyDelta=-123.45|dialogue=S1NG controlled dialogue proof|npcId=test|targetObjectId=4",
    "t|client_impact_after|role=client|scenario=impact|onlineBalance=0"
)
$fixture = New-Fixture "impact-protected" "Impact" "RpcDefense" $hostRpcDefense $clientRpcDefense @(
    "[S1NetGuard] Blocked remote shared-money mutation RPC from SteamID $clientId",
    "[S1NetGuard] Blocked remote free-text worldspace dialogue RPC from SteamID $clientId",
    "[S1NetGuard] Blocked remote NPC target control RPC from SteamID $clientId"
)
Invoke-Fixture $fixture "Impact" "RpcDefense" "VERDICT|RpcDefenseBlockedImpact|"

$negativePassed = $false
try {
    & $verifier `
        -HostRunPath $fixture.Host `
        -ClientRunPath $fixture.Client `
        -HostSteamId $hostId `
        -ClientSteamId "76561198000000073" `
        -LobbyId $lobbyId `
        -Scenario Impact `
        -Protection RpcDefense | Out-Null
}
catch {
    if ($_.Exception.Message -like "INCONCLUSIVE:*") {
        $negativePassed = $true
    }
}
if (-not $negativePassed) {
    throw "Verifier accepted a mismatched asserted client SteamID."
}
Write-Output "PASS|Fixture|RejectsMismatchedIdentity"
Write-Output "PASS|S1NetGuard.LiveValveVerifierFixtures|root=$OutputRoot"
