[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$HostRunPath,

    [Parameter(Mandatory = $true)]
    [string]$ClientRunPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^7656119[0-9]{10}$')]
    [string]$HostSteamId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^7656119[0-9]{10}$')]
    [string]$ClientSteamId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9]{15,20}$')]
    [string]$LobbyId,

    [ValidateSet("Lobby", "Direct", "Impact")]
    [string]$Scenario = "Lobby",

    [ValidateSet("Baseline", "AdmissionGate", "RpcDefense")]
    [string]$Protection = "Baseline"
)

$ErrorActionPreference = "Stop"

function Read-RequiredFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "INCONCLUSIVE: required evidence file not found: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw
}

function Require-Match {
    param([string]$Text, [string]$Pattern, [string]$Description)

    if ($Text -notmatch $Pattern) {
        throw "INCONCLUSIVE: missing $Description"
    }
}

function Require-NoMatch {
    param([string]$Text, [string]$Pattern, [string]$Description)

    if ($Text -match $Pattern) {
        throw "INCONCLUSIVE: unexpected $Description"
    }
}

function Read-ManifestValue {
    param([string]$Text, [string]$Name)

    $match = [regex]::Match($Text, "(?m)^$([regex]::Escape($Name))=(?<value>[^\r\n]*)\r?$")
    if (-not $match.Success) {
        throw "INCONCLUSIVE: manifest field missing: $Name"
    }
    return $match.Groups['value'].Value
}

if ($HostSteamId -eq $ClientSteamId) {
    throw "INCONCLUSIVE: host and client SteamIDs must differ."
}
if ($Protection -eq "AdmissionGate" -and $Scenario -ne "Direct") {
    throw "INCONCLUSIVE: AdmissionGate protection is valid only for Direct."
}
if ($Protection -eq "RpcDefense" -and $Scenario -ne "Impact") {
    throw "INCONCLUSIVE: RpcDefense protection is valid only for Impact."
}
if ($Scenario -eq "Lobby" -and $Protection -ne "Baseline") {
    throw "INCONCLUSIVE: Lobby must be a baseline control."
}

$hostPath = [System.IO.Path]::GetFullPath($HostRunPath)
$clientPath = [System.IO.Path]::GetFullPath($ClientRunPath)
$hostEvents = Read-RequiredFile (Join-Path $hostPath "host-events.txt")
$clientEvents = Read-RequiredFile (Join-Path $clientPath "client-events.txt")
$hostManifest = Read-RequiredFile (Join-Path $hostPath "manifest.txt")
$clientManifest = Read-RequiredFile (Join-Path $clientPath "manifest.txt")

foreach ($entry in @(
    @{ Name = 'backend'; Host = 'ValveSteam'; Client = 'ValveSteam' },
    @{ Name = 'runtime'; Host = 'Mono'; Client = 'Mono' },
    @{ Name = 'scenario'; Host = $Scenario; Client = $Scenario },
    @{ Name = 'protection'; Host = $Protection; Client = 'Baseline' },
    @{ Name = 'role'; Host = 'Host'; Client = 'Client' },
    @{ Name = 'expectedPeerSteamId'; Host = $ClientSteamId; Client = $HostSteamId }
)) {
    $hostValue = Read-ManifestValue $hostManifest $entry.Name
    $clientValue = Read-ManifestValue $clientManifest $entry.Name
    if ($hostValue -ne $entry.Host -or $clientValue -ne $entry.Client) {
        throw "INCONCLUSIVE: manifest $($entry.Name) mismatch."
    }
}

if ((Read-ManifestValue $clientManifest 'suppliedHostSteamId') -ne $HostSteamId -or
    (Read-ManifestValue $clientManifest 'suppliedLobbyId') -ne $LobbyId) {
    throw "INCONCLUSIVE: client handoff values do not match the asserted host and lobby."
}

$hashNames = @(
    'assemblySha256',
    'fishNetSha256',
    'steamworksNetSha256',
    'melonLoaderSha256',
    'steamApiSha256',
    'probeSha256'
)
foreach ($hashName in $hashNames) {
    $hostHash = Read-ManifestValue $hostManifest $hashName
    $clientHash = Read-ManifestValue $clientManifest $hashName
    if ($hostHash -notmatch '^[A-F0-9]{64}$' -or $clientHash -notmatch '^[A-F0-9]{64}$') {
        throw "INCONCLUSIVE: invalid $hashName value."
    }
    if ($hostHash -ne $clientHash) {
        throw "INCONCLUSIVE: host and client $hashName values differ."
    }
}

$hostGuardHash = Read-ManifestValue $hostManifest 'guardSha256'
$clientGuardHash = Read-ManifestValue $clientManifest 'guardSha256'
$hostProtectionConfigHash = Read-ManifestValue $hostManifest 'protectionConfigSha256'
$clientProtectionConfigHash = Read-ManifestValue $clientManifest 'protectionConfigSha256'
if ($clientGuardHash -ne 'none') {
    throw "INCONCLUSIVE: the controlled client must not load S1NetGuard."
}
if ($clientProtectionConfigHash -ne 'none') {
    throw "INCONCLUSIVE: the controlled client must not apply a protection configuration."
}
if ($Protection -eq 'Baseline') {
    if ($hostGuardHash -ne 'none' -or $hostProtectionConfigHash -ne 'none') {
        throw "INCONCLUSIVE: baseline host unexpectedly records protection artifacts."
    }
}
else {
    if ($hostGuardHash -notmatch '^[A-F0-9]{64}$' -or $hostProtectionConfigHash -notmatch '^[A-F0-9]{64}$') {
        throw "INCONCLUSIVE: protected host guard or configuration hash is missing or invalid."
    }
    $protectionConfigPath = Join-Path $hostPath 'applied-protection.cfg'
    $protectionConfig = Read-RequiredFile $protectionConfigPath
    if ((Get-FileHash -LiteralPath $protectionConfigPath -Algorithm SHA256).Hash -ne $hostProtectionConfigHash) {
        throw "INCONCLUSIVE: applied protection configuration hash differs from the manifest."
    }
    Require-Match $protectionConfig "(?m)^EnableAdmissionGate = true\r?$" "enabled admission gate configuration"
    Require-Match $protectionConfig "(?m)^EnableRpcDefenseInDepth = true\r?$" "enabled RPC defense configuration"
    Require-Match $protectionConfig "(?m)^DisconnectOnRpcViolation = false\r?$" "non-disconnecting RPC control configuration"
    if ($Protection -eq 'AdmissionGate') {
        Require-Match $protectionConfig '(?m)^AllowedSteamIds = ""\r?$' "empty admission allowlist"
    }
    else {
        Require-Match $protectionConfig "(?m)^AllowedSteamIds = `"$ClientSteamId`"\r?$" "controlled client RPC-defense allowlist"
    }
}

$hostAssemblyHash = Read-ManifestValue $hostManifest 'assemblySha256'
Require-Match $hostEvents "(?m)\|probe_initialized\|.*applicationVersion=(?<version>[^|\r\n]+)(?:\||\r?$)" "host application version"
Require-Match $clientEvents "(?m)\|probe_initialized\|.*applicationVersion=(?<version>[^|\r\n]+)(?:\||\r?$)" "client application version"
$hostVersion = [regex]::Match($hostEvents, "(?m)\|probe_initialized\|.*applicationVersion=(?<version>[^|\r\n]+)(?:\||\r?$)").Groups['version'].Value
$clientVersion = [regex]::Match($clientEvents, "(?m)\|probe_initialized\|.*applicationVersion=(?<version>[^|\r\n]+)(?:\||\r?$)").Groups['version'].Value
if ($hostVersion -ne $clientVersion) {
    throw "INCONCLUSIVE: host and client application versions differ."
}

Require-Match $hostEvents "(?m)\|steam_ready\|.*localSteamId=$HostSteamId\|.*expectedPeerSteamId=$ClientSteamId\|expectedPeerIsImmediateFriend=false\|" "host identity and non-friend result"
Require-Match $clientEvents "(?m)\|steam_ready\|.*localSteamId=$ClientSteamId\|.*expectedPeerSteamId=$HostSteamId\|expectedPeerIsImmediateFriend=false\|" "client identity and non-friend result"
Require-Match $hostEvents "(?m)\|host_create_lobby_requested\|.*requestedType=k_ELobbyTypeFriendsOnly(?:\||\r?$)" "FriendsOnly creation request"
Require-Match $hostEvents "(?m)\|steam_create_lobby_api\|.*requestedType=k_ELobbyTypeFriendsOnly\|maxMembers=4(?:\||\r?$)" "actual FriendsOnly Steam API call"
Require-Match $hostEvents "(?m)\|lobby_created_callback\|.*result=k_EResultOK\|lobbyId=$LobbyId\|localSteamId=$HostSteamId(?:\||\r?$)" "successful host lobby callback"

if ($Scenario -eq 'Lobby') {
    Require-Match $clientEvents "(?m)\|client_join_lobby_requested\|.*lobbyId=$LobbyId(?:\||\r?$)" "client JoinLobby request"
    Require-Match $clientEvents "(?m)\|steam_join_lobby_api\|.*lobbyId=$LobbyId(?:\||\r?$)" "actual Steam JoinLobby API call"
    Require-Match $clientEvents "(?m)\|lobby_enter_callback\|.*lobbyId=$LobbyId\|.*response=(?<response>[^|]+)\|responseRaw=(?<raw>[0-9]+)(?:\||\r?$)" "client LobbyEnter_t result"
    Require-Match $hostEvents "(?m)\|host_lobby_final\|.*lobbyId=$LobbyId\|.*memberCount=(?<count>[0-9]+)\|memberIds=(?<members>[^\r\n]*)(?:\||\r?$)" "host final lobby snapshot"
    Require-Match $clientEvents "(?m)\|client_lobby_final\|.*lobbyId=$LobbyId\|isInLobby=(?<joined>true|false)\|.*memberCount=(?<clientCount>[0-9]+)\|memberIds=(?<clientMembers>[^\r\n]*)(?:\||\r?$)" "client final lobby snapshot"

    $enterMatch = [regex]::Match($clientEvents, "(?m)\|lobby_enter_callback\|.*lobbyId=$LobbyId\|.*response=(?<response>[^|]+)\|responseRaw=(?<raw>[0-9]+)(?:\||\r?$)")
    $hostFinal = [regex]::Match($hostEvents, "(?m)\|host_lobby_final\|.*lobbyId=$LobbyId\|.*memberCount=(?<count>[0-9]+)\|memberIds=(?<members>[^\r\n]*)(?:\||\r?$)")
    $clientFinal = [regex]::Match($clientEvents, "(?m)\|client_lobby_final\|.*lobbyId=$LobbyId\|isInLobby=(?<joined>true|false)\|.*memberCount=(?<clientCount>[0-9]+)\|memberIds=(?<clientMembers>[^\r\n]*)(?:\||\r?$)")
    $response = $enterMatch.Groups['response'].Value
    $responseRaw = $enterMatch.Groups['raw'].Value
    $hostMembers = @($hostFinal.Groups['members'].Value.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries))
    $clientMembers = @($clientFinal.Groups['clientMembers'].Value.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries))
    $clientJoined = $clientFinal.Groups['joined'].Value -eq 'true'
    $hostSawEntered = $hostEvents -match "(?m)\|lobby_chat_update_callback\|.*lobbyId=$LobbyId\|changedSteamId=$ClientSteamId\|actorSteamId=$ClientSteamId\|state=k_EChatMemberStateChangeEntered\|stateRaw=1(?:\||\r?$)"

    if ($response -eq 'k_EChatRoomEnterResponseSuccess') {
        if (-not $clientJoined -or -not $hostSawEntered -or $ClientSteamId -notin $hostMembers -or $HostSteamId -notin $clientMembers) {
            throw "INCONCLUSIVE: LobbyEnter_t reported success but callbacks or final member lists disagree."
        }
        Write-Output "VERDICT|ValveAcceptedUnrelatedIdentity|lobbyId=$LobbyId|response=$response|responseRaw=$responseRaw|applicationVersion=$hostVersion|assemblySha256=$hostAssemblyHash"
        exit 0
    }

    if ($clientJoined -or $hostSawEntered -or $ClientSteamId -in $hostMembers) {
        throw "INCONCLUSIVE: LobbyEnter_t reported $response but host/client membership evidence indicates entry."
    }
    if ($response -ne 'k_EChatRoomEnterResponseNotAllowed') {
        throw "INCONCLUSIVE: LobbyEnter_t returned $response ($responseRaw), which does not specifically prove FriendsOnly enforcement."
    }
    if ($hostMembers.Count -ne 1 -or $hostMembers[0] -ne $HostSteamId) {
        throw "INCONCLUSIVE: denied control ended with an unexpected host member list."
    }

    Write-Output "VERDICT|ValveEnforcedFriendsOnly|lobbyId=$LobbyId|response=$response|responseRaw=$responseRaw|applicationVersion=$hostVersion|assemblySha256=$hostAssemblyHash"
    exit 0
}

Require-NoMatch $clientEvents "(?m)\|client_join_lobby_requested\|" "JoinLobby request in direct scenario"
Require-NoMatch $clientEvents "(?m)\|steam_join_lobby_api\|" "Steam JoinLobby API call in direct scenario"
Require-NoMatch $clientEvents "(?m)\|lobby_enter_callback\|.*lobbyId=$LobbyId\|" "LobbyEnter_t callback in direct scenario"
Require-NoMatch $hostEvents "(?m)\|lobby_chat_update_callback\|.*lobbyId=$LobbyId\|changedSteamId=$ClientSteamId\|.*state=k_EChatMemberStateChangeEntered\|" "client lobby-entry callback in direct scenario"
Require-Match $hostEvents "(?m)\|fishnet_authenticator_state\|.*readSucceeded=true\|configured=false\|authenticatorType=none(?:\||\r?$)" "empty FishNet authenticator at server startup"
Require-Match $hostEvents "(?m)\|host_direct_ready\|.*lobbyId=$LobbyId\|isInLobby=true\|isHost=true\|memberCount=1\|memberIds=$HostSteamId(?:\||\r?$)" "host-only lobby snapshot before direct connection"
Require-Match $clientEvents "(?m)\|client_host_ready\|.*hostSteamId=$HostSteamId\|lobbyId=$LobbyId\|clientInLobbyBeforeAction=false(?:\||\r?$)" "client non-membership before direct action"
Require-Match $clientEvents "(?m)\|client_direct_start\|.*hostSteamId=$HostSteamId\|clientInLobby=false(?:\||\r?$)" "direct LoadAsClient start"
Require-Match $hostEvents "(?m)\|fishnet_remote_started\|.*transportAddress=$ClientSteamId\|peerInLobby=false(?:\||\r?$)" "non-member FishNet transport start"
Require-Match $hostEvents "(?m)\|host_direct_final\|.*peerInLobby=false\|peerConnectionPresent=(?<present>true|false)\|peerAuthenticated=(?<authenticated>true|false|null)\|lobbyMembers=1(?:\||\r?$)" "host direct final state"
Require-Match $clientEvents "(?m)\|client_direct_final\|.*clientInLobby=false\|fishNetClient=(?<fishnet>true|false)\|localPlayerSpawned=(?<spawned>true|false)\|gameLoaded=(?<loaded>true|false)\|authenticated=(?<clientAuthenticated>true|false|null)\|" "client direct final state"

$hostDirect = [regex]::Match($hostEvents, "(?m)\|host_direct_final\|.*peerInLobby=false\|peerConnectionPresent=(?<present>true|false)\|peerAuthenticated=(?<authenticated>true|false|null)\|lobbyMembers=1(?:\||\r?$)")
$clientDirect = [regex]::Match($clientEvents, "(?m)\|client_direct_final\|.*clientInLobby=false\|fishNetClient=(?<fishnet>true|false)\|localPlayerSpawned=(?<spawned>true|false)\|gameLoaded=(?<loaded>true|false)\|authenticated=(?<clientAuthenticated>true|false|null)\|")
$hostAuthenticatedEvent = $hostEvents -match "(?m)\|fishnet_client_authenticated\|.*transportAddress=$ClientSteamId\|peerInLobby=false\|authenticatedBeforeCall=false(?:\||\r?$)"

if ($Protection -eq 'AdmissionGate') {
    $hostMelon = Read-RequiredFile (Join-Path $hostPath "host-melon.log")
    Require-Match $hostMelon "Rejected SteamID $ClientSteamId \(NotInCurrentLobby, connection" "S1NetGuard non-member rejection"
    if ($hostAuthenticatedEvent) {
        throw "INCONCLUSIVE: protected non-member reached FishNet authentication."
    }
    if ($hostDirect.Groups['present'].Value -ne 'false' -or
        $clientDirect.Groups['spawned'].Value -ne 'false' -or
        $clientDirect.Groups['loaded'].Value -ne 'false' -or
        $clientDirect.Groups['clientAuthenticated'].Value -eq 'true') {
        throw "INCONCLUSIVE: admission-gate result contains a loaded or authenticated client state."
    }

    Write-Output "VERDICT|AdmissionGateRejectedNonMember|lobbyId=$LobbyId|applicationVersion=$hostVersion|assemblySha256=$hostAssemblyHash|guardSha256=$hostGuardHash"
    exit 0
}

if (-not $hostAuthenticatedEvent -or
    $hostDirect.Groups['present'].Value -ne 'true' -or
    $hostDirect.Groups['authenticated'].Value -ne 'true' -or
    $clientDirect.Groups['fishnet'].Value -ne 'true' -or
    $clientDirect.Groups['spawned'].Value -ne 'true' -or
    $clientDirect.Groups['loaded'].Value -ne 'true' -or
    $clientDirect.Groups['clientAuthenticated'].Value -ne 'true') {
    throw "INCONCLUSIVE: direct peer did not reach the complete authenticated and loaded game state."
}

if ($Scenario -eq 'Direct') {
    Write-Output "VERDICT|DirectAdmissionConfirmed|lobbyId=$LobbyId|applicationVersion=$hostVersion|assemblySha256=$hostAssemblyHash"
    exit 0
}

Require-Match $clientEvents "(?m)\|client_impact_sent\|.*moneyDelta=-123\.45\|dialogue=S1NG controlled dialogue proof\|" "controlled client impact requests"

if ($Protection -eq 'RpcDefense') {
    $hostMelon = Read-RequiredFile (Join-Path $hostPath "host-melon.log")
    foreach ($capability in @('shared-money mutation', 'free-text worldspace dialogue', 'NPC target control')) {
        Require-Match $hostMelon "Blocked remote $([regex]::Escape($capability)) RPC from SteamID $ClientSteamId" "$capability defense log"
    }
    Require-Match $hostEvents "(?m)\|host_impact_blocked_runtime_final\|.*onlineBalance=0\|.*moneySinkObserved=false\|.*dialogueLogicPrefixObserved=(?:true|false)\|combatLogicPrefixObserved=(?:true|false)(?:\||\r?$)" "unchanged protected runtime balance"
    Require-Match $hostEvents "(?m)\|host_impact_blocked_persistence_final\|.*persisted=true\|persistedOnlineBalance=0\|runtimeOnlineBalance=0(?:\||\r?$)" "unchanged protected persisted balance"

    Write-Output "VERDICT|RpcDefenseBlockedImpact|lobbyId=$LobbyId|applicationVersion=$hostVersion|assemblySha256=$hostAssemblyHash|guardSha256=$hostGuardHash"
    exit 0
}

Require-Match $hostEvents "(?m)\|host_money_rpc_logic_after\|.*onlineBalanceBefore=0\|onlineBalanceAfter=-123\.45\|expectedDelta=-123\.45\|applied=true(?:\||\r?$)" "host shared-money mutation"
Require-Match $hostEvents "(?m)\|host_dialogue_rpc_logic\|.*text=S1NG controlled dialogue proof\|duration=3(?:\||\r?$)" "host dialogue execution"
Require-Match $hostEvents "(?m)\|host_combat_rpc_logic\|" "host NPC target-control execution"
Require-Match $hostEvents "(?m)\|host_impact_runtime_final\|.*moneyApplied=true\|moneyBefore=0\|moneyAfter=-123\.45\|dialogueApplied=true\|combatApplied=true\|" "complete host impact state"
Require-Match $hostEvents "(?m)\|host_impact_persistence_final\|.*persisted=true\|persistedOnlineBalance=-123\.45\|runtimeOnlineBalance=-123\.45(?:\||\r?$)" "persisted shared-money mutation"

Write-Output "VERDICT|ImpactConfirmed|lobbyId=$LobbyId|moneyBefore=0|moneyAfter=-123.45|persistedOnlineBalance=-123.45|applicationVersion=$hostVersion|assemblySha256=$hostAssemblyHash"
