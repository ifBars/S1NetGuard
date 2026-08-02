[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MonoGamePath,

    [Parameter(Mandatory = $true)]
    [string]$Il2CppGamePath
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command ilspycmd -ErrorAction SilentlyContinue)) {
    throw "ilspycmd is required for game-surface verification."
}

$targets = @(
    @{ Runtime = "Mono"; Assembly = (Join-Path $MonoGamePath "Schedule I_Data\Managed\FishNet.Runtime.dll"); Type = "FishNet.Managing.Server.ServerManager"; Patterns = @("Transport_OnRemoteConnectionState", "authenticator.OnRemoteConnection", "ClientAuthenticated", "SetAuthenticator") },
    @{ Runtime = "IL2CPP"; Assembly = (Join-Path $Il2CppGamePath "MelonLoader\Il2CppAssemblies\Il2CppFishNet.Runtime.dll"); Type = "Il2CppFishNet.Managing.Server.ServerManager"; Patterns = @("Transport_OnRemoteConnectionState", "ClientAuthenticated", "SetAuthenticator") },
    @{ Runtime = "Mono"; Assembly = (Join-Path $MonoGamePath "Schedule I_Data\Managed\FishNet.Runtime.dll"); Type = "FishNet.Authenticating.Authenticator"; Patterns = @("OnAuthenticationResult", "OnRemoteConnection") },
    @{ Runtime = "IL2CPP"; Assembly = (Join-Path $Il2CppGamePath "MelonLoader\Il2CppAssemblies\Il2CppFishNet.Runtime.dll"); Type = "Il2CppFishNet.Authenticating.Authenticator"; Patterns = @("OnAuthenticationResult", "OnRemoteConnection") },
    @{ Runtime = "Mono"; Assembly = (Join-Path $MonoGamePath "Schedule I_Data\Managed\Assembly-CSharp.dll"); Type = "ScheduleOne.Persistence.LoadManager"; Patterns = @("LoadAsClient", "InstanceFinder.ClientManager.StartConnection(steamId64)") },
    @{ Runtime = "IL2CPP"; Assembly = (Join-Path $Il2CppGamePath "MelonLoader\Il2CppAssemblies\Assembly-CSharp.dll"); Type = "Il2CppScheduleOne.Persistence.LoadManager"; Patterns = @("LoadAsClient") },
    @{ Runtime = "Mono"; Assembly = (Join-Path $MonoGamePath "Schedule I_Data\Managed\Assembly-CSharp.dll"); Type = "ScheduleOne.Money.MoneyManager"; Patterns = @("RpcReader___Server_CreateOnlineTransaction_", "RpcLogic___CreateOnlineTransaction_") },
    @{ Runtime = "IL2CPP"; Assembly = (Join-Path $Il2CppGamePath "MelonLoader\Il2CppAssemblies\Assembly-CSharp.dll"); Type = "Il2CppScheduleOne.Money.MoneyManager"; Patterns = @("RpcReader___Server_CreateOnlineTransaction_", "RpcLogic___CreateOnlineTransaction_") },
    @{ Runtime = "Mono"; Assembly = (Join-Path $MonoGamePath "Schedule I_Data\Managed\Assembly-CSharp.dll"); Type = "ScheduleOne.NPCs.NPC"; Patterns = @("RpcReader___Server_SendWorldSpaceDialogue_", "RpcLogic___SendWorldSpaceDialogue_") },
    @{ Runtime = "IL2CPP"; Assembly = (Join-Path $Il2CppGamePath "MelonLoader\Il2CppAssemblies\Assembly-CSharp.dll"); Type = "Il2CppScheduleOne.NPCs.NPC"; Patterns = @("RpcReader___Server_SendWorldSpaceDialogue_", "RpcLogic___SendWorldSpaceDialogue_") },
    @{ Runtime = "Mono"; Assembly = (Join-Path $MonoGamePath "Schedule I_Data\Managed\Assembly-CSharp.dll"); Type = "ScheduleOne.PlayerScripts.Player"; Patterns = @("RpcReader___Server_SendWorldSpaceDialogue_", "RpcLogic___SendWorldSpaceDialogue_") },
    @{ Runtime = "IL2CPP"; Assembly = (Join-Path $Il2CppGamePath "MelonLoader\Il2CppAssemblies\Assembly-CSharp.dll"); Type = "Il2CppScheduleOne.PlayerScripts.Player"; Patterns = @("RpcReader___Server_SendWorldSpaceDialogue_", "RpcLogic___SendWorldSpaceDialogue_") },
    @{ Runtime = "Mono"; Assembly = (Join-Path $MonoGamePath "Schedule I_Data\Managed\Assembly-CSharp.dll"); Type = "ScheduleOne.Combat.CombatBehaviour"; Patterns = @("RpcReader___Server_SetTargetAndEnable_Server_", "RpcLogic___SetTargetAndEnable_Server_") },
    @{ Runtime = "IL2CPP"; Assembly = (Join-Path $Il2CppGamePath "MelonLoader\Il2CppAssemblies\Assembly-CSharp.dll"); Type = "Il2CppScheduleOne.Combat.CombatBehaviour"; Patterns = @("RpcReader___Server_SetTargetAndEnable_Server_", "RpcLogic___SetTargetAndEnable_Server_") },
    @{ Runtime = "Mono"; Assembly = (Join-Path $MonoGamePath "Schedule I_Data\Managed\Assembly-CSharp.dll"); Type = "ScheduleOne.Networking.SteamLobbyService"; Patterns = @("CreateLobby", "k_ELobbyTypeFriendsOnly", "PlayerEnterOrLeave", "m_ulSteamIDUserChanged") },
    @{ Runtime = "IL2CPP"; Assembly = (Join-Path $Il2CppGamePath "MelonLoader\Il2CppAssemblies\Assembly-CSharp.dll"); Type = "Il2CppScheduleOne.Networking.SteamLobbyService"; Patterns = @("CreateLobby", "PlayerEnterOrLeave", "LobbyChatUpdate_t") }
)

$verified = 0
foreach ($target in $targets) {
    $assembly = [System.IO.Path]::GetFullPath($target.Assembly)
    if (-not (Test-Path -LiteralPath $assembly -PathType Leaf)) {
        throw "Missing $($target.Runtime) assembly: $assembly"
    }

    $surface = (& ilspycmd -t $target.Type $assembly 2>$null) -join "`n"
    foreach ($pattern in $target.Patterns) {
        if ($surface.IndexOf($pattern, [System.StringComparison]::Ordinal) -lt 0) {
            throw "Missing $($target.Runtime) surface $($target.Type).$pattern"
        }
    }

    $verified++
}

$monoHash = (Get-FileHash -LiteralPath (Join-Path $MonoGamePath "Schedule I_Data\Managed\Assembly-CSharp.dll") -Algorithm SHA256).Hash
$il2CppHash = (Get-FileHash -LiteralPath (Join-Path $Il2CppGamePath "MelonLoader\Il2CppAssemblies\Assembly-CSharp.dll") -Algorithm SHA256).Hash
Write-Output "PASS|S1NetGuard.GameSurface|$verified targets|Mono=$monoHash|IL2CPP=$il2CppHash"
