using HarmonyLib;
using MelonLoader;
using S1NetGuard.Runtime;
#if MONO
using ScheduleOne.Networking;
using Steamworks;
#else
using Il2CppScheduleOne.Networking;
using Il2CppSteamworks;
#endif

namespace S1NetGuard.Patches;

[HarmonyPatch(typeof(SteamLobbyService), "PlayerEnterOrLeave")]
internal static class LobbyAuditPatch
{
    private static void Prefix(LobbyChatUpdate_t result)
    {
        ulong changedSteamId = result.m_ulSteamIDUserChanged;
        ulong actorSteamId = result.m_ulSteamIDMakingChange;
        var state = (EChatMemberStateChange)result.m_rgfChatMemberStateChange;
        bool isFriend = LobbyAccess.IsImmediateSteamFriend(changedSteamId);

        MelonLogger.Msg(
            $"{Constants.LogPrefix} Lobby member update: changedSteamId={changedSteamId}, " +
            $"actorSteamId={actorSteamId}, lobbyId={result.m_ulSteamIDLobby}, " +
            $"state={state}, immediateFriend={isFriend}.");
    }
}
