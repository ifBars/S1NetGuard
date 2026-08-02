using System.Reflection;
using HarmonyLib;
using MelonLoader;
using S1NetGuard.Runtime;
using S1NetGuard.Security;
#if MONO
using RemoteConnectionState = FishNet.Transporting.RemoteConnectionState;
using RemoteConnectionStateArgs = FishNet.Transporting.RemoteConnectionStateArgs;
using ServerManager = FishNet.Managing.Server.ServerManager;
using SteamUser = Steamworks.SteamUser;
#else
using RemoteConnectionState = Il2CppFishNet.Transporting.RemoteConnectionState;
using RemoteConnectionStateArgs = Il2CppFishNet.Transporting.RemoteConnectionStateArgs;
using ServerManager = Il2CppFishNet.Managing.Server.ServerManager;
using SteamUser = Il2CppSteamworks.SteamUser;
#endif

namespace S1NetGuard.Patches;

[HarmonyPatch]
internal static class ServerAdmissionPatch
{
    private static MethodBase TargetMethod()
    {
        return AccessTools.Method(
            typeof(ServerManager),
            "Transport_OnRemoteConnectionState",
            new[] { typeof(RemoteConnectionStateArgs) });
    }

    private static bool Prefix(ServerManager __instance, RemoteConnectionStateArgs args)
    {
        if (!NetGuardPreferences.EnableAdmissionGate.Value ||
            args.ConnectionState != RemoteConnectionState.Started)
        {
            return true;
        }

        string? transportAddress = null;
        try
        {
            transportAddress = __instance.NetworkManager.TransportManager.Transport
                .GetConnectionAddress(args.ConnectionId);
        }
        catch (Exception exception)
        {
            MelonLogger.Warning($"{Constants.LogPrefix} Could not read transport identity: {exception.Message}");
        }

        bool lobbyAvailable = LobbyAccess.TryGetMemberIds(out string[] lobbyMemberIds);
        AdmissionPolicy.TryParseSteamId(transportAddress, out ulong transportSteamId);
        bool isSteamFriend = LobbyAccess.IsImmediateSteamFriend(transportSteamId);
        AdmissionDecision decision = AdmissionPolicy.Evaluate(
            args.ConnectionId,
            transportAddress,
            SteamUser.GetSteamID().m_SteamID,
            lobbyAvailable,
            lobbyMemberIds,
            isSteamFriend,
            NetGuardPreferences.TrustSteamFriendsInLobby.Value,
            NetGuardPreferences.TrustAllCurrentLobbyMembers.Value,
            ConnectionRegistry.ExplicitlyAllowedSteamIds,
            ConnectionRegistry.DeniedSteamIds,
            NetGuardPreferences.FailClosedWhenLobbyUnavailable.Value);

        if (decision.Allowed)
        {
            if (decision.Reason != AdmissionReason.LocalHost)
            {
                MelonLogger.Msg(
                    $"{Constants.LogPrefix} Admitted SteamID {decision.SteamId} " +
                    $"({decision.Reason}, connection {args.ConnectionId}).");
            }

            return true;
        }

        ConnectionRegistry.Deny(decision.SteamId);
        MelonLogger.Warning(
            $"{Constants.LogPrefix} Rejected SteamID {decision.SteamId} " +
            $"({decision.Reason}, connection {args.ConnectionId}).");

        try
        {
            __instance.NetworkManager.TransportManager.Transport.StopConnection(args.ConnectionId, true);
        }
        catch (Exception exception)
        {
            MelonLogger.Error($"{Constants.LogPrefix} Failed to close rejected connection: {exception}");
        }

        return false;
    }
}
